//
//  RemoteExecutionManager.swift
//  Code
//
//  Adds a VS Code style Run (▶) / Stop (■) feature for files opened from an
//  SSH (SFTP) project. This manager owns ONLY execution logic — language
//  detection, command construction, and run/stop state. It never opens an
//  SSH connection and never creates a terminal:
//
//  - Sending the command reuses `TerminalInstance.type(text:)`, the exact
//    method already used by the terminal's on-screen keyboard toolbar to
//    forward typed text to the active shell. When a remote
//    `TerminalServiceProvider` is attached (i.e. SSH is connected), typed
//    text is routed straight to the SSH channel — see
//    `TerminalInstance.userContentController(_:didReceive:)`.
//  - Stopping reuses `TerminalInstance.sendInterrupt()`, the exact method
//    already used elsewhere to send Ctrl+C.
//  - Output is read from the same `Data` MainApp already forwards from
//    `WorkSpaceStorage.onTerminalData` to `TerminalInstance.write(data:)` —
//    this manager only observes a copy of that stream to find the
//    completion marker it appends to its own command; it never writes to
//    the terminal view itself.
//

import Combine
import Foundation

// MARK: - Supported languages

enum SupportedLanguage {
    case python, javascript, typescript, dart, shell, php, ruby, lua, perl, go, java, rust, c, cpp

    static func detect(fileExtension ext: String) -> SupportedLanguage? {
        switch ext.lowercased() {
        case "py": return .python
        case "js", "mjs", "cjs": return .javascript
        case "ts", "tsx": return .typescript
        case "dart": return .dart
        case "sh", "bash": return .shell
        case "php": return .php
        case "rb": return .ruby
        case "lua": return .lua
        case "pl": return .perl
        case "go": return .go
        case "java": return .java
        case "rs": return .rust
        case "c": return .c
        case "cpp", "cc", "cxx": return .cpp
        default: return nil
        }
    }
}

/// A single choice the user can run. For a plain script this is just "the
/// current file"; for a project (package.json / Cargo.toml / pubspec.yaml)
/// there can be several, offered from the Run button's context menu.
struct RemoteRunTarget: Identifiable, Equatable {
    let id = UUID()
    let title: String
    fileprivate let command: String
}

// MARK: - Execution state

enum RemoteExecutionState: Equatable {
    case idle
    case running(startedAt: Date)
    case finished(exitCode: Int32, duration: TimeInterval)
    case failed(message: String)
}

/// - Important: Like `TerminalManager`, access this class only from the main
///   thread. Callers that may run off the main thread (e.g. SSH data
///   callbacks) should hop to main first — see the `Task { @MainActor in }`
///   wrapping used at MainApp's `onTerminalData`/`onRemoteDisconnect` call sites.
final class RemoteExecutionManager: ObservableObject {

    @Published private(set) var state: RemoteExecutionState = .idle

    private static let markerPrefix = "__CODEAPP_RUN_DONE__"
    private static let outputBufferCap = 4096

    private var runStartedAt: Date?
    private var currentToken: String?
    private var outputBuffer = ""

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: Button visibility / enablement

    /// Whether the Run button should be shown at all for the file currently open.
    func shouldShowRunButton(app: MainApp) -> Bool {
        guard app.workSpaceStorage.remoteConnected else { return false }
        guard let editor = app.activeTextEditor else { return false }
        guard isFileInsideCurrentWorkspace(editor.url, app: app) else { return false }
        return SupportedLanguage.detect(fileExtension: editor.url.pathExtension) != nil
    }

    /// Whether the button should currently accept taps. While running, it
    /// stays enabled so it can be tapped again to Stop.
    func isRunButtonEnabled(app: MainApp) -> Bool {
        if isRunning { return true }
        return app.workSpaceStorage.remoteConnected && app.terminalManager.remoteTerminal != nil
    }

