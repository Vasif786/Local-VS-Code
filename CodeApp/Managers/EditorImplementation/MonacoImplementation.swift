//
//  MonacoImplementation.swift
//  Code
//
//  Created by Ken Chung on 01/02/2024.
//

import Foundation
import GCDWebServers
import GameController
import SwiftUI
import WebKit

class EditorService {
    static let PORT = 20234
    private let webServer = GCDWebServer()

    init() {
        let basePath = "/"
        let directoryPath =
            Bundle.main.path(forResource: "monaco-textmate", ofType: "bundle")! + "/"
        webServer.addGETHandler(
            forBasePath: "/", directoryPath: directoryPath, indexFilename: "index.html",
            cacheAge: 10, allowRangeRequests: true)
        try? webServer.start(options: [
            GCDWebServerOption_AutomaticallySuspendInBackground: true,
            GCDWebServerOption_Port: EditorService.PORT,
        ])
    }
}

extension WKWebView {
    @MainActor
    @discardableResult
    func evaluateJavaScriptAsync(_ str: String) async throws -> Any? {
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Any?, Error>) in
            DispatchQueue.main.async {
                self.evaluateJavaScript(str) { data, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: data)
                    }
                }
            }
        }
    }
}

class MonacoImplementation: NSObject {
    private var monacoWebView = WebViewBase()
    var options: EditorOptions {
        didSet {
            Task { await configureCustomOptions() }
        }
    }
    var theme: EditorTheme {
        didSet {
            Task { await configureTheme() }
        }
    }
    weak var delegate: EditorImplementationDelegate?

    init(options: EditorOptions, theme: EditorTheme) {
        self.options = options
        self.theme = theme
        super.init()

        monacoWebView.isOpaque = false
        monacoWebView.scrollView.bounces = false
        monacoWebView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) AppleWebKit/605.1.15 (KHTML, like Gecko) CodeApp"
        monacoWebView.contentMode = .scaleToFill

        if !monacoWebView.isMessageHandlerAdded {
            let contentManager = monacoWebView.configuration.userContentController
            contentManager.add(self, name: "toggleMessageHandler")
            contentManager.add(self, name: "dartLSPMessageHandler")
            monacoWebView.isMessageHandlerAdded = true
        }

