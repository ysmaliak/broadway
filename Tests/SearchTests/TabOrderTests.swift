import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class TabOrderTests {
    private var browser: Browser!
    private var old: (groups: Bool, split: Bool, floating: Bool, back: Bool)

    init() {
        keepSettings("tabs.closeGoesBack", "spaces", "tabs.groups", "splitView", "newtab.floating")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let prefs = browser.prefs
        old = (prefs.usesTabGroups, prefs.splitView, prefs.floatingNewTab, prefs.closeGoesBack)
        prefs.usesTabGroups = true
        prefs.splitView = true
        prefs.floatingNewTab = false
        prefs.closeGoesBack = false
        browser.closeAll()
        addTeardownBlock { self.tearDown() }
    }

    private func tearDown() {
        browser?.closeAll()
        if let prefs = browser?.prefs {
            (prefs.usesTabGroups, prefs.splitView, prefs.floatingNewTab, prefs.closeGoesBack) = old
        }
        browser = nil
    }

    private func page(_ name: String) -> Tab {
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.restore(url: URL(string: "about:blank#\(name)")!, title: name)
        return tab
    }

    private func row(_ names: String...) -> [Tab] {
        let made = names.map(page)
        browser.showRow(made, active: made.first?.id)
        return made
    }

    private func loaded(_ names: String...) -> [Tab] {
        let made = names.map { browser.open(URL(string: "about:blank#\($0)")!, foreground: true) }
        for blank in browser.tabs where blank.isBlank { browser.close(blank) }
        return made
    }

    private func link(_ name: String, from source: Tab, front: Bool = false) -> Tab {
        browser.open(URL(string: "about:blank#\(name)")!, foreground: front, from: source, link: true)
    }

    private var on: Tab.ID? { browser.activeID }

    private func ids() -> [Tab.ID] { browser.tabs.map(\.id) }

    @Test func theNewTabButtonsTabIsLastAndSelected() throws {
        let t = row("a", "b", "c")
        browser.select(t[1])
        browser.newTab()
        let fresh = try #require(browser.active)
        #expect(fresh.isBlank)
        #expect(ids().last == fresh.id)
    }

    @Test func aNewTabClosedStraightAwayGoesBackToTheTabYouWereOn() throws {
        let t = row("a", "b", "c")
        browser.select(t[1])
        browser.newTab()
        let fresh = try #require(browser.active)
        browser.close(fresh)
        #expect(on == t[1].id)
    }

    @Test func aNewTabStillGoesBackAfterAnAddressIsTypedInIt() throws {
        let t = row("a", "b", "c")
        browser.select(t[1])
        browser.newTab()
        let fresh = try #require(browser.active)
        fresh.restore(url: URL(string: "about:blank#typed")!, title: "typed")
        browser.close(fresh)
        #expect(on == t[1].id)
    }

    @Test func aNewTabLeftAndComeBackToClosesToItsNeighbour() throws {
        let t = row("a", "b", "c")
        browser.select(t[1])
        browser.newTab()
        let fresh = try #require(browser.active)
        fresh.restore(url: URL(string: "about:blank#typed")!, title: "typed")
        browser.select(t[0])
        browser.select(fresh)
        browser.close(fresh)
        #expect(on == t[2].id)
    }

    @Test func aNewTabFromTheCommandBarOrAnotherAppGoesBackWhenClosed() {
        let t = row("a", "b", "c")
        browser.select(t[0])
        let opened = browser.open(URL(string: "about:blank#elsewhere")!, foreground: true)
        #expect(on == opened.id)
        browser.close(opened)
        #expect(on == t[0].id)
    }

    @Test func aDuplicateSitsNextToItsTabAndClosesBackToIt() throws {
        let t = row("a", "b", "c")
        browser.select(t[1])
        browser.duplicate()
        let copy = try #require(browser.active)
        #expect(ids().firstIndex(of: copy.id) == 2)
        browser.close(copy)
        #expect(on == t[1].id)
    }

    @Test func linksOpenedBehindSitAfterTheirPageInClickOrder() {
        let t = row("x", "s", "y")
        browser.select(t[1])
        let l1 = link("l1", from: t[1]), l2 = link("l2", from: t[1]), l3 = link("l3", from: t[1])
        #expect(ids() == [t[0].id, t[1].id, l1.id, l2.id, l3.id, t[2].id])
        #expect(on == t[1].id)
    }

    @Test func closingLinksOpenedBehindWalksThemThenGoesBackToTheirPage() {
        let t = row("x", "s", "y")
        browser.select(t[1])
        let l1 = link("l1", from: t[1]), l2 = link("l2", from: t[1]), l3 = link("l3", from: t[1])
        browser.select(l1)
        browser.close(l1)
        #expect(on == l2.id)
        browser.close(l2)
        #expect(on == l3.id)
        browser.close(l3)
        #expect(on == t[1].id)
    }

    @Test func aLinkInFrontSitsNextToItsPageAndClosesBackToIt() {
        let t = row("x", "s", "y")
        browser.select(t[1])
        let front = link("front", from: t[1], front: true)
        #expect(on == front.id)
        #expect(ids() == [t[0].id, t[1].id, front.id, t[2].id])
        browser.close(front)
        #expect(on == t[1].id)
    }

    @Test func aLinkInFrontClosesBackToItsPageEvenWithLinksBehindBesideIt() {
        let t = row("x", "s", "y")
        browser.select(t[1])
        _ = link("l1", from: t[1])
        let front = link("front", from: t[1], front: true)
        browser.close(front)
        #expect(on == t[1].id)
    }

    @Test func movingBetweenAPageAndItsLinksKeepsTheWayBack() {
        let t = row("x", "s", "y")
        browser.select(t[1])
        let l1 = link("l1", from: t[1]), l2 = link("l2", from: t[1])
        browser.select(l2)
        browser.select(t[1])
        browser.select(l2)
        browser.close(l2)
        #expect(on == l1.id)
        browser.close(l1)
        #expect(on == t[1].id)
    }

    @Test func goingToAnotherTabForgetsTheWayBack() {
        let t = row("x", "s", "y")
        browser.select(t[1])
        let l1 = link("l1", from: t[1])
        browser.select(t[2])
        browser.select(l1)
        browser.close(l1)
        #expect(on == t[2].id)
    }

    @Test func closingTheLastTabInTheListGoesToTheOneAbove() {
        let t = row("a", "b", "c")
        browser.select(t[2])
        browser.select(t[0])
        browser.select(t[2])
        browser.close(t[2])
        #expect(on == t[1].id)
    }

    @Test func closingTheFirstTabInTheListGoesToTheOneBelow() {
        let t = row("a", "b", "c")
        browser.select(t[2])
        browser.select(t[0])
        browser.close(t[0])
        #expect(on == t[1].id)
    }

    @Test func closingATabYouAreNotOnChangesNothing() {
        let t = row("a", "b", "c")
        browser.select(t[0])
        browser.close(t[1])
        #expect(on == t[0].id)
        browser.close(t[2])
        #expect(on == t[0].id)
    }

    @Test func closingTheOnlyTabLeavesANewOne() throws {
        let t = row("a")
        browser.close(t[0])
        let left = try #require(browser.active)
        #expect(browser.tabs.count == 1)
        #expect(left.isBlank)
    }

    @Test func closingInAFolderStaysInTheFolder() {
        let t = row("above", "f1", "f2", "f3", "below")
        let folder = browser.addTabGroup(containing: t[1], pinned: false)
        browser.move(t[2], toGroup: folder)
        browser.move(t[3], toGroup: folder)
        browser.select(t[3])
        browser.close(t[3])
        #expect(on == t[2].id)
        browser.select(t[1])
        browser.close(t[1])
        #expect(on == t[2].id)
    }

    @Test func closingOneSideOfSplitViewLeavesTheOther() {
        let t = row("left", "right", "other")
        browser.putBackSplit(TabSplit(tabs: [t[0].id, t[1].id], focused: t[0].id))
        browser.select(t[0])
        browser.close(t[0])
        #expect(on == t[1].id)
    }

    @Test func closingSeveralAtOnceKeepsTheOneAskedFor() {
        let t = row("a", "b", "c", "d")
        browser.select(t[3])
        browser.closeTabsBelow(t[1])
        #expect(on == t[1].id)
        #expect(ids() == [t[0].id, t[1].id])
    }

    @Test func aTabBehindClosedByItsPageChangesNothing() {
        let t = row("s", "y")
        browser.select(t[0])
        let win = link("win", from: t[0], front: true)
        win.opener = t[0].id
        browser.select(t[1])
        browser.webViewDidClose(win.web)
        #expect(on == t[1].id)
        #expect(!ids().contains(win.id))
    }

    @Test func aTabInFrontClosedByItsPageGoesBackToThePageThatOpenedIt() {
        let t = row("s", "y")
        browser.select(t[0])
        let win = link("win", from: t[0], front: true)
        win.opener = t[0].id
        browser.select(t[1])
        browser.select(win)
        browser.webViewDidClose(win.web)
        #expect(on == t[0].id)
    }

    @Test func closingNeverLandsOnAnAgentsTab() {
        let t = row("a", "agent", "c")
        t[1].agent = true
        browser.select(t[2])
        browser.close(t[2])
        #expect(on == t[0].id)
    }

    @Test func aNewTabOpenedOverAnAgentsTabDoesNotGoBackToIt() throws {
        let t = row("a", "agent", "c")
        t[1].agent = true
        browser.select(t[0])
        browser.select(t[1])
        browser.newTab()
        let fresh = try #require(browser.active)
        browser.close(fresh)
        #expect(on != t[1].id)
    }

    @Test func closingAnAgentsTabGoesBackToYourLastTab() {
        let t = loaded("a", "b", "agent")
        t[2].agent = true
        browser.select(t[1])
        browser.select(t[0])
        browser.select(t[2])
        browser.close(t[2])
        #expect(on == t[0].id)
    }

    @Test func movingTheSelectedTabToAnotherWindowGoesToItsNeighbour() {
        let t = row("a", "b", "c")
        browser.select(t[1])
        let other = Browser(record: WindowRecord())
        other.leaveFiles()
        defer { other.closeAll() }
        browser.moveToWindow(t[1], other)
        #expect(on == t[2].id)
        #expect(other.activeID == t[1].id)
    }

    @Test func movingALinkToAnotherWindowGoesBackToItsPage() {
        let t = row("x", "s", "y")
        browser.select(t[1])
        let front = link("front", from: t[1], front: true)
        let other = Browser(record: WindowRecord())
        other.leaveFiles()
        defer { other.closeAll() }
        browser.moveToWindow(front, other)
        #expect(on == t[1].id)
    }

    @Test func aPinPutDownGoesToTheLastTabYouLookedAt() {
        let t = loaded("p", "a", "b")
        browser.pin(t[0])
        browser.select(t[2])
        browser.select(t[1])
        browser.select(t[0])
        browser.close(t[0])
        #expect(on == t[1].id)
    }

    @Test func steppingPastTheEndsGoesRound() {
        let t = row("a", "b", "c")
        browser.select(t[2])
        browser.step(1)
        #expect(on == t[0].id)
        browser.step(-1)
        #expect(on == t[2].id)
    }
}
