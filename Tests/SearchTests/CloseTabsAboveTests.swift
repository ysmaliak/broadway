import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct CloseTabsAboveTests {
    @Test func closesOnlyTheTabsAboveAndBringsThemBackAsOne() {
        withBrowser { browser, tabs in
            browser.select(tabs[0])

            browser.closeTabsAbove(tabs[2])

            #expect(browser.tabs.map(\.id) == [tabs[2].id, tabs[3].id])
            #expect(browser.activeID == tabs[2].id)
            #expect(browser.reopenTitle == "Reopen 2 Closed Tabs")
            browser.reopen()
            #expect(browser.tabs.compactMap(\.address) == tabs.compactMap { $0.address })
            #expect(browser.active?.address == tabs[0].address)
        }
    }

    @Test func broadwaysRowMenusLeaveOutTheSystemsOwnRows() {
        withBrowser(count: 1) { browser, tabs in
            let row = TabMenuItems.menu(browser: browser, tab: tabs[0], close: {})
            let made = KitMenu.make([])

            #expect(!row.allowsContextMenuPlugIns)
            #expect(!made.allowsContextMenuPlugIns)
        }
    }

    @Test func doesNothingOnTheFirstTab() {
        withBrowser { browser, tabs in
            #expect(browser.tabsAbove(tabs[0]).isEmpty)

            browser.closeTabsAbove(tabs[0])

            #expect(browser.tabs.count == 4)
            #expect(browser.recentlyClosed.isEmpty)
        }
    }

    @Test func pinsAboveAreLeftAlone() {
        withBrowser { browser, tabs in
            browser.pin(tabs[0])
            defer { browser.unpin(tabs[0]) }

            browser.closeTabsAbove(tabs[2])

            #expect(browser.tabs.map(\.id) == [tabs[0].id, tabs[2].id, tabs[3].id])
            #expect(tabs[0].pin != nil)
        }
    }

    @Test func aPinnedFolderTheTabIsNotInIsLeftAlone() {
        withBrowser { browser, tabs in
            browser.prefs.usesTabGroups = true
            let pinned = browser.addTabGroup(containing: tabs[0], pinned: true)
            browser.editingGroupID = nil

            browser.closeTabsAbove(tabs[3])

            #expect(browser.tabs.map(\.id) == [tabs[0].id, tabs[3].id])
            #expect(browser.tabGroups.map(\.id) == [pinned])
        }
    }

    @Test func aFolderAboveGoesWholeAndComesBack() {
        withBrowser { browser, tabs in
            browser.prefs.usesTabGroups = true
            let folder = browser.addTabGroup(containing: tabs[0])
            browser.move(tabs[1], toGroup: folder)
            browser.editingGroupID = nil
            browser.select(tabs[3])

            browser.closeTabsAbove(tabs[2])

            #expect(browser.tabs.map(\.id) == [tabs[2].id, tabs[3].id])
            #expect(browser.tabGroups.isEmpty)
            browser.reopen()
            #expect(browser.tabs(in: folder).compactMap(\.address) == tabs.prefix(2).compactMap { $0.address })
        }
    }

    @Test func bothPagesOfThePairStay() {
        for half in 1...2 {
            withBrowser { browser, tabs in
                browser.prefs.splitView = true
                browser.pair(tabs[2], with: tabs[1], onLeft: false)

                browser.closeTabsAbove(tabs[half])

                #expect(browser.tabs.map(\.id) == [tabs[1].id, tabs[2].id, tabs[3].id])
                #expect(browser.split(for: tabs[1]) != nil)
            }
        }
    }

    @Test func theTabMenuOffersCloseTabsAboveJustBeforeCloseTabsBelow() {
        withBrowser { browser, tabs in
            let middle = TabMenuItems.items(browser: browser, tab: tabs[1], close: {}).map(\.title)
            let top = TabMenuItems.items(browser: browser, tab: tabs[0], close: {}).map(\.title)

            let above = middle.firstIndex(of: "Close Tabs Above")

            #expect(above != nil)
            #expect(above.map { $0 + 1 } == middle.firstIndex(of: "Close Tabs Below"))
            #expect(!top.contains("Close Tabs Above"))
        }
    }

    @Test func closeTabsAboveAndBelowAreCommandsOnTheTabInFront() {
        withBrowser { browser, tabs in
            browser.select(tabs[2])

            Command.named("tabs.closeAbove")?.run(browser)
            Command.named("tabs.closeBelow")?.run(browser)

            #expect(browser.tabs.map(\.id) == [tabs[2].id])
            #expect(Command.named("tabs.closeAbove")?.title == "Close Tabs Above")
            #expect(Command.named("tabs.closeBelow")?.title == "Close Tabs Below")
            #expect(Command.named("tabs.closeAbove")?.defaultKey == nil)
            #expect(Command.named("tabs.closeBelow")?.defaultKey == nil)
        }
    }

    @Test func closeOtherTabsIsOnOptionCommandW() {
        let command = Command.named("tabs.closeOthers")

        let key = command?.defaultKey

        #expect(key == KeyCombo("w", option: true))
        #expect(key?.display == "⌥⌘W")
    }

    private func withBrowser(count: Int = 4, _ body: (Browser, [Tab]) throws -> Void) rethrows {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        keepSetting(prefs, \.newTabPlace, "tabs.newPlace")
        let saved = (prefs.usesTabGroups, prefs.splitView, prefs.newTabPlace)
        defer {
            browser.closeAll()
            prefs.usesTabGroups = saved.0
            prefs.splitView = saved.1
            prefs.newTabPlace = saved.2
        }
        prefs.usesTabGroups = false
        prefs.splitView = false
        prefs.newTabPlace = .end
        for number in 1...count {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        try body(browser, browser.tabs)
    }
}
