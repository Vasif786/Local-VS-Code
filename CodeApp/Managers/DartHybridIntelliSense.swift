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

    // Markers (from pushMarkers/pushAnalyzerFailureMarker below) already get
    // an inline squiggly underline and a hover tooltip for free from Monaco.
    // The gutter icon next to the line ("red cross") additionally requires
    // glyphMargin to be enabled — it's off by default.
    if (typeof editor !== "undefined" && editor.updateOptions) {
        editor.updateOptions({ glyphMargin: true, renderValidationDecorations: "on" });
    }

    // Finds the Monaco model diagnostics/failure markers are actually FOR,
    // given the URI/path Swift computed.
    window.__dartFindModel = function (uriString, pathString) {
        // Fast path covering the overwhelming common case: the file these
        // diagnostics are for IS the currently active editor. Checked by
        // exact path/URI match (not just filename) so this behaves exactly
        // like it always has for a single open file, without depending on
        // assumptions about Monaco's internal model URI scheme.
        if (typeof editor !== "undefined" && editor.getModel) {
            var active = editor.getModel();
            if (active) {
                var activePath = active.uri.path || "";
                if (activePath === pathString || active.uri.toString() === uriString) {
                    return active;
                }
            }
        }

        // The active tab is a DIFFERENT file than these diagnostics are
        // for (e.g. the user switched tabs while an async analysis/LSP
        // result was still in flight) — find the real target model
        // instead of mis-attaching diagnostics to whatever's visible now.
        var model = null;
        try { model = monaco.editor.getModel(monaco.Uri.parse(uriString)); } catch (e) {}
        if (model) { return model; }

        var all = monaco.editor.getModels();
        for (var i = 0; i < all.length; i++) {
            var u = all[i].uri;
            if (u.toString() === uriString || u.path === pathString) { return all[i]; }
        }
        return null;
    };

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
            {l:"codeUnitAt", k:"Method", d:"int codeUnitAt(int index)"},
            {l:"padLeft", k:"Method", d:"String padLeft(int width, [String padding])"},
            {l:"padRight", k:"Method", d:"String padRight(int width, [String padding])"},
            {l:"replaceFirst", k:"Method", d:"String replaceFirst(Pattern from, String to)"},
            {l:"compareTo", k:"Method", d:"int compareTo(String other)"},
            {l:"toList", k:"Method", d:"List<String> toList()"},
            {l:"runes", k:"Property", d:"Runes runes"}
        ],
        "List": [
            {l:"add", k:"Method", d:"void add(E value)"},
            {l:"addAll", k:"Method", d:"void addAll(Iterable<E> iterable)"},
            {l:"remove", k:"Method", d:"bool remove(Object? value)"},
            {l:"removeAt", k:"Method", d:"E removeAt(int index)"},
            {l:"removeLast", k:"Method", d:"E removeLast()"},
            {l:"removeWhere", k:"Method", d:"void removeWhere(bool Function(E) test)"},
            {l:"insert", k:"Method", d:"void insert(int index, E element)"},
            {l:"clear", k:"Method", d:"void clear()"},
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
            {l:"join", k:"Method", d:"String join([String separator])"},
            {l:"reduce", k:"Method", d:"E reduce(E Function(E, E) combine)"},
            {l:"fold", k:"Method", d:"T fold<T>(T initialValue, T Function(T, E) combine)"},
            {l:"take", k:"Method", d:"Iterable<E> take(int count)"},
            {l:"skip", k:"Method", d:"Iterable<E> skip(int count)"},
            {l:"toList", k:"Method", d:"List<E> toList()"},
            {l:"toSet", k:"Method", d:"Set<E> toSet()"},
            {l:"asMap", k:"Method", d:"Map<int, E> asMap()"},
            {l:"indexWhere", k:"Method", d:"int indexWhere(bool Function(E) test)"},
            {l:"any", k:"Method", d:"bool any(bool Function(E) test)"},
            {l:"every", k:"Method", d:"bool every(bool Function(E) test)"},
            {l:"reversed", k:"Property", d:"Iterable<E> reversed"}
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
            {l:"length", k:"Property", d:"int length"},
            {l:"putIfAbsent", k:"Method", d:"V putIfAbsent(K key, V Function() ifAbsent)"},
            {l:"update", k:"Method", d:"V update(K key, V Function(V) update)"},
            {l:"clear", k:"Method", d:"void clear()"},
            {l:"entries", k:"Property", d:"Iterable<MapEntry<K, V>> entries"}
        ],
        "int": [
            {l:"toString", k:"Method", d:"String toString()"},
            {l:"toDouble", k:"Method", d:"double toDouble()"},
            {l:"isEven", k:"Property", d:"bool isEven"},
            {l:"isOdd", k:"Property", d:"bool isOdd"},
            {l:"isNegative", k:"Property", d:"bool isNegative"},
            {l:"abs", k:"Method", d:"int abs()"},
            {l:"clamp", k:"Method", d:"num clamp(num lower, num upper)"},
            {l:"toRadixString", k:"Method", d:"String toRadixString(int radix)"}
        ],
        "double": [
            {l:"toString", k:"Method", d:"String toString()"},
            {l:"toInt", k:"Method", d:"int toInt()"},
            {l:"round", k:"Method", d:"int round()"},
            {l:"floor", k:"Method", d:"int floor()"},
            {l:"ceil", k:"Method", d:"int ceil()"},
            {l:"abs", k:"Method", d:"double abs()"},
            {l:"toStringAsFixed", k:"Method", d:"String toStringAsFixed(int fractionDigits)"},
            {l:"isNaN", k:"Property", d:"bool isNaN"}
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
        {l:"GridView.builder", k:"Constructor", d:"GridView.builder({required SliverGridDelegate gridDelegate, required IndexedWidgetBuilder itemBuilder})"},
        {l:"Padding", k:"Constructor", d:"Padding({required EdgeInsetsGeometry padding, Widget? child})"},
        {l:"SizedBox", k:"Constructor", d:"SizedBox({double? width, double? height, Widget? child})"},
        {l:"ElevatedButton", k:"Constructor", d:"ElevatedButton({required VoidCallback? onPressed, required Widget child})"},
        {l:"TextButton", k:"Constructor", d:"TextButton({required VoidCallback? onPressed, required Widget child})"},
        {l:"TextField", k:"Constructor", d:"TextField({TextEditingController? controller})"},
        {l:"TextFormField", k:"Constructor", d:"TextFormField({TextEditingController? controller, FormFieldValidator<String>? validator})"},
        {l:"Form", k:"Constructor", d:"Form({required Widget child, GlobalKey<FormState>? key})"},
        {l:"MaterialApp", k:"Constructor", d:"MaterialApp({Widget? home, String? title})"},
        {l:"StatelessWidget", k:"Class", d:"abstract class StatelessWidget extends Widget"},
        {l:"StatefulWidget", k:"Class", d:"abstract class StatefulWidget extends Widget"},
        {l:"Expanded", k:"Constructor", d:"Expanded({required Widget child, int flex = 1})"},
        {l:"Flexible", k:"Constructor", d:"Flexible({required Widget child})"},
        {l:"SafeArea", k:"Constructor", d:"SafeArea({required Widget child})"},
        {l:"GestureDetector", k:"Constructor", d:"GestureDetector({VoidCallback? onTap, required Widget child})"},
        {l:"InkWell", k:"Constructor", d:"InkWell({VoidCallback? onTap, required Widget child})"},
        {l:"Card", k:"Constructor", d:"Card({Widget? child, double? elevation})"},
        {l:"Divider", k:"Constructor", d:"Divider({double? height, double? thickness})"},
        {l:"Wrap", k:"Constructor", d:"Wrap({List<Widget> children})"},
        {l:"CircularProgressIndicator", k:"Constructor", d:"CircularProgressIndicator({double? value})"},
        {l:"AlertDialog", k:"Constructor", d:"AlertDialog({Widget? title, Widget? content, List<Widget>? actions})"},
        {l:"ClipRRect", k:"Constructor", d:"ClipRRect({BorderRadius? borderRadius, required Widget child})"},
        {l:"Navigator", k:"Class", d:"class Navigator", doc:"Manages a stack of Route objects."},
        {l:"FloatingActionButton", k:"Constructor", d:"FloatingActionButton({required VoidCallback? onPressed, Widget? child})"}
    ];

    // Common Flutter named parameters. These are deliberately separate from
    // widget constructors so typing `backgroundColor:` or `padding:` shows
    // the property/value-oriented suggestions instead of a list of widgets.
    var FLUTTER_PROPERTIES = [
        {l:"backgroundColor", k:"Property", d:"Color? backgroundColor"},
        {l:"color", k:"Property", d:"Color? color"},
        {l:"foregroundColor", k:"Property", d:"Color? foregroundColor"},
        {l:"surfaceTintColor", k:"Property", d:"Color? surfaceTintColor"},
        {l:"shadowColor", k:"Property", d:"Color? shadowColor"},
        {l:"padding", k:"Property", d:"EdgeInsetsGeometry? padding"},
        {l:"margin", k:"Property", d:"EdgeInsetsGeometry? margin"},
        {l:"width", k:"Property", d:"double? width"},
        {l:"height", k:"Property", d:"double? height"},
        {l:"constraints", k:"Property", d:"BoxConstraints? constraints"},
        {l:"alignment", k:"Property", d:"AlignmentGeometry? alignment"},
        {l:"decoration", k:"Property", d:"Decoration? decoration"},
        {l:"foregroundDecoration", k:"Property", d:"Decoration? foregroundDecoration"},
        {l:"borderRadius", k:"Property", d:"BorderRadius? borderRadius"},
        {l:"border", k:"Property", d:"Border? border"},
        {l:"shape", k:"Property", d:"ShapeBorder? shape"},
        {l:"elevation", k:"Property", d:"double? elevation"},
        {l:"title", k:"Property", d:"Widget? title"},
        {l:"leading", k:"Property", d:"Widget? leading"},
        {l:"trailing", k:"Property", d:"Widget? trailing"},
        {l:"actions", k:"Property", d:"List<Widget>? actions"},
        {l:"body", k:"Property", d:"Widget? body"},
        {l:"child", k:"Property", d:"Widget? child"},
        {l:"children", k:"Property", d:"List<Widget> children"},
        {l:"onPressed", k:"Property", d:"VoidCallback? onPressed"},
        {l:"onTap", k:"Property", d:"GestureTapCallback? onTap"},
        {l:"style", k:"Property", d:"TextStyle? style"},
        {l:"fontSize", k:"Property", d:"double? fontSize"},
        {l:"fontWeight", k:"Property", d:"FontWeight? fontWeight"},
        {l:"textAlign", k:"Property", d:"TextAlign? textAlign"},
        {l:"mainAxisAlignment", k:"Property", d:"MainAxisAlignment mainAxisAlignment"},
        {l:"crossAxisAlignment", k:"Property", d:"CrossAxisAlignment crossAxisAlignment"},
        {l:"mainAxisSize", k:"Property", d:"MainAxisSize mainAxisSize"},
        {l:"fit", k:"Property", d:"BoxFit fit"},
        {l:"icon", k:"Property", d:"IconData? icon"},
        {l:"size", k:"Property", d:"double? size"},
        {l:"duration", k:"Property", d:"Duration duration"}
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
            if (window.__dartLSPConnected) {
                return dartBridgeRequest('completion', {
                    uri: model.uri.toString(), line: position.lineNumber - 1, character: position.column - 1
                }).then(function (lspItems) {
                    if (lspItems && lspItems.length) {
                        var wi = model.getWordUntilPosition(position);
                        var r = {
                            startLineNumber: position.lineNumber, endLineNumber: position.lineNumber,
                            startColumn: wi.startColumn, endColumn: wi.endColumn
                        };
                        return {
                            suggestions: lspItems.map(function (it) {
                                return {
                                    label: it.label, kind: kindOf(lspKindName(it.kind)),
                                    detail: it.detail || "", documentation: it.documentation || "",
                                    insertText: it.insertText || it.label, range: r
                                };
                            })
                        };
                    }
                    return provideCompletionItemsLocal(model, position);
                });
            }
            return provideCompletionItemsLocal(model, position);
        }
    });

    function provideCompletionItemsLocal(model, position) {
            if (model.getLanguageId() !== 'dart' && !/\.dart$/.test(model.uri.path || '')) {
                return { suggestions: [] };
            }
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

            // Named-argument completion. If the user has already typed a
            // property prefix (e.g. `backgroundC`), return matching Flutter
            // properties so the list behaves like an IDE instead of only
            // offering widget names.
            var namedArgumentMatch = textBeforeCursor.match(/(?:^|[,\n])\s*([A-Za-z_][A-Za-z0-9_]*)$/);
            if (namedArgumentMatch) {
                var prefix = namedArgumentMatch[1].toLowerCase();
                var propertySuggestions = FLUTTER_PROPERTIES.filter(function (p) {
                    return p.l.toLowerCase().indexOf(prefix) === 0;
                });
                if (propertySuggestions.length) {
                    return { suggestions: propertySuggestions.map(function (p) { return toSuggestion(p, range); }) };
                }
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

    // --- LSP bridge helpers (native Dart Analysis Server over SSH) ---
    // Swift populates window.__dartLSPConnected via executeCustomScript
    // whenever DartAnalysisServerClient's status changes; everything below
    // no-ops immediately (no round trip, no delay) while it's false, so a
    // remote project without a working Dart SDK behaves exactly as before.
    window.__dartLSPConnected = window.__dartLSPConnected || false;
    window.__dartBridgePending = window.__dartBridgePending || {};
    window.__dartBridgeRequestId = window.__dartBridgeRequestId || 0;

    window.__dartBridgeResolve = function (id, resultJSON) {
        var entry = window.__dartBridgePending[id];
        if (!entry) { return; }
        delete window.__dartBridgePending[id];
        var parsed = null;
        try { parsed = resultJSON ? JSON.parse(resultJSON) : null; } catch (e) { parsed = null; }
        entry(parsed);
    };

    function dartBridgeRequest(kind, payload) {
        return new Promise(function (resolve) {
            var id = ++window.__dartBridgeRequestId;
            window.__dartBridgePending[id] = resolve;
            try {
                window.webkit.messageHandlers.toggleMessageHandler.postMessage({
                    Event: "Dart LSP Request", id: id, kind: kind, payload: payload
                });
            } catch (e) {
                delete window.__dartBridgePending[id];
                resolve(null);
                return;
            }
            // Second safety net beyond the native side always resolving:
            // never leave a Monaco provider's promise hanging.
            setTimeout(function () {
                if (window.__dartBridgePending[id]) {
                    delete window.__dartBridgePending[id];
                    resolve(null);
                }
            }, 8000);
        });
    }

    // LSP CompletionItemKind (numeric) -> the string names `kindOf` above
    // already knows how to map to monaco.languages.CompletionItemKind.
    function lspKindName(n) {
        switch (n) {
            case 2: return "Method";
            case 3: return "Function";
            case 4: return "Constructor";
            case 7: return "Class";
            case 10: return "Property";
            case 14: return "Keyword";
            default: return "Text";
        }
    }

    monaco.languages.registerHoverProvider('dart', {
        provideHover: function (model, position) {
            if (!window.__dartLSPConnected) { return null; }
            return dartBridgeRequest('hover', {
                uri: model.uri.toString(), line: position.lineNumber - 1, character: position.column - 1
            }).then(function (result) {
                if (!result || !result.contents) { return null; }
                return { contents: [{ value: String(result.contents) }] };
            });
        }
    });

    monaco.languages.registerDefinitionProvider('dart', {
        provideDefinition: function (model, position) {
            if (!window.__dartLSPConnected) { return null; }
            return dartBridgeRequest('definition', {
                uri: model.uri.toString(), line: position.lineNumber - 1, character: position.column - 1
            }).then(function (result) {
                if (!result || !result.length) { return []; }
                var loc = result[0];
                var targetUri = monaco.Uri.parse(loc.uri);
                var existingModel = monaco.editor.getModel(targetUri);
                if (existingModel) {
                    return [{
                        uri: targetUri,
                        range: { startLineNumber: loc.line, startColumn: loc.column, endLineNumber: loc.line, endColumn: loc.column }
                    }];
                }
                // Target file isn't open as a tab/model yet — ask native
                // to open it (Cmd/Ctrl+Click across files), then briefly
                // poll for the model to appear before giving up.
                return dartBridgeRequest('openFile', { path: targetUri.path }).then(function () {
                    return new Promise(function (resolve) {
                        var attempts = 0;
                        var iv = setInterval(function () {
                            attempts++;
                            var m = monaco.editor.getModel(targetUri);
                            if (m || attempts > 20) {
                                clearInterval(iv);
                                resolve(m ? [{
                                    uri: targetUri,
                                    range: { startLineNumber: loc.line, startColumn: loc.column, endLineNumber: loc.line, endColumn: loc.column }
                                }] : []);
                            }
                        }, 150);
                    });
                });
            });
        }
    });

    monaco.languages.registerCodeActionProvider('dart', {
        provideCodeActions: function (model, range, context) {
            if (!window.__dartLSPConnected) { return { actions: [], dispose: function () {} }; }
            var diagnosticMessages = (context.markers || []).map(function (m) { return m.message; });
            return dartBridgeRequest('codeAction', {
                uri: model.uri.toString(),
                startLine: range.startLineNumber - 1, startCharacter: range.startColumn - 1,
                endLine: range.endLineNumber - 1, endCharacter: range.endColumn - 1,
                diagnosticMessages: diagnosticMessages
            }).then(function (result) {
                var actions = (result || []).map(function (action) {
                    var edits = (action.edits || []).map(function (e) {
                        return {
                            resource: model.uri,
                            textEdit: {
                                range: {
                                    startLineNumber: e.startLine, startColumn: e.startColumn,
                                    endLineNumber: e.endLine, endColumn: e.endColumn
                                },
                                text: e.newText
                            },
                            versionId: model.getVersionId()
                        };
                    });
                    return { title: action.title, kind: 'quickfix', edit: { edits: edits }, isPreferred: false };
                });
                return { actions: actions, dispose: function () {} };
            });
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
    /// A monaco.MarkerSeverity value directly (Hint=1, Info=2, Warning=4,
    /// Error=8) rather than `DartAnalyzeSeverity`, so diagnostics coming
    /// from the LSP bridge (DartAnalysisServerClient, which has its own
    /// severity numbering) can be pushed through the exact same
    /// `pushMarkers` used by the one-shot `dart analyze` path below.
    let monacoSeverity: Int
    let message: String
    let line: Int
    let column: Int
    let length: Int
    /// Only populated by the LSP bridge, which reports a real end
    /// position (possibly on a different line). The one-shot `dart
    /// analyze --format=machine` path only reports a length, so it leaves
    /// these nil and `pushMarkers` falls back to `line`/`column + length`.
    let endLine: Int?
    let endColumn: Int?

    init(monacoSeverity: Int, message: String, line: Int, column: Int, length: Int, endLine: Int? = nil, endColumn: Int? = nil) {
        self.monacoSeverity = monacoSeverity
        self.message = message
        self.line = line
        self.column = column
        self.length = length
        self.endLine = endLine
        self.endColumn = endColumn
    }
}

/// Runs one command over a short-lived, dedicated SSH session (connect →
/// run → disconnect). Never shares a session/channel with the interactive
/// terminal — NMSSH's own docs say its classes aren't safe to use
/// concurrently from different threads, and the terminal's channel is a
/// PTY, unsuitable for machine-readable output anyway.
final class OneShotSSHCommandRunner: NSObject, NMSSHChannelDelegate {
    private var session: NMSSHSession?
    /// Shared (not per-instance) on purpose: even though the coordinator
    /// above already limits analysis to one at a time, this guarantees
    /// every NMSSH operation from this feature is globally serialized —
    /// belt-and-suspenders against NMSSH's documented lack of thread
    /// safety for concurrent use, which is the most likely source of the
    /// intermittent crashes.
    private static let queue = DispatchQueue(label: "dart-analyze.oneshot.queue")
    private var queue: DispatchQueue { Self.queue }
    private var outputBuffer = ""
    private var continuation: CheckedContinuation<String, Error>?
    private var marker: String = ""

    enum RunnerError: LocalizedError {
        case connectFailed
        case timedOut(seconds: Double)

        var errorDescription: String? {
            switch self {
            case .connectFailed:
                return "Could not connect over SSH."
            case .timedOut(let seconds):
                return "Timed out after \(Int(seconds))s waiting for the command to finish."
            }
        }
    }

    func run(host: URL, authenticationMode: RemoteAuthenticationMode, command: String, timeoutSeconds: Double = 30)
        async throws -> String
    {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            self.continuation = continuation
            let token = UUID().uuidString.prefix(8)
            self.marker = "__DARTANALYZE_DONE__\(token)__"

            queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                self?.finish(.failure(RunnerError.timedOut(seconds: timeoutSeconds)))
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

// MARK: - Local analyzer runner

/// Runs the installed Dart SDK against a local temporary file without using
/// the user's visible terminal. This is a fallback/diagnostics path; the
/// normal Monaco LSP bridge is also allowed to connect to `dart language-server`
/// when the SDK is available.
private final class LocalDartAnalyzeRunner {
    func run(root: URL, file: URL, useFlutter: Bool) async -> String {
        await withCheckedContinuation { continuation in
            var output = ""
            let executor = Executor(
                root: root,
                sessionIdentifier: "com.thebaselab.codeapp.dart-analyzer.\(UUID().uuidString)",
                onStdout: { data in output += String(decoding: data, as: UTF8.self) },
                onStderr: { data in output += String(decoding: data, as: UTF8.self) },
                onRequestInput: { prompt in output += prompt }
            )

            let quotedRoot = Self.shellQuoted(root.path)
            let quotedFile = Self.shellQuoted(file.path)
            let analyzeCommand =
                useFlutter ? "flutter analyze --no-preamble --no-congratulate" : "dart analyze --format=machine"
            executor.dispatch(
                command: "cd \(quotedRoot) && \(analyzeCommand) \(quotedFile) 2>&1"
            ) { _ in
                continuation.resume(returning: output)
            }
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    private var pending: (editorURL: URL, content: String, generation: Int)?
    /// Bumped on every new content change. A result is only shown if it's
    /// still the most recent generation by the time it comes back — an
    /// older, now-superseded analysis (still in flight when the user kept
    /// typing) is discarded rather than briefly overwriting fresh state
    /// with stale markers.
    private var generation = 0

    // MARK: LSP bridge coordinator state (DartAnalysisServerClient.swift)

    /// The active persistent connection to the remote Dart Analysis
    /// Server, if any. nil until SDK detection + connect succeeds for the
    /// current remote host/project; torn down and rebuilt whenever the
    /// host or project root changes, or the SSH link drops.
    private var lspClient: DartAnalysisServerClient?
    /// Fingerprint of what `lspClient` is currently connected to
    /// ("<host>|<projectRootPath>"), used to detect when a fresh
    /// connection is needed instead of reusing the existing one.
    private var lspConnectionKey: String?
    /// LSP document URI ("file://<remote path>") -> the editor URL
    /// (sftp://...) it corresponds to, so incoming `publishDiagnostics`
    /// notifications route back to the right Monaco model. Populated by
    /// `didOpen`; not cleaned up on tab close (see file header note in
    /// DartAnalysisServerClient.swift).
    private var lspOpenDocuments: [String: URL] = [:]
    /// Needed because bridge requests from Monaco (hover/definition/
    /// completion/code actions) arrive asynchronously via the WKWebView
    /// message handler, without an `app` parameter to hand them — unlike
    /// every other entry point in this file, which always receives one.
    private weak var activeApp: MainApp?

    /// Call when a remote `.dart` file becomes the active editor. Installs
    /// the completion provider (no-op if already installed) and requests
    /// markers for the current content immediately, so diagnostics don't
    /// wait for the first edit.
    func activate(app: MainApp, editorURL: URL, content: String) {
        activeApp = app
        Task {
            _ = try? await (app.monacoInstance as? MonacoImplementation)?
                .executeCustomScript(dartCompletionProviderScript)
        }
        scheduleAnalysis(app: app, editorURL: editorURL, content: content)

        // Real analyzer-backed IntelliSense (hover/go-to-definition/quick
        // fixes/completion) — remote only; local files already get the
        // genuine Monaco LSP bridge via `connectLanguageService` in
        // MainApp.swift when a local Dart SDK is installed.
        guard app.workSpaceStorage.remoteConnected else { return }
        Task {
            await self.ensureLSPConnection(app: app, editorURL: editorURL)
            self.notifyLSPDocumentOpenedOrChanged(editorURL: editorURL, content: content)
        }
    }

    /// Call on every content change for the active file (from
    /// `MainApp.editorImplementation(contentDidChangeForModelURL:...)`) —
    /// debounces internally, so callers don't need to.
    func scheduleAnalysis(app: MainApp, editorURL: URL, content: String) {
        generation += 1
        let thisGeneration = generation

        debounceTask?.cancel()
        let task = DispatchWorkItem { [weak app] in
            guard let app = app else { return }
            Task {
                await DartHybridIntelliSense.shared.runOrQueue(
                    app: app, editorURL: editorURL, content: content, generation: thisGeneration)
            }
        }
        debounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }

    private func runOrQueue(app: MainApp, editorURL: URL, content: String, generation: Int) async {
        guard !isAnalyzing else {
            pending = (editorURL, content, generation)  // coalesce: only the latest edit matters
            return
        }
        isAnalyzing = true
        await runAnalysis(app: app, editorURL: editorURL, content: content, generation: generation)
        isAnalyzing = false

        if let next = pending {
            pending = nil
            await runOrQueue(
                app: app, editorURL: next.editorURL, content: next.content, generation: next.generation)
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

    private func runAnalysis(app: MainApp, editorURL: URL, content: String, generation: Int) async {
        guard let contentData = content.data(using: .utf8) else { return }

        if app.workSpaceStorage.remoteConnected {
            notifyLSPDocumentOpenedOrChanged(editorURL: editorURL, content: content)
            if let client = lspClient, client.status == .connected {
                // The persistent analysis server's own `publishDiagnostics`
                // notifications (see `onDiagnostics` in
                // `ensureLSPConnection`) are the live diagnostics source
                // now. Skip the one-shot `dart analyze` round trip
                // entirely to avoid duplicate/conflicting markers and an
                // unnecessary extra SSH session on every keystroke.
                return
            }
            guard let connectionInfo = app.workSpaceStorage.currentRemoteConnectionInfo else { return }
            let projectRoot = await dartAnalysisRoot(app: app, forFileURL: editorURL)
            let tempURL = editorURL.deletingLastPathComponent()
                .appendingPathComponent("." + editorURL.deletingPathExtension().lastPathComponent + Self.tempFileSuffix)
            let rootPath = projectRoot.path
            let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            let relativeTempPath = String(tempURL.path.dropFirst(rootPrefix.count))
            let quotedRoot = "'" + rootPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let quotedRelativeTemp = "'" + relativeTempPath.replacingOccurrences(of: "'", with: "'\\''") + "'"

            do {
                try await app.workSpaceStorage.write(
                    at: tempURL, content: contentData, atomically: true, overwrite: true)
            } catch {
                // Do not silently continue with a temp file that was never written.
                // The editor must never show stale/incorrect diagnostics.
                return
            }
            defer {
                Task { try? await app.workSpaceStorage.removeItem(at: tempURL) }
            }

            let useFlutterAnalyze = Self.isInLibFolder(projectRoot: projectRoot, fileURL: editorURL)
            let analyzeCommand =
                useFlutterAnalyze
                ? "flutter analyze --no-preamble --no-congratulate" : "dart analyze --format=machine"
            let command = "cd \(quotedRoot) && \(analyzeCommand) \(quotedRelativeTemp) 2>&1"
            let output: String
            do {
                output = try await OneShotSSHCommandRunner().run(
                    host: connectionInfo.host, authenticationMode: connectionInfo.authenticationMode,
                    command: command, timeoutSeconds: useFlutterAnalyze ? 90 : 30)
            } catch {
                await pushAnalyzerFailureMarker(app: app, editorURL: editorURL, message: "Dart analyzer could not be started: \(error.localizedDescription)")
                return
            }

            guard generation == self.generation else { return }
            let diagnostics =
                useFlutterAnalyze
                ? Self.parseFlutterAnalyzeOutput(output, matchingFileSuffix: relativeTempPath)
                : Self.parseMachineOutput(output, matchingFileSuffix: relativeTempPath)
            if diagnostics.isEmpty, let reason = Self.analyzerFailureReason(from: output) {
                await pushAnalyzerFailureMarker(
                    app: app, editorURL: editorURL,
                    message: "\(useFlutterAnalyze ? "flutter analyze" : "dart analyze") did not run cleanly: \(reason)"
                )
                return
            }
            await pushMarkers(app: app, editorURL: editorURL, diagnostics: diagnostics)
            return
        }

        // Local project: analyze the unsaved buffer in a hidden temporary file.
        guard editorURL.isFileURL else { return }
        let projectRoot = localDartProjectRoot(for: editorURL)
        let useFlutterAnalyze = Self.isInLibFolder(projectRoot: projectRoot, fileURL: editorURL)
        let tempURL = editorURL.deletingLastPathComponent()
            .appendingPathComponent("." + editorURL.deletingPathExtension().lastPathComponent + Self.tempFileSuffix)
        do {
            try contentData.write(to: tempURL, options: .atomic)
            let output = await LocalDartAnalyzeRunner().run(
                root: projectRoot, file: tempURL, useFlutter: useFlutterAnalyze)
            try? FileManager.default.removeItem(at: tempURL)
            guard generation == self.generation else { return }

            let diagnostics =
                useFlutterAnalyze
                ? Self.parseFlutterAnalyzeOutput(output, matchingFileSuffix: tempURL.path)
                : Self.parseMachineOutput(output, matchingFileSuffix: tempURL.path)
            if diagnostics.isEmpty, let reason = Self.analyzerFailureReason(from: output) {
                await pushAnalyzerFailureMarker(
                    app: app, editorURL: editorURL,
                    message: "\(useFlutterAnalyze ? "flutter analyze" : "dart analyze") did not run cleanly: \(reason)"
                )
                return
            }
            await pushMarkers(app: app, editorURL: editorURL, diagnostics: diagnostics)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private func localDartProjectRoot(for fileURL: URL) -> URL {
        var current = fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: current.appendingPathComponent("pubspec.yaml").path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return fileURL.deletingLastPathComponent() }
            current = parent
        }
    }

    /// Parses `dart analyze --format=machine` output:
    /// SEVERITY|TYPE|ERROR_CODE|FILE|LINE|COLUMN|LENGTH|MESSAGE
    ///
    /// `matchingFileSuffix` (our temp file's path, relative to the analysis
    /// root) is required: when a `pubspec.yaml` is present, `dart analyze`
    /// often reports diagnostics for the WHOLE package context, not just
    /// the single file we asked about. Without filtering by FILE here,
    /// another file's errors could get attributed to the current file (or
    /// mixed in with it) — this was the cause of markers showing up on
    /// correct code, or not showing up on genuinely broken code.
    private static func parseMachineOutput(_ output: String, matchingFileSuffix: String) -> [DartDiagnostic] {
        var results: [DartDiagnostic] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 7, omittingEmptySubsequences: false)
            guard parts.count == 8,
                let severity = DartAnalyzeSeverity(rawValue: String(parts[0])),
                parts[3].hasSuffix(matchingFileSuffix),
                let lineNumber = Int(parts[4]),
                let column = Int(parts[5]),
                let length = Int(parts[6])
            else {
                continue
            }
            results.append(
                DartDiagnostic(
                    monacoSeverity: severity.monacoValue, message: String(parts[7]), line: lineNumber,
                    column: column, length: max(length, 1)))
        }
        return results
    }

    /// True when the file sits inside the project's `lib/` folder,
    /// relative to `projectRoot` — the convention Flutter app source lives
    /// under. Per feature request: these files are analyzed with `flutter
    /// analyze` rather than plain `dart analyze`, since it also runs
    /// Flutter-specific lints/checks that `dart analyze` alone does not.
    /// Files elsewhere in the project (`bin/`, `test/`, etc.) keep using
    /// `dart analyze`.
    /// Parses `flutter analyze --no-preamble --no-congratulate` output.
    ///
    /// IMPORTANT: unlike `dart analyze`, `flutter analyze` has no
    /// `--machine`/`--format=machine` flag (this was a long-requested
    /// Flutter tooling feature that was never consistently shipped) — an
    /// earlier version of this file incorrectly assumed one existed, which
    /// is why `flutter analyze` diagnostics silently never showed up.
    /// Its real output, with the banner and the "No issues found!"/"N
    /// issues found." summary suppressed by the two flags above, is one
    /// diagnostic per line in the human-readable bullet format:
    ///   info • Name types using UpperCamelCase • lib/main.dart:5:7 • camel_case_types
    ///   warning • Unused import: 'dart:async' • lib/main.dart:2:8 • unused_import
    /// i.e. `severity • message • file:line:col • rule_name`, separated by
    /// " • " (U+2022 BULLET). A clean file with both flags produces no
    /// output at all.
    private static func parseFlutterAnalyzeOutput(_ output: String, matchingFileSuffix: String) -> [DartDiagnostic] {
        var results: [DartDiagnostic] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.components(separatedBy: " • ")
            guard parts.count >= 3 else { continue }  // not a diagnostic line — skip silently, don't misparse banner/summary text

            let monacoSeverity: Int
            switch parts[0].lowercased() {
            case "error": monacoSeverity = 8
            case "warning": monacoSeverity = 4
            case "info": monacoSeverity = 2
            default: continue  // unrecognized first field — not actually a diagnostic line
            }

            // Location field is "path:line:col" — split from the right so a
            // colon-containing path (unlikely, but possible) doesn't break this.
            let locationParts = parts[2].split(separator: ":")
            guard locationParts.count >= 3,
                let column = Int(locationParts[locationParts.count - 1]),
                let lineNumber = Int(locationParts[locationParts.count - 2])
            else { continue }
            let filePath = locationParts.dropLast(2).joined(separator: ":")
            guard filePath.hasSuffix(matchingFileSuffix) else { continue }

            results.append(
                DartDiagnostic(
                    monacoSeverity: monacoSeverity, message: parts[1], line: lineNumber, column: column,
                    length: 1))
        }
        return results
    }

    private static func isInLibFolder(projectRoot: URL, fileURL: URL) -> Bool {
        let rootPath = projectRoot.path.hasSuffix("/") ? projectRoot.path : projectRoot.path + "/"
        guard fileURL.path.hasPrefix(rootPath) else { return false }
        let relative = fileURL.path.dropFirst(rootPath.count)
        return relative == "lib" || relative.hasPrefix("lib/")
    }

    /// When machine-format parsing finds zero diagnostics, decides whether
    /// that's a genuinely clean file (nothing to show — `dart
    /// analyze`/`flutter analyze --machine` print nothing when there's
    /// nothing to report) or the analyze command itself failing to run
    /// (SDK/PATH issue, no pubspec, packages not resolved, analyzer
    /// crash...) — in which case the raw output IS the reason and must be
    /// shown, never silently swallowed into a false "no problems" state.
    ///
    /// This is a heuristic (keyword match on the combined stdout+stderr
    /// text), not a real exit-code check, because the SSH/local runners
    /// here don't currently plumb the process exit code back — see
    /// `OneShotSSHCommandRunner`'s marker line, which already carries the
    /// exit code in the output stream but isn't parsed out yet. Erring
    /// toward "not a failure" on ambiguous chatter (e.g. first-run SDK
    /// precache messages) avoids false failure markers on working code.
    private static func analyzerFailureReason(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.contains("no issues found") { return nil }
        let errorSignals = [
            "command not found", "not found", "no pubspec.yaml", "no pubspec file",
            "error:", "exception", "fatal", "unable to", "failed", "cannot find",
            "not recognized", "permission denied",
        ]
        guard errorSignals.contains(where: { lower.contains($0) }) else { return nil }
        return String(trimmed.prefix(500))
    }

    private func pushAnalyzerFailureMarker(app: MainApp, editorURL: URL, message: String) async {
        guard let monaco = app.monacoInstance as? MonacoImplementation else { return }
        let msg = Self.jsEscape(message)
        let uri = Self.jsEscape(editorURL.absoluteString)
        let path = Self.jsEscape(editorURL.path)
        let script = """
        (function() {
          var model = window.__dartFindModel ? window.__dartFindModel("\(uri)", "\(path)") : null;
          if (model) monaco.editor.setModelMarkers(model, "dart-analyzer", [{
            severity: 8, message: "\(msg)", startLineNumber: 1, startColumn: 1, endLineNumber: 1, endColumn: 1
          }]);
        })();
        """
        _ = try? await monaco.executeCustomScript(script)
    }

    private func pushMarkers(app: MainApp, editorURL: URL, diagnostics: [DartDiagnostic]) async {
        guard let monaco = app.monacoInstance as? MonacoImplementation else { return }

        let markersJSON = diagnostics.map { d -> String in
            let escapedMessage = Self.jsEscape(d.message)
            let endLine = d.endLine ?? d.line
            let endColumn = d.endColumn ?? (max(d.column, 1) + max(d.length, 1))
            return """
                {"severity":\(d.monacoSeverity),"message":"\(escapedMessage)",\
                "startLineNumber":\(d.line),"startColumn":\(max(d.column, 1)),\
                "endLineNumber":\(endLine),"endColumn":\(endColumn)}
                """
        }.joined(separator: ",")

        let escapedURI = Self.jsEscape(editorURL.absoluteString)
        let escapedPath = Self.jsEscape(editorURL.path)
        let script = """
            (function() {
                var model = window.__dartFindModel ? window.__dartFindModel("\(escapedURI)", "\(escapedPath)") : null;
                if (!model) { return; }
                monaco.editor.setModelMarkers(model, "dart-analyzer", [\(markersJSON)]);
            })();
            """
        _ = try? await monaco.executeCustomScript(script)
    }

    private static func jsEscape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    // MARK: - LSP bridge coordinator

    /// Connects (or reconnects) the persistent Dart Analysis Server client
    /// for the given file's project. Safe to call on every `activate` —
    /// it's a no-op if already connected/connecting to the same host +
    /// project root. Never throws; SDK-not-found and connection failures
    /// are surfaced as a marker on the current file (never silently) and
    /// leave the one-shot `dart analyze` fallback fully in charge.
    private func ensureLSPConnection(app: MainApp, editorURL: URL) async {
        guard app.workSpaceStorage.remoteConnected,
            let connectionInfo = app.workSpaceStorage.currentRemoteConnectionInfo
        else { return }

        let projectRoot = await dartAnalysisRoot(app: app, forFileURL: editorURL)
        let key = connectionInfo.host.absoluteString + "|" + projectRoot.path

        if lspConnectionKey == key, let client = lspClient,
            client.status == .connected || client.status == .starting
        {
            return  // already connected/connecting to this project
        }

        lspClient?.disconnect()
        lspClient = nil
        lspOpenDocuments.removeAll()
        lspConnectionKey = key
        await setLSPConnectedFlag(app: app, connected: false)

        let sdkResult: DartSDKLocator.Result
        do {
            sdkResult = try await DartSDKLocator.detect(
                host: connectionInfo.host, authenticationMode: connectionInfo.authenticationMode)
        } catch {
            print("[DartAnalyzer] SDK detection failed: \(error.localizedDescription)")
            await pushAnalyzerFailureMarker(
                app: app, editorURL: editorURL,
                message: "Dart Analyzer: SDK not found. \(error.localizedDescription)")
            return
        }

        let client = DartAnalysisServerClient()
        client.onStatusChange = { [weak self] status in
            guard let self else { return }
            Task { @MainActor in
                guard let app = self.activeApp else { return }
                await self.setLSPConnectedFlag(app: app, connected: status == .connected)
            }
        }
        client.onDiagnostics = { [weak self] uri, diagnostics in
            guard let self else { return }
            Task { @MainActor in
                guard let app = self.activeApp, let url = self.lspOpenDocuments[uri] else { return }
                let mapped = diagnostics.map {
                    DartDiagnostic(
                        monacoSeverity: $0.monacoSeverity, message: $0.message, line: $0.line,
                        column: $0.column, length: max($0.endColumn - $0.column, 1),
                        endLine: $0.endLine, endColumn: $0.endColumn)
                }
                await self.pushMarkers(app: app, editorURL: url, diagnostics: mapped)
            }
        }
        lspClient = client

        do {
            try await client.connect(
                host: connectionInfo.host, authenticationMode: connectionInfo.authenticationMode,
                dartExecutable: sdkResult.dartExecutable, projectRootPath: projectRoot.path)
        } catch {
            print("[DartAnalyzer] Connection failed: \(error.localizedDescription)")
            await pushAnalyzerFailureMarker(
                app: app, editorURL: editorURL,
                message: "Dart Analyzer: could not start language server. \(error.localizedDescription)")
        }
    }

    /// Sends the current buffer to the LSP client (`didOpen` the first
    /// time a document is seen, `didChange` after that). No-op if the
    /// client isn't connected yet — the caller doesn't need to check.
    private func notifyLSPDocumentOpenedOrChanged(editorURL: URL, content: String) {
        guard let client = lspClient, client.status == .connected else { return }
        let uri = Self.lspURI(for: editorURL)
        if lspOpenDocuments[uri] == nil {
            lspOpenDocuments[uri] = editorURL
            client.didOpen(uri: uri, text: content)
        } else {
            client.didChange(uri: uri, text: content)
        }
    }

    /// Maps a Monaco/editor URL for a remote file (`sftp://host/path...`)
    /// to the URI the REMOTE analysis server needs (`file:///path...`,
    /// using the path as seen on the Android/Termux host itself) — the
    /// URI/path mapping the Dart LSP integration requirement calls for.
    private static func lspURI(for editorURL: URL) -> String {
        "file://" + editorURL.path
    }

    private func setLSPConnectedFlag(app: MainApp, connected: Bool) async {
        guard let monaco = app.monacoInstance as? MonacoImplementation else { return }
        _ = try? await monaco.executeCustomScript("window.__dartLSPConnected = \(connected ? "true" : "false");")
    }

    /// Called from `MainApp`'s existing `onRemoteDisconnect` hook so a live
    /// LSP session doesn't linger (and so stale hover/completion requests
    /// don't hang) after the SSH link drops. Also called by the one existing
    /// remote-disconnect handler in MainApp.swift, not a new one.
    func handleRemoteDisconnect() {
        guard lspClient != nil else { return }
        print("[DartAnalyzer] SSH disconnected")
        lspClient?.disconnect()
        lspClient = nil
        lspConnectionKey = nil
        lspOpenDocuments.removeAll()
        if let app = activeApp {
            Task { await self.setLSPConnectedFlag(app: app, connected: false) }
        }
    }

    /// Entry point for the "Dart LSP Request" bridge message forwarded
    /// from `MonacoImplementation`'s script message handler. Handles
    /// hover / definition / completion / codeAction / openFile requests
    /// from the JS providers registered in `dartCompletionProviderScript`,
    /// and always resolves the JS-side pending promise — never leaves it
    /// hanging (the JS side also has its own timeout as a second safety
    /// net).
    func handleBridgeRequest(_ message: [String: AnyObject]) {
        guard let id = (message["id"] as? NSNumber)?.intValue ?? (message["id"] as? Int),
            let kind = message["kind"] as? String,
            let payload = message["payload"] as? [String: AnyObject]
        else { return }

        Task { @MainActor in
            guard let app = self.activeApp, let client = self.lspClient, client.status == .connected else {
                await self.resolveBridgeRequest(id: id, result: nil)
                return
            }

            switch kind {
            case "hover", "definition", "completion":
                guard let uri = payload["uri"] as? String,
                    let line = (payload["line"] as? NSNumber)?.intValue ?? (payload["line"] as? Int),
                    let character = (payload["character"] as? NSNumber)?.intValue
                        ?? (payload["character"] as? Int)
                else {
                    await self.resolveBridgeRequest(id: id, result: nil)
                    return
                }
                switch kind {
                case "hover":
                    let hover = await client.hover(uri: uri, line: line, character: character)
                    await self.resolveBridgeRequest(id: id, result: hover.map { ["contents": $0.contents] })
                case "definition":
                    let defs = await client.definition(uri: uri, line: line, character: character)
                    let arr = defs.map { d -> [String: Any] in
                        ["uri": "file://" + d.path, "line": d.line, "column": d.column]
                    }
                    await self.resolveBridgeRequest(id: id, result: arr)
                default:  // "completion"
                    let items = await client.completion(uri: uri, line: line, character: character)
                    let arr = items.map { c -> [String: Any] in
                        [
                            "label": c.label, "kind": c.kind, "detail": c.detail ?? "",
                            "documentation": c.documentation ?? "", "insertText": c.insertText ?? c.label,
                        ]
                    }
                    await self.resolveBridgeRequest(id: id, result: arr)
                }
            case "codeAction":
                guard let uri = payload["uri"] as? String,
                    let startLine = (payload["startLine"] as? NSNumber)?.intValue,
                    let startCharacter = (payload["startCharacter"] as? NSNumber)?.intValue,
                    let endLine = (payload["endLine"] as? NSNumber)?.intValue,
                    let endCharacter = (payload["endCharacter"] as? NSNumber)?.intValue
                else {
                    await self.resolveBridgeRequest(id: id, result: nil)
                    return
                }
                let messages = (payload["diagnosticMessages"] as? [String]) ?? []
                let actions = await client.codeActions(
                    uri: uri, startLine: startLine, startCharacter: startCharacter, endLine: endLine,
                    endCharacter: endCharacter, diagnosticMessages: messages)
                let arr = actions.map { a -> [String: Any] in
                    [
                        "title": a.title,
                        "edits": a.edits.map { e -> [String: Any] in
                            [
                                "startLine": e.startLine, "startColumn": e.startColumn,
                                "endLine": e.endLine, "endColumn": e.endColumn, "newText": e.newText,
                            ]
                        },
                    ]
                }
                await self.resolveBridgeRequest(id: id, result: arr)
            case "openFile":
                // Cross-file go-to-definition: the target file isn't open
                // as a Monaco model yet, so ask the app to open it as a
                // new tab (reusing the existing `openFile`, not a new file
                // -opening path) before the JS side retries resolving the
                // definition against the now-loaded model.
                guard let path = payload["path"] as? String,
                    let host = app.workSpaceStorage.currentRemoteConnectionInfo?.host,
                    var components = URLComponents(url: host, resolvingAgainstBaseURL: false)
                else {
                    await self.resolveBridgeRequest(id: id, result: nil)
                    return
                }
                components.path = path
                if let url = components.url {
                    _ = try? await app.openFile(url: url)
                }
                await self.resolveBridgeRequest(id: id, result: ["ok": true])
            default:
                await self.resolveBridgeRequest(id: id, result: nil)
            }
        }
    }

    private func resolveBridgeRequest(id: Int, result: Any?) async {
        guard let app = activeApp, let monaco = app.monacoInstance as? MonacoImplementation else { return }
        guard let result = result else {
            _ = try? await monaco.executeCustomScript("window.__dartBridgeResolve(\(id), null)")
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: []) else {
            _ = try? await monaco.executeCustomScript("window.__dartBridgeResolve(\(id), null)")
            return
        }
        let base64 = data.base64EncodedString()
        let script =
            "window.__dartBridgeResolve(\(id), decodeURIComponent(escape(window.atob('\(base64)'))))"
        _ = try? await monaco.executeCustomScript(script)
    }
}
