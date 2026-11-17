import AppKit
import Darwin
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class StuckPagesTests {
    private let task = UUID()
    private var browser: Browser!
    private var box: BrowserToolbox!
    private var server: LocalPageServer!
    private var seen: Set<Int> = []

    private static let fresh = ["Cache-Control": "no-store"]
    private static let page = "<!doctype html><title>Pond notes</title><p>Pond notes</p>"
    private static let other = "<!doctype html><title>Reed list</title><p>Reed list</p>"
    private static let form = "<!doctype html><title>Order seeds</title><form method=post action=/sent><input name=packet value=reeds><button>Send</button></form>"
    private static let sent = "<!doctype html><title>Order sent</title><p>Order sent</p>"
    private static let loop = "<!doctype html><title>Pond loop</title><button id=loop style='width:300px;height:120px' onclick='while (true) {}'>Stir the pond</button>"

    init() async throws {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        box = BrowserToolbox()
        box.browser = browser
        browser.prefs.agentMode = .auto
        server = try LocalPageServer([
            "/page": .init(type: "text/html", body: Self.page, headers: Self.fresh),
            "/other": .init(type: "text/html", body: Self.other, headers: Self.fresh),
            "/form": .init(type: "text/html", body: Self.form, headers: Self.fresh),
            "/sent": .init(type: "text/html", body: Self.sent, headers: Self.fresh),
            "/loop": .init(type: "text/html", body: Self.loop, headers: Self.fresh),
        ])
        StuckClock.shorten(StuckTimes(question: 0.6, agent: 1, quiet: 2))
    }

    private func tearDown() async {
        StuckClock.shorten(nil)
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        AgentDesk.shared.drop(task: task)
        for pid in seen where pid > 0 && alive(pid) { Darwin.kill(pid_t(pid), SIGKILL) }
        server?.stop()
        browser?.closeAll()
        browser = nil
    }

    private func alive(_ pid: Int) -> Bool {
        pid > 0 && Darwin.kill(pid_t(pid), 0) == 0
    }

    private func ended(_ pid: Int) async throws -> Bool {
        try await until("process \(pid) ends", within: 3) { !alive(pid) }
        return !alive(pid)
    }

    private func until(_ what: String, within seconds: TimeInterval = 8, sourceLocation: SourceLocation = #_sourceLocation,
                       _ done: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !done() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("timed out: \(what)", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func settled(_ tab: Tab, at path: String) -> Bool {
        tab.built.map { !$0.isLoading && $0.processID > 0 } == true && tab.committed?.path == path
    }

    private func open(_ path: String, front: Bool = true) async throws -> (tab: Tab, pid: Int) {
        let tab = browser.open(server.url(path), foreground: front)
        try await until("\(path) loads") { settled(tab, at: path) }
        let pid = tab.web.processID
        seen.insert(pid)
        return (tab, pid)
    }

    private func loads(_ path: String) -> Int {
        server.requests.filter { $0 == path }.count
    }

    private func hang(_ tab: Tab) {
        tab.web.evaluateJavaScript("setTimeout(function () { while (true) {} }, 30); 0", completionHandler: nil)
    }

    private func newProcess(_ tab: Tab, after old: Int, at path: String) async throws -> Int {
        try await until("a new process for \(path)") { tab.built.map { $0.processID != old } == true && settled(tab, at: path) }
        let pid = tab.web.processID
        seen.insert(pid)
        return pid
    }

    @Test func reloadOnAStuckTabEndsTheOldProcessAndLoadsOnce() async throws {
        let (tab, old) = try await open("/page")
        let before = loads("/page")
        hang(tab)
        browser.heardStuck(tab)

        browser.reload()
        let now = try await newProcess(tab, after: old, at: "/page")
        try await Task.sleep(for: .seconds(1))

        #expect(now != old)
        #expect(try await ended(old))
        #expect(loads("/page") == before + 1, "\(server.requests)")
        #expect(!tab.isStuck)
    }

    @Test func aReloadAskedBeforeTheWordIsDoneAgainOnAFreshProcessOnce() async throws {
        let (tab, old) = try await open("/page")
        let before = loads("/page")
        hang(tab)
        try await Task.sleep(for: .milliseconds(200))

        browser.reload()
        browser.heardStuck(tab)
        _ = try await newProcess(tab, after: old, at: "/page")
        try await Task.sleep(for: .seconds(1))

        #expect(try await ended(old))
        #expect(loads("/page") == before + 1, "\(server.requests)")
        #expect(!tab.stuck.card)
    }

    @Test func anAddressAskedBeforeTheWordLoadsOnceOnAFreshProcess() async throws {
        let (tab, old) = try await open("/page")
        hang(tab)
        try await Task.sleep(for: .milliseconds(200))

        tab.go(to: server.url("/other"))
        browser.heardStuck(tab)
        _ = try await newProcess(tab, after: old, at: "/other")
        try await Task.sleep(for: .seconds(1))

        #expect(try await ended(old))
        #expect(loads("/other") == 1, "\(server.requests)")
    }

    @Test func backOnAStuckTabEndsTheProcessAndGoesBackOneStep() async throws {
        let (tab, _) = try await open("/other")
        tab.go(to: server.url("/page"))
        try await until("the second page loads") { settled(tab, at: "/page") }
        let old = tab.web.processID
        seen.insert(old)
        hang(tab)
        browser.heardStuck(tab)

        browser.back()
        _ = try await newProcess(tab, after: old, at: "/other")

        #expect(try await ended(old))
        #expect(tab.committed?.path == "/other")
    }

    @Test func closeOnAStuckTabEndsItsProcessAndLoadsNothing() async throws {
        _ = try await open("/other")
        let (tab, old) = try await open("/page")
        let before = server.requests.count
        hang(tab)
        browser.heardStuck(tab)

        browser.close(tab)
        try await until("the old process is gone") { !alive(old) }
        try await Task.sleep(for: .seconds(1))

        #expect(try await ended(old))
        #expect(!browser.tabs.contains { $0 === tab })
        #expect(server.requests.count == before, "\(server.requests)")
    }

    @Test func stopOnAStuckTabEndsTheProcessAndLeavesItAsleepOnItsAddress() async throws {
        let (tab, old) = try await open("/page")
        let before = loads("/page")
        hang(tab)
        browser.heardStuck(tab)

        tab.stop()
        try await Task.sleep(for: .milliseconds(500))

        #expect(try await ended(old))
        #expect(tab.asleep)
        #expect(tab.address?.path == "/page")
        #expect(loads("/page") == before)
    }

    @Test func sleepOnAStuckTabEndsItsProcessWithoutAskingThePage() async throws {
        let (tab, old) = try await open("/page", front: false)
        _ = try await open("/other")
        hang(tab)
        try await Task.sleep(for: .milliseconds(200))
        browser.heardStuck(tab)

        var said: String?
        browser.sleep(tab) { said = $0 }
        try await until("sleep answers", within: 3) { said != nil }

        #expect(said == "asleep")
        #expect(tab.asleep)
        #expect(try await ended(old))
    }

    @Test func theCardComesWhenDueAndOnlyOnScreen() async throws {
        let (behind, _) = try await open("/other", front: false)
        let (front, _) = try await open("/page")
        browser.heardStuck(front)
        browser.heardStuck(behind)

        #expect(!front.stuck.card)
        try await until("the card comes on the tab in front") { front.stuck.card }
        try await Task.sleep(for: .milliseconds(200))

        #expect(front.stuck.card)
        #expect(!behind.stuck.card)
        #expect(behind.stuck.owed)
        browser.select(behind)
        #expect(behind.stuck.card)
    }

    @Test func aTabThatAnsweredBeforeComingForwardIsNotAskedAbout() async throws {
        let (behind, _) = try await open("/other", front: false)
        _ = try await open("/page")
        browser.heardStuck(behind)
        try await until("the question is owed") { behind.stuck.owed }

        browser.heardAnswering(behind)
        browser.select(behind)

        #expect(!behind.stuck.card)
    }

    @Test func theOwedCardComesWhenTheTabInFrontClosesAndItsNeighbourComesForward() async throws {
        let (behind, _) = try await open("/other", front: false)
        let (front, _) = try await open("/page")
        browser.heardStuck(behind)
        try await until("the question is owed") { behind.stuck.owed }

        browser.close(front)

        #expect(browser.activeID == behind.id)
        #expect(behind.stuck.card)
    }

    @Test func aStopThePageTookIsNotDoneAgainWhenThePageSticksLater() async throws {
        let (tab, old) = try await open("/page")
        tab.stop()
        try await Task.sleep(for: .seconds(StuckTimes.askHolds + 0.5))

        browser.heardStuck(tab)

        #expect(!tab.asleep)
        #expect(tab.web.processID == old)
        #expect(tab.stuck.due != nil)
    }

    @Test func aReloadThatFinishedIsNotDoneAgainWhenThePageSticksRightAfter() async throws {
        let (tab, old) = try await open("/page")
        let before = loads("/page")
        browser.reload()
        try await until("the reload finishes") { loads("/page") == before + 1 && settled(tab, at: "/page") }

        browser.heardStuck(tab)
        try await Task.sleep(for: .milliseconds(300))

        #expect(tab.web.processID == old)
        #expect(loads("/page") == before + 1)
        #expect(tab.stuck.due != nil || tab.stuck.card)
    }

    @Test func theCardSaysItsWordsAndItsButtonsWaitBeforeTheyTakeAClick() async throws {
        let (tab, _) = try await open("/page")
        let card = StuckCardView(tab: tab, browser: browser)
        card.frame = NSRect(x: 0, y: 0, width: 300, height: 500)
        card.layoutSubtreeIfNeeded()
        let labels = card.kitSubviews(of: KitLabel.self)
        let buttons = card.kitSubviews(of: KitButton.self)
        let heading = try #require(labels.first { $0.text == "This page stopped answering" })
        let words = try #require(labels.first { $0.text == "Reload starts it again. Anything typed into it may be lost." })

        let reload = try #require(buttons.first { $0.accessibilityLabel() == "Reload" })
        let wait = try #require(buttons.first { $0.accessibilityLabel() == "Wait" })

        #expect(!card.ready)
        #expect(buttons.count == 2)
        #expect(reload.look == .keycap(.primary))
        #expect(wait.look == .keycap(.secondary))
        #expect(reload.frame.minX > wait.frame.maxX)
        #expect(words.frame.height > heading.frame.height * 1.5)
        #expect(buttons.allSatisfy { $0.frame.maxY <= ($0.superview?.bounds.height ?? 0) })
        try await until("the buttons wake", within: 2) { card.ready }
        #expect(card.ready)
    }

    @Test func anAgentsRealClickOnALoopingPageIsAnsweredWithTheCodeAndAFreshPage() async throws {
        let (tab, id, old) = try await agentTab("/loop")
        let captured = await PageSelection.run(tab, AgentPage.snapshotScript, AgentPage.snapshotArguments)
        let items = try #require((captured as? [String: Any])?["items"] as? [[String: Any]])
        let ref = try #require(items.first { ($0["name"] as? String ?? "").contains("Stir") }?["ref"] as? String)

        let clicked = await box.call("click", ["tab": id, "ref": ref], task: task)
        _ = try await newProcess(tab, after: old, at: "/loop")

        #expect(try await ended(old))
        #expect(clicked.code == "page_reloaded", "\(clicked.text ?? "") \(tab.stuck)")
        #expect(clicked.retrySafe == false)
        #expect(!tab.stuck.card)
    }

    @Test func waitKeepsTheCardAwayForTheQuietTime() async throws {
        let (tab, old) = try await open("/page")
        browser.heardStuck(tab)
        try await until("the card comes") { tab.stuck.card }

        browser.answerStuck(tab, reload: false)
        #expect(!tab.stuck.card)
        browser.heardAnswering(tab)
        browser.heardStuck(tab)
        try await Task.sleep(for: .seconds(1))
        #expect(!tab.stuck.card)

        try await Task.sleep(for: .seconds(1.2))
        browser.heardAnswering(tab)
        browser.heardStuck(tab)
        try await until("the card comes again after the quiet") { tab.stuck.card }
        #expect(tab.web.processID == old)
    }

    @Test func aPageThatAnswersByItselfTakesTheCardAwayAndSaysNothing() async throws {
        let (tab, old) = try await open("/page")
        browser.heardStuck(tab)
        try await until("the card comes") { tab.stuck.card }

        browser.heardAnswering(tab)

        #expect(!tab.stuck.card)
        #expect(!tab.isStuck)
        #expect(tab.stuck.quietUntil == nil)
        #expect(tab.web.processID == old)
    }

    @Test func reloadOnTheCardEndsTheProcessAndLoadsTheAddressAgain() async throws {
        let (tab, old) = try await open("/page")
        let before = loads("/page")
        hang(tab)
        browser.heardStuck(tab)
        try await until("the card comes") { tab.stuck.card }

        browser.answerStuck(tab, reload: true)
        _ = try await newProcess(tab, after: old, at: "/page")
        try await Task.sleep(for: .milliseconds(500))

        #expect(try await ended(old))
        #expect(!tab.stuck.card)
        #expect(loads("/page") == before + 1)
    }

    @Test func anEndedProcessIsNotTakenForACrash() async throws {
        _ = try await open("/other", front: false)
        let (tab, old) = try await open("/page")
        let before = loads("/page")
        browser.heardStuck(tab)

        tab.stop()
        try await Task.sleep(for: .seconds(1))

        #expect(try await ended(old))
        #expect(tab.asleep)
        #expect(!tab.stale)
        #expect(loads("/page") == before)
    }

    private func agentTab(_ path: String) async throws -> (tab: Tab, id: String, pid: Int) {
        _ = await box.call("open", ["url": server.url(path).absoluteString], task: task)
        let tab = try #require(browser.tabs.first { $0.agent })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        try await until("the agent's page loads") { settled(tab, at: path) }
        let pid = tab.web.processID
        seen.insert(pid)
        return (tab, id, pid)
    }

    @Test func anAgentsStuckTabIsReloadedWithAPlainRequestAndItsNextCallFails() async throws {
        let (tab, id, _) = try await agentTab("/form")
        tab.web.evaluateJavaScript("document.forms[0].submit(); 0", completionHandler: nil)
        try await until("the form is sent") { settled(tab, at: "/sent") }
        let old = tab.web.processID
        seen.insert(old)
        hang(tab)
        browser.heardStuck(tab)

        try await Task.sleep(for: .milliseconds(400))
        #expect(!tab.stuck.card)
        _ = try await newProcess(tab, after: old, at: "/sent")
        let failed = await box.call("text", ["tab": id], task: task)
        let after = await box.call("text", ["tab": id], task: task)

        #expect(try await ended(old))
        #expect(!tab.stuck.card)
        #expect(server.methods.filter { $0.hasSuffix(" /sent") } == ["POST /sent", "GET /sent"], "\(server.methods)")
        #expect(failed.failed)
        #expect(failed.code == "page_reloaded")
        #expect(failed.retrySafe == false)
        #expect(failed.text == "The page stopped answering, so Broadway loaded its address again. Look at the page before you repeat anything.")
        #expect(!after.failed, "\(after.text ?? "")")
    }

    @Test func theAgentsCallWaitingOnAStuckPageFailsWithTheCode() async throws {
        let (tab, id, old) = try await agentTab("/page")
        hang(tab)
        try await Task.sleep(for: .milliseconds(200))
        browser.heardStuck(tab)

        let waiting = await box.call("text", ["tab": id], task: task)
        _ = try await newProcess(tab, after: old, at: "/page")
        let after = await box.call("text", ["tab": id], task: task)

        #expect(try await ended(old))
        #expect(waiting.code == "page_reloaded", "\(waiting.text ?? "")")
        #expect(waiting.retrySafe == false)
        #expect(!after.failed, "\(after.text ?? "")")
    }
}
