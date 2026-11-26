import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct CloseOtherTabsTests {
    @Test func closeOtherTabsIsOneStepThatBringsBackEveryTabPastThirty() {
        withBrowser(count: 40) { browser, tabs in
            browser.closeOthers(but: tabs[0])
            #expect(browser.tabs.map(\.id) == [tabs[0].id])
            #expect(browser.recentlyClosed.count == 1)
            #expect(browser.reopenTitle == "Reopen 39 Closed Tabs")

            browser.reopen()
            #expect(browser.tabs.compactMap(\.address) == tabs.compactMap { $0.address })
            #expect(browser.activeID == tabs[0].id)
            #expect(browser.ghosts.isEmpty)
        }
    }

    @Test func aFolderClosedWithTheOtherTabsComesBackAsAFolder() {
        withBrowser { browser, tabs in
            browser.prefs.usesTabGroups = true
            let folder = browser.addTabGroup(containing: tabs[1])
            browser.move(tabs[2], toGroup: folder)
            browser.closeOthers(but: tabs[0])
            #expect(browser.tabGroups.isEmpty)

            browser.reopen()
            #expect(browser.tabGroups.map(\.id) == [folder])
            #expect(browser.tabs(in: folder).compactMap(\.address) == [tabs[1], tabs[2]].compactMap { $0.address })
        }
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
