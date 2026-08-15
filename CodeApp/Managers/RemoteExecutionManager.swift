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
//    forward typed text to the active shell.
//  - Stopping reuses `TerminalInstance.sendInterrupt()`, the exact method
//    already used elsewhere to send Ctrl+C.
//  - Completion is detected from the SAME single data stream MainApp
//    already forwards from `WorkSpaceStorage.onTerminalData` to
//    `TerminalInstance.write(data:)` for display — via `ingestRemoteOutput`.
//    There is deliberately NO separate background polling / second SFTP
//    channel running concurrently with the terminal: driving SFTP calls on
//    a timer while the same SSH session is also streaming heavy output
//    (e.g. `flutter run`) is what was causing crashes and dropped output in
//    the previous version. This version reads only the one data path the
//    app already has.
//
//  Clean terminal output: instead of typing a long `cd ... && cmd; echo
//  marker` line, the real command is written ONCE to a small hidden script
//  on the remote host via the app's existing SFTP write API, and only a
//  single short line is typed to run it:
//
//      bash '/absolute/path/to/.codeapp_run.sh'
//
//  The script's own last line echoes a short completion marker to stdout,
//  which arrives through the terminal's normal output exactly like any
//  other program output — no extra network channel involved.
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
///   thread.
final class RemoteExecutionManager: ObservableObject {

    @Published private(set) var state: RemoteExecutionState = .idle

    private static let scriptFileName = ".codeapp_run.sh"
    /// Short on purpose — this is the only "extra" text that ever appears in
    /// the terminal, right after the program's own output finishes.
    private static let marker = "~CAEXIT~"
    private static let outputBufferCap = 4096

    private var runStartedAt: Date?
    private var currentToken: String?
    private var outputBuffer = ""
    private var pendingStopTimeout: DispatchWorkItem?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: Button visibility / enablement

    func shouldShowRunButton(app: MainApp) -> Bool {
        guard app.workSpaceStorage.remoteConnected else { return false }
        guard let editor = app.activeTextEditor else { return false }
        guard isFileInsideCurrentWorkspace(editor.url, app: app) else { return false }
        return SupportedLanguage.detect(fileExtension: editor.url.pathExtension) != nil
    }

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

