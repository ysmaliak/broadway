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
    private var oldCloseGoesBack = false

    init() {
        keepSettings("tabs.closeGoesBack", "spaces")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        oldSplitView = browser.prefs.splitView
        oldCloseGoesBack = browser.prefs.closeGoesBack
        browser.prefs.splitView = false
        browser.prefs.closeGoesBack = true
        browser.closeAll()
    }

    private func tearDown() {
        browser?.closeAll()
        browser?.prefs.splitView = oldSplitView
        browser?.prefs.closeGoesBack = oldCloseGoesBack
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
        browser.prefs.closeGoesBack = false
        let (_, b, c) = viewedBAC()
        browser.close(c)
        #expect(browser.activeID == b.id)
    }

    @Test func closingCurrentGoesBackToLastViewed() {
        let (a, _, c) = viewedBAC()
        browser.close(c)
        #expect(browser.activeID == a.id)
    }

    @Test func successiveClosesKeepGoingBack() {
        let (a, b, c) = viewedBAC()
        browser.close(c)
        #expect(browser.activeID == a.id)
        browser.close(a)
        #expect(browser.activeID == b.id)
    }

    @Test func tabClosedBehindIsNotGoneBackTo() {
        let (a, b, c) = viewedBAC()
        browser.close(a)
        #expect(browser.activeID == c.id)
        browser.close(c)
        #expect(browser.activeID == b.id)
    }

    @Test func orderInTheRowDoesNotMatter() {
        let (a, b, c) = viewedBAC()
        browser.move(c, to: 1)
        #expect(browser.tabs.map(\.id) == [a.id, c.id, b.id])
        browser.close(c)
        #expect(browser.activeID == a.id)
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

    @Test func sleepingTabGoneBackToWakes() {
        let (a, _, c) = viewedBAC()
        a.rest()
        #expect(a.asleep)
        browser.close(c)
        #expect(browser.activeID == a.id)
        #expect(!a.asleep)
        #expect(a.built != nil)
    }

    @Test func noHistoryKeepsNeighbour() {
        let (_, b, c) = viewedBAC()
        browser.select(b)
        browser.tabSwitcher.reset()
        browser.close(b)
        #expect(browser.activeID == c.id)
    }

    @Test func staysInItsSpace() {
        let oldUsesSpaces = browser.prefs.usesSpaces
        let oldSpaces = browser.spaces
        defer {
            browser.prefs.usesSpaces = oldUsesSpaces
            browser.spaces = oldSpaces
        }
        browser.prefs.usesSpaces = true
        let firstID = browser.spaceID
        let secondID = UUID()
        browser.spaces = [Space(id: firstID, name: "First", colour: 0), Space(id: secondID, name: "Second", colour: 1)]

        let (a, _, c) = viewedBAC()
        browser.switchSpace(to: secondID)
        let (d, e) = (tab("D"), tab("E"))
        browser.showRow([d, e], active: d.id)
        browser.select(e)
        browser.select(d)

        browser.switchSpace(to: firstID)
        browser.close(c)
        #expect(browser.activeID == a.id)
        #expect(browser.spaceID == firstID)
    }

    /// ⌘Y from a tab in the middle of the row: History opens beside it, and
    /// closing History goes back to that tab, switch or no switch.
    @Test func ownPageGoesBackWithSwitchOff() {
        browser.prefs.closeGoesBack = false
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
        browser.prefs.closeGoesBack = false
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
        browser.prefs.closeGoesBack = false
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
