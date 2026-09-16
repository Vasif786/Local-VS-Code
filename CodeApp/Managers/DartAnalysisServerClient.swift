//
//  DartAnalysisServerClient.swift
//  Code
//
//  A persistent LSP (Language Server Protocol) client for the REAL remote
//  Dart Analysis Server (`dart language-server --protocol=lsp`), connected
//  over a dedicated, long-lived SSH channel using the app's existing SSH
//  credentials (see `RemoteAuthenticationMode` / `currentRemoteConnectionInfo`
//  in WorkSpaceStorage — nothing new is added there).
//
//  This is deliberately additive to DartHybridIntelliSense.swift, not a
//  replacement of it:
//   - The one-shot `dart analyze` path in DartHybridIntelliSense remains the
//     fallback whenever this client isn't connected yet (SDK not found,
//     still starting, or the SSH link dropped) — diagnostics never
//     disappear silently while this connects or reconnects.
//   - Hover, go-to-definition, real analyzer-backed completion, and quick
//     fixes are ONLY available through this client. There is no
//     regex/fake substitute for any of them.
//
//  Transport: NEVER shares a session with the interactive terminal's PTY
//  channel or with the one-shot analyzer's channel (same reasoning as
//  `OneShotSSHCommandRunner` in DartHybridIntelliSense.swift — NMSSH is not
//  documented as safe for concurrent multi-channel use from different
//  threads). This client owns one dedicated channel for the lifetime of the
//  connection, running `dart language-server --protocol=lsp` remotely and
//  speaking standard Content-Length-framed JSON-RPC over its stdio.
//
//  Known simplifications (documented rather than hidden):
//   - Full LSP text sync ("full" sync kind) is used instead of incremental
//     sync — simpler and robust to correctness, at the cost of sending the
//     whole buffer on every debounced change rather than a diff.
//   - Quick fixes are only auto-applicable when every edit in the action
//     targets the CURRENTLY OPEN document. Actions that also touch other
//     files (e.g. certain refactors) are filtered out rather than partially
//     applied, since Code App's remote editing model isn't set up for
//     atomic multi-file edits yet.
//   - `textDocument/didClose` is not sent on tab close (Code App has no
//     existing tab-close hook this file can attach to without touching
//     unrelated code); the remote analysis server simply keeps documents
//     open for the connection's lifetime, which real analysis servers
//     tolerate fine for a handful of files.
//

import Foundation
import NMSSH

// MARK: - Connection status

enum DartLSPStatus: Equatable {
    case idle
    case detectingSDK
    case starting
    case connected
    case disconnected
    case error(String)
}

// MARK: - SDK detection

/// Detects a remote Dart SDK before attempting to start the analysis
/// server. Tries a login shell first (so `~/.bashrc` / `~/.profile` PATH
/// customisations — common on Termux — are honoured), then falls back to a
/// fixed list of known Flutter SDK install locations. Also captures `dart
/// --version` output for the detected binary. Never fails silently: the
/// thrown error always names what was tried and what PATH was seen.
enum DartSDKLocator {
    struct Result {
        /// Absolute path to the `dart` executable to launch the analysis
        /// server with.
        let dartExecutable: String
        let versionOutput: String
    }

    enum LocatorError: LocalizedError {
        case connectFailed
        case notFound(path: String)

        var errorDescription: String? {
            switch self {
            case .connectFailed:
                return "Could not connect over SSH to detect the Dart SDK."
            case .notFound(let path):
                return
                    "'dart' was not found on the remote host (checked PATH and common Flutter install locations). PATH: \(path)"
            }
        }
    }

    /// Not an exhaustive list — extend here if a project lives at another
    /// well-known Flutter SDK location.
    private static let candidateFlutterRoots = [
        "/opt/flutter", "$HOME/flutter", "~/flutter",
        "/data/data/com.termux/files/usr/opt/flutter",
        "/data/data/com.termux/files/home/flutter",
    ]

