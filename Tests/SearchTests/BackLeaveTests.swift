import AppKit
import WebKit
import Testing
@testable import Search

struct BackLeaveRuleTests {
    @Test func aLinkedTabWithNothingBehindLeaves() {
        #expect(BackLeave.leaves(BackLeaveCase()))
    }

    @Test func aTabWithItsOwnPageBehindDoesNotLeave() {
        #expect(!BackLeave.leaves(BackLeaveCase(ownBack: true)))
    }

    @Test func aStuckTabDoesNotLeaveSoItsPageIsReachedFirst() {
        #expect(!BackLeave.leaves(BackLeaveCase(stuck: true)))
    }

    @Test func aBlankTabDoesNotLeave() {
        #expect(!BackLeave.leaves(BackLeaveCase(blank: true)))
    }

    @Test func aTabNothingOpenedDoesNotLeave() {
        #expect(!BackLeave.leaves(BackLeaveCase(hasSource: false)))
    }

    @Test func aTabWhoseSourceClosedDoesNotLeave() {
        #expect(!BackLeave.leaves(BackLeaveCase(sourceOpen: false)))
    }

    @Test func aTabFromAnAgentsTabDoesNotLeave() {
        #expect(!BackLeave.leaves(BackLeaveCase(sourceAgent: true)))
    }

    @Test func aPinnedTabDoesNotLeave() {
        #expect(!BackLeave.leaves(BackLeaveCase(pinned: true)))
    }

    @Test func halfOfASplitViewDoesNotLeave() {
        #expect(!BackLeave.leaves(BackLeaveCase(split: true)))
    }

    @Test func anAgentsTabDoesNotLeave() {
        #expect(!BackLeave.leaves(BackLeaveCase(agent: true)))
    }

    @Test func aPrivateTabFromAnOrdinaryTabDoesNotLeave() {
        #expect(!BackLeave.leaves(BackLeaveCase(privateTab: true, privateSource: false)))
    }

    @Test func aPrivateTabFromAPrivateTabLeaves() {
        #expect(BackLeave.leaves(BackLeaveCase(privateTab: true, privateSource: true)))
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class BackLeaveWorldTests {
    private var browser: Browser!
    private var box: BrowserToolbox!
    private var server: LocalPageServer!
    private var old: (split: Bool, floating: Bool) = (false, false)

    private static let fresh = ["Cache-Control": "no-store"]

    init() async throws {
        keepSettings("splitView", "newtab.floating")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        box = BrowserToolbox()
        box.browser = browser
        old = (browser.prefs.splitView, browser.prefs.floatingNewTab)
        browser.prefs.splitView = true
        browser.prefs.floatingNewTab = false
        server = try LocalPageServer([
            "/pond": .init(type: "text/html", body: "<!doctype html><title>Pond</title><p>Pond", headers: Self.fresh),
            "/reeds": .init(type: "text/html", body: "<!doctype html><title>Reeds</title><p>Reeds", headers: Self.fresh),
            "/frogs": .init(type: "text/html", body: "<!doctype html><title>Frogs</title><p>Frogs", headers: Self.fresh),
        ])
        browser.closeAll()
    }

    private func tearDown() async {
        server?.stop()
        browser?.closeAll()
        if let prefs = browser?.prefs { (prefs.splitView, prefs.floatingNewTab) = old }
        browser = nil
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
        tab.built.map { !$0.isLoading } == true && tab.committed?.path == path
    }

    private func source() async throws -> Tab {
        let tab = browser.open(server.url("/pond"), foreground: true)
        for blank in browser.tabs where blank.isBlank { browser.close(blank) }
        try await until("the source loads") { settled(tab, at: "/pond") }
        return tab
    }

    private func linked(from source: Tab, front: Bool = true) async throws -> Tab {
        let tab = browser.open(server.url("/reeds"), foreground: front, from: source, link: true)
        try await until("the linked page loads") { settled(tab, at: "/reeds") }
        return tab
    }

    private func open(_ tab: Tab) -> Bool { browser.tabs.contains { $0.id == tab.id } }

    @Test func backOnALinkedTabsFirstPageClosesItAndShowsTheSource() async throws {
        let from = try await source()
        let tab = try await linked(from: from)
        try #require(browser.activeID == tab.id)

        #expect(browser.backGoes(tab))
        browser.back()

        #expect(!open(tab))
        #expect(browser.activeID == from.id)
    }

    @Test func backWalksTheLinkedTabsOwnPagesBeforeClosingIt() async throws {
        let from = try await source()
        let tab = try await linked(from: from)
        tab.go(to: server.url("/frogs"))
        try await until("the second page loads") { settled(tab, at: "/frogs") && tab.canGoBack }

        browser.back()
        try await until("back on the first page") { settled(tab, at: "/reeds") && !tab.canGoBack }

        #expect(open(tab))
        #expect(browser.activeID == tab.id)
        browser.back()
        #expect(!open(tab))
        #expect(browser.activeID == from.id)
    }

    @Test func theMouseButtonAndTheSwipeCloseALinkedTabByThePagesOwnHook() async throws {
        let from = try await source()
        let tab = try await linked(from: from)
        let page = try #require(tab.built)

        #expect(page.leave?(false) == true)
        #expect(page.leave?(true) == true)
        try await until("the tab closes") { !open(tab) }

        #expect(browser.activeID == from.id)
    }

    @Test func thePagesHookDoesNothingForATabWithAPageBehind() async throws {
        let from = try await source()
        let tab = try await linked(from: from)
        tab.go(to: server.url("/frogs"))
        try await until("the second page loads") { settled(tab, at: "/frogs") && tab.canGoBack }

        #expect(tab.built?.leave?(true) == false)
        try await Task.sleep(for: .milliseconds(100))

        #expect(open(tab))
    }

    @Test func anAgentsBackClosesNothing() async throws {
        let from = try await source()
        let tab = try await linked(from: from, front: false)
        let verb = try #require(PersonCommands.find("page", "back"))

        _ = try await verb.run(PersonCall(noun: "page", verb: "back", arguments: [:], browser: browser, box: box, tab: (tab, browser)))
        browser.select(tab)
        tab.back()

        #expect(open(tab))
        #expect(open(from))
    }

    @Test func aPinnedTabIsLeftAlone() async throws {
        let from = try await source()
        let tab = try await linked(from: from)
        browser.pin(tab)
        browser.select(tab)

        #expect(!browser.backGoes(tab))
        browser.back()

        #expect(open(tab))
        #expect(tab.pin != nil)
    }

    @Test func aPaneOfASplitViewIsLeftAlone() async throws {
        let from = try await source()
        let tab = try await linked(from: from)
        let other = browser.open(server.url("/frogs"), foreground: false)
        browser.pair(other, with: tab, onLeft: false)
        browser.select(tab)
        try #require(browser.split(for: tab) != nil)

        #expect(!browser.backGoes(tab))
        browser.back()

        #expect(open(tab))
        #expect(browser.split(for: tab) != nil)
    }

    @Test func reopenClosedTabBringsTheTabBack() async throws {
        let from = try await source()
        let tab = try await linked(from: from)
        let address = tab.address
        browser.back()
        try #require(!open(tab))

        browser.reopen()

        #expect(browser.active?.address == address)
        #expect(browser.tabs.count == 2)
    }
}