        let request = URLRequest(
            url: URL(string: "http://localhost:\(String(EditorService.PORT))/index.html")!)
        monacoWebView.load(request)
    }

    private func setupEditor() async {
        await monacoWebView.removeUIDropInteraction()
        await configureCustomOptions()
        await configureTheme()

        // Built-in Node.js types
        await injectTypes(
            url: Bundle.main.url(forResource: "npm", withExtension: "bundle")!
                .appendingPathComponent("node_modules/@types"))
    }

    private func configureTheme() async {
        if let dark = theme.dark {
            await setVSTheme(theme: dark)
        }
        if let light = theme.light {
            await setVSTheme(theme: light)
        }
    }

    private func configureCustomOptions() async {
        await applyOptions(options: "automaticLayout: true, lineNumbersMinChars: 5")
        await applyOptions(options: "fontSize: \(String(options.fontSize))")
        await applyFont(fontFamily: options.fontFamily)
        await applyOptions(options: "autoClosingBrackets: \(options.autoClosingBrackets)")
        await applyOptions(options: "minimap: {enabled: \(options.miniMapEnabled)}")
        await applyOptions(options: "lineNumbers: \(options.lineNumbersEnabled)")
        await applyOptions(options: "smoothScrolling: \(options._smoothScrollingEnabled)")
        await applyOptions(options: "readOnly: \(options.readOnly)")
        await applyOptions(options: "tabSize: \(String(options.tabRenderSize))")
        await applyOptions(options: "renderWhitespace: '\(options.renderWhiteSpaces)'")
        await applyOptions(options: "wordWrap: '\(options.wordWrap)'")
        _ = try? await monacoWebView.evaluateJavaScriptAsync("toggleVimMode(\(options.vimEnabled))")
        await MainActor.run {
            if options.toolBarEnabled {
                let toolbar = UIHostingController(
                    rootView: EditorKeyboardToolBar(editorImplementation: self))
                toolbar.view.frame = CGRect(
                    x: 0, y: 0, width: (monacoWebView.bounds.width), height: 40)
                monacoWebView.addInputAccessoryView(toolbar: toolbar.view)
            } else {
                monacoWebView.removeInputAccessoryView()
            }
        }
    }

    private func applyOptions(options: String) async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync("editor.updateOptions({\(options)})")
    }

    private func provideOriginalTextForUri(uri: String, value: String) async {
        guard let encoded = value.base64Encoded() else {
            return
        }
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "provideOriginalTextForUri(`\(uri)`, `\(encoded)`)")
    }

    private func applyFont(fontFamily: String) async {
        guard
            let percentEncoded = fontFamily.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed)
        else {
            return
        }
        let js = """
            var styles = `
                @font-face {
                font-family: "\(fontFamily)";
                src: local("\(fontFamily)"),
                  url("fonts://\(percentEncoded).ttf") format("truetype");
              }
            `
            var styleSheet = document.createElement("style")
            styleSheet.innerHTML = styles
            document.head.appendChild(styleSheet)
            """
        _ = try? await monacoWebView.evaluateJavaScriptAsync(js)
        await applyOptions(options: "fontFamily: \"\(fontFamily)\"")
    }

    private func injectTypes(url: URL) async {
        var files = [URL]()
        if let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        {
            for case let fileURL as URL in enumerator {
                do {
                    let fileAttributes = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    if fileAttributes.isRegularFile!, fileURL.absoluteString.hasSuffix("d.ts") {
                        files.append(fileURL)
                    }
                } catch { print(error, fileURL) }
            }
        }
        for file in files {
            guard
                let encodedContent = try? String(contentsOf: file, encoding: .utf8).base64Encoded()
            else {
                continue
            }
            var path = file.absoluteString
            if !file.absoluteString.contains("@types"), file.absoluteString.contains("node_modules")
            {
                path = path.replacingOccurrences(of: "node_modules", with: "node_modules/@types")
            }
            _ = try? await monacoWebView.evaluateJavaScriptAsync(
                "monaco.languages.typescript.javascriptDefaults.addExtraLib(decodeURIComponent(escape(window.atob('\(encodedContent)'))),'\(path)')"
            )
            _ = try? await monacoWebView.evaluateJavaScriptAsync(
                "monaco.languages.typescript.typescriptDefaults.addExtraLib(decodeURIComponent(escape(window.atob('\(encodedContent)'))),'\(path)')"
            )
        }
    }
    static let remoteDartLSPBridgeScript = #"""
