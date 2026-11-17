import AppKit
import Darwin
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class MemoryCeilingWorldTests {
    private let task = UUID()
    private var browser: Browser!
    private var box: BrowserToolbox!
    private var server: LocalPageServer!
    private var seen: Set<Int> = []

    private static let ceiling: UInt64 = 600 << 20
    private static let fresh = ["Cache-Control": "no-store"]
    private static let page = "<!doctype html><title>Pond notes</title><p>Pond notes</p>"
    private static let grow = """
        <!doctype html><title>Heron count</title><p>Heron count</p>
        <script>
        var kept = [];
        function grow() {
          if (kept.length >= 10) return;
          var block = new Uint8Array(128 * 1024 * 1024);
          for (var i = 0; i < block.length; i += 4096) block[i] = 1;
          kept.push(block);
          setTimeout(grow, 20);
        }
        </script>
        """
    private static let growing = grow + "<img src=/held><script>grow()</script>"

    init() async throws {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        box = BrowserToolbox()
        box.browser = browser
        browser.prefs.agentMode = .auto
        server = try LocalPageServer([
            "/page": .init(type: "text/html", body: Self.page, headers: Self.fresh),
            "/grow": .init(type: "text/html", body: Self.grow, headers: Self.fresh),
            "/growing": .init(type: "text/html", body: Self.growing, headers: Self.fresh),
            "/held": .init(type: "text/html", body: Self.page, headers: Self.fresh, hold: 25),
        ])
        MemoryPages.note(browser)
        MemoryPages.start()
        MemoryWatch.shared.lower(to: Self.ceiling)
    }

    private func tearDown() async {
        MemoryWatch.shared.lower(to: nil)
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
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func settled(_ tab: Tab, at path: String) -> Bool {
        tab.built.map { !$0.isLoading && $0.processID > 0 } == true && tab.committed?.path == path && tab.failure == nil
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

    private func watched(_ pid: Int) async throws {
        try await until("the watch is told of \(pid)", within: 12) { MemoryWatch.shared.watched[Int32(pid)] != nil }
    }

    private func stopped(_ tab: Tab, after readings: Int) async throws -> Int {
        try await until("the page is stopped", within: 25) { tab.failure == MemoryWords.title }
        return MemoryWatch.shared.readings - readings
    }

    private func button(on tab: Tab) throws -> TroubleView {
        let view = PageTroubleView(tab: tab, browser: browser)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        return try #require(view.kitSubviews(of: TroubleView.self).first)
    }

    @Test func aGrowingPageInFrontIsEndedWithinThreeReadingsAndShowsTheMessage() async throws {
        let (tab, pid) = try await open("/grow")
        try await watched(pid)
        let readings = MemoryWatch.shared.readings

        tab.web.evaluateJavaScript("grow(); 0", completionHandler: nil)
        let took = try await stopped(tab, after: readings)

        #expect(took <= 3)
        #expect(try await ended(pid))
        #expect(tab.trouble == .tooLarge)
        #expect(try button(on: tab).message == "This page used too much memory and was stopped")
    }

    @Test func aStoppedPageStaysStoppedUntilThePersonAsks() async throws {
        let (tab, pid) = try await open("/grow")
        try await watched(pid)
        let before = loads("/grow")
        tab.web.evaluateJavaScript("grow(); 0", completionHandler: nil)
        _ = try await stopped(tab, after: MemoryWatch.shared.readings)

        try await Task.sleep(for: .seconds(3))

        #expect(tab.failure == MemoryWords.title)
        #expect(loads("/grow") == before)
        #expect(!tab.stale)
        #expect(!tab.asleep)
    }

    @Test func pressingTheButtonLoadsThePageAgainOnANewProcess() async throws {
        let (tab, pid) = try await open("/grow")
        try await watched(pid)
        tab.web.evaluateJavaScript("grow(); 0", completionHandler: nil)
        _ = try await stopped(tab, after: MemoryWatch.shared.readings)
        let before = loads("/grow")

        try button(on: tab).onRetry()
        try await until("the page loads again", within: 10) { settled(tab, at: "/grow") }

        #expect(loads("/grow") == before + 1)
        #expect(tab.web.processID != pid)
        #expect(tab.failure == nil)
        seen.insert(tab.web.processID)
    }

    @Test func aGrowingTabBehindIsEndedTooAndStaysStoppedWhenItComesForward() async throws {
        let (front, _) = try await open("/page")
        let (tab, pid) = try await open("/grow", front: false)
        try await watched(pid)
        let before = loads("/grow")
        let readings = MemoryWatch.shared.readings

        tab.web.evaluateJavaScript("grow(); 0", completionHandler: nil)
        let took = try await stopped(tab, after: readings)
        let kept = browser.awake(because: tab)
        browser.select(tab)
        try await Task.sleep(for: .seconds(2))

        #expect(took <= 3)
        #expect(try await ended(pid))
        #expect(kept == "stopped for its memory")
        #expect(browser.activeID == tab.id)
        #expect(tab.failure == MemoryWords.title)
        #expect(loads("/grow") == before)
        #expect(front.failure == nil)
    }

    @Test func anAgentsNextCallOnAStoppedTabFailsWithTheCode() async throws {
        _ = await box.call("open", ["url": server.url("/grow").absoluteString], task: task)
        let tab = try #require(browser.tabs.first { $0.agent })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        try await until("the agent's page loads") { settled(tab, at: "/grow") }
        let pid = tab.web.processID
        seen.insert(pid)
        try await watched(pid)

        tab.web.evaluateJavaScript("grow(); 0", completionHandler: nil)
        _ = try await stopped(tab, after: MemoryWatch.shared.readings)
        let said = await box.call("snapshot", ["tab": id], task: task)
        let after = await box.call("snapshot", ["tab": id], task: task)

        #expect(said.code == "page_too_large", "\(said.text ?? "")")
        #expect(said.text == "The page used too much memory and was stopped. Loading it again may do the same.")
        #expect(said.retrySafe == false)
        #expect(after.code != "page_too_large")
        #expect(tab.failure == MemoryWords.title)
    }

    @Test func anAgentsCallWaitingOnThePageWhenItIsStoppedFailsWithTheCode() async throws {
        _ = await box.call("open", ["url": server.url("/grow").absoluteString], task: task)
        let tab = try #require(browser.tabs.first { $0.agent })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        try await until("the agent's page loads") { settled(tab, at: "/grow") }
        let pid = tab.web.processID
        seen.insert(pid)
        try await watched(pid)
        let before = loads("/grow")

        async let waited = box.call("wait", ["tab": id, "text": "Herons counted", "seconds": 20], task: task)
        try await Task.sleep(for: .milliseconds(400))
        tab.web.evaluateJavaScript("grow(); 0", completionHandler: nil)
        let said = await waited

        #expect(said.code == "page_too_large", "\(said.text ?? "")")
        #expect(said.retrySafe == false)
        #expect(tab.failure == MemoryWords.title)
        #expect(loads("/grow") == before)
    }

    @Test func aPageStoppedWhileItIsStillLoadingKeepsItsOwnMessageAndLoadsNothingMore() async throws {
        let tab = browser.open(server.url("/growing"), foreground: true)
        try await until("the page commits") { tab.committed?.path == "/growing" && tab.web.processID > 0 }
        let pid = tab.web.processID
        seen.insert(pid)
        try await watched(pid)

        _ = try await stopped(tab, after: MemoryWatch.shared.readings)
        try await Task.sleep(for: .seconds(2))

        #expect(try await ended(pid))
        #expect(tab.failure == MemoryWords.title)
        #expect(loads("/growing") == 1)
    }

    @Test func aPageStoppedWhileItGoesSomewhereNewKeepsItsOwnMessage() async throws {
        let (tab, pid) = try await open("/grow")
        try await watched(pid)
        tab.web.evaluateJavaScript("grow(); 0", completionHandler: nil)
        try await Task.sleep(for: .milliseconds(300))

        tab.go(to: server.url("/held"))
        _ = try await stopped(tab, after: MemoryWatch.shared.readings)
        try await Task.sleep(for: .seconds(2))

        #expect(try await ended(pid))
        #expect(tab.failure == MemoryWords.title)
        #expect(loads("/held") <= 1)
        #expect(loads("/grow") == 1)
    }

    @Test func aPageIsEndedWhileTheMainThreadIsBlocked() async throws {
        let (tab, pid) = try await open("/grow")
        try await watched(pid)
        tab.web.evaluateJavaScript("grow(); 0", completionHandler: nil)
        try await Task.sleep(for: .milliseconds(500))
        let readings = MemoryWatch.shared.readings
        let renewed = MemoryWatch.shared.renewed

        Thread.sleep(forTimeInterval: 11)
        let dead = !alive(pid)
        let read = MemoryWatch.shared.readings - readings
        let renewedSince = MemoryWatch.shared.renewed - renewed
        _ = try await stopped(tab, after: readings)

        #expect(dead)
        #expect(read >= 2)
        #expect(renewedSince == 0)
        #expect(tab.failure == MemoryWords.title)
    }

    @Test func aTabInAnotherSpaceIsStoppedTooAndShowsTheMessageWhenItsSpaceComesBack() async throws {
        browser.prefs.usesSpaces = true
        let first = browser.spaceID
        browser.addSpace(named: "Marsh")
        let second = browser.spaceID
        defer {
            browser.spaces.removeAll { $0.id == second }
            Spaces.write(browser.spaces)
        }
        browser.switchSpace(to: first)
        let (tab, pid) = try await open("/grow")
        try await watched(pid)
        browser.switchSpace(to: second)
        try await until("the tab is parked") { browser.parkedTabs.contains { $0 === tab } && MemoryWatch.shared.watched[Int32(pid)] != nil }
        let before = loads("/grow")

        tab.web.evaluateJavaScript("grow(); 0", completionHandler: nil)
        _ = try await stopped(tab, after: MemoryWatch.shared.readings)
        browser.switchSpace(to: first)
        try await Task.sleep(for: .seconds(2))

        #expect(try await ended(pid))
        #expect(tab.failure == MemoryWords.title)
        #expect(!tab.stale)
        #expect(loads("/grow") == before)
    }

    @Test func aPageUnderTheCeilingIsLeftAlone() async throws {
        let (tab, pid) = try await open("/page")
        try await watched(pid)
        let readings = MemoryWatch.shared.readings

        try await until("two readings", within: 15) { MemoryWatch.shared.readings >= readings + 2 }

        #expect(alive(pid))
        #expect(tab.failure == nil)
        #expect(MemoryWatch.shared.lastReadings.contains { Int($0.pid) == pid && $0.bytes > 0 && $0.bytes < Self.ceiling })
    }
}
