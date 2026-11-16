import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentHandoffTests {
    private let task = UUID()

    private var browser: Browser!
    private var box: BrowserToolbox!
    private var server: LocalPageServer!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        let mine = Tab(configuration: Web.configuration(space: browser.spaceID))
        mine.restore(url: URL(string: "https://example.com/mine")!, title: "Mine")
        browser.showRow([mine], active: mine.id)
        box = BrowserToolbox()
        box.browser = browser
        browser.prefs.agentMode = .auto
        AgentSites.shared.reset()
    }

    private func tearDown() async {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        server?.stop()
        browser.prefs.agentMode = .auto
        AgentSites.shared.reset()
        browser?.closeAll()
        browser = nil
    }

    private func page() async throws -> (tab: Tab, id: String) {
        server = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><title>Shop</title><h1>Shop</h1>")])
        let before = Set(browser.tabs.map(\.id))
        _ = await box.call("open", ["url": "http://127.0.0.1:\(server.port)/page"], task: task)
        let tab = try #require(browser.tabs.first { !before.contains($0.id) })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        return (tab, id)
    }

    private func question() async -> AgentQuestion? {
        for _ in 0..<400 {
            if let front = AgentDesk.shared.front { return front }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    @Test func theCardsAnswersMeanDoneSkippedOrNoAnswer() {
        #expect(AgentHandoff.ending(.picked(0), optional: false) == .done)
        #expect(AgentHandoff.ending(.picked(1), optional: true) == .skipped)
        #expect(AgentHandoff.ending(.picked(1), optional: false) == .done)
        #expect(AgentHandoff.ending(.no, optional: true) == .done)
        #expect(AgentHandoff.ending(.dropped, optional: false) == .unanswered)
        #expect(AgentHandoff.ending(nil, optional: false) == .unanswered)
    }

    @Test func theWaitAndTheReasonHaveLimits() {
        #expect(AgentHandoff.wait([:]) == 300)
        #expect(AgentHandoff.wait(["seconds": 5000]) == 900)
        #expect(AgentHandoff.wait(["seconds": 0.0]) == 1)
        #expect(AgentHandoff.reason(["reason": String(repeating: "a", count: 100)]).count == 60)
    }

    @Test func handoffIsAToolWithItsCommand() {
        #expect(box.tools.contains { $0.name == "handoff" })
        let command = AgentCatalog.command(AgentHandoff.spec)
        #expect(command?["name"] as? String == "handoff")
        #expect((command?["positional"] as? [[String: Any]])?.first?["name"] as? String == "reason")
    }

    @Test func withoutASessionNoCardGoesUp() async throws {
        let (_, id) = try await page()
        let said = await box.call("handoff", ["tab": id, "reason": "Solve the captcha"], task: nil)
        #expect(said.failed)
        #expect(said.code == "needs_task")
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func aReasonIsNeeded() async throws {
        let (_, id) = try await page()
        let said = await box.call("handoff", ["tab": id, "reason": "  "], task: task)
        #expect(said.code == "usage")
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func donePutsTheTabBackWithAnAnswer() async throws {
        let (tab, id) = try await page()
        let running = Task { await box.call("handoff", ["tab": id, "reason": "Solve the captcha"], task: task) }
        let asked = try #require(await question())
        #expect(asked.title == "Solve the captcha")
        #expect(asked.kind == .choice(["Done"]))
        #expect(asked.tab == tab.id)
        #expect(asked.task == task)
        AgentDesk.shared.take(asked.id, .picked(0))
        let said = await running.value
        #expect(!said.failed)
        #expect(said.data?["did"] as? String == "handoff")
        #expect(said.data?["skipped"] == nil)
        #expect((said.data?["message"] as? String)?.hasPrefix("The person gave the tab back after") == true)
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func skipIsAnAnswerNotAnError() async throws {
        let (_, id) = try await page()
        let running = Task { await box.call("handoff", ["tab": id, "reason": "Accept the cookies", "optional": true], task: task) }
        let asked = try #require(await question())
        #expect(asked.kind == .choice(["Done", "Skip"]))
        AgentDesk.shared.take(asked.id, .picked(1))
        let said = await running.value
        #expect(!said.failed)
        #expect(said.data?["skipped"] as? Bool == true)
    }

    @Test func noAnswerInTimeIsNeedsYouAndTheCardGoes() async throws {
        let (_, id) = try await page()
        let said = await box.call("handoff", ["tab": id, "reason": "Type the code", "seconds": 1], task: task)
        #expect(said.failed)
        #expect(said.code == "needs_you")
        #expect(said.hint == "Tell the person, then run the same command again")
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func takingTheTabAndHandingItBackEndsTheHandoff() async throws {
        let (tab, id) = try await page()
        let running = Task { await box.call("handoff", ["tab": id, "reason": "Solve the captcha", "seconds": 20], task: task) }
        let asked = try #require(await question())
        tab.driving = true
        AgentDesk.shared.take(asked.id, .dropped)
        try? await Task.sleep(for: .milliseconds(200))
        tab.driving = false
        tab.handedBack = true
        let said = await running.value
        #expect(!said.failed)
        #expect(!tab.handedBack)
    }

    @Test func neverHereRefusesWithoutACard() async throws {
        let (tab, id) = try await page()
        let site = try #require(AgentSites.site(of: tab.pageAddress))
        AgentSites.shared.set(.never, for: site)
        let said = await box.call("handoff", ["tab": id, "reason": "Solve the captcha"], task: task)
        #expect(said.failed)
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func askModeAsksForTheTabBeforeHandingItOver() async throws {
        let (_, id) = try await page()
        browser.prefs.agentMode = .ask
        let running = Task { await box.call("handoff", ["tab": id, "reason": "Solve the captcha"], task: task) }
        let first = try #require(await question())
        #expect(first.kind == .approval(.tab))
        AgentDesk.shared.take(first.id, .no)
        let said = await running.value
        #expect(said.failed)
        #expect(AgentDesk.shared.pending.isEmpty)
    }
}
