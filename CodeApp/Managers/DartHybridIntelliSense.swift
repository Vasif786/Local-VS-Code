//
//  DartHybridIntelliSense.swift
//  Code
//
//  Adds VS Code-style Dart/Flutter editing support for SSH-connected
//  remote projects, WITHOUT a full Language Server Protocol connection —
//  see the architecture diagram in the original feature request. Two
//  independent pieces:
//
//  1. Completion ("IntelliSense"): a Monaco `CompletionItemProvider`
//     registered via one injected JS snippet, backed by a curated,
//     easily-extended table of Dart core + Flutter widget symbols, with a
//     light heuristic for member-access context (`text.` → String members,
//     `myList.` → List members if `myList` was declared nearby). This runs
//     entirely inside Monaco's JS — no native round-trip per keystroke.
//
//  2. Diagnostics: on a debounced content change, the CURRENT UNSAVED
//     content is written to a hidden temp file next to the real one (over
//     the app's existing SFTP connection), and `dart analyze
//     --format=machine` is run against it over a short-lived, one-shot SSH
//     session that connects, runs the one command, and disconnects — no
//     persistent second session sitting alongside the interactive
//     terminal. Results are converted to Monaco markers and pushed through
//     `monaco.editor.setModelMarkers`, which the app's existing
//     `markersDidUpdate` delegate callback already picks up generically
//     (that's also what feeds the Problems panel) — so red/yellow
//     underlines and hover messages work with no other app changes.
//
//  Known limitation (per the "don't fake it" requirement): the completion
//  provider's member-access detection is a light regex heuristic over the
//  visible text, not real semantic/type analysis — it won't resolve types
//  that come from a chained call, a function's return value, or another
//  file. Real cross-file semantic completion would require the actual
//  analysis server's completion endpoint (i.e. real LSP), which is exactly
//  what this hybrid approach deliberately avoids. Diagnostics ARE real
//  (they come straight from `dart analyze`), just not live-as-you-type at
//  the token level — only after the debounce.
//

import Foundation
import NMSSH

// MARK: - Curated, extensible Dart/Flutter completion database (JS side)

