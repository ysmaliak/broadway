import Foundation
import JavaScriptCore
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class JSONViewTests {
    private var js: JSContext!

    init() {        js = JSContext()
        js.evaluateScript(JSONView.core)
    }

    private func run(_ code: String) -> JSValue {
        js.exceptionHandler = { _, error in Issue.record("JS threw: \(error?.toString() ?? "")") }
        return js.evaluateScript(code)
    }

    private func call(_ name: String, _ arguments: [Any]) -> JSValue {
        js.objectForKeyedSubscript("__broadwayJSONCore").objectForKeyedSubscript(name).call(withArguments: arguments)
    }

    private func failure(_ text: String) -> (message: String, line: Int, column: Int)? {
        js.setObject(text, forKeyedSubscript: "input" as NSString)
        let result = js.evaluateScript("""
        (function () {
          try { __broadwayJSONCore.parse(input); return null; }
          catch (e) { var w = __broadwayJSONCore.where(input, e.at); return { msg: e.msg, line: w.line, column: w.column }; }
        })()
        """)
        guard let result, !result.isNull else { return nil }
        return (result.forProperty("msg").toString(), Int(result.forProperty("line").toInt32()), Int(result.forProperty("column").toInt32()))
    }

    @Test func declaredJSONTypesAreShown() {
        let types = ["application/json", "application/json; charset=utf-8", "text/json", "application/vnd.api+json", "application/problem+json", "APPLICATION/LD+JSON"]

        let kinds = types.map { call("classify", [$0, "/api"]).toString() }

        #expect(kinds == Array(repeating: "declared", count: types.count))
    }

    @Test func plainTextCountsOnlyWithAJSONName() {
        let named = call("classify", ["text/plain", "/data/file.JSON"])

        let unnamed = call("classify", ["text/plain", "/data/file.txt"])
        let html = call("classify", ["text/html", "/data/file.json"])
        let script = call("classify", ["application/javascript", "/x.json"])

        #expect(named.toString() == "named")
        #expect(unnamed.isNull)
        #expect(html.isNull)
        #expect(script.isNull)
    }

    @Test func roundTripKeepsOrderNumbersAndDuplicates() {
        let text = #"{"b":1,"a":12345678901234567890123,"2":true,"1":null,"a":1.50e+3,"s":"x\"\u00e9\n"}"#

        let compact = run("__broadwayJSONCore.text(__broadwayJSONCore.parse(\(String(reflecting: text))), '')").toString()

        #expect(compact == #"{"b":1,"a":12345678901234567890123,"2":true,"1":null,"a":1.50e+3,"s":"x\"é\n"}"#)
    }

    @Test func prettyTextIndentsByTwo() {
        let text = #"{"a":[1,{"b":[]}],"c":{}}"#

        let pretty = run("__broadwayJSONCore.text(__broadwayJSONCore.parse(\(String(reflecting: text))))").toString()

        #expect(pretty == "{\n  \"a\": [\n    1,\n    {\n      \"b\": []\n    }\n  ],\n  \"c\": {}\n}")
    }

    private func renderedPage(_ text: String, mode: JSONMode) -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, error in Issue.record("JS threw: \(error?.toString() ?? "")") }
        context.setObject(text, forKeyedSubscript: "input" as NSString)
        context.evaluateScript("""
        class Element {
          constructor(tag) {
            this.tagName = tag.toUpperCase();
            this.children = [];
            this.style = { setProperty() {} };
            this.dataset = {};
            this.attributes = {};
            this.listeners = {};
            this.classList = { add() {}, toggle() {} };
          }
          get textContent() { return this.children.map(child => child.textContent).join(''); }
          set textContent(text) { this.children = [{ textContent: String(text) }]; }
          get firstElementChild() { return this.children[0]; }
          get firstChild() { return this.children[0]; }
          appendChild(child) {
            if (child.tagName === 'FRAGMENT') {
              for (var node of child.children) {
                node.parentNode = this;
                this.children.push(node);
              }
              child.children = [];
              return child;
            }
            if (child.parentNode) child.parentNode.children.splice(child.parentNode.children.indexOf(child), 1);
            child.parentNode = this;
            this.children.push(child);
            return child;
          }
          insertBefore(child, next) {
            child.parentNode = this;
            this.children.splice(this.children.indexOf(next), 0, child);
          }
          remove() {
            this.parentNode.children.splice(this.parentNode.children.indexOf(this), 1);
            this.parentNode = null;
          }
          setAttribute(name, value) { this.attributes[name] = String(value); }
          addEventListener(name, listener) { this.listeners[name] = listener; }
          click() { if (this.listeners.click) this.listeners.click(); }
        }
        var pre = new Element('pre');
        pre.textContent = input;
        var body = new Element('body');
        body.appendChild(pre);
        var document = {
          body: body, head: new Element('head'), documentElement: new Element('html'), contentType: 'application/json',
          createElement: tag => new Element(tag), createTextNode: text => ({ textContent: text }),
          createDocumentFragment: () => new Element('fragment'), addEventListener() {}
        };
        var window = {}, location = { pathname: '/data' };
        window.top = window;
        """)
        context.evaluateScript(JSONView.source(for: mode))
        return context
    }

    private func renderedPretty(_ text: String) -> String? {
        let context = renderedPage(text, mode: .pretty)
        return context.evaluateScript("body.children.find(child => child.className === 'aj-pretty').textContent")?.toString()
    }

    @Test func expandAllBudgetsWideRootAndKeepsPagination() {
        let text = "[" + Array(repeating: "0", count: 60_000).joined(separator: ",") + "]"
        let context = renderedPage(text, mode: .tree)
        #expect(context.evaluateScript("window.__broadwayJSON.rows()")?.toInt32() == 501)

        context.evaluateScript("""
        var root = body.children.find(child => child.className === 'aj-tree').firstChild;
        var bar = body.children.find(child => child.className === 'aj-bar');
        bar.children.find(child => child.attributes['aria-label'] === 'Expand All').click();
        var kids = root.children.find(child => child.className === 'aj-kids');
        """)

        #expect(context.evaluateScript("window.__broadwayJSON.rows()")?.toInt32() == 50_001)
        #expect(context.evaluateScript("window.__broadwayJSON.find('$[49999]')")!.toInt32() >= 0)
        #expect(context.evaluateScript("window.__broadwayJSON.find('$[50000]')")?.toInt32() == -1)
        #expect(context.evaluateScript("kids.children.find(child => child.className === 'aj-more').firstChild.attributes['data-label']")?.toString() == "Show 500 More")
        #expect(context.evaluateScript("window.__broadwayJSON.raw()")?.toString() == text)

        context.evaluateScript("kids.children.find(child => child.className === 'aj-more')?.firstChild.click()")

        #expect(context.evaluateScript("window.__broadwayJSON.rows()")?.toInt32() == 50_501)
        #expect(context.evaluateScript("window.__broadwayJSON.path(window.__broadwayJSON.find('$[50499]'))")?.toString() == "$[50499]")
    }

    @Test func expandAllCapsFirstChunkAtRemainingBudget() {
        let branch = "[" + Array(repeating: "0", count: 24_980).joined(separator: ",") + "]"
        let wide = "[" + Array(repeating: "0", count: 60_000).joined(separator: ",") + "]"
        let context = renderedPage("[\(branch),\(branch),\(wide)]", mode: .tree)
        #expect(context.evaluateScript("window.__broadwayJSON.find('$[2][0]')")?.toInt32() == -1)

        context.evaluateScript("""
        var bar = body.children.find(child => child.className === 'aj-bar');
        bar.children.find(child => child.attributes['aria-label'] === 'Expand All').click();
        """)

        #expect(context.evaluateScript("window.__broadwayJSON.rows()")?.toInt32() == 50_001)
        #expect(context.evaluateScript("window.__broadwayJSON.find('$[0][24979]')")!.toInt32() >= 0)
        #expect(context.evaluateScript("window.__broadwayJSON.find('$[1][24979]')")!.toInt32() >= 0)
        #expect(context.evaluateScript("window.__broadwayJSON.find('$[2][36]')")!.toInt32() >= 0)
        #expect(context.evaluateScript("window.__broadwayJSON.find('$[2][37]')")?.toInt32() == -1)
    }

    @Test func expandAllStillOpensSmallNestedDocuments() {
        let context = renderedPage(#"{"items":[{"id":1},{"id":2}],"empty":[]}"#, mode: .tree)
        context.evaluateScript("""
        var bar = body.children.find(child => child.className === 'aj-bar');
        bar.children.find(child => child.attributes['aria-label'] === 'Collapse All').click();
        """)

        context.evaluateScript("bar.children.find(child => child.attributes['aria-label'] === 'Expand All').click()")

        #expect(context.evaluateScript("window.__broadwayJSON.rows()")?.toInt32() == 7)
        #expect(context.evaluateScript("window.__broadwayJSON.value(window.__broadwayJSON.find('$.items[1].id'))")?.toString() == "2")
        #expect(context.evaluateScript("""
        (function walk(node) {
          return (node.attributes?.role === 'treeitem' && node.attributes['aria-expanded'] === 'false' ? 1 : 0)
            + (node.children || []).reduce((sum, child) => sum + walk(child), 0);
        })(body)
        """)?.toInt32() == 0)
    }

    @Test func prettyRendererEscapesStringValuesAndKeys() throws {
        let text = #"{"say \"hi\"":"quoted \"value\"","path\\key":"C:\\temp\\notes","line\nkey":"line\nnext\ttab\bback\fform\rreturn\u0000","unicode":"Привет 😀","link":"https://example.com/a\\b","nested":[{"s":"a\"b\nc"}]}"#
        let expected = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary

        let pretty = try #require(renderedPretty(text))
        let actual = try JSONSerialization.jsonObject(with: Data(pretty.utf8)) as? NSDictionary

        #expect(actual == expected)
        #expect(pretty.contains(#""path\\key": "C:\\temp\\notes""#))
    }

    @Test func prettyRendererEscapesTopLevelStrings() throws {
        let texts = [#""quote\" slash\\ newline\n tab\t control\u0000 Привет 😀""#, #""https://example.com/a\\b""#, "\"\""]
        for text in texts {
            let expected = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) as? String

            let pretty = try #require(renderedPretty(text))
            let actual = try JSONSerialization.jsonObject(with: Data(pretty.utf8), options: .fragmentsAllowed) as? String

            #expect(actual == expected)
        }
    }

    @Test func copiedValueIsBareForStringsAndPrettyForBoxes() {
        let string = "__broadwayJSONCore.value(__broadwayJSONCore.parse('\"<b>hi</b>\"'))"
        let box = "__broadwayJSONCore.value(__broadwayJSONCore.parse('{\"id\":7}'))"

        let bare = run(string).toString()
        let pretty = run(box).toString()

        #expect(bare == "<b>hi</b>")
        #expect(pretty == "{\n  \"id\": 7\n}")
    }

    @Test func pathsUseDotsAndQuotedBrackets() {
        let keys: [[Any]] = [[], ["items", 3, "id"], ["content-type"], ["0"], ["a b", "$ok", "_x1"], ["say \"hi\""]]

        let paths = keys.map { call("path", [$0]).toString() }

        #expect(paths == ["$", "$.items[3].id", #"$["content-type"]"#, #"$["0"]"#, #"$["a b"].$ok._x1"#, #"$["say \"hi\""]"#])
    }

    @Test func errorsSayWhereTheyAre() {
        let broken = "{\n  \"a\": 1,\n  \"b\": tru\n}"

        let error = failure(broken)

        #expect(error?.line == 3)
        #expect(error?.column == 8)
        #expect(error?.message == "Unexpected character “t”")
    }

    @Test func invalidDocumentsAreRefused() {
        let documents = ["", "{", "[1,]", "{\"a\":1,}", "01", "1 2", "\"\\x\"", "{'a':1}", "\"tab\there\"", "NaN"]

        let failures = documents.map { failure($0) }

        for (document, error) in zip(documents, failures) {
            #expect(error != nil, "accepted \(document.debugDescription)")
        }
    }

    @Test func deepNestingFailsInsteadOfCrashing() {
        let deep = String(repeating: "[", count: 6000) + String(repeating: "]", count: 6000)

        let error = failure(deep)

        #expect(error?.message == "Nested too deeply")
    }

    @Test func byteOrderMarkIsSkipped() {
        let text = "\u{FEFF}{\"a\":1}"

        let error = failure(text)

        #expect(error == nil)
    }

    @Test func modeIsBakedIntoThePageScript() {
        let modes = JSONMode.allCases

        let sources = modes.map { JSONView.source(for: $0) }

        for (mode, source) in zip(modes, sources) {
            #expect(source.contains("var wanted = '\(mode.rawValue)';"))
            #expect(!source.contains(JSONView.modeToken))
        }
    }

    @Test func pageScriptParsesAsJavaScript() {
        let context = JSContext()!
        var thrown: String?
        context.exceptionHandler = { _, error in thrown = error?.toString() }

        context.evaluateScript("var window = {}, document = { contentType: 'text/html' }, location = { pathname: '/' }; window.top = window;")
        context.evaluateScript(JSONView.source(for: .tree))

        #expect(thrown == nil)
    }
}
