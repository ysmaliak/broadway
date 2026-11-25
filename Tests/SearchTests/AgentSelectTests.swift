import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentSelectTests {
    private let task = UUID()
    private var browser: Browser!
    private var box: BrowserToolbox!
    private var server: LocalPageServer!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        box = BrowserToolbox()
        box.browser = browser
        browser.prefs.agentMode = .auto
        AgentSites.shared.reset()
    }

    private func tearDown() async {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        AgentDesk.shared.drop(task: task)
        server?.stop()
        AgentSites.shared.reset()
        browser?.closeAll()
        browser = nil
    }

    private func page(_ body: String) async throws -> (tab: Tab, id: String) {
        server = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><html lang=\"en\"><title>Shop</title><body>" + body + "</body></html>")])
        _ = await box.call("open", ["url": server.url("/page").absoluteString], task: task)
        let tab = try #require(browser.tabs.first { $0.agent })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        return (tab, id)
    }

    private func value(_ tab: Tab, _ script: String) async -> String? {
        (try? await tab.web.evaluateJavaScript(script)) as? String
    }

    static let sizes = "<select aria-label=\"Size\">" + (1...25).map { "<option>Size \($0)</option>" }.joined() + "</select>"

    static let colours = """
    <button id="c" aria-haspopup="listbox" aria-expanded="false" onclick="var l = document.getElementById('l'); var open = l.hidden; l.hidden = !open; this.setAttribute('aria-expanded', String(open));">Colour</button>
    <ul id="l" role="listbox" hidden>
    <li role="option" onclick="window.picked = 'Red'; document.getElementById('l').hidden = true">Red</li>
    <li role="option" onclick="window.picked = 'Green'; document.getElementById('l').hidden = true">Green</li>
    <li role="option" onclick="window.picked = 'Blue'; document.getElementById('l').hidden = true">Blue</li>
    </ul>
    """

    @Test func aNativeListWithNoSuchOptionListsTwentyAndCountsTheRest() async throws {
        let (_, id) = try await page(Self.sizes)

        let chose = await box.call("choose", ["tab": id, "ref": "Size", "value": "Huge"], task: task)
        let selected = await box.call("select", ["tab": id, "ref": "Size", "text": "Huge"], task: task)

        for said in [chose, selected] {
            #expect(said.failed)
            #expect(said.code == "not_found")
            let hint = said.hint ?? ""
            #expect(hint.contains("\"Size 1\"") && hint.contains("\"Size 20\""), "\(hint)")
            #expect(!hint.contains("\"Size 21\""), "\(hint)")
            #expect(hint.contains("5 more"), "\(hint)")
        }
    }

    @Test func aCustomListWithNoSuchOptionListsItsOptions() async throws {
        let (tab, id) = try await page(Self.colours)

        let none = await box.call("choose", ["tab": id, "ref": "Colour", "value": "Purple"], task: task)

        #expect(none.failed)
        #expect(none.code == "not_found")
        let hint = none.hint ?? ""
        #expect(hint.contains("\"Red\"") && hint.contains("\"Green\"") && hint.contains("\"Blue\""), "\(hint)")
        #expect(await value(tab, "String(window.picked)") == "undefined")
    }

    @Test func aCustomListPicksAListedOptionAfterAMiss() async throws {
        let (tab, id) = try await page(Self.colours)
        _ = await box.call("choose", ["tab": id, "ref": "Colour", "value": "Purple"], task: task)

        let chose = await box.call("choose", ["tab": id, "ref": "Colour", "value": "Green"], task: task)

        #expect(!chose.failed, "\(chose.text ?? "")")
        #expect(await value(tab, "String(window.picked)") == "Green")
    }
}