(function () {
    if (window.__codeappRemoteDartLSPInstalled) { return; }
    window.__codeappRemoteDartLSPInstalled = true;
    const pending = new Map();
    let nextId = 1;
    const opened = new Map();
    let initialized = false;

    function post(payload) {
        window.webkit.messageHandlers.dartLSPMessageHandler.postMessage({
            Event: "DartLSP",
            Payload: JSON.stringify(payload)
        });
    }
    function request(method, params) {
        return new Promise((resolve, reject) => {
            const id = nextId++;
            pending.set(id, {resolve, reject});
            post({jsonrpc:"2.0", id:id, method:method, params:params});
        });
    }
    function notify(method, params) {
        post({jsonrpc:"2.0", method:method, params:params});
    }
    function remoteFileURI(uri) {
        try {
            const u = new URL(uri);
            if (u.protocol === "file:") return u.toString();
            if (u.protocol === "sftp:") {
                return "file://" + encodeURI(decodeURIComponent(u.pathname));
            }
        } catch (_) {}
        return uri;
    }
    function modelForURI(uri) {
        const models = monaco.editor.getModels();
        for (const m of models) {
            if (m.uri.toString() === uri) return m;
            if (remoteFileURI(m.uri.toString()) === uri) return m;
        }
        return null;
    }
    function markdownValue(value) {
        if (!value) return "";
        if (typeof value === "string") return value;
        if (value.value) return value.value;
        return String(value);
    }
    function lspPosition(position) {
        return {line: position.lineNumber - 1, character: position.column - 1};
    }
    function monacoRange(range) {
        if (!range) return undefined;
        return {
            startLineNumber: range.start.line + 1,
            startColumn: range.start.character + 1,
            endLineNumber: range.end.line + 1,
            endColumn: range.end.character + 1
        };
    }
    function completionKind(k) {
        const map = {1:17,2:19,3:18,4:1,5:2,6:3,7:4,8:5,9:6,10:7,11:8,12:9,13:10,14:11,15:12,16:13,17:14,18:15,19:16,20:21,21:22,22:23,23:24,24:25};
        return map[k] || monaco.languages.CompletionItemKind.Text;
    }
    function sendDidOpen(model) {
        if (!model || model.getLanguageId() !== "dart") return;
        const key = model.uri.toString();
        if (opened.has(key)) return;
        const uri = remoteFileURI(key);
        opened.set(key, {version:1});
        notify("textDocument/didOpen", {
            textDocument: {uri:uri, languageId:"dart", version:1, text:model.getValue()}
        });
    }
    function attachModel(model) {
        if (!model || model.getLanguageId() !== "dart") return;
        sendDidOpen(model);
        if (model.__codeappDartLSPAttached) return;
        model.__codeappDartLSPAttached = true;
        model.onDidChangeContent(function () {
            const key = model.uri.toString();
            let state = opened.get(key);
            if (!state) { sendDidOpen(model); state = opened.get(key); }
            if (!state) return;
            state.version += 1;
            notify("textDocument/didChange", {
                textDocument:{uri:remoteFileURI(key), version:state.version},
                contentChanges:[{text:model.getValue()}]
            });
        });
        model.onWillDispose(function () {
            if (opened.has(key)) {
                notify("textDocument/didClose", {textDocument:{uri:remoteFileURI(key)}});
                opened.delete(key);
            }
        });
    }
    function attachAll() {
        monaco.editor.getModels().forEach(attachModel);
        const current = monaco.editor.getModel();
        if (current) attachModel(current);
    }

    window.__codeappDartLSPReceive = function (base64) {
        let message;
        try { message = JSON.parse(decodeURIComponent(escape(atob(base64)))); } catch (_) { return; }
        if (message.id !== undefined && pending.has(message.id)) {
            const p = pending.get(message.id); pending.delete(message.id);
            if (message.error) p.reject(message.error); else p.resolve(message.result);
            return;
        }
        if (message.method === "textDocument/publishDiagnostics") {
            const p = message.params || {};
            const model = modelForURI(p.uri);
            if (!model) return;
            const markers = (p.diagnostics || []).map(function(d) {
                let sev = monaco.MarkerSeverity.Info;
                if (d.severity === 1) sev = monaco.MarkerSeverity.Error;
                else if (d.severity === 2) sev = monaco.MarkerSeverity.Warning;
                else if (d.severity === 3) sev = monaco.MarkerSeverity.Info;
                else if (d.severity === 4) sev = monaco.MarkerSeverity.Hint;
                return {
                    severity:sev,
                    message:(d.message || "") + (d.code ? " [" + d.code + "]" : ""),
                    startLineNumber:d.range.start.line + 1,
                    startColumn:d.range.start.character + 1,
                    endLineNumber:d.range.end.line + 1,
                    endColumn:d.range.end.character + 1
                };
            });
            monaco.editor.setModelMarkers(model, "dart-language-server", markers);
        }
    };
    window.__codeappDartLSPStop = function () {
        initialized = false;
        pending.forEach(p => p.reject("Dart language server stopped"));
        pending.clear();
        monaco.editor.getModels().forEach(m => monaco.editor.setModelMarkers(m, "dart-language-server", []));
    };

    window.__codeappStartDartLSP = async function () {
        attachAll();
        const model = monaco.editor.getModel();
        if (!model || model.getLanguageId() !== "dart") return;
        const root = remoteFileURI(model.uri.toString()).split("/").slice(0,-1).join("/") || "file:///";
        try {
            await request("initialize", {
                processId:null,
                clientInfo:{name:"Code App",version:"remote-dart-lsp"},
                rootUri:root,
                workspaceFolders:[{uri:root,name:"Flutter Project"}],
                capabilities:{
                    textDocument:{
                        completion:{completionItem:{snippetSupport:true,documentationFormat:["markdown","plaintext"]}},
                        hover:{contentFormat:["markdown","plaintext"]},
                        signatureHelp:{signatureInformation:{documentationFormat:["markdown","plaintext"]}},
                        codeAction:{codeActionLiteralSupport:{codeActionKind:{valueSet:["quickfix","refactor","source"]}}}
                    },
                    workspace:{applyEdit:true,workspaceEdit:{documentChanges:true}}
                }
            });
            notify("initialized", {});
            initialized = true;
            attachAll();
        } catch (_) {}
    };

    monaco.languages.registerCompletionItemProvider("dart", {
        triggerCharacters:[".",":"],
        provideCompletionItems: async function(model, position) {
            attachModel(model);
            if (!initialized) return {suggestions:[]};
            try {
                const result = await request("textDocument/completion", {
                    textDocument:{uri:remoteFileURI(model.uri.toString())},
                    position:lspPosition(position),
                    context:{triggerKind:1}
                });
                const items = Array.isArray(result) ? result : ((result && result.items) || []);
                const word = model.getWordUntilPosition(position);
                const range = {startLineNumber:position.lineNumber,endLineNumber:position.lineNumber,startColumn:word.startColumn,endColumn:position.column};
                return {suggestions:items.map(function(item) {
                    const text = item.textEdit && item.textEdit.newText ? item.textEdit.newText : (item.insertText || item.label);
                    return {
                        label:item.label,
                        kind:completionKind(item.kind),
                        detail:item.detail || "",
                        documentation:markdownValue(item.documentation),
                        sortText:item.sortText,
                        filterText:item.filterText,
                        insertText:text,
                        insertTextRules:item.insertTextFormat === 2 ? monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet : undefined,
                        range:item.textEdit && item.textEdit.range ? monacoRange(item.textEdit.range) : range
                    };
                })};
            } catch (_) { return {suggestions:[]}; }
        }
    });

    monaco.languages.registerHoverProvider("dart", {
        provideHover: async function(model, position) {
            attachModel(model);
            if (!initialized) return null;
            try {
                const result = await request("textDocument/hover", {textDocument:{uri:remoteFileURI(model.uri.toString())},position:lspPosition(position)});
                if (!result) return null;
                const contents = Array.isArray(result.contents) ? result.contents : [result.contents];
                return {range:monacoRange(result.range),contents:contents.map(c => ({value:markdownValue(c)}))};
            } catch (_) { return null; }
        }
    });

    monaco.languages.registerSignatureHelpProvider("dart", {
        signatureHelpTriggerCharacters:["(",","],
        provideSignatureHelp: async function(model, position) {
            if (!initialized) return null;
            try {
                const result = await request("textDocument/signatureHelp", {textDocument:{uri:remoteFileURI(model.uri.toString())},position:lspPosition(position),context:{triggerKind:1}});
                if (!result) return null;
                return {value:{signatures:(result.signatures||[]).map(s => ({label:s.label,documentation:markdownValue(s.documentation),parameters:(s.parameters||[]).map(p => ({label:p.label,documentation:markdownValue(p.documentation)}))})),activeSignature:result.activeSignature||0,activeParameter:result.activeParameter||0},dispose:function(){}};
            } catch (_) { return null; }
        }
    });

    monaco.languages.registerCodeActionProvider("dart", {
        provideCodeActions: async function(model, range, context) {
            if (!initialized) return {actions:[],dispose:function(){}};
            try {
                const result = await request("textDocument/codeAction", {
                    textDocument:{uri:remoteFileURI(model.uri.toString())},
                    range:{start:lspPosition({lineNumber:range.startLineNumber,column:range.startColumn}),end:lspPosition({lineNumber:range.endLineNumber,column:range.endColumn})},
                    context:{diagnostics:(context.markers||[]).map(m => ({range:{start:{line:m.startLineNumber-1,character:m.startColumn-1},end:{line:m.endLineNumber-1,character:m.endColumn-1}},message:m.message,severity:m.severity}))}
                });
                const actions = (result||[]).filter(a => a && a.title).map(a => {
                    const action = {title:a.title,kind:a.kind || "quickfix",diagnostics:context.markers||[]};
                    if (a.edit && a.edit.changes) {
                        action.edit = {edits:[]};
                        Object.keys(a.edit.changes).forEach(uri => {
                            (a.edit.changes[uri]||[]).forEach(e => action.edit.edits.push({resource:monaco.Uri.parse(uri),edit:{range:monacoRange(e.range),text:e.newText}}));
                        });
                    }
                    return action;
                });
                return {actions:actions,dispose:function(){}};
            } catch (_) { return {actions:[],dispose:function(){}}; }
        }
    });

    const oldModelChanged = monaco.editor.onDidChangeModel;
    monaco.editor.onDidChangeModel(function() { attachAll(); });
    setTimeout(attachAll, 250);
})();
"""#
}

extension MonacoImplementation: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let result = message.body as? [String: AnyObject],
            let event = result["Event"] as? String
        else {
            return
        }

        switch event {
        case "DartLSP":
            guard let payload = result["Payload"] as? String else { return }
            RemoteDartLanguageServer.shared.send(json: payload)
        case "focus":
            delegate?.didEnterFocus()
        case "Request Diff Update":
            guard let modelUri = result["URI"] as? String else { return }
            Task {
                if let updatedText = await delegate?.editorImplementation(
                    requestTextForDiffForModelURL: modelUri, ignoreCache: true)
                {
                    await provideOriginalTextForUri(uri: modelUri, value: updatedText)
                }
            }
        case "Crusor Position changed":
            let lineNumber = result["lineNumber"] as! Int
            let column = result["Column"] as! Int
            delegate?.editorImplementation(cursorPositionDidChange: lineNumber, column: column)
        case "Content changed":
            let version = result["VersionID"] as! Int
            let content = result["currentContent"] as! String
            let modelUri = result["URI"] as! String
            delegate?.editorImplementation(
                contentDidChangeForModelURL: modelUri, content: content, versionID: version)
            Task {
                if let updatedText = await delegate?.editorImplementation(
                    requestTextForDiffForModelURL: modelUri, ignoreCache: false)
                {
                    await provideOriginalTextForUri(uri: modelUri, value: updatedText)
                }
            }
        case "Editor Initialising":
            Task { @MainActor in
                await setupEditor()
                delegate?.didFinishInitialising()
            }
        case "Markers updated":
            guard let markers = result["Markers"] as? [Any] else { return }
            let monacoMarkers = markers.map {
                let jsonData = try! JSONSerialization.data(withJSONObject: $0, options: [])
                return try! JSONDecoder().decode(MonacoEditorMarker.self, from: jsonData)
            }
            delegate?.editorImplementation(markersDidUpdate: monacoMarkers)
        case "Open URL":
            let urlString = result["url"] as! String
            delegate?.editorImplementation(onOpenURL: urlString)
        case "vim.mode.change", "vim.keybuffer.set", "vim.visible.set", "vim.close.input",
            "vim.claer":
            delegate?.editorImplementation(vimModeEvent: event, userInfo: result)
        case "Language Server Connection Dropped":
            let languageIdentifier = result["languageIdentifier"] as! String
            delegate?.editorImplementation(languageServerDidDisconnect: languageIdentifier)
        default:
            print("[MonacoImplementation]: Event '\(event)' not handled.")
        }
    }
}

extension MonacoImplementation: EditorImplementation {
    var view: UIView {
        monacoWebView
    }

    func setModel(url: String) async {
        guard let encodedUrl = url.base64Encoded() else {
            return
        }
        _ = try? await monacoWebView.evaluateJavaScriptAsync("setModel('\(encodedUrl)');")
    }

    func setModelToEmpty() async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync("editor.setModel()")
    }

    func createNewModel(url: String, value: String) async {
        guard let encodedContent = value.base64Encoded(),
            let encodedUrl = url.base64Encoded()
        else {
            return
        }
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "onRequestNewTextModel('\(encodedUrl)', '\(encodedContent)')"
        )
    }

    func renameModel(oldURL: String, updatedURL: String) async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "renameModel(`\(oldURL)`,`\(updatedURL)`)"
        )
    }

    func setValueForModel(url: String, value: String) async {
        guard let encodedContent = value.base64Encoded(),
            let encodedUrl = url.base64Encoded()
        else {
            return
        }
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "setValueForModel('\(encodedUrl)', '\(encodedContent)')"
        )
    }

    func removeAllModels() async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "monaco.editor.getModels().forEach(model => model.dispose());"
        )
    }

    func getViewState() async -> String {
        return
            (try? await monacoWebView.evaluateJavaScriptAsync(
                "JSON.stringify(editor.saveViewState())"
            )) as? String ?? "{}"
    }

    func setVSTheme(theme: Theme) async {
        var theme = theme
        if let base64 = theme.jsonString.base64Encoded() {
            _ = try? await monacoWebView.evaluateJavaScriptAsync(
                "applyBase64AsTheme('\(base64)')")
        }
    }

    func focus() async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync("editor.focus()")
    }

    func blur() async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "document.getElementById('overlay').focus()")
    }

    func searchTermInEditor(term: String) async {
        guard let encoded = term.base64Encoded() else {
            return
        }
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "var decodedCommand = decodeURIComponent(escape(window.atob('\(encoded)')))")
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "var range = editor.getModel().findMatches(decodedCommand)[0].range")
        _ = try? await monacoWebView.evaluateJavaScriptAsync("editor.setSelection(range)")
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "editor.getAction('actions.find').run()")
    }

    func scrollToLine(line: Int) async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync("editor.revealLine(\(String(line)));")
    }

    func openSearchWidget() async {
        await focus()
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "editor.getAction('actions.find').run()")
    }

    func undo() async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync("editor.getModel().undo()")
    }

    func redo() async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync("editor.getModel().redo()")
    }

    func getSelectedValue() async -> String {
        return
            (try? await monacoWebView.evaluateJavaScriptAsync(
                "editor.getModel().getValueInRange(editor.getSelection())")) as? String ?? ""
    }

    func pasteText(text: String) async {
        guard let encoded = text.base64Encoded() else { return }
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "editor.executeEdits('source',[{identifier: {major: 1, minor: 1}, range: editor.getSelection(), text: decodeURIComponent(escape(window.atob('\(encoded)'))), forceMoveMarkers: true}])"
        )
    }

    func insertTextAtCurrentCursor(text: String) async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "editor.trigger('keyboard', 'type', {text: decodeURIComponent(escape(window.atob('\(text)')))})"
        )
    }

    func moveCursor(direction: CursorDirection) async {
        switch direction {
        case .left:
            _ = try? await monacoWebView.evaluateJavaScriptAsync(
                "editor.setPosition({lineNumber: editor.getPosition().lineNumber, column: editor.getPosition().column - 1})"
            )
        case .right:
            _ = try? await monacoWebView.evaluateJavaScriptAsync(
                "editor.setPosition({lineNumber: editor.getPosition().lineNumber, column: editor.getPosition().column + 1})"
            )
        case .up:
            _ = try? await monacoWebView.evaluateJavaScriptAsync(
                "editor.setPosition({lineNumber: editor.getPosition().lineNumber - 1, column: editor.getPosition().column})"
            )
        case .down:
            _ = try? await monacoWebView.evaluateJavaScriptAsync(
                "editor.setPosition({lineNumber: editor.getPosition().lineNumber + 1, column: editor.getPosition().column})"
            )
        }
    }

    func editorInFocus() async -> Bool {
        return
            (try? await monacoWebView.evaluateJavaScriptAsync(
                "document.activeElement.tagName == 'TEXTAREA'")) as? Bool ?? false
    }

    func invalidateDecorations() async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync("invalidateDecorations()")
    }

    func switchToDiffMode(
        originalContent: String, modifiedContent: String, originalUrl: String, modifiedUrl: String
    ) async {
        guard let base64Original = originalContent.base64Encoded(),
            let base64Modified = modifiedContent.base64Encoded(),
            let base64OriginalUrl = originalUrl.base64Encoded(),
            let base64ModifiedUrl = modifiedUrl.base64Encoded()
        else {
            return
        }
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "switchToDiffView('\(base64Original)','\(base64Modified)','\(base64OriginalUrl)','\(base64ModifiedUrl)')"
        )
    }

    func switchToInlineDiffView() async {
        await applyOptions(options: "renderSideBySide: false")
    }

    func switchToNormalMode() async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync("switchToNormalView()")
    }

    func moveToNextDiff() async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync("goToNextDiff()")
    }

    func moveToPreviousDiff() async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync("goToPreviousDiff()")
    }

    func isEditorInDiffMode() async -> Bool {
        let result = try? await monacoWebView.evaluateJavaScriptAsync(
            "document.getElementsByClassName('monaco-diff-editor').length > 0")
        return (result as? Bool) ?? false
    }

    /// Runs arbitrary JS in the Monaco WebView. Used only by the Dart
    /// Execute a custom Monaco script. Used by editor integrations; Dart
    /// completion/diagnostics themselves are provided by the remote LSP bridge.
    func executeCustomScript(_ script: String) async throws -> Any? {
        try await monacoWebView.evaluateJavaScriptAsync(script)
    }

    /// Installs the native bridge used by the remote Dart analysis server.
    /// This is intentionally independent of the old local LSP bridge.
    func installRemoteDartLanguageServerBridge() async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync(Self.remoteDartLSPBridgeScript)
    }

    func startRemoteDartLanguageServer(
        host: URL,
        authenticationMode: RemoteAuthenticationMode,
        onRequestInteractiveKeyboard: @escaping (String) async -> String
    ) async {
        await installRemoteDartLanguageServerBridge()
        RemoteDartLanguageServer.shared.start(
            host: host,
            authenticationMode: authenticationMode,
            onRequestInteractiveKeyboard: onRequestInteractiveKeyboard,
            receiver: { [weak self] message in
                guard let self, let data = message.data(using: .utf8) else { return }
                let encoded = data.base64EncodedString()
                Task { @MainActor in
                    _ = try? await self.monacoWebView.evaluateJavaScriptAsync(
                        "window.__codeappDartLSPReceive('\(encoded)')")
                }
            },
            onReady: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    _ = try? await self.monacoWebView.evaluateJavaScriptAsync(
                        "window.__codeappStartDartLSP && window.__codeappStartDartLSP()")
                }
            })
    }

    func sendRemoteDartLSPMessage(_ json: String) {
        RemoteDartLanguageServer.shared.send(json: json)
    }

    func stopRemoteDartLanguageServer() {
        RemoteDartLanguageServer.shared.stop()
        Task { try? await monacoWebView.evaluateJavaScriptAsync("window.__codeappDartLSPStop && window.__codeappDartLSPStop()") }
    }

    func connectLanguageService(
        serverURL: URL, serverArgs: [String], pwd: URL, languageIdentifier: String
    ) {
        guard let pwdBookmark = try? pwd.bookmarkData(),
            let encodedPwd = pwd.absoluteString.base64Encoded()
        else {
            return
        }
        Task {
            try? await monacoWebView.evaluateJavaScriptAsync(
                """
                connectMonacoToLanguageServer(
                    "\(serverURL.absoluteString)",
                    \(serverArgs),
                    "\(encodedPwd)",
                    "\(pwdBookmark.base64EncodedString())",
                    "\(languageIdentifier)"
                )
                """)
        }
    }

    func disconnectLanguageService() {
        Task {
            try? await monacoWebView.evaluateJavaScriptAsync("disconnectLanguageServer()")
        }
    }

    var isLanguageServiceConnected: Bool {
        get async {
            let result = try? await monacoWebView.evaluateJavaScriptAsync(
                "isLanguageServiceConnected()")
            return (result as? Bool) ?? false
        }
    }

    func _applyCustomShortcuts() async {
        if let result = UserDefaults.standard.value(forKey: "thebaselab.custom.keyboard.shortcuts")
            as? [String: [GCKeyCode]]
        {
            for entry in result {
                let gcCodes = entry.value
                var key = 0
                for gc in gcCodes {
                    if let monacoKey = shortcutsMapping[gc]?.0 {
                        key |= monacoKey
                    }
                }
                let command =
                    "editor.addCommand(\(String(key)), () => editor.trigger('', '\(entry.key)', null), '');"
                _ = try? await monacoWebView.evaluateJavaScriptAsync(command)
            }
        }
    }

    func _toggleCommandPalatte() async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "editor.trigger('', 'editor.action.quickCommand')")
    }

    func _toggleGoToLineWidget() async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "editor.focus();editor.trigger('', 'editor.action.gotoLine')")
    }

    func _restoreEditorState(state: String) async {
        _ = try? await monacoWebView.evaluateJavaScriptAsync(
            "editor.restoreViewState(\(state))")
    }

    func _getMonacoActions() async -> [MonacoEditorAction] {
        let script = "editor.getActions().map((e) => {return {id: e.id, label: e.label}})"
        do {
            guard let result = (try await monacoWebView.evaluateJavaScriptAsync(script)) as? NSArray
            else {
                return []
            }
            let jsonData = try JSONSerialization.data(
                withJSONObject: result, options: [])
            return try JSONDecoder().decode([MonacoEditorAction].self, from: jsonData)
        } catch {
            return []
        }
    }
}
