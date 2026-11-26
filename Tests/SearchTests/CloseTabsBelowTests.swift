import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct CloseTabsBelowTests {
    @Test func closesOnlyTabsBelowBackgroundTabAndRemembersThem() {
        withBrowser { browser, tabs in
            browser.select(tabs[3])
            browser.closeTabsBelow(tabs[1])
            #expect(browser.tabs.map(\.id) == tabs.prefix(2).map { $0.id })
            #expect(browser.activeID == tabs[1].id)
            #expect(Set(browser.ghosts.map { $0.title }) == Set(["Tab 3", "Tab 4"]))
            #expect(browser.recentlyClosed.count == 1)
            #expect(browser.reopenTitle == "Reopen 2 Closed Tabs")

            browser.reopen()
            #expect(browser.tabs.compactMap(\.address) == tabs.compactMap { $0.address })
            #expect(browser.active?.address == tabs[3].address)
            #expect(browser.ghosts.isEmpty)
        }
    }

    @Test func preservesFocusAboveAndDoesNothingAtEndOrForMissingTab() {
        withBrowser { browser, tabs in
            browser.select(tabs[0])
            #expect(browser.tabsBelow(tabs[3]).isEmpty)
            browser.closeTabsBelow(tabs[3])
            #expect(browser.tabs.count == 4)
            #expect(browser.recentlyClosed.isEmpty)
            browser.closeTabsBelow(tabs[1])
            #expect(browser.activeID == tabs[0].id)
            #expect(browser.tabsBelow(tabs[2]).isEmpty)
            browser.closeTabsBelow(tabs[2])
            #expect(browser.tabs.map(\.id) == tabs.prefix(2).map { $0.id })
            browser.reopen()
            #expect(browser.tabs.compactMap(\.address) == tabs.compactMap { $0.address })
            #expect(browser.activeID == tabs[0].id)
        }
    }

    @Test func pinsStayWhenClosingBelowFirstTab() {
        withBrowser { browser, tabs in
            browser.pin(tabs[0])
            browser.pin(tabs[1])
            defer {
                browser.unpin(tabs[0])
                browser.unpin(tabs[1])
            }
            browser.closeTabsBelow(tabs[0])
            #expect(browser.tabs.map(\.id) == tabs.prefix(2).map { $0.id })
            #expect(tabs[1].pin != nil)
        }
    }

    @Test func keepsBothPagesWhenInvokedFromEitherSplitHalf() {
        for half in 0...1 {
            withBrowser { browser, tabs in
                browser.prefs.splitView = true
                browser.pair(tabs[1], with: tabs[0], onLeft: false)
                browser.closeTabsBelow(tabs[half])
                #expect(browser.tabs.map(\.id) == tabs.prefix(2).map { $0.id })
                #expect(browser.split(for: tabs[0]) != nil)
            }
        }
    }

    @Test func closesFoldedGroupsBelowInTheirDisplayOrder() {
        withBrowser { browser, tabs in
            let below = browser.addTabGroup(containing: tabs[0])
            browser.move(tabs[1], toGroup: below)
            let above = browser.addTabGroup(containing: tabs[2])
            browser.dropFolder(above, on: below, inside: false)
            browser.select(tabs[3])
            browser.toggleTabGroup(below)
            #expect(!browser.shownTabs.contains { $0.id == tabs[0].id })
            browser.closeTabsBelow(tabs[2])
            #expect(browser.tabs.map(\.id) == [tabs[2].id])
            #expect(browser.tabGroups.map(\.id) == [above])

            browser.reopen()
            #expect(browser.listItems(browser.displayedTabs).filter { item in
                if case .folder = item { true } else { false }
            }.map(\.id) == [above, below])
            #expect(browser.tabs(in: below).compactMap(\.address) == tabs.prefix(2).compactMap { $0.address })
            #expect(browser.tabs.compactMap(\.address) == [tabs[2], tabs[0], tabs[1], tabs[3]].compactMap { $0.address })
        }
    }

    @Test func recentlyClosedRestoresWholeBatchWithoutReopeningOtherActions() throws {
        try withBrowser(count: 6) { browser, tabs in
            browser.close(tabs[5])
            browser.closeTabsBelow(tabs[1])
            browser.close(tabs[0])

            #expect(browser.recentlyClosed.count == 3)
            #expect(browser.recentlyClosed.map { browser.closedTitle(for: $0) } == ["Tab 1", "3 Closed Tabs", "Tab 6"])
            let entry = try #require(browser.recentlyClosed.first { $0.batch != nil })
            browser.reopen(entry)
            #expect(browser.tabs.compactMap(\.address) == tabs[1...4].compactMap { $0.address })
            #expect(browser.active?.address == tabs[4].address)
            #expect(Set(browser.ghosts.map { $0.title }) == Set(["Tab 1", "Tab 6"]))
        }
    }

    @Test func batchLargerThanHistoryLimitReopensEveryTab() {
        withBrowser(count: 16) { browser, tabs in
            browser.select(tabs[0])
            browser.closeTabsBelow(tabs[0])
            #expect(browser.ghosts.count == 15)
            #expect(browser.recentlyClosed.count == 1)
            #expect(browser.reopenTitle == "Reopen 15 Closed Tabs")
            browser.reopen()
            #expect(browser.tabs.compactMap(\.address) == tabs.compactMap { $0.address })
            #expect(browser.activeID == tabs[0].id)
        }
    }

    @Test func reopeningRestoresSplitBelowClickedTab() throws {
        try withBrowser { browser, tabs in
            browser.prefs.splitView = true
            browser.pair(tabs[3], with: tabs[2], onLeft: false)
            browser.select(tabs[0])
            browser.closeTabsBelow(tabs[1])
            browser.reopen()
            #expect(browser.tabs.compactMap(\.address) == tabs.compactMap { $0.address })
            let pair = try #require(browser.split(for: browser.tabs[2]))
            #expect(pair.tabs == Array(browser.tabs.suffix(2)).map { $0.id })
            #expect(browser.activeID == tabs[0].id)
        }
    }

    @Test func reopeningRestoresMultipleGroupsAndPartiallyClosedGroup() {
        withBrowser(count: 6) { browser, tabs in
            let first = browser.addTabGroup(containing: tabs[0])
            browser.move(tabs[1], toGroup: first)
            let second = browser.addTabGroup(containing: tabs[2])
            browser.move(tabs[3], toGroup: second)
            let third = browser.addTabGroup(containing: tabs[4])
            browser.renameTabGroup(second, to: "Research")
            browser.select(tabs[0])
            browser.closeTabsBelow(tabs[0])
            #expect(browser.reopenTitle == "Reopen 5 Closed Tabs")
            browser.reopen()
            #expect(browser.tabs.compactMap(\.address) == tabs.compactMap { $0.address })
            #expect(browser.tabGroups.map(\.id) == [first, second, third])
            #expect(browser.tabGroups[1].name == "Research")
            #expect(browser.tabs.map(\.groupID) == [first, first, second, second, third, nil])
        }
    }

    @Test func closeGroupKeepsItsBatchLabelAndHistoryAction() throws {
        try withBrowser { browser, tabs in
            let group = browser.addTabGroup(containing: tabs[0])
            browser.move(tabs[1], toGroup: group)
            browser.select(tabs[0])
            browser.closeTabGroup(group)
            #expect(browser.reopenTitle == "Reopen Closed Group")
            #expect(browser.recentlyClosed.map { browser.closedTitle(for: $0) } == ["Closed Group"])
            browser.reopen()
            #expect(browser.tabs.filter { !$0.isBlank }.compactMap(\.address) == tabs.compactMap { $0.address })
            #expect(browser.tabs(in: group).count == 2)
            #expect(browser.ghosts.isEmpty)
        }
    }

    private func withBrowser(count: Int = 4, _ body: (Browser, [Tab]) throws -> Void) rethrows {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = prefs.splitView
        defer {
            browser.closeAll()
            prefs.splitView = saved
        }
        prefs.splitView = false
        for number in 1...count {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        try body(browser, browser.tabs)
    }
}
