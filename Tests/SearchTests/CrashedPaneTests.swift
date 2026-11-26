import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct CrashedPaneTests {
    @Test func aCrashedPaneOfASplitReloadsWhenItIsFocused() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        keepSetting(browser.prefs, \.splitView, "splitView")
        browser.prefs.splitView = true
        defer { browser.closeAll() }
        browser.tabs.last?.restore(url: URL(string: "about:blank#1")!, title: "Tab 1")
        browser.newTab()
        browser.tabs.last?.restore(url: URL(string: "about:blank#2")!, title: "Tab 2")
        let (left, right) = (browser.tabs[0], browser.tabs[1])
        browser.pair(right, with: left, onLeft: false)
        browser.focusPane(left)
        #expect(browser.activeID == left.id)
        #expect(browser.visibleTabIDs.contains(right.id))
        right.stale = true

        browser.focusPane(right)

        #expect(browser.activeID == right.id)
        #expect(!right.stale)
    }
}
