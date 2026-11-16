import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SplitCloseTests {
    private func pair(_ body: (Browser, Tab, Tab) throws -> Void) throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        let left = try #require(browser.tabs.last)
        left.restore(url: URL(string: "about:blank#left")!, title: "Left")
        browser.newTab()
        let right = try #require(browser.tabs.last)
        right.restore(url: URL(string: "about:blank#right")!, title: "Right")
        browser.putBackSplit(TabSplit(tabs: [left.id, right.id], focused: right.id))
        browser.select(right)
        try body(browser, left, right)
    }

    @Test func closingTheFocusedPaneLeavesTheOtherInFront() throws {
        try pair { browser, left, right in
            browser.leaveSplit(right)

            #expect(browser.splits.isEmpty)
            #expect(browser.activeID == left.id)
            #expect(browser.tabs.contains { $0.id == right.id })
        }
    }

    @Test func closingTheOtherPaneKeepsTheFocusedOneInFront() throws {
        try pair { browser, left, right in
            browser.leaveSplit(left)

            #expect(browser.splits.isEmpty)
            #expect(browser.activeID == right.id)
        }
    }

    @Test func thePaneBarsButtonsSitInTheSameInsetOnEverySide() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let bar = PaneBarView(browser: browser, tab: browser.tabs[0])
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: Metrics.paneBar)
        bar.show(tab: browser.tabs[0], focused: true, carrying: false, corner: Metrics.pageRadius, look: nil)

        bar.layoutSubtreeIfNeeded()
        let doors = bar.subviews.compactMap { $0 as? PaneDoorBase }.map(\.frame)

        let inset = PaneBarView.inset
        #expect(doors.count == 5)
        #expect(doors.allSatisfy { $0.minY == inset && bar.bounds.height - $0.maxY == inset })
        #expect(doors.map(\.minX).min() == inset)
        #expect(doors.map { bar.bounds.width - $0.maxX }.min() == inset)
    }
}
