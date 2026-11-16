import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SplitHelmTests {
    @Test func theColumnsTopRowStaysWithAPairInFront() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let prefs = browser.prefs
        let previous = prefs.splitView
        prefs.splitView = true
        browser.newTab()
        let left = try #require(browser.tabs.last)
        left.restore(url: URL(string: "about:blank#left")!, title: "Left")
        browser.newTab()
        let right = try #require(browser.tabs.last)
        right.restore(url: URL(string: "about:blank#right")!, title: "Right")
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: prefs.columnWidth, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        let column = SideColumnView(browser: browser)
        window.contentView = column
        defer {
            window.contentView = nil
            window.close()
            browser.closeAll()
            prefs.splitView = previous
        }
        column.layoutSubtreeIfNeeded()
        let helm = try #require(column.kitSubviews(of: HelmView.self).first)
        let alone = helm.frame

        browser.putBackSplit(TabSplit(tabs: [left.id, right.id], focused: right.id))
        browser.select(right)
        column.needsLayout = true
        column.layoutSubtreeIfNeeded()

        #expect(browser.activeSplit != nil)
        #expect(browser.shownTab === right)
        #expect(!helm.isHidden)
        #expect(helm.frame == alone)
        #expect(helm.frame.width > 0 && helm.frame.height > 0)

        browser.focusPane(left)
        column.needsLayout = true
        column.layoutSubtreeIfNeeded()

        #expect(browser.shownTab === left)
        #expect(!helm.isHidden)
    }
}
