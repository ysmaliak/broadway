import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SwitcherSpacesTests {
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

    @Test func theSwitcherListsTabsOfEverySpaceMostRecentlyUsedFirst() {
        let (a, b, c, d) = twoSpaces()

        let order = browser.tabSwitcher.ordered(row: browser.switcherRow, current: browser.activeID)

        #expect(order == [d.id, c.id, a.id, b.id])
    }

    @Test func choosingATabOfAnotherSpaceGoesToThatSpaceAndSelectsIt() {
        let (_, b, _, _) = twoSpaces()
        browser.switchTabs(backwards: false)

        browser.commitTabSwitch(picking: b.id)

        #expect(browser.spaceID == first)
        #expect(browser.activeID == b.id)
    }

    @Test func aCardOfAnotherSpaceKnowsThatSpaceForItsMark() {
        let (a, _, c, _) = twoSpaces()

        let elsewhere = browser.switcherSpace(of: a.id)
        let here = browser.switcherSpace(of: c.id)

        #expect(elsewhere?.id == first)
        #expect(elsewhere?.shownIcon.emoji == "🏠")
        #expect(here == nil)
    }

    @Test func closingACardOfAnotherSpaceClosesItInThatSpace() {
        let (a, b, _, _) = twoSpaces()

        browser.act(.close, onCard: a.id)

        #expect(browser.parked[first]?.tabs.map(\.id) == [b.id])
        #expect(browser.spaceID == second)
    }

    @Test func anEmptyTabOfAnotherSpaceIsNotOffered() {
        _ = twoSpaces()
        let blank = Tab(configuration: Web.configuration(space: first))
        browser.parked[first]?.tabs.append(blank)

        let row = browser.switcherRow

        #expect(!row.contains(blank.id))
    }

    @Test func withSpacesOffOnlyTheRowOnScreenIsOffered() {
        _ = twoSpaces()
        browser.prefs.usesSpaces = false

        let row = browser.switcherRow

        #expect(row.count == 2)
        #expect(Set(row) == Set(browser.tabs.map(\.id)))
    }

    @Test func aPrivateWindowKeepsToItself() {
        let shy = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { shy.closeAll() }
        _ = twoSpaces()

        let row = shy.switcherRow

        #expect(Set(row) == Set(shy.tabs.map(\.id)))
    }
}