    private func isFileInsideCurrentWorkspace(_ url: URL, app: MainApp) -> Bool {
        guard let root = URL(string: app.workSpaceStorage.currentDirectory.url) else {
            return false
        }
        // Remote files all live under the same host/scheme as the workspace
        // root for the duration of one SSH session, so a path-prefix check
        // is sufficient and avoids assuming anything about the filesystem
        // provider beyond what WorkSpaceStorage already exposes.
        return url.path == root.path || url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    // MARK: Project-level run options (package.json / Cargo.toml / pubspec.yaml)

    /// Extra project-wide targets to offer alongside "run this file", based
    /// on manifest files at the project root. Empty when none apply.
    func availableProjectRunTargets(app: MainApp) async -> [RemoteRunTarget] {
        guard app.workSpaceStorage.remoteConnected,
            let root = URL(string: app.workSpaceStorage.currentDirectory.url)
        else {
            return []
        }

        var targets: [RemoteRunTarget] = []

        if await fileExists(app: app, root: root, relativePath: "package.json") {
            targets.append(RemoteRunTarget(title: "npm start", command: "npm start"))
            targets.append(RemoteRunTarget(title: "npm run dev", command: "npm run dev"))
            targets.append(RemoteRunTarget(title: "npm test", command: "npm test"))
        }
        if await fileExists(app: app, root: root, relativePath: "Cargo.toml") {
            targets.append(RemoteRunTarget(title: "Cargo Run", command: "cargo run"))
        }
        if await fileExists(app: app, root: root, relativePath: "pubspec.yaml") {
            targets.append(RemoteRunTarget(title: "Flutter Run", command: "flutter run"))
        }
        return targets
    }

    private func fileExists(app: MainApp, root: URL, relativePath: String) async -> Bool {
        (try? await app.workSpaceStorage.fileExists(at: root.appendingPathComponent(relativePath)))
            ?? false
    }

    // MARK: Command construction for a single file

    private func command(forFileURL fileURL: URL, root: URL) -> String? {
        guard let language = SupportedLanguage.detect(fileExtension: fileURL.pathExtension) else {
            return nil
        }

        let relativePath = relativePath(of: fileURL, root: root)
        let quotedRelative = shellQuoted(relativePath)
        let baseName = fileURL.lastPathComponent
        let baseNameNoExt = (baseName as NSString).deletingPathExtension
        let quotedBaseName = shellQuoted(baseName)
        let quotedBaseNameNoExt = shellQuoted(baseNameNoExt)
        let relativeDir = (relativePath as NSString).deletingLastPathComponent
        let hasDir = !relativeDir.isEmpty
        let quotedDir = shellQuoted(relativeDir)

        switch language {
        case .python: return "python3 \(quotedRelative)"
        case .javascript: return "node \(quotedRelative)"
        case .typescript: return "ts-node \(quotedRelative)"
        case .dart: return "dart \(quotedRelative)"
        case .shell: return "bash \(quotedRelative)"
        case .php: return "php \(quotedRelative)"
        case .ruby: return "ruby \(quotedRelative)"
        case .lua: return "lua \(quotedRelative)"
        case .perl: return "perl \(quotedRelative)"
        case .go: return "go run \(quotedRelative)"
        case .rust:
            // A Cargo project is offered via availableProjectRunTargets();
            // this is only the fallback for a standalone .rs file.
            return "rustc \(quotedRelative) -o \(quotedBaseNameNoExt) && ./\(quotedBaseNameNoExt)"
        case .java:
            return hasDir
                ? "cd \(quotedDir) && javac \(quotedBaseName) && java \(quotedBaseNameNoExt)"
                : "javac \(quotedBaseName) && java \(quotedBaseNameNoExt)"
        case .c:
            return hasDir
                ? "cd \(quotedDir) && gcc \(quotedBaseName) -o \(quotedBaseNameNoExt) && ./\(quotedBaseNameNoExt)"
                : "gcc \(quotedBaseName) -o \(quotedBaseNameNoExt) && ./\(quotedBaseNameNoExt)"
        case .cpp:
            return hasDir
                ? "cd \(quotedDir) && g++ \(quotedBaseName) -o \(quotedBaseNameNoExt) && ./\(quotedBaseNameNoExt)"
                : "g++ \(quotedBaseName) -o \(quotedBaseNameNoExt) && ./\(quotedBaseNameNoExt)"
        }
    }

    private func relativePath(of fileURL: URL, root: URL) -> String {
        let filePath = fileURL.path
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if filePath.hasPrefix(rootPath) {
            return String(filePath.dropFirst(rootPath.count))
        }
        return fileURL.lastPathComponent
    }

    private func shellQuoted(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Run / Stop

    /// Entry point for the toolbar's Run button when running the currently
    /// open file. Saves the editor first and only runs once saving has
    /// completed; never runs unsaved code.
    func runCurrentFile(app: MainApp) async {
        guard !isRunning else { return }

        guard app.workSpaceStorage.remoteConnected else {
            fail("SSH is disconnected. Reconnect to run this file.")
            return
        }
        guard let terminal = app.terminalManager.remoteTerminal else {
            fail("SSH is reconnecting. Try again once the connection is restored.")
            return
        }
        guard let editor = app.activeTextEditor else {
            fail("No file is open to run.")
            return
        }
        guard let rootURL = URL(string: app.workSpaceStorage.currentDirectory.url) else {
            fail("Couldn't determine the remote project's root directory.")
            return
        }
        guard let command = command(forFileURL: editor.url, root: rootURL) else {
            fail("This file type can't be executed.")
            return
        }

        await app.saveCurrentFile()
        guard editor.isSaved else {
            fail("Couldn't save the file before running.")
            return
        }

        run(command: command, rootPath: rootURL.path, terminal: terminal)
    }

    /// Entry point for running a project-level target (npm/cargo/flutter),
    /// selected from `availableProjectRunTargets(app:)`.
    func run(projectTarget: RemoteRunTarget, app: MainApp) {
        guard !isRunning else { return }
        guard app.workSpaceStorage.remoteConnected,
            let terminal = app.terminalManager.remoteTerminal
        else {
            fail("SSH is disconnected. Reconnect to run this.")
            return
        }
        guard let rootURL = URL(string: app.workSpaceStorage.currentDirectory.url) else {
            fail("Couldn't determine the remote project's root directory.")
            return
        }
        run(command: projectTarget.command, rootPath: rootURL.path, terminal: terminal)
    }

    private func run(command: String, rootPath: String, terminal: TerminalInstance) {
        let token = UUID().uuidString
        currentToken = token
        outputBuffer = ""
        runStartedAt = Date()
        state = .running(startedAt: runStartedAt!)

        let quotedRoot = shellQuoted(rootPath.isEmpty ? "/" : rootPath)
        // Never run from HOME: always cd into the project root first.
        // The trailing echo carries the exit code inside a unique marker so
        // completion can be detected without a second connection, a second
        // terminal, or polling.
        let line =
            "cd \(quotedRoot) && \(command); echo \"\(Self.markerPrefix)\(token):$?\"\r"

        // Sent exactly as if the user had typed it — same call path the
        // terminal's on-screen keyboard toolbar already uses.
        terminal.type(text: line)
    }

    /// Entry point for the toolbar's Stop button. Sends Ctrl+C through the
    /// same SSH shell via the terminal's existing interrupt mechanism.
    func stop(app: MainApp) {
        guard isRunning else { return }
        app.terminalManager.remoteTerminal?.sendInterrupt()
    }

    // MARK: Completion detection

    /// Called by MainApp with the same raw `Data` it already forwards from
    /// `WorkSpaceStorage.onTerminalData` to the terminal view. This manager
    /// only reads it to find its own completion marker.
    func ingestRemoteOutput(_ data: Data) {
        guard isRunning, let token = currentToken else { return }
        guard let chunk = String(data: data, encoding: .utf8) else { return }

        outputBuffer += chunk

        let marker = "\(Self.markerPrefix)\(token):"
        guard let range = outputBuffer.range(of: marker) else {
            if outputBuffer.count > Self.outputBufferCap {
                outputBuffer.removeFirst(outputBuffer.count - Self.outputBufferCap)
            }
            return
        }

        let afterMarker = outputBuffer[range.upperBound...]
        let digits = afterMarker.prefix { $0.isNumber }
        guard !digits.isEmpty, let exitCode = Int32(digits) else { return }

        let duration = runStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        state = .finished(exitCode: exitCode, duration: duration)
        resetRunTracking()
    }

    /// Called by MainApp's existing `onRemoteDisconnect` hook so a run in
    /// progress doesn't get stuck showing "Running…" after the link drops.
    func handleDisconnect() {
        guard isRunning else { return }
        fail("SSH disconnected while running.")
    }

    private func fail(_ message: String) {
        state = .failed(message: message)
        resetRunTracking()
    }

    private func resetRunTracking() {
        currentToken = nil
        runStartedAt = nil
    }
}