/// Injected once per Monaco session. Safe to inject multiple times (guarded
/// by a `window` flag) since it's re-sent defensively whenever Dart support
/// activates for a newly opened file.
private let dartCompletionProviderScript = #"""
(function () {
    if (window.__codeappDartProviderInstalled) { return; }
    window.__codeappDartProviderInstalled = true;

    // Extend these tables to add more symbols — no other code needs to change.
    var DART_KEYWORDS = ["abstract","as","assert","async","await","break","case",
        "catch","class","const","continue","covariant","default","deferred","do",
        "dynamic","else","enum","export","extends","extension","external","factory",
        "false","final","finally","for","Function","get","hide","if","implements",
        "import","in","interface","is","late","library","mixin","new","null","on",
        "operator","part","required","rethrow","return","set","show","static",
        "super","switch","sync","this","throw","true","try","typedef","var","void",
        "while","with","yield"];

    var TOP_LEVEL = [
        {l:"print", k:"Function", d:"void print(Object? object)", doc:"Prints object to the console."},
        {l:"String", k:"Class", d:"class String", doc:"A sequence of UTF-16 code units."},
        {l:"int", k:"Class", d:"class int", doc:"An integer number."},
        {l:"double", k:"Class", d:"class double", doc:"A double-precision floating point number."},
        {l:"bool", k:"Class", d:"class bool", doc:"true or false."},
        {l:"num", k:"Class", d:"class num", doc:"Common superclass of int and double."},
        {l:"List", k:"Class", d:"class List<E>", doc:"An indexable collection of objects."},
        {l:"Map", k:"Class", d:"class Map<K, V>", doc:"A collection of key/value pairs."},
        {l:"Set", k:"Class", d:"class Set<E>", doc:"A collection of unique objects."},
        {l:"Future", k:"Class", d:"class Future<T>", doc:"The result of an asynchronous computation."},
        {l:"Duration", k:"Class", d:"class Duration", doc:"A span of time."},
        {l:"void main()", k:"Function", d:"void main()", doc:"Program entry point.", insert:"void main() {\n\t$0\n}"}
    ];

    var MEMBERS = {
        "String": [
            {l:"length", k:"Property", d:"int length"},
            {l:"isEmpty", k:"Property", d:"bool isEmpty"},
            {l:"isNotEmpty", k:"Property", d:"bool isNotEmpty"},
            {l:"toUpperCase", k:"Method", d:"String toUpperCase()"},
            {l:"toLowerCase", k:"Method", d:"String toLowerCase()"},
            {l:"trim", k:"Method", d:"String trim()"},
            {l:"split", k:"Method", d:"List<String> split(Pattern pattern)"},
            {l:"substring", k:"Method", d:"String substring(int start, [int? end])"},
            {l:"contains", k:"Method", d:"bool contains(Pattern other)"},
            {l:"replaceAll", k:"Method", d:"String replaceAll(Pattern from, String to)"},
            {l:"startsWith", k:"Method", d:"bool startsWith(Pattern other)"},
            {l:"endsWith", k:"Method", d:"bool endsWith(String other)"},
            {l:"indexOf", k:"Method", d:"int indexOf(Pattern pattern)"},
            {l:"codeUnitAt", k:"Method", d:"int codeUnitAt(int index)"}
        ],
        "List": [
            {l:"add", k:"Method", d:"void add(E value)"},
            {l:"addAll", k:"Method", d:"void addAll(Iterable<E> iterable)"},
            {l:"remove", k:"Method", d:"bool remove(Object? value)"},
            {l:"removeAt", k:"Method", d:"E removeAt(int index)"},
            {l:"length", k:"Property", d:"int length"},
            {l:"isEmpty", k:"Property", d:"bool isEmpty"},
            {l:"isNotEmpty", k:"Property", d:"bool isNotEmpty"},
            {l:"map", k:"Method", d:"Iterable<T> map<T>(T Function(E) f)"},
            {l:"where", k:"Method", d:"Iterable<E> where(bool Function(E) test)"},
            {l:"forEach", k:"Method", d:"void forEach(void Function(E) f)"},
            {l:"sort", k:"Method", d:"void sort([int Function(E, E)? compare])"},
            {l:"contains", k:"Method", d:"bool contains(Object? element)"},
            {l:"first", k:"Property", d:"E first"},
            {l:"last", k:"Property", d:"E last"},
            {l:"join", k:"Method", d:"String join([String separator])"}
        ],
        "Map": [
            {l:"keys", k:"Property", d:"Iterable<K> keys"},
            {l:"values", k:"Property", d:"Iterable<V> values"},
            {l:"containsKey", k:"Method", d:"bool containsKey(Object? key)"},
            {l:"containsValue", k:"Method", d:"bool containsValue(Object? value)"},
            {l:"remove", k:"Method", d:"V? remove(Object? key)"},
            {l:"forEach", k:"Method", d:"void forEach(void Function(K, V) f)"},
            {l:"isEmpty", k:"Property", d:"bool isEmpty"},
            {l:"isNotEmpty", k:"Property", d:"bool isNotEmpty"},
            {l:"length", k:"Property", d:"int length"}
        ],
        "int": [
            {l:"toString", k:"Method", d:"String toString()"},
            {l:"toDouble", k:"Method", d:"double toDouble()"},
            {l:"isEven", k:"Property", d:"bool isEven"},
            {l:"isOdd", k:"Property", d:"bool isOdd"},
            {l:"abs", k:"Method", d:"int abs()"}
        ],
        "double": [
            {l:"toString", k:"Method", d:"String toString()"},
            {l:"toInt", k:"Method", d:"int toInt()"},
            {l:"round", k:"Method", d:"int round()"},
            {l:"floor", k:"Method", d:"int floor()"},
            {l:"ceil", k:"Method", d:"int ceil()"}
        ]
    };

    var FLUTTER_WIDGETS = [
        {l:"Container", k:"Constructor", d:"Container({Key? key, ...})", doc:"A convenience widget for common painting/positioning/sizing."},
        {l:"Center", k:"Constructor", d:"Center({Key? key, Widget? child})", doc:"Centers its child."},
        {l:"Column", k:"Constructor", d:"Column({List<Widget> children})", doc:"Lays out children vertically."},
        {l:"Row", k:"Constructor", d:"Row({List<Widget> children})", doc:"Lays out children horizontally."},
        {l:"Stack", k:"Constructor", d:"Stack({List<Widget> children})", doc:"Overlaps children."},
        {l:"Scaffold", k:"Constructor", d:"Scaffold({PreferredSizeWidget? appBar, Widget? body, ...})", doc:"Basic Material Design visual layout."},
        {l:"AppBar", k:"Constructor", d:"AppBar({Widget? title, List<Widget>? actions})", doc:"A Material Design app bar."},
        {l:"Text", k:"Constructor", d:"Text(String data, {TextStyle? style})", doc:"Displays a string of text."},
        {l:"Icon", k:"Constructor", d:"Icon(IconData icon, {double? size, Color? color})"},
        {l:"Image", k:"Constructor", d:"Image.network(String src)"},
        {l:"ListView", k:"Constructor", d:"ListView({List<Widget> children})", doc:"A scrollable list of widgets."},
        {l:"ListView.builder", k:"Constructor", d:"ListView.builder({required int itemCount, required IndexedWidgetBuilder itemBuilder})"},
        {l:"Padding", k:"Constructor", d:"Padding({required EdgeInsetsGeometry padding, Widget? child})"},
        {l:"SizedBox", k:"Constructor", d:"SizedBox({double? width, double? height, Widget? child})"},
        {l:"ElevatedButton", k:"Constructor", d:"ElevatedButton({required VoidCallback? onPressed, required Widget child})"},
        {l:"TextButton", k:"Constructor", d:"TextButton({required VoidCallback? onPressed, required Widget child})"},
        {l:"TextField", k:"Constructor", d:"TextField({TextEditingController? controller})"},
        {l:"MaterialApp", k:"Constructor", d:"MaterialApp({Widget? home, String? title})"},
        {l:"StatelessWidget", k:"Class", d:"abstract class StatelessWidget extends Widget"},
        {l:"StatefulWidget", k:"Class", d:"abstract class StatefulWidget extends Widget"},
        {l:"Expanded", k:"Constructor", d:"Expanded({required Widget child, int flex = 1})"},
        {l:"Flexible", k:"Constructor", d:"Flexible({required Widget child})"},
        {l:"SafeArea", k:"Constructor", d:"SafeArea({required Widget child})"},
        {l:"GestureDetector", k:"Constructor", d:"GestureDetector({VoidCallback? onTap, required Widget child})"}
    ];

    function kindOf(k) {
        var m = monaco.languages.CompletionItemKind;
        switch (k) {
            case "Class": return m.Class;
            case "Constructor": return m.Constructor;
            case "Function": return m.Function;
            case "Method": return m.Method;
            case "Property": return m.Property;
            case "Keyword": return m.Keyword;
            default: return m.Text;
        }
    }

    function toSuggestion(item, range) {
        return {
            label: item.l,
            kind: kindOf(item.k),
            detail: item.d || "",
            documentation: item.doc || "",
            insertText: item.insert || item.l,
            insertTextRules: item.insert
                ? monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet
                : undefined,
            range: range
        };
    }

    // Very light heuristic, NOT semantic analysis: look for the nearest
    // "TYPE name =" declaration of `varName` above the cursor. Doesn't
    // resolve types from function returns, chained calls, or other files.
    function inferSimpleType(model, varName) {
        var text = model.getValue();
        var re = new RegExp("\\b(String|int|double|bool|List(?:<[^>]*>)?|Map(?:<[^>]*>)?)\\s+" + varName + "\\b");
        var m = text.match(re);
        if (m) {
            if (m[1].indexOf("List") === 0) return "List";
            if (m[1].indexOf("Map") === 0) return "Map";
            return m[1];
        }
        if (new RegExp("\\b" + varName + "\\s*=\\s*['\"]").test(text)) return "String";
        if (new RegExp("\\b" + varName + "\\s*=\\s*\\[").test(text)) return "List";
        if (new RegExp("\\b" + varName + "\\s*=\\s*\\{").test(text)) return "Map";
        return null;
    }

    monaco.languages.registerCompletionItemProvider('dart', {
        triggerCharacters: ['.', ':', ' '],
        provideCompletionItems: function (model, position) {
            var line = model.getLineContent(position.lineNumber);
            var textBeforeCursor = line.substring(0, position.column - 1);
            var wordInfo = model.getWordUntilPosition(position);
            var range = {
                startLineNumber: position.lineNumber, endLineNumber: position.lineNumber,
                startColumn: wordInfo.startColumn, endColumn: wordInfo.endColumn
            };

            var dotMatch = textBeforeCursor.match(/([A-Za-z_][A-Za-z0-9_]*)\.\s*[A-Za-z0-9_]*$/);
            if (dotMatch) {
                var inferred = inferSimpleType(model, dotMatch[1]);
                var members = inferred ? MEMBERS[inferred] : null;
                if (members) {
                    return { suggestions: members.map(function (m) { return toSuggestion(m, range); }) };
                }
                // Unknown receiver type: offer nothing rather than a
                // misleading guess (see the file header's known limitation).
                return { suggestions: [] };
            }

            var widgetPropertyContext =
                /\b(body|child|home|title|leading|trailing|floatingActionButton|appBar|content)\s*:\s*[A-Za-z0-9_]*$/;
            if (widgetPropertyContext.test(textBeforeCursor)) {
                return { suggestions: FLUTTER_WIDGETS.map(function (w) { return toSuggestion(w, range); }) };
            }

            var all = DART_KEYWORDS.map(function (k) { return { l: k, k: "Keyword" }; })
                .concat(TOP_LEVEL)
                .concat(FLUTTER_WIDGETS);
            return { suggestions: all.map(function (s) { return toSuggestion(s, range); }) };
        }
    });
})();
"""#

// MARK: - Diagnostics (one-shot remote `dart analyze`)

private enum DartAnalyzeSeverity: String {
    case error = "ERROR"
    case warning = "WARNING"
    case info = "INFO"
    case lint = "LINT"

    /// Matches monaco.MarkerSeverity (Hint=1, Info=2, Warning=4, Error=8).
    var monacoValue: Int {
        switch self {
        case .error: return 8
        case .warning: return 4
        case .info, .lint: return 2
        }
    }
}

private struct DartDiagnostic {
    let severity: DartAnalyzeSeverity
    let message: String
    let line: Int
    let column: Int
    let length: Int
}

/// Runs one command over a short-lived, dedicated SSH session (connect →
/// run → disconnect). Never shares a session/channel with the interactive
/// terminal — NMSSH's own docs say its classes aren't safe to use
/// concurrently from different threads, and the terminal's channel is a
/// PTY, unsuitable for machine-readable output anyway.
private final class OneShotSSHCommandRunner: NSObject, NMSSHChannelDelegate {
    private var session: NMSSHSession?
    private let queue = DispatchQueue(label: "dart-analyze.oneshot.queue")
    private var outputBuffer = ""
    private var continuation: CheckedContinuation<String, Error>?
    private var marker: String = ""

    enum RunnerError: Error { case connectFailed, timedOut }

    func run(host: URL, authenticationMode: RemoteAuthenticationMode, command: String, timeoutSeconds: Double = 15)
        async throws -> String
    {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            self.continuation = continuation
            let token = UUID().uuidString.prefix(8)
            self.marker = "__DARTANALYZE_DONE__\(token)__"

            queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                self?.finish(.failure(RunnerError.timedOut))
            }

            queue.async { [weak self] in
                guard let self = self, let hostname = host.host, let port = host.port else {
                    self?.finish(.failure(RunnerError.connectFailed))
                    return
                }

                let session = NMSSHSession(
                    host: hostname, port: port,
                    andUsername: authenticationMode.credentials.user ?? "")
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
                    self.finish(.failure(RunnerError.connectFailed))
                    return
                }

                self.session = session
                session.channel.requestPty = false
                try? session.channel.startShell()

                let fullCommand = "\(command); echo \"\(self.marker)$?\"\n"
                var err: NSError?
                if let data = fullCommand.data(using: .utf8) {
                    session.channel.write(data, error: &err, timeout: 5)
                }
            }
        }
    }

    func channel(_ channel: NMSSHChannel, didReadRawData data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.outputBuffer += text
            guard let range = self.outputBuffer.range(of: self.marker) else { return }
            let output = String(self.outputBuffer[..<range.lowerBound])
            self.finish(.success(output))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation = self.continuation else { return }  // already finished once
        self.continuation = nil
        session?.channel.closeShell()
        session?.disconnect()
        session = nil
        continuation.resume(with: result)
    }
}

// MARK: - Coordinator

@MainActor
final class DartHybridIntelliSense {
    static let shared = DartHybridIntelliSense()
    private init() {}

    private static let tempFileSuffix = ".codeapp_analyze.dart"

    private var debounceTask: DispatchWorkItem?
    private var isAnalyzing = false
    private var pending: (editorURL: URL, content: String)?

    /// Call when a remote `.dart` file (inside a Flutter project's `lib/`)
    /// becomes the active editor. Installs the completion provider (no-op
    /// if already installed) and requests markers for the current content
    /// immediately, so diagnostics don't wait for the first edit.
    func activate(app: MainApp, editorURL: URL, content: String) {
        Task {
            _ = try? await (app.monacoInstance as? MonacoImplementation)?
                .executeCustomScript(dartCompletionProviderScript)
        }
        scheduleAnalysis(app: app, editorURL: editorURL, content: content)
    }

    /// Call on every content change for the active file (from
    /// `MainApp.editorImplementation(contentDidChangeForModelURL:...)`) —
    /// debounces internally, so callers don't need to.
    func scheduleAnalysis(app: MainApp, editorURL: URL, content: String) {
        debounceTask?.cancel()
        let task = DispatchWorkItem { [weak app] in
            guard let app = app else { return }
            Task { await DartHybridIntelliSense.shared.runOrQueue(app: app, editorURL: editorURL, content: content) }
        }
        debounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }

    private func runOrQueue(app: MainApp, editorURL: URL, content: String) async {
        guard !isAnalyzing else {
            pending = (editorURL, content)  // coalesce: only the latest edit matters
            return
        }
        isAnalyzing = true
        await runAnalysis(app: app, editorURL: editorURL, content: content)
        isAnalyzing = false

        if let next = pending {
            pending = nil
            await runOrQueue(app: app, editorURL: next.editorURL, content: next.content)
        }
    }

    /// Finds the Dart/Flutter project root for a file: the nearest ancestor
    /// directory containing `pubspec.yaml`, checked over the app's existing
    /// SFTP connection. Unlike the Run feature's `flutterProjectRoot`
    /// (which specifically requires a `lib/` folder, since that's how
    /// `flutter run` locates the app entry point), this works for ANY
    /// `.dart` file anywhere in the project — `bin/`, `test/`, the project
    /// root itself, or nested arbitrarily deep.
    ///
    /// If no `pubspec.yaml` is found anywhere up to the SSH connection's
    /// own root, falls back to the file's own directory — `dart analyze`
    /// can still catch syntax-level issues in a standalone file, just
    /// without full package/import resolution. This fallback is a real,
    /// documented limitation, not a silent failure.
    private func dartAnalysisRoot(app: MainApp, forFileURL fileURL: URL) async -> URL {
        let fileDirectory = fileURL.deletingLastPathComponent()
        guard let sshRoot = URL(string: app.workSpaceStorage.currentDirectory.url) else {
            return fileDirectory
        }

        var current = fileDirectory
        while true {
            if await fileExistsOnRemote(app: app, directory: current, relativePath: "pubspec.yaml") {
                return current
            }
            if current.path == sshRoot.path { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }  // reached filesystem root
            current = parent
        }
        return fileDirectory  // no pubspec.yaml found anywhere — analyze standalone
    }

    private func fileExistsOnRemote(app: MainApp, directory: URL, relativePath: String) async -> Bool {
        (try? await app.workSpaceStorage.fileExists(at: directory.appendingPathComponent(relativePath)))
            ?? false
    }

    private func runAnalysis(app: MainApp, editorURL: URL, content: String) async {
        guard app.workSpaceStorage.remoteConnected,
            let connectionInfo = app.workSpaceStorage.currentRemoteConnectionInfo
        else {
            return
        }
        let projectRoot = await dartAnalysisRoot(app: app, forFileURL: editorURL)

        let tempURL = editorURL.deletingLastPathComponent()
            .appendingPathComponent("." + editorURL.deletingPathExtension().lastPathComponent + Self.tempFileSuffix)
        let rootPath = projectRoot.path
        let relativeTempPath = String(tempURL.path.dropFirst((rootPath.hasSuffix("/") ? rootPath : rootPath + "/").count))
        let quotedRoot = "'" + rootPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let quotedRelativeTemp = "'" + relativeTempPath.replacingOccurrences(of: "'", with: "'\\''") + "'"

        guard let contentData = content.data(using: .utf8) else { return }
        try? await app.workSpaceStorage.write(
            at: tempURL, content: contentData, atomically: true, overwrite: true)
        defer {
            Task { try? await app.workSpaceStorage.removeItem(at: tempURL) }
        }

        let command = "cd \(quotedRoot) && dart analyze --format=machine \(quotedRelativeTemp)"
        let output: String
        do {
            output = try await OneShotSSHCommandRunner().run(
                host: connectionInfo.host, authenticationMode: connectionInfo.authenticationMode,
                command: command)
        } catch {
            return  // background diagnostics — fail silently, don't interrupt typing
        }

        let diagnostics = Self.parseMachineOutput(output)
        await pushMarkers(app: app, editorURL: editorURL, diagnostics: diagnostics)
    }

    /// Parses `dart analyze --format=machine` output:
    /// SEVERITY|TYPE|ERROR_CODE|FILE|LINE|COLUMN|LENGTH|MESSAGE
    private static func parseMachineOutput(_ output: String) -> [DartDiagnostic] {
        var results: [DartDiagnostic] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 7, omittingEmptySubsequences: false)
            guard parts.count == 8,
                let severity = DartAnalyzeSeverity(rawValue: String(parts[0])),
                let lineNumber = Int(parts[4]),
                let column = Int(parts[5]),
                let length = Int(parts[6])
            else {
                continue
            }
            results.append(
                DartDiagnostic(
                    severity: severity, message: String(parts[7]), line: lineNumber, column: column,
                    length: max(length, 1)))
        }
        return results
    }

    private func pushMarkers(app: MainApp, editorURL: URL, diagnostics: [DartDiagnostic]) async {
        guard let monaco = app.monacoInstance as? MonacoImplementation else { return }

        let markersJSON = diagnostics.map { d -> String in
            let escapedMessage =
                d.message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            return """
                {"severity":\(d.severity.monacoValue),"message":"\(escapedMessage)",\
                "startLineNumber":\(d.line),"startColumn":\(d.column),\
                "endLineNumber":\(d.line),"endColumn":\(d.column + d.length)}
                """
        }.joined(separator: ",")

        let script = """
            (function() {
                var model = monaco.editor.getModel(monaco.Uri.parse("\(editorURL.absoluteString)"));
                if (!model) { return; }
                monaco.editor.setModelMarkers(model, "dart-analyzer", [\(markersJSON)]);
            })();
            """
        _ = try? await monaco.executeCustomScript(script)
    }
}