    static func detect(host: URL, authenticationMode: RemoteAuthenticationMode) async throws -> Result {
        let rootChecks = candidateFlutterRoots
            .map {
                "[ -x \($0)/bin/dart ] && { V=$(\($0)/bin/dart --version 2>&1); echo FOUND:\($0)/bin/dart; echo VERSION:$V; exit 0; }; "
            }
            .joined()
        let command = """
            bash -lc '
            echo PATH_IS:$PATH;
            command -v dart >/dev/null 2>&1 && { D=$(command -v dart); V=$($D --version 2>&1); echo FOUND:$D; echo VERSION:$V; exit 0; };
            \(rootChecks)
            echo NOTFOUND
            '
            """

        print("[DartAnalyzer] Starting")
        let output: String
        do {
            output = try await OneShotSSHCommandRunner().run(
                host: host, authenticationMode: authenticationMode, command: command,
                timeoutSeconds: 15)
        } catch {
            throw LocatorError.connectFailed
        }

        var detectedPath = ""
        var seenPath = ""
        var versionOutput = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("PATH_IS:") { seenPath = String(line.dropFirst("PATH_IS:".count)) }
            if line.hasPrefix("FOUND:") {
                detectedPath = String(line.dropFirst("FOUND:".count)).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("VERSION:") {
                versionOutput = String(line.dropFirst("VERSION:".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        guard !detectedPath.isEmpty else {
            print("[DartAnalyzer] Dart SDK not found. PATH seen: \(seenPath)")
            throw LocatorError.notFound(path: seenPath)
        }

        print("[DartAnalyzer] Remote Dart detected: \(detectedPath) (\(versionOutput))")
        return Result(dartExecutable: detectedPath, versionOutput: versionOutput)
    }
}

// MARK: - Persistent SSH transport

/// A long-lived, non-interactive SSH channel used only for the Dart
/// Analysis Server process. Modeled directly on
/// `OneShotSSHCommandRunner` (same connection pattern, same dedicated
/// serial queue for NMSSH thread-safety) but never closes itself after one
/// response — it stays open for the connection's lifetime and streams raw
/// bytes both ways.
private final class PersistentSSHChannel: NSObject, NMSSHChannelDelegate {
    private static let queue = DispatchQueue(label: "dart-lsp.channel.queue")
    private var queue: DispatchQueue { Self.queue }

    private var session: NMSSHSession?
    var onData: ((Data) -> Void)?
    var onClosed: (() -> Void)?
    private var isOpen = false

    enum ChannelError: Error { case connectFailed }

    func open(host: URL, authenticationMode: RemoteAuthenticationMode, startCommand: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self = self, let hostname = host.host, let port = host.port else {
                    continuation.resume(throwing: ChannelError.connectFailed)
                    return
                }

                let session = NMSSHSession(
                    host: hostname, port: port, andUsername: authenticationMode.credentials.user ?? "")
                session.channel.delegate = self
                session.connect()
                session.timeout = 10

                switch authenticationMode {
                case .plainUsernamePassword(let credentials):
                    session.authenticate(byPassword: credentials.password ?? "")
                case .inMemorySSHKey(let credentials, let privateKeyContent):
                    session.authenticateBy(
                        inMemoryPublicKey: nil, privateKey: privateKeyContent,
                        andPassword: credentials.password)
                case .inFileSSHKey(let credentials, let _privateKeyURL):
                    let privateKeyURL =
                        _privateKeyURL ?? getRootDirectory().appendingPathComponent(".ssh/id_rsa")
                    if let privateKeyContent = try? String(contentsOf: privateKeyURL) {
                        session.authenticateBy(
                            inMemoryPublicKey: nil, privateKey: privateKeyContent,
                            andPassword: credentials.password)
                    }
                }

                guard session.isConnected, session.isAuthorized else {
                    continuation.resume(throwing: ChannelError.connectFailed)
                    return
                }

                self.session = session
                session.channel.requestPty = false
                try? session.channel.startShell()
                self.isOpen = true

                var err: NSError?
                if let data = (startCommand + "\n").data(using: .utf8) {
                    session.channel.write(data, error: &err, timeout: 5)
                }
                continuation.resume(returning: ())
            }
        }
    }

    func write(_ data: Data) {
        queue.async { [weak self] in
            guard let self = self, self.isOpen, let session = self.session else { return }
            var err: NSError?
            session.channel.write(data, error: &err, timeout: 5)
        }
    }

    func close() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isOpen = false
            self.session?.channel.closeShell()
            self.session?.disconnect()
            self.session = nil
        }
    }

