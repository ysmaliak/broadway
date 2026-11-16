import Foundation
import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SplitReplaceTests {
    private func browser(tabs count: Int) -> Browser {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.prefs.splitView = true
        for number in 0..<count {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "\(number)")
        }
        return browser
    }

    @Test func replacingAHalfKeepsTheOtherHalf() {
        let count = 3
        let browser = browser(tabs: count)
        let tabs = Array(browser.tabs.filter { $0.pin == nil }.suffix(count))
        browser.pair(tabs[1], with: tabs[0], onLeft: false)

        browser.replacePage(tabs[0], with: tabs[2])

        let pair = browser.split(for: tabs[1])
        #expect(pair?.contains(tabs[2].id) == true)
        #expect(pair?.contains(tabs[1].id) == true)
        #expect(browser.split(for: tabs[0]) == nil)
        #expect(browser.activeID == tabs[2].id)
    }

    @Test func replacingALonePageShowsTheCarriedTab() {
        let count = 2
        let browser = browser(tabs: count)
        let tabs = Array(browser.tabs.filter { $0.pin == nil }.suffix(count))
        browser.select(tabs[0])

        browser.replacePage(tabs[0], with: tabs[1])

        #expect(browser.activeID == tabs[1].id)
        #expect(browser.split(for: tabs[1]) == nil)
    }

    @Test func thePageBeforeIsRememberedWhenATabComesForward() {
        let count = 3
        let browser = browser(tabs: count)
        let tabs = Array(browser.tabs.filter { $0.pin == nil }.suffix(count))
        browser.select(tabs[0])

        browser.select(tabs[2])

        #expect(browser.pageBefore == tabs[0].id)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ColumnMenuTests {
    @Test func theEmptyColumnOffersTheQueuedItems() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())

        let titles = PlusMenu.column(for: browser).items.filter { !$0.isSeparatorItem }.map(\.title)

        #expect(titles.count == 5)
        #expect(Array(titles.prefix(3)) == ["New Tab", "New Folder", "Hide Sidebar"])
        #expect(titles[3].hasPrefix("Sidebar on "))
        #expect(titles.last == "Sidebar Settings")
        #expect(!titles.contains("Space Settings…"))
    }
}
