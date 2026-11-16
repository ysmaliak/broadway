import Foundation
import JavaScriptCore
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SnippetClassifierTests {
    private func status(label: String, shadow: Bool) throws -> String? {
        let js = try #require(JSContext())
        js.exceptionHandler = { _, error in Issue.record("JS threw: \(error?.toString() ?? "")") }
        js.setObject(label, forKeyedSubscript: "caption" as NSString)
        js.setObject(shadow, forKeyedSubscript: "shadow" as NSString)
        js.evaluateScript("""
        var label = { textContent: caption };
        var document = { getElementById: function () { return null; } };
        var root = { getElementById: function (id) { return id === 'caption' ? label : null; } };
        var el = {
          tagName: 'INPUT', id: '', parentElement: null, labels: shadow ? [] : [label],
          getRootNode: function () { return root; },
          getAttribute: function (name) { return shadow && name === 'aria-labelledby' ? 'caption' : null; }
        };
        \(SnippetPage.helpers)
        """)
        return js.evaluateScript("snippetStatus(el)")?.toString()
    }

    @Test func shadowRootLabelsBlockSensitiveInputs() throws {
        let labels = ["API key", "Пароль"]

        for label in labels { #expect(try status(label: label, shadow: true) == "blocked", "\(label)") }
        #expect(try status(label: "Mailing address", shadow: true) == "editor")
    }

    @Test func russianCardAndVerificationLabelsBlockSensitiveInputs() throws {
        let labels = ["Номер карты", "Номер банковской карты", "Код подтверждения", "Одноразовый код"]

        for label in labels { #expect(try status(label: label, shadow: false) == "blocked", "\(label)") }
        #expect(try status(label: "Почтовый адрес", shadow: false) == "editor")
    }

    @Test func ordinaryFocusedShadowHostsAreNotTreatedAsSafeClipboardTargets() throws {
        let js = try #require(JSContext())
        js.exceptionHandler = { _, error in Issue.record("JS threw: \(error?.toString() ?? "")") }
        js.evaluateScript("""
        var document = { body: {}, documentElement: {} };
        var host = { tagName: 'DIV', id: '', parentElement: null, shadowRoot: null,
          getAttribute: function () { return null; } };
        \(SnippetPage.helpers)
        """)

        let status = js.evaluateScript("snippetStatus(host)")?.toString()

        #expect(status == "blocked")
    }
}
