import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct TabSelectionTests {
    @Test func commandTogglesAndShiftSelectsVisibleRange() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = makeBrowser()
        let tabs = browser.shownTabs
        #expect(tabs.count == 4)

        browser.extendTabSelection(to: tabs[0], modifiers: .command)
        browser.extendTabSelection(to: tabs[2], modifiers: .command)
        #expect(browser.selectedTabIDs == Set([tabs[0].id, tabs[2].id, tabs[3].id]))
        #expect(browser.selectedTabLinks == ["https://one.example/", "https://three.example/", "https://four.example/"])

        browser.extendTabSelection(to: tabs[1], modifiers: .shift)
        #expect(browser.selectedTabIDs == Set([tabs[1].id, tabs[2].id]))
        #expect(browser.selectedTabLinks == ["https://two.example/", "https://three.example/"])

        browser.extendTabSelection(to: tabs[2], modifiers: .command)
        #expect(browser.selectedTabIDs == [tabs[1].id])
        browser.clearTabSelection()
        #expect(browser.selectedTabIDs.isEmpty)
    }

    @Test func bothSplitHalvesCanBeSelectedAndRangesIncludeBoth() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = makeBrowser()
        let tabs = browser.shownTabs
        browser.prefs.splitView = true
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.select(tabs[3])
        browser.extendTabSelection(to: tabs[0], modifiers: .command)
        browser.extendTabSelection(to: tabs[1], modifiers: .command)
        #expect(browser.selectedTabIDs == Set([tabs[0].id, tabs[1].id, tabs[3].id]))
        #expect(browser.selectedTabLinks == ["https://one.example/", "https://two.example/", "https://four.example/"])

        browser.clearTabSelection()
        browser.extendTabSelection(to: tabs[0], modifiers: .shift)
        #expect(browser.selectedTabIDs == Set(tabs.map { $0.id }))
        #expect(browser.visibleSelectedTabCount == 4)
        #expect(browser.selectedTabLinks.count == 4)
    }

    private func makeBrowser() -> Browser {
        let browser = Browser(record: WindowRecord())
        let tabs = ["one", "two", "three", "four"].map { word in
            let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
            tab.restore(url: URL(string: "https://\(word).example/")!, title: word)
            return tab
        }
        browser.showRow(tabs, active: tabs[3].id)
        return browser
    }
}
