import AppKit
import WebKit
import Testing
@testable import Search

/// Which tab is on screen after the one on screen closes, with and without
/// Settings › Tabs › Closing a tab goes back to the one before.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class TabCloseTests {
    private var browser: Browser!
    private var oldSplitView = false

    init() {
        keepSettings("spaces")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        oldSplitView = browser.prefs.splitView
        browser.prefs.splitView = false
        browser.closeAll()
    }

    private func tearDown() {
        browser?.closeAll()
        browser?.prefs.splitView = oldSplitView
        browser = nil
    }

    private func tab(_ name: String) -> Tab {
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.restore(url: URL(string: "about:blank#\(name)")!, title: name)
        return tab
    }

    /// A, B and C in the row, viewed B, then A, then C: C's neighbour is B,
    /// the tab viewed before it is A.
    private func viewedBAC() -> (a: Tab, b: Tab, c: Tab) {
        let (a, b, c) = (tab("A"), tab("B"), tab("C"))
        browser.showRow([a, b, c], active: c.id)
        browser.select(b)
        browser.select(a)
        browser.select(c)
        return (a, b, c)
    }

    @Test func offClosingCurrentSelectsNeighbour() {
        let (_, b, c) = viewedBAC()
        browser.close(c)
        #expect(browser.activeID == b.id)
    }

    @Test func tabClosedBehindIsNotGoneBackTo() {
        let (a, b, c) = viewedBAC()
        browser.close(a)
        #expect(browser.activeID == c.id)
        browser.close(c)
        #expect(browser.activeID == b.id)
    }

    @Test func splitPartnerStaysFirst() {
        browser.prefs.splitView = true
        let (a, b, c) = (tab("A"), tab("B"), tab("C"))
        browser.showRow([a, b, c], active: c.id)
        browser.pair(b, with: a, onLeft: false)
        browser.select(c)
        browser.select(b)
        browser.close(b)
        #expect(browser.activeID == a.id)
        #expect(browser.activeSplit == nil)
    }

    @Test func noHistoryKeepsNeighbour() {
        let (_, b, c) = viewedBAC()
        browser.select(b)
        browser.tabSwitcher.reset()
        browser.close(b)
        #expect(browser.activeID == c.id)
    }

    /// ⌘Y from a tab in the middle of the row: History opens beside it, and
    /// closing History goes back to that tab, switch or no switch.
    @Test func ownPageGoesBackWithSwitchOff() {
        let (a, b, c, d) = (tab("A"), tab("B"), tab("C"), tab("D"))
        browser.showRow([a, b, c, d], active: b.id)
        let history = browser.show(InternalPage(.history))
        let besideB: [Tab.ID] = [a.id, b.id, history.id, c.id, d.id]
        #expect(browser.tabs.map(\.id) == besideB)
        browser.close(history)
        #expect(browser.activeID == b.id)
    }

    /// History already open at the end of the row, brought forward from a
    /// tab in the middle: closing it went to the last tab.
    @Test func ownPageAlreadyOpenGoesBack() {
        let (a, b, c) = (tab("A"), tab("B"), tab("C"))
        browser.showRow([a, b, c], active: c.id)
        let history = browser.show(InternalPage(.history))
        browser.select(b)
        #expect(browser.show(InternalPage(.history)) === history)
        browser.close(history)
        #expect(browser.activeID == b.id)
    }

    /// A web page still goes to its neighbour with the switch off.
    @Test func webPageKeepsNeighbourWithSwitchOff() {
        let (a, b, c) = (tab("A"), tab("B"), tab("C"))
        browser.showRow([a, b, c], active: a.id)
        browser.select(b)
        browser.close(b)
        #expect(browser.activeID == c.id)
    }

    @Test func tabMovedToAnotherWindowIsNotGoneBackTo() {
        let other = Browser(record: WindowRecord(space: browser.spaceID))
        defer { other.closeAll() }
        let (a, b, c) = viewedBAC()
        browser.moveToWindow(a, other)
        browser.close(c)
        #expect(browser.activeID == b.id)
        #expect(other.tabs.contains { $0.id == a.id })
    }
}
