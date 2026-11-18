import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AgentScrollInBoxTests {
    static let page = """
    <!doctype html><html lang="en"><title>Box</title><h1>Box</h1>
    <div id="log" style="height:300px;overflow-y:auto">\((1...200).map { "<p id=\"line\($0)\">Line \($0)</p>" }.joined())</div>
    <div style="height:3000px"></div><p id="far">Far words</p>
    """

    let browser: Browser
    let box = BrowserToolbox()
    let server: LocalPageServer
    let task = UUID()

    init() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        box.browser = browser
        browser.prefs.agentMode = .auto
        server = try LocalPageServer(["/page": .init(type: "text/html", body: Self.page)])
    }

    func open() async throws -> (Tab, String) {
        _ = await box.call("open", ["url": server.url("/page").absoluteString], task: task)
        let tab = try #require(browser.tabs.first { $0.agent })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        return (tab, id)
    }

    func ref(_ tab: Tab, _ id: String) async throws -> String {
        try #require(await PageSelection.run(tab, AgentPage.naming + AgentPage.stateScript + "return broadwayRef(document.getElementById('\(id)'));") as? String)
    }

    func number(_ tab: Tab, _ script: String) async -> Double {
        let found = await PageSelection.run(tab, script)
        return (found as? NSNumber)?.doubleValue ?? -1
    }

    func finish() {
        AgentDesk.shared.drop(task: task)
        server.stop()
        browser.closeAll()
    }

    @Test func scrollingDownInABoxMovesTheBoxAndNotThePage() async throws {
        defer { finish() }
        let (tab, id) = try await open()
        let log = try await ref(tab, "log")

        let said = await box.call("scroll", ["tab": id, "by": "down", "in": "@\(log)"], task: task)

        #expect(!said.failed, "\(said.text ?? "")")
        let moved = await number(tab, "return document.getElementById('log').scrollTop;")
        #expect(moved > 200)
        let bottom = await box.call("scroll", ["tab": id, "by": "bottom", "in": "@\(log)"], task: task)
        #expect(bottom.text?.contains("Scrolled to the bottom") == true, "\(bottom.text ?? "")")
    }

    @Test func aTargetWithADirectionMovesItsOwnScrollBoxThatWay() async throws {
        defer { finish() }
        let (tab, id) = try await open()
        let line = try await ref(tab, "line3")

        let said = await box.call("scroll", ["tab": id, "ref": "@\(line)", "by": "bottom"], task: task)

        #expect(!said.failed, "\(said.text ?? "")")
        let top = await number(tab, "var b = document.getElementById('log'); return b.scrollHeight - b.clientHeight - b.scrollTop;")
        #expect(top >= 0 && top <= 1, "\(top)")
        let page = await number(tab, "return scrollY;")
        #expect(page == 0)
        #expect(said.text?.contains("Scrolled the box around @\(line) to the bottom") == true, "\(said.text ?? "")")
    }

    @Test func aTargetAloneIsBroughtIntoView() async throws {
        defer { finish() }
        let (tab, id) = try await open()
        let line = try await ref(tab, "line150")

        let said = await box.call("scroll", ["tab": id, "ref": "@\(line)"], task: task)

        #expect(!said.failed, "\(said.text ?? "")")
        #expect(said.text?.contains("Scrolled to @\(line)") == true, "\(said.text ?? "")")
        let shown = await number(tab, "var r = document.getElementById('line150').getBoundingClientRect(), b = document.getElementById('log').getBoundingClientRect(); return r.top >= b.top && r.bottom <= b.bottom ? 1 : 0;")
        #expect(shown == 1)
    }

    @Test func aTargetWithNoScrollBoxOfItsOwnIsBroughtIntoViewAndTheDirectionIsSaidUnused() async throws {
        defer { finish() }
        let (tab, id) = try await open()
        let far = try await ref(tab, "far")

        let said = await box.call("scroll", ["tab": id, "ref": "@\(far)", "by": "down"], task: task)

        #expect(!said.failed, "\(said.text ?? "")")
        #expect(said.text?.contains("which has no scroll box of its own, so down was not used") == true, "\(said.text ?? "")")
        #expect(said.data?["direction"] as? String == "not used")
        let shown = await number(tab, "var r = document.getElementById('far').getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight ? 1 : 0;")
        #expect(shown == 1)
    }
}
