import AppKit
import Foundation
import Testing
@testable import Search

/// History › Clear Browsing Data…, which asks for the clearing controls
/// that live inside History (#749).
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ClearBrowsingDataTests {
    private func fresh() -> Browser {
        _ = NSApplication.shared
        return Browser(record: WindowRecord())
    }

    /// Asked for with History closed, which is how it is usually asked for:
    /// the mode alone left nothing on screen, so the menu item and its
    /// shortcut did nothing at all.
    @Test func bringsHistoryOutOnItsClearingControls() {
        let browser = fresh()
        #expect(!browser.recalling)

        browser.clearBrowsingData()

        #expect(browser.recalling)
        #expect(browser.recallMode == .clearing)
    }

    /// Asked for with History already open, where it worked before: the mode
    /// has to be set after the page is out, since a page coming out afresh
    /// puts the mode back to its list.
    @Test func switchesHistoryAlreadyOpenToItsClearingControls() {
        let browser = fresh()
        browser.recalling = true
        #expect(browser.recallMode == .history)

        browser.clearBrowsingData()

        #expect(browser.recalling)
        #expect(browser.recallMode == .clearing)
    }

    /// Never a second History, however often it is asked for, as ⌘Y's own
    /// page is brought forward rather than opened again.
    @Test func asksTwiceAndKeepsOneHistory() {
        let browser = fresh()
        browser.clearBrowsingData()
        browser.clearBrowsingData()

        #expect(browser.tabs.filter { $0.page?.kind == .history }.count == 1)
        #expect(browser.recallMode == .clearing)
    }

    /// Show History… is unchanged: it opens on the list, not on clearing.
    @Test func showHistoryStillOpensOnItsList() {
        let browser = fresh()
        browser.recalling = true

        #expect(browser.recalling)
        #expect(browser.recallMode == .history)
    }
}
