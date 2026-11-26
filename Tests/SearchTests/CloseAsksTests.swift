import AppKit
import Darwin
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class CloseAsksTests {
    private let task = UUID()
    private var browser: Browser!
    private var box: BrowserToolbox!
    private var server: LocalPageServer!
    private var window: NSWindow!

    private static let fresh = ["Cache-Control": "no-store"]
    private static let field = "<input id=f autofocus style='position:absolute;left:0;top:0;width:500px;height:60px'>"
    private static let asks = "<!doctype html><title>Marsh log</title>" + field
        + "<script>addEventListener('beforeunload', function (e) { if (document.getElementById('f').value) { e.preventDefault(); e.returnValue = ''; } });</script>"
    private static let plain = "<!doctype html><title>Reed list</title>" + field
    private static let spins = "<!doctype html><title>Heron watch</title>" + field
        + "<script>addEventListener('beforeunload', function (e) { while (true) {} });</script>"

    init() async throws {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        keepSetting(Shared.prefs, \.splitView, "splitView")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        box = BrowserToolbox()
        box.browser = browser
        browser.prefs.agentMode = .auto
        server = try LocalPageServer([
            "/asks": .init(type: "text/html", body: Self.asks, headers: Self.fresh),
            "/also": .init(type: "text/html", body: Self.asks, headers: Self.fresh),
            "/plain": .init(type: "text/html", body: Self.plain, headers: Self.fresh),
            "/spins": .init(type: "text/html", body: Self.spins, headers: Self.fresh),
        ])
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 400), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        LeaveHold.hold(true)
    }

    private func tearDown() async {
        LeaveHold.hold(false)
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        AgentDesk.shared.drop(task: task)
        window?.contentView = nil
        window?.close()
        server?.stop()
        browser?.closeAll()
        browser = nil
    }

    private func alive(_ pid: Int) -> Bool {
        pid > 0 && Darwin.kill(pid_t(pid), 0) == 0
    }

    private func until(_ what: String, within seconds: TimeInterval = 8, sourceLocation: SourceLocation = #_sourceLocation,
                       _ done: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !done() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("timed out: \(what)", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func settled(_ tab: Tab, at path: String) -> Bool {
        tab.built.map { !$0.isLoading && $0.processID > 0 } == true && tab.committed?.path == path
    }

    private func open(_ path: String, front: Bool = true) async throws -> Tab {
        let tab = browser.open(server.url(path), foreground: front)
        try await until("\(path) loads") { settled(tab, at: path) }
        return tab
    }

    private func loads(_ path: String) -> Int {
        server.requests.filter { $0 == path }.count
    }

    private func typeInto(_ tab: Tab) async throws {
        let web = tab.web
        web.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = web
        window.makeFirstResponder(web)
        let point = NSPoint(x: 100, y: 370)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if kind == .leftMouseDown { web.mouseDown(with: event) } else { web.mouseUp(with: event) }
        }
        try await Task.sleep(for: .milliseconds(200))
        for (letter, code) in [("h", UInt16(4)), ("i", UInt16(34))] {
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try #require(NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil, characters: letter,
                                                          charactersIgnoringModifiers: letter, isARepeat: false, keyCode: code))
                if kind == .keyDown { web.keyDown(with: event) } else { web.keyUp(with: event) }
            }
        }
        try await until("the field holds what was typed") { typed(tab) == "hi" }
    }

    private var values: [ObjectIdentifier: String] = [:]

    private func typed(_ tab: Tab) -> String {
        tab.web.evaluateJavaScript("document.getElementById('f').value") { [weak self] value, _ in
            MainActor.assumeIsolated { self?.values[ObjectIdentifier(tab)] = value as? String ?? "" }
        }
        return values[ObjectIdentifier(tab)] ?? ""
    }

    private func text(_ tab: Tab) async throws -> String {
        try await tab.web.evaluateJavaScript("document.getElementById('f').value") as? String ?? ""
    }

    private func open(_ tab: Tab) -> Bool {
        browser.tabs.contains { $0 === tab }
    }

    @Test func closeBothPagesAsksOnceBeforeLeavingTypedWorkAndStayKeepsThePair() async throws {
        browser.prefs.splitView = true
        let typed = try await open("/asks")
        try await typeInto(typed)
        let other = try await open("/plain")
        browser.pair(other, with: typed, onLeft: false)

        browser.closeSplit()
        try await until("the page asks") { typed.leaveQuestion != nil }
        browser.answerLeave(typed, leave: false)
        try await Task.sleep(for: .seconds(1))

        #expect(open(typed) && open(other))
        #expect(browser.split(for: typed) != nil)
        #expect(try await text(typed) == "hi")
    }

    @Test func controlWInTheSwitcherAsksBeforeLeavingTypedWork() async throws {
        let typed = try await open("/asks")
        try await typeInto(typed)
        _ = try await open("/plain")

        browser.act(.close, onCard: typed.id)
        try await until("the page asks") { typed.leaveQuestion != nil }
        browser.answerLeave(typed, leave: false)
        try await Task.sleep(for: .seconds(1))

        #expect(open(typed))
        #expect(try await text(typed) == "hi")
    }

    @Test func leavingAfterControlWClosesBothPagesOfThePairAsOneStep() async throws {
        browser.prefs.splitView = true
        let typed = try await open("/asks")
        try await typeInto(typed)
        let other = try await open("/plain")
        browser.pair(other, with: typed, onLeft: false)
        browser.tabSwitcher.partners = [typed.id: other.id]

        browser.act(.close, onCard: typed.id)
        browser.tabSwitcher.partners = [:]
        try await until("the page asks") { typed.leaveQuestion != nil }
        browser.answerLeave(typed, leave: true)
        try await until("both pages close") { !open(typed) && !open(other) }

        #expect(browser.recentlyClosed.count == 1)
        #expect(browser.reopenTitle == "Reopen 2 Closed Tabs")
    }
}
