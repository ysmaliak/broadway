import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct CloseBothPagesTests {
    @Test func closeBothPagesIsOneStepThatBringsThePairBackAsASplitView() throws {
        try withBrowser { browser, tabs in
            browser.prefs.splitView = true
            browser.pair(tabs[2], with: tabs[1], onLeft: false)
            browser.select(tabs[2])
            browser.closeSplit()
            #expect(browser.tabs.map(\.id) == [tabs[0].id, tabs[3].id])
            #expect(browser.recentlyClosed.count == 1)
            #expect(browser.reopenTitle == "Reopen 2 Closed Tabs")

            browser.reopen()
            #expect(browser.tabs.compactMap(\.address) == tabs.compactMap { $0.address })
            let pair = try #require(browser.split(for: browser.tabs[1]))
            #expect(pair.tabs == [browser.tabs[1].id, browser.tabs[2].id])
            #expect(browser.ghosts.isEmpty)
        }
    }

    @Test func halvesClosedOneByOneComeBackAsAPairWithTwoReopens() throws {
        try withBrowser { browser, tabs in
            browser.prefs.splitView = true
            browser.pair(tabs[2], with: tabs[1], onLeft: false)
            browser.select(tabs[0])
            browser.close(tabs[1])
            browser.close(tabs[2])
            browser.reopen()
            browser.reopen()
            #expect(browser.tabs.compactMap(\.address) == tabs.compactMap { $0.address })
            let pair = try #require(browser.split(for: browser.tabs[1]))
            #expect(Set(pair.tabs) == Set([browser.tabs[1].id, browser.tabs[2].id]))
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
