//
//  LanguageService.swift
//  Code
//
//  Remote language services used by Code App.
//  Dart/Flutter is intentionally REMOTE-ONLY: no local Dart analyzer is started.
//

import Foundation
import NMSSH

final class LanguageService {
    struct Configuration {
        let languageIdentifier: String
        let extensions: [String]
        let args: [String]
    }

    var candidateLanguageIdentifier: String? = nil

    static let shared = LanguageService()
    static let configurations: [Configuration] = [
        Configuration(languageIdentifier: "python", extensions: ["py"], args: ["jedi-language-server", "-v"]),
        Configuration(languageIdentifier: "java", extensions: ["java"], args: ["java", "-jar", "${JAVA_LSP_FAT_JAR_PATH}"])
    ]

    static func configurationFor(url: URL) -> Configuration? {
        configurations.first { $0.extensions.contains(url.pathExtension) }
    }
}

/// A real Dart Language Server Protocol connection over the already-authenticated
/// SSH credentials held by WorkSpaceStorage. The remote process is:
///     dart language-server --protocol=lsp
///
/// Monaco talks to this class through WKScriptMessageHandler. This is deliberately
/// not based on `dart analyze` or a curated completion list, so completion,
/// diagnostics, hover and code actions are provided by the remote Dart analyzer.
final class RemoteDartLanguageServer: NSObject, NMSSHChannelDelegate, NMSSHSessionDelegate {
    static let shared = RemoteDartLanguageServer()

    private let queue = DispatchQueue(label: "codeapp.remote.dart.lsp", qos: .userInitiated)
    private var session: NMSSHSession?
    private var buffer = Data()
    private var isRunning = false
    private var sendLock = NSLock()
    private var receiver: ((String) -> Void)?
    private var keyboardHandler: ((String) async -> String)?

    private override init() {
        super.init()
    }

    func start(
        host: URL,
        authenticationMode: RemoteAuthenticationMode,
        onRequestInteractiveKeyboard: @escaping (String) async -> String,
        receiver: @escaping (String) -> Void,
        onReady: @escaping () -> Void = {}
    ) {
        stop()
        self.receiver = receiver
        self.keyboardHandler = onRequestInteractiveKeyboard

        queue.async { [weak self] in
            guard let self else { return }
            guard let hostname = host.host, let port = host.port else { return }

            let ssh = NMSSHSession(
                host: hostname,
                port: port,
                andUsername: authenticationMode.credentials.user ?? "")
            ssh.delegate = self
            ssh.channel.delegate = self
            ssh.timeout = 15
            ssh.connect()

            guard ssh.isConnected else {
                self.emitError("SSH connection failed while starting Dart language server.")
                return
            }

            switch authenticationMode {
            case .plainUsernamePassword(let credentials):
                ssh.authenticate(byPassword: credentials.password ?? "")
            case .inMemorySSHKey(let credentials, let privateKeyContent):
                ssh.authenticateBy(
                    inMemoryPublicKey: nil,
                    privateKey: privateKeyContent,
                    andPassword: credentials.password)
            case .inFileSSHKey(let credentials, let keyURL):
                let url = keyURL ?? getRootDirectory().appendingPathComponent(".ssh/id_rsa")
                if let key = try? String(contentsOf: url) {
                    ssh.authenticateBy(
                        inMemoryPublicKey: nil,
                        privateKey: key,
                        andPassword: credentials.password)
                }
            }

            guard ssh.isAuthorized else {
                self.emitError("SSH authentication failed while starting Dart language server.")
                ssh.disconnect()
                return
            }

            self.session = ssh
            ssh.channel.requestPty = false

            do {
                // Replace the shell with the analyzer. No PTY means the LSP
                // Content-Length protocol is not polluted by terminal escape codes.
                try ssh.channel.startShell()
                var error: NSError?
                let command = "exec sh -c \"export PATH=/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/opt/flutter/bin:$PATH; exec dart language-server --protocol=lsp\"\n"
                guard let commandData = command.data(using: .utf8) else {
                    self.emitError("Unable to encode Dart language server command.")
                    ssh.disconnect()
                    return
                }
                ssh.channel.write(commandData, error: &error, timeout: 5)
                if let error {
                    self.emitError(error.localizedDescription)
                    ssh.disconnect()
                    return
                }
                self.isRunning = true
                DispatchQueue.main.async { onReady() }
            } catch {
                self.emitError(error.localizedDescription)
                ssh.disconnect()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.buffer.removeAll(keepingCapacity: false)
            self.session?.channel.closeShell()
            self.session?.disconnect()
            self.session = nil
        }
    }

    func send(json: String) {
        queue.async { [weak self] in
            guard let self, self.isRunning, let channel = self.session?.channel,
                  let data = json.data(using: .utf8) else { return }

            let header = "Content-Length: \(data.count)\r\n\r\n"
            guard let framed = header.data(using: .utf8) else { return }
            self.sendLock.lock()
            var error: NSError?
            channel.write(framed, error: &error, timeout: 5)
            channel.write(data, error: &error, timeout: 5)
            self.sendLock.unlock()
        }
    }

    func send(message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let string = String(data: data, encoding: .utf8) else { return }
        send(json: string)
    }

    private func consumeIncoming() {
        while true {
            guard let headerEndRange = buffer.range(of: Data([13, 10, 13, 10])) else { return }
            let headerData = buffer.subdata(in: 0..<headerEndRange.lowerBound)
            guard let header = String(data: headerData, encoding: .utf8) else {
                buffer.removeSubrange(0..<headerEndRange.upperBound)
                continue
            }
            var contentLength: Int?
            for line in header.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-length" {
                    contentLength = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            guard let length = contentLength else {
                buffer.removeSubrange(0..<headerEndRange.upperBound)
                continue
            }
            let bodyStart = headerEndRange.upperBound
            guard buffer.count >= bodyStart + length else { return }
            let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
            buffer.removeSubrange(0..<(bodyStart + length))
            guard let json = String(data: body, encoding: .utf8) else { continue }
            DispatchQueue.main.async { [weak self] in self?.receiver?(json) }
        }
    }

    private func emitError(_ message: String) {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let json = "{\"jsonrpc\":\"2.0\",\"method\":\"codeapp/dartServerError\",\"params\":{\"message\":\"\(escaped)\"}}"
        DispatchQueue.main.async { [weak self] in self?.receiver?(json) }
    }

    func channel(_ channel: NMSSHChannel, didReadRawData data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(data)
            self.consumeIncoming()
        }
    }

    func channel(_ channel: NMSSHChannel, didReadRawError error: Data) {
        // Never mix stderr into stdout/LSP framing, but surface useful startup
        // errors so a failed remote Dart command is diagnosable in Code App.
        guard let text = String(data: error, encoding: .utf8), !text.isEmpty else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        self.emitError("Remote Dart LSP: " + clean)
    }

    func session(_ session: NMSSHSession, keyboardInteractiveRequest request: String) -> String {
        guard let keyboardHandler else { return "" }
        return UnsafeTask { await keyboardHandler(request) }.get()
    }

    func session(_ session: NMSSHSession, didDisconnectWithError error: Error) {
        isRunning = false
        emitError(error.localizedDescription)
    }
}