    func channel(_ channel: NMSSHChannel, didReadRawData data: Data) {
        onData?(data)
    }
}

// MARK: - LSP JSON-RPC framing

/// Parses `Content-Length: N\r\n\r\n<N bytes of JSON>` frames out of a raw
/// byte stream, and builds outgoing frames the same way. Tolerant of noise
/// before the first frame (a shell prompt or startup banner printed before
/// the analysis server's first message) — it scans forward for the next
/// "Content-Length:" header rather than assuming the stream starts clean.
final class LSPMessageFramer {
    private var buffer = Data()

    func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var results: [Data] = []
        while true {
            guard let headerRange = buffer.range(of: Data("Content-Length:".utf8)) else {
                if buffer.count > 1_000_000 { buffer.removeAll() }  // bound memory if it's just noise
                break
            }
            guard
                let separatorRange = buffer.range(
                    of: Data("\r\n\r\n".utf8), options: [],
                    in: headerRange.upperBound..<buffer.endIndex)
            else {
                break  // header started but not finished yet
            }
            let headerText =
                String(data: buffer[headerRange.upperBound..<separatorRange.lowerBound], encoding: .utf8) ?? ""
            guard let length = Int(headerText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                buffer.removeSubrange(buffer.startIndex..<separatorRange.upperBound)
                continue
            }
            let bodyStart = separatorRange.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else {
                break  // body not fully received yet
            }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            results.append(Data(buffer[bodyStart..<bodyEnd]))
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        }
        return results
    }

    static func frame(_ payload: Data) -> Data {
        var out = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        out.append(payload)
        return out
    }
}

// MARK: - Analysis Server client

@MainActor
final class DartAnalysisServerClient {
    struct Diagnostic {
        let monacoSeverity: Int
        let message: String
        let line: Int  // 1-based
        let column: Int  // 1-based
        let endLine: Int
        let endColumn: Int
    }

    struct HoverResult {
        let contents: String
    }

    struct DefinitionResult {
        let path: String  // remote absolute path
        let line: Int  // 1-based
        let column: Int  // 1-based
    }

    struct CompletionResult {
        let label: String
        let kind: Int  // LSP CompletionItemKind, mapped to Monaco's on the JS side
        let detail: String?
        let documentation: String?
        let insertText: String?
    }

    struct CodeActionEdit {
        let startLine: Int
        let startColumn: Int
        let endLine: Int
        let endColumn: Int
        let newText: String
    }

    struct CodeActionResult {
        let title: String
        let edits: [CodeActionEdit]
    }

    private(set) var status: DartLSPStatus = .idle {
        didSet { onStatusChange?(status) }
    }
    var onStatusChange: ((DartLSPStatus) -> Void)?
    var onDiagnostics: ((_ uri: String, _ diagnostics: [Diagnostic]) -> Void)?

    private let channel = PersistentSSHChannel()
    private let framer = LSPMessageFramer()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var documentVersions: [String: Int] = [:]

