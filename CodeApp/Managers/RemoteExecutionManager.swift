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
//
//  Clean terminal output: rather than typing a long `cd ... && cmd; echo
//  marker` line (which the shell echoes back verbatim, cluttering the
//  terminal with paths and marker text), the real command is written to a
//  small hidden script on the remote host via the app's existing SFTP
//  write API, and only a single short line is ever typed:
//
//      bash '.codeapp_run.sh'
//
//  The script itself writes its exit code to a hidden file
//  (`.codeapp_run.exit`) instead of echoing it — completion is detected by
//  quietly polling for that file over SFTP (the same `WorkSpaceStorage`
//  API the file explorer already uses), never by scanning terminal text.
//  So the terminal shows just that one clean line plus whatever the
//  program itself actually prints.
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
    /// `label` is a short, friendly name (e.g. "v.py", "npm start") shown in
    /// the status bar — not the raw shell command, so it stays clean.
    case running(startedAt: Date, label: String)
    case finished(exitCode: Int32, duration: TimeInterval)
    case failed(message: String)
}

/// - Important: Like `TerminalManager`, access this class only from the main
///   thread. Its own internal polling always hops back to the main actor
///   before touching `state` — see `scheduleNextPoll`.
final class RemoteExecutionManager: ObservableObject {

    @Published private(set) var state: RemoteExecutionState = .idle

    private static let scriptFileName = ".codeapp_run.sh"
    private static let exitFileName = ".codeapp_run.exit"
    private static let pollInterval: UInt64 = 600_000_000  // 0.6s, in nanoseconds

    private var runStartedAt: Date?
    private var currentToken: String?
    private var pendingStopTimeout: DispatchWorkItem?

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
        return url.path == root.path || url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    // MARK: Project-level run options (package.json / Cargo.toml / pubspec.yaml)

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
            targets.append(RemoteRunTarget(title: "Flutter Run", command: "flutter run -d web-server"))
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
        guard var command = command(forFileURL: editor.url, root: rootURL) else {
            fail("This file type can't be executed.")
            return
        }

        var label = editor.url.lastPathComponent

        // A .dart file inside a Flutter project's lib/ folder isn't run with
        // plain `dart file.dart` — the project as a whole is run instead.
        if SupportedLanguage.detect(fileExtension: editor.url.pathExtension) == .dart {
            let relative = relativePath(of: editor.url, root: rootURL)
            let isInsideLib = relative == "lib" || relative.hasPrefix("lib/")
            if isInsideLib, await fileExists(app: app, root: rootURL, relativePath: "pubspec.yaml") {
                command = "flutter run -d web-server"
                label = "Flutter (web)"
            }
        }

        await app.saveCurrentFile()
        guard editor.isSaved else {
            fail("Couldn't save the file before running.")
            return
        }

        await run(command: command, label: label, root: rootURL, app: app, terminal: terminal)
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
        Task {
            await run(
                command: projectTarget.command, label: projectTarget.title, root: rootURL, app: app,
                terminal: terminal)
        }
    }

    /// Writes the actual command into a small hidden script on the remote
    /// host and types only a single short line to run it — keeping the
    /// terminal free of cd/path/marker clutter. Completion is detected by
    /// quietly polling for a hidden exit-code file over SFTP, never by
    /// reading terminal text.
    private func run(command: String, label: String, root: URL, app: MainApp, terminal: TerminalInstance)
        async
    {
        pendingStopTimeout?.cancel()
        pendingStopTimeout = nil

        let token = UUID().uuidString
        currentToken = token

        let scriptURL = root.appendingPathComponent(Self.scriptFileName)
        let exitURL = root.appendingPathComponent(Self.exitFileName)

        // Clear any leftover exit marker from a previous run before this one
        // starts, so a stale file can't be mistaken for immediate completion.
        try? await app.workSpaceStorage.removeItem(at: exitURL)

        let script = """
            cd \(shellQuoted(root.path)) || exit 1
            \(command)
            __codeapp_exit=$?
            echo "$__codeapp_exit" > \(shellQuoted(Self.exitFileName))
            exit "$__codeapp_exit"
            """
        guard let scriptData = script.data(using: .utf8) else {
            fail("Couldn't prepare the run script.")
            return
        }

        do {
            try await app.workSpaceStorage.write(
                at: scriptURL, content: scriptData, atomically: true, overwrite: true)
        } catch {
            fail("Couldn't write the run script to the remote project.")
            return
        }

        guard currentToken == token else { return }  // stopped/replaced while writing

        runStartedAt = Date()
        state = .running(startedAt: runStartedAt!, label: label)

        // The only line the terminal ever shows for this run. Use the
        // script's absolute path — the terminal shell's own cwd is not
        // guaranteed to already be the project root.
        terminal.type(text: "bash \(shellQuoted(scriptURL.path))\r")

        scheduleNextPoll(app: app, token: token, exitURL: exitURL)
    }

    /// Entry point for the toolbar's Stop button. Sends Ctrl+C through the
    /// same SSH shell via the terminal's existing interrupt mechanism.
    ///
    /// Ctrl+C only interrupts the foreground process — the script may still
    /// take a moment (or, rarely, fail) to reach its own exit-code write.
    /// Without a fallback, the button could stay stuck on "Stop" forever. To
    /// prevent that, arm a short grace period: if the exit file hasn't shown
    /// up shortly after Stop was pressed, force the state back to idle so
    /// Run works again on the next tap.
    func stop(app: MainApp) {
        guard isRunning, let token = currentToken else { return }
        app.terminalManager.remoteTerminal?.sendInterrupt()

        pendingStopTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.currentToken == token else { return }
            self.fail("Cancelled.")
        }
        pendingStopTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    // MARK: Completion detection (silent SFTP polling — never reads terminal text)

    private func scheduleNextPoll(app: MainApp, token: String, exitURL: URL) {
        guard currentToken == token else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            guard let self = self else { return }
            await self.pollOnce(app: app, token: token, exitURL: exitURL)
        }
    }

    private func pollOnce(app: MainApp, token: String, exitURL: URL) async {
        guard currentToken == token else { return }  // stopped/finished/replaced meanwhile

        let exists = (try? await app.workSpaceStorage.fileExists(at: exitURL)) ?? false
        guard exists else {
            await MainActor.run { [weak self] in
                self?.scheduleNextPoll(app: app, token: token, exitURL: exitURL)
            }
            return
        }

        let exitCode = await readExitCode(app: app, exitURL: exitURL)
        try? await app.workSpaceStorage.removeItem(at: exitURL)

        await MainActor.run { [weak self] in
            guard let self = self, self.currentToken == token else { return }
            let duration = self.runStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            self.state = .finished(exitCode: exitCode, duration: duration)
            self.resetRunTracking()
        }
    }

    private func readExitCode(app: MainApp, exitURL: URL) async -> Int32 {
        guard let data = try? await app.workSpaceStorage.contents(at: exitURL),
            let text = String(data: data, encoding: .utf8)
        else {
            return -1
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(trimmed) ?? -1
    }

    /// Called by MainApp's existing `onTerminalData` hook. Completion is now
    /// detected by silently polling a hidden exit-code file (see above), not
    /// by scanning terminal text, so this is intentionally unused — kept
    /// only so that existing call site keeps compiling unchanged.
    func ingestRemoteOutput(_ data: Data) {}

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
        pendingStopTimeout?.cancel()
        pendingStopTimeout = nil
        currentToken = nil
        runStartedAt = nil
    }
}