    /// Walks up from a file's directory looking for a `lib` folder anywhere
    /// in its ancestry (not just directly under the SSH workspace root —
    /// a Flutter project is very often a subfolder of the connected root,
    /// e.g. `<root>/pdf_reader/lib/main.dart`). Returns the Flutter
    /// project's own root (the parent of `lib`), or nil if the file isn't
    /// inside a `lib` folder at all.
    static func flutterProjectRoot(forFileURL fileURL: URL) -> URL? {
        var current = fileURL.deletingLastPathComponent()
        while !current.path.isEmpty && current.path != "/" {
            if current.lastPathComponent == "lib" {
                return current.deletingLastPathComponent()
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
        return nil
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
    ///
    /// - Important (crash safety): after an `await`, Swift does NOT guarantee
    ///   execution resumes on the main thread — it can resume on a
    ///   background thread from the cooperative pool. Touching `@Published
    ///   state` or the terminal's WebView from a background thread is what
    ///   was crashing the app. Every block below that touches `state` or
    ///   `terminal` is therefore explicitly wrapped in
    ///   `await MainActor.run { ... }`, regardless of which thread we
    ///   actually resumed on.
    func runCurrentFile(app: MainApp) async {
        struct Setup {
            let terminal: TerminalInstance
            let editorURL: URL
            let rootURL: URL
            var command: String
            var label: String
        }

        // 1) All the fast, synchronous guard-checks, plus flipping the
        // button to Stop immediately — done on the main actor before any
        // await, so the icon changes the instant Run is tapped.
        let setup: Setup? = await MainActor.run {
            guard !self.isRunning else { return nil }
            guard app.workSpaceStorage.remoteConnected else {
                self.fail("SSH is disconnected. Reconnect to run this file.")
                return nil
            }
            guard let terminal = app.terminalManager.remoteTerminal else {
                self.fail("SSH is reconnecting. Try again once the connection is restored.")
                return nil
            }
            guard let editor = app.activeTextEditor else {
                self.fail("No file is open to run.")
                return nil
            }
            guard let rootURL = URL(string: app.workSpaceStorage.currentDirectory.url) else {
                self.fail("Couldn't determine the remote project's root directory.")
                return nil
            }
            guard let command = self.command(forFileURL: editor.url, root: rootURL) else {
                self.fail("This file type can't be executed.")
                return nil
            }

            self.pendingStopTimeout?.cancel()
            self.pendingStopTimeout = nil
            self.runStartedAt = Date()
            self.currentToken = "pending"  // placeholder; replaced with the real token below
            self.state = .running(startedAt: self.runStartedAt!, label: editor.url.lastPathComponent)

            return Setup(
                terminal: terminal, editorURL: editor.url, rootURL: rootURL, command: command,
                label: editor.url.lastPathComponent)
        }
        guard let setup = setup else { return }

        // 2) A .dart file inside a Flutter project's lib/ folder isn't run
        // with plain `dart file.dart` — the whole Flutter project is run
        // instead, and directly (no hidden script) so its live build output
        // streams to the terminal exactly as it would if typed by hand.
        if SupportedLanguage.detect(fileExtension: setup.editorURL.pathExtension) == .dart,
            let projectRoot = Self.flutterProjectRoot(forFileURL: setup.editorURL),
            await fileExists(app: app, root: projectRoot, relativePath: "pubspec.yaml")
        {
            await runFlutterDirect(app: app, projectRoot: projectRoot, terminal: setup.terminal)
            return
        }

        await app.saveCurrentFile()

        let stillGoing: Bool = await MainActor.run {
            guard self.currentToken == "pending" else { return false }  // stopped meanwhile
            guard app.activeTextEditor?.isSaved == true else {
                self.fail("Couldn't save the file before running.")
                return false
            }
            return true
        }
        guard stillGoing else { return }

        await run(
            command: setup.command, label: setup.label, root: setup.rootURL, app: app,
            terminal: setup.terminal)
    }

    /// Entry point for running a project-level target (npm/cargo/flutter),
    /// selected from `availableProjectRunTargets(app:)`. Must be called from
    /// the main thread (e.g. a SwiftUI button action).
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

        pendingStopTimeout?.cancel()
        pendingStopTimeout = nil
        runStartedAt = Date()
        currentToken = "pending"
        state = .running(startedAt: runStartedAt!, label: projectTarget.title)

        Task {
            await run(
                command: projectTarget.command, label: projectTarget.title, root: rootURL, app: app,
                terminal: terminal)
        }
    }

    /// Runs `flutter run -d web-server` directly — no hidden script, no
    /// completion marker. Flutter's own build/server output is what the
    /// user wants to watch live, and routing it through a wrapper script
    /// can change how Flutter buffers its output; typing the command
    /// straight into the terminal avoids that entirely. Since `flutter run`
    /// doesn't exit on its own, this stays "running" until Stop is pressed.
    private func runFlutterDirect(app: MainApp, projectRoot: URL, terminal: TerminalInstance) async {
        let shouldProceed: Bool = await MainActor.run {
            guard self.currentToken == "pending" else { return false }  // stopped meanwhile
            self.currentToken = "flutter-direct"
            self.state = .running(startedAt: self.runStartedAt ?? Date(), label: "Flutter (web)")
            return true
        }
        guard shouldProceed else { return }

        await app.saveCurrentFile()

        let quotedRoot = shellQuoted(projectRoot.path)
        await MainActor.run {
            guard self.currentToken == "flutter-direct" else { return }  // stopped while saving
            // The only line the terminal ever shows for this run — cd into
            // the actual Flutter project (which may be a subfolder of the
            // SSH root), then run it, exactly as if typed by hand.
            terminal.type(text: "cd \(quotedRoot) && krinry flutter run web\r")
        }
    }

    /// Writes the actual command into a small hidden script on the remote
    /// host (one write, not recurring) and types only a single short line
    /// to run it. The script's own final line echoes the completion marker
    /// to stdout, so it arrives through the terminal's existing, single
    /// output stream — no second channel, no timers, no polling. (Not used
    /// for Flutter — see `runFlutterDirect` above.)

    private func run(command: String, label: String, root: URL, app: MainApp, terminal: TerminalInstance)
        async
    {
        let token = String(UUID().uuidString.prefix(8))
        let scriptURL = root.appendingPathComponent(Self.scriptFileName)

        let script = """
            cd \(shellQuoted(root.path)) || exit 1
            \(command)
            echo "\(Self.marker)\(token):$?"
            """
        guard let scriptData = script.data(using: .utf8) else {
            await MainActor.run { self.fail("Couldn't prepare the run script.") }
            return
        }

        do {
            try await app.workSpaceStorage.write(
                at: scriptURL, content: scriptData, atomically: true, overwrite: true)
        } catch {
            await MainActor.run { self.fail("Couldn't write the run script to the remote project.") }
            return
        }

        // Everything from here touches `state`/`outputBuffer`/the terminal's
        // WebView — always on the main actor, no exceptions.
        await MainActor.run {
            guard self.currentToken == "pending" else { return }  // stopped meanwhile
            self.currentToken = token
            self.outputBuffer = ""
            self.state = .running(startedAt: self.runStartedAt ?? Date(), label: label)

            // The only line the terminal ever shows for this run. Absolute
            // path, since the shell's own cwd is not guaranteed to be the
            // project root.
            terminal.type(text: "bash \(self.shellQuoted(scriptURL.path))\r")
        }
    }

    /// Entry point for the toolbar's Stop button. Sends Ctrl+C through the
    /// same SSH shell via the terminal's existing interrupt mechanism. Must
    /// be called from the main thread (e.g. a SwiftUI button action).
    ///
    /// Ctrl+C only interrupts the foreground process — the script may not
    /// always get to echo its marker afterwards. Without a fallback, the
    /// button could stay stuck on "Stop" forever. To prevent that, arm a
    /// short grace period: if the marker hasn't shown up shortly after Stop
    /// was pressed, force the state back to idle so Run works again.
    func stop(app: MainApp) {
        guard isRunning else { return }
        let token = currentToken
        app.terminalManager.remoteTerminal?.sendInterrupt()

        pendingStopTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.currentToken == token else { return }
            self.fail("Cancelled.")
        }
        pendingStopTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
    }

    // MARK: Completion detection (single data path — no polling, no second channel)

    /// Called by MainApp with the same raw `Data` it already forwards from
    /// `WorkSpaceStorage.onTerminalData` to the terminal view for display.
    /// This only reads a copy to find this run's completion marker; it
    /// never writes to the terminal itself.
    ///
    /// - Important: MainApp already calls this from inside
    ///   `Task { @MainActor in ... }`, so this always runs on the main
    ///   thread already — no further hop needed here.
    func ingestRemoteOutput(_ data: Data) {
        guard isRunning, let token = currentToken, token != "pending" else { return }
        guard let chunk = String(data: data, encoding: .utf8) else { return }

        outputBuffer += chunk

        let markerText = "\(Self.marker)\(token):"
        guard let range = outputBuffer.range(of: markerText) else {
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

    /// Called by MainApp's existing `onRemoteDisconnect` hook (already inside
    /// `Task { @MainActor in ... }`) so a run in progress doesn't get stuck
    /// showing "Running…" after the link drops.
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