    enum ClientError: LocalizedError {
        case notConnected
        case requestFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Dart analysis server is not connected."
            case .requestFailed(let message): return message
            case .timedOut: return "Dart analysis server did not respond in time."
            }
        }
    }

    func connect(
        host: URL, authenticationMode: RemoteAuthenticationMode, dartExecutable: String,
        projectRootPath: String
    ) async throws {
        status = .starting
        print("[DartAnalyzer] Starting")

        channel.onData = { [weak self] data in
            guard let self = self else { return }
            Task { @MainActor in self.ingest(data) }
        }
        channel.onClosed = { [weak self] in
            Task { @MainActor in self?.handleDisconnected() }
        }

        let quotedRoot = "'" + projectRootPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let quotedDart = "'" + dartExecutable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let startCommand = "cd \(quotedRoot) && exec \(quotedDart) language-server --protocol=lsp"

        do {
            try await channel.open(host: host, authenticationMode: authenticationMode, startCommand: startCommand)
        } catch {
            status = .error("Could not open the SSH channel for the analysis server.")
            print("[DartAnalyzer] Failed to open SSH channel: \(error.localizedDescription)")
            throw error
        }

        print("[DartAnalyzer] Project: \(projectRootPath)")

        let rootURI = "file://" + projectRootPath
        let initParams: [String: Any] = [
            "processId": NSNull(),
            "rootUri": rootURI,
            "capabilities": [
                "textDocument": [
                    "hover": ["contentFormat": ["plaintext", "markdown"]],
                    "completion": ["completionItem": ["snippetSupport": false]],
                    "definition": [String: Any](),
                    "codeAction": [String: Any](),
                    "publishDiagnostics": [String: Any](),
                ]
            ],
            "workspaceFolders": [
                ["uri": rootURI, "name": (projectRootPath as NSString).lastPathComponent]
            ],
        ]

        do {
            _ = try await sendRequest(method: "initialize", params: initParams, timeoutSeconds: 20)
        } catch {
            status = .error("Analysis server did not respond to 'initialize'.")
            print("[DartAnalyzer] initialize failed: \(error.localizedDescription)")
            channel.close()
            throw error
        }
        sendNotification(method: "initialized", params: [String: Any]())

        status = .connected
        print("[DartAnalyzer] Connected")
    }

    func disconnect() {
        channel.close()
        status = .disconnected
        documentVersions.removeAll()
        failAllPending(with: ClientError.notConnected)
    }

    private func handleDisconnected() {
        guard status == .connected || status == .starting else { return }
        status = .disconnected
        print("[DartAnalyzer] Disconnected")
        failAllPending(with: ClientError.notConnected)
    }

    private func failAllPending(with error: Error) {
        let all = pending
        pending.removeAll()
        for (_, continuation) in all { continuation.resume(throwing: error) }
    }

    // MARK: Document sync (full-text sync — see file header note)

    func didOpen(uri: String, text: String) {
        guard status == .connected else { return }
        documentVersions[uri] = 1
        print("[DartAnalyzer] Document opened: \(uri)")
        sendNotification(
            method: "textDocument/didOpen",
            params: [
                "textDocument": [
                    "uri": uri, "languageId": "dart", "version": 1, "text": text,
                ]
            ])
    }

    func didChange(uri: String, text: String) {
        guard status == .connected else { return }
        let version = (documentVersions[uri] ?? 1) + 1
        documentVersions[uri] = version
        sendNotification(
            method: "textDocument/didChange",
            params: [
                "textDocument": ["uri": uri, "version": version],
                "contentChanges": [["text": text]],
            ])
    }

    // MARK: Requests

    func hover(uri: String, line: Int, character: Int) async -> HoverResult? {
        guard status == .connected else { return nil }
        guard
            let result = try? await sendRequest(
                method: "textDocument/hover", params: positionParams(uri: uri, line: line, character: character))
        else { return nil }
        guard let contents = result["contents"] else { return nil }
        let text = Self.stringifyHoverContents(contents)
        guard !text.isEmpty else { return nil }
        return HoverResult(contents: text)
    }

    func definition(uri: String, line: Int, character: Int) async -> [DefinitionResult] {
        guard status == .connected else { return [] }
        guard
            let result = try? await sendRequest(
                method: "textDocument/definition",
                params: positionParams(uri: uri, line: line, character: character))
        else { return [] }
        let raw = (result["__array__"] as? [[String: Any]]) ?? []
        return raw.compactMap { Self.parseLocation($0) }
    }

    func completion(uri: String, line: Int, character: Int) async -> [CompletionResult] {
        guard status == .connected else { return [] }
        guard
            let result = try? await sendRequest(
                method: "textDocument/completion",
                params: positionParams(uri: uri, line: line, character: character))
        else { return [] }
        let items: [[String: Any]]
        if let list = result["items"] as? [[String: Any]] {
            items = list
        } else {
            items = (result["__array__"] as? [[String: Any]]) ?? []
        }
        return items.compactMap { Self.parseCompletionItem($0) }
    }

    func codeActions(
        uri: String, startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int,
        diagnosticMessages: [String]
    ) async -> [CodeActionResult] {
        guard status == .connected else { return [] }
        let range: [String: Any] = [
            "start": ["line": startLine, "character": startCharacter],
            "end": ["line": endLine, "character": endCharacter],
        ]
        let params: [String: Any] = [
            "textDocument": ["uri": uri],
            "range": range,
            "context": [
                "diagnostics": diagnosticMessages.map { ["message": $0, "range": range] }
            ],
        ]
        guard let result = try? await sendRequest(method: "textDocument/codeAction", params: params) else {
            return []
        }
        let raw = (result["__array__"] as? [[String: Any]]) ?? []
        return raw.compactMap { Self.parseCodeAction($0, documentUri: uri) }
    }

    private func positionParams(uri: String, line: Int, character: Int) -> [String: Any] {
        [
            "textDocument": ["uri": uri],
            "position": ["line": line, "character": character],
        ]
    }

    // MARK: JSON-RPC transport

    private func sendRequest(method: String, params: [String: Any], timeoutSeconds: Double = 10) async throws
        -> [String: Any]
    {
        guard status == .connected || status == .starting else { throw ClientError.notConnected }
        let id = nextId
        nextId += 1
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let payload = try? JSONSerialization.data(withJSONObject: envelope, options: []) else {
            throw ClientError.requestFailed("Could not encode request.")
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            pending[id] = continuation
            channel.write(LSPMessageFramer.frame(payload))

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                Task { @MainActor in
                    guard let self = self, let stillPending = self.pending[id] else { return }
                    self.pending.removeValue(forKey: id)
                    stillPending.resume(throwing: ClientError.timedOut)
                }
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) {
        let envelope: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        guard let payload = try? JSONSerialization.data(withJSONObject: envelope, options: []) else { return }
        channel.write(LSPMessageFramer.frame(payload))
    }

    private func ingest(_ data: Data) {
        for messageData in framer.feed(data) {
            guard
                let object = try? JSONSerialization.jsonObject(with: messageData, options: []),
                let message = object as? [String: Any]
            else { continue }
            handleIncoming(message)
        }
    }

    private func handleIncoming(_ message: [String: Any]) {
        if let id = Self.intValue(message["id"]) {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = message["error"] as? [String: Any] {
                let msg = (error["message"] as? String) ?? "Analysis server returned an error."
                continuation.resume(throwing: ClientError.requestFailed(msg))
                return
            }
            let result = message["result"]
            if let array = result as? [[String: Any]] {
                continuation.resume(returning: ["__array__": array])
            } else if let dict = result as? [String: Any] {
                continuation.resume(returning: dict)
            } else {
                continuation.resume(returning: [:])
            }
            return
        }

        guard let method = message["method"] as? String else { return }
        switch method {
        case "textDocument/publishDiagnostics":
            guard let params = message["params"] as? [String: Any],
                let uri = params["uri"] as? String,
                let rawDiagnostics = params["diagnostics"] as? [[String: Any]]
            else { return }
            let diagnostics = rawDiagnostics.compactMap { Self.parseDiagnostic($0) }
            print("[DartAnalyzer] Diagnostics received: \(diagnostics.count)")
            print("[DartAnalyzer] Applying \(diagnostics.count) Monaco markers")
            onDiagnostics?(uri, diagnostics)
        case "window/logMessage", "window/showMessage":
            if let params = message["params"] as? [String: Any], let text = params["message"] as? String {
                print("[DartAnalyzer] Server: \(text)")
            }
        default:
            break  // other notifications ($/progress, etc.) aren't needed here
        }
    }

    // MARK: LSP payload parsing

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        return any as? Int
    }

    private static func parseDiagnostic(_ raw: [String: Any]) -> Diagnostic? {
        guard let range = raw["range"] as? [String: Any],
            let start = range["start"] as? [String: Any],
            let end = range["end"] as? [String: Any],
            let startLine = intValue(start["line"]), let startChar = intValue(start["character"]),
            let endLine = intValue(end["line"]), let endChar = intValue(end["character"]),
            let message = raw["message"] as? String
        else { return nil }
        let severityRaw = intValue(raw["severity"]) ?? 1
        let monacoSeverity: Int
        switch severityRaw {
        case 1: monacoSeverity = 8  // Error
        case 2: monacoSeverity = 4  // Warning
        case 3: monacoSeverity = 2  // Information
        default: monacoSeverity = 1  // Hint
        }
        return Diagnostic(
            monacoSeverity: monacoSeverity, message: message,
            line: startLine + 1, column: startChar + 1,
            endLine: endLine + 1, endColumn: endChar + 1)
    }

    private static func parseLocation(_ raw: [String: Any]) -> DefinitionResult? {
        // Handles both `Location` (uri/range) and `LocationLink`
        // (targetUri/targetRange) response shapes.
        let uri = (raw["uri"] as? String) ?? (raw["targetUri"] as? String)
        let range = (raw["range"] as? [String: Any]) ?? (raw["targetSelectionRange"] as? [String: Any])
            ?? (raw["targetRange"] as? [String: Any])
        guard let uri, let range,
            let start = range["start"] as? [String: Any],
            let line = intValue(start["line"]), let character = intValue(start["character"])
        else { return nil }
        let path = uri.hasPrefix("file://") ? String(uri.dropFirst("file://".count)) : uri
        return DefinitionResult(path: path, line: line + 1, column: character + 1)
    }

    private static func parseCompletionItem(_ raw: [String: Any]) -> CompletionResult? {
        guard let label = raw["label"] as? String else { return nil }
        let kind = intValue(raw["kind"]) ?? 1
        let detail = raw["detail"] as? String
        var documentation: String? = nil
        if let doc = raw["documentation"] as? String {
            documentation = doc
        } else if let docObj = raw["documentation"] as? [String: Any] {
            documentation = docObj["value"] as? String
        }
        let insertText = raw["insertText"] as? String
        return CompletionResult(
            label: label, kind: kind, detail: detail, documentation: documentation, insertText: insertText)
    }

    private static func parseCodeAction(_ raw: [String: Any], documentUri: String) -> CodeActionResult? {
        guard let title = raw["title"] as? String else { return nil }
        guard let edit = raw["edit"] as? [String: Any] else {
            // A code action with no workspace edit (e.g. a command-only
            // action) has nothing this bridge can apply — skip it rather
            // than exposing a lightbulb entry that silently does nothing.
            return nil
        }
        guard let changes = edit["changes"] as? [String: Any] else { return nil }
        // Only expose actions whose edits are ENTIRELY within the current
        // document — see file header note on cross-file quick fixes.
        guard changes.keys.allSatisfy({ $0 == documentUri }), let docEdits = changes[documentUri] as? [[String: Any]]
        else { return nil }

        var edits: [CodeActionEdit] = []
        for e in docEdits {
            guard let range = e["range"] as? [String: Any],
                let start = range["start"] as? [String: Any],
                let end = range["end"] as? [String: Any],
                let startLine = intValue(start["line"]), let startChar = intValue(start["character"]),
                let endLine = intValue(end["line"]), let endChar = intValue(end["character"]),
                let newText = e["newText"] as? String
            else { continue }
            edits.append(
                CodeActionEdit(
                    startLine: startLine + 1, startColumn: startChar + 1,
                    endLine: endLine + 1, endColumn: endChar + 1, newText: newText))
        }
        guard !edits.isEmpty else { return nil }
        return CodeActionResult(title: title, edits: edits)
    }

    private static func stringifyHoverContents(_ raw: Any) -> String {
        if let s = raw as? String { return s }
        if let dict = raw as? [String: Any], let value = dict["value"] as? String { return value }
        if let array = raw as? [Any] {
            return array.compactMap { item -> String? in
                if let s = item as? String { return s }
                if let dict = item as? [String: Any] { return dict["value"] as? String }
                return nil
            }.joined(separator: "\n\n")
        }
        return ""
    }
}
