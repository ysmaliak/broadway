import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ReloadPickedTests {
    private func withBrowser(_ body: (Browser, [Tab]) throws -> Void) rethrows {
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
        for number in 1...4 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        let tabs = browser.tabs
        for tab in tabs.prefix(3) { _ = tab.wake() }
        browser.select(tabs[3])
        try body(browser, tabs)
    }

    @Test func reloadPageReloadsEveryPickedTab() {
        withBrowser { browser, tabs in
            browser.extendTabSelection(to: tabs[0], modifiers: .command)
            browser.extendTabSelection(to: tabs[1], modifiers: .command)
            let before = tabs.map(\.kicks.reload)

            Command.named("view.reload")?.run(browser)

            #expect(tabs[0].kicks.reload == before[0] + 1)
            #expect(tabs[1].kicks.reload == before[1] + 1)
            #expect(tabs[2].kicks.reload == before[2])
        }
    }

    @Test func aPickedTabThatIsAsleepStaysAsleep() {
        withBrowser { browser, tabs in
            browser.extendTabSelection(to: tabs[0], modifiers: .command)
            browser.extendTabSelection(to: tabs[1], modifiers: .command)
            tabs[1].sleep(picture: nil)
            #expect(tabs[1].asleep)

            browser.reloadPage()

            #expect(tabs[1].asleep)
        }
    }

    @Test func withNoTabsPickedReloadPageReloadsThePageInFront() {
        withBrowser { browser, tabs in
            browser.select(tabs[2])
            let before = tabs.map(\.kicks.reload)

            browser.reloadPage()

            #expect(tabs[2].kicks.reload == before[2] + 1)
            #expect(tabs[0].kicks.reload == before[0])
        }
    }
}
