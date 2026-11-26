import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SwitcherCloseTests {
    private var browser: Browser!
    private var first = UUID()
    private var second = UUID()

    init() {
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        keepSetting(Shared.prefs, \.splitView, "splitView")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.closeAll()
        browser.prefs.usesSpaces = true
        browser.prefs.splitView = false
        first = browser.spaceID
        browser.spaces = [Space(id: first, name: "First", colour: 0, icon: TabIcon(emoji: "🏠")),
                          Space(id: second, name: "Second", colour: 1, icon: TabIcon(emoji: "🌿"))]
    }

    private func tearDown() {
        browser?.tabSwitcher.reset()
        browser?.switchSpace(to: first)
        browser?.closeAll()
        browser = nil
    }

    private func tab(_ name: String, in space: UUID) -> Tab {
        let tab = Tab(configuration: Web.configuration(space: space))
        tab.restore(url: URL(string: "about:blank#\(name)")!, title: name)
        return tab
    }

    private func twoSpaces() -> (a: Tab, b: Tab, c: Tab, d: Tab) {
        let (a, b) = (tab("A", in: first), tab("B", in: first))
        browser.showRow([a, b], active: b.id)
        browser.select(a)
        browser.switchSpace(to: second)
        let (c, d) = (tab("C", in: second), tab("D", in: second))
        browser.showRow([c, d], active: c.id)
        browser.select(d)
        return (a, b, c, d)
    }

    @Test func aCardOfAnotherSpaceClosedWithControlWIsInRecentlyClosed() {
        let (a, _, _, _) = twoSpaces()

        browser.act(.close, onCard: a.id)

        #expect(browser.recentlyClosed.map { browser.closedTitle(for: $0) } == ["A"])
        #expect(browser.recentlyClosed.first?.space == first)
    }

    @Test func reopeningACardOfAnotherSpaceBringsItBackInItsOwnSpace() {
        let (a, b, _, _) = twoSpaces()
        browser.act(.close, onCard: a.id)

        browser.reopen()

        #expect(browser.spaceID == first)
        #expect(browser.tabs.compactMap(\.address) == [a.address, b.address].compactMap { $0 })
        #expect(browser.active?.address == a.address)
        #expect(browser.ghosts.isEmpty)
    }

    @Test func undoBringsACardOfAnotherSpaceBackInItsOwnSpace() {
        let (a, _, _, _) = twoSpaces()
        browser.act(.close, onCard: a.id)

        browser.undoClose()

        #expect(browser.spaceID == first)
        #expect(browser.tabs.contains { $0.address == a.address })
    }

    @Test func aPairOfAnotherSpaceClosesAsOneStepAndComesBackAsAPair() throws {
        browser.prefs.splitView = true
        let (a, b, _, _) = twoSpaces()
        browser.parked[first]?.splits = [TabSplit(tabs: [a.id, b.id], focused: a.id)]
        browser.tabSwitcher.partners = [a.id: b.id]

        browser.act(.close, onCard: a.id)

        #expect(browser.parked[first]?.tabs.isEmpty == true)
        #expect(browser.recentlyClosed.count == 1)
        browser.reopen()
        #expect(browser.spaceID == first)
        let back = try #require(browser.tabs.first { $0.address == a.address })
        let pair = try #require(browser.split(for: back))
        #expect(pair.tabs.count == 2)
        #expect(browser.activeID == back.id)
    }

    @Test func aPairOnScreenClosedFromTheSwitcherIsOneStep() throws {
        browser.prefs.splitView = true
        let (_, _, c, d) = twoSpaces()
        browser.pair(c, with: d, onLeft: false)
        browser.tabSwitcher.partners = [d.id: c.id]

        browser.act(.close, onCard: d.id)

        #expect(browser.recentlyClosed.count == 1)
        #expect(browser.reopenTitle == "Reopen 2 Closed Tabs")
        browser.reopen()
        let back = try #require(browser.tabs.first { $0.address == c.address })
        #expect(browser.split(for: back) != nil)
    }

    @Test func theTabInFrontInAFolderIsPutAwayNotClosed() throws {
        let (_, _, c, d) = twoSpaces()
        let group = browser.addTabGroup(containing: d)
        browser.setFolderPinned(group, true)
        browser.select(d)
        try #require(browser.putsAway(d))

        browser.act(.close, onCard: d.id)

        #expect(browser.tabs.contains { $0.id == d.id })
        #expect(browser.activeID != d.id)
        #expect(browser.recentlyClosed.isEmpty)
        _ = c
    }
}
