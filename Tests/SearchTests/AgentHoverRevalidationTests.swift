import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AgentHoverRevalidationTests {
    @Test func hoverRefusesATargetRemovedDuringItsWakeWait() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let box = BrowserToolbox()
        box.browser = browser
        browser.prefs.agentMode = .auto
        let server = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><button id='target'>Hover target</button>")])
        let task = UUID()
        defer {
            AgentDesk.shared.drop(task: task)
            server.stop()
            browser.closeAll()
        }
        _ = await box.call("open", ["url": server.url("/page").absoluteString], task: task)
        let tab = try #require(browser.tabs.first { $0.agent })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        let captured = await PageSelection.run(tab, AgentPage.snapshotScript, AgentPage.snapshotArguments)
        let snapshot = try #require(captured as? [String: Any])
        let items = try #require(snapshot["items"] as? [[String: Any]])
        let ref = try #require(items.first(where: { $0["name"] as? String == "Hover target" })?["ref"] as? String)
        _ = await PageSelection.run(tab, """
        var target = document.getElementById('target');
        target.scrollIntoView = function () { setTimeout(function () { target.remove(); }, 25); };
        return true;
        """)

        let outcome = await box.call("hover", ["tab": id, "ref": ref], task: task)

        #expect(outcome.failed, "\(outcome.text ?? "")")
        #expect(outcome.text?.contains("left the page") == true, "\(outcome.text ?? "")")
    }
}
