import AppKit
import Testing
@testable import Search

/// What the bookmarks bar's right-click menu does, without the menu: a
/// real one is an NSMenu that a hidden run can't open (#439).
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct BookmarksBarMenuTests {
    @Test func openInPrivateWindowTakesThePrivateWindowsBlankTab() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { browser.closeAll() }
        browser.arrive(URL(string: "https://example.com/a")!)
        #expect(browser.tabs.count == 1)
        let tab = browser.active
        #expect(tab?.shy == true, "Open in Private Window keeps nothing")
        #expect(tab?.store.isPersistent == false)
        #expect(browser.editing == false)
    }

    @Test func openAllInTabGroupNamesTheGroupAfterTheFolder() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = prefs.usesTabGroups
        defer { browser.closeAll(); prefs.usesTabGroups = saved }

        prefs.usesTabGroups = false
        let off = browser.tabs.count
        browser.openInTabGroup([URL(string: "https://example.com/1")!], named: "Off")
        #expect(browser.tabs.count == off, "With tab groups off, nothing opens")

        prefs.usesTabGroups = true
        let urls = (1...3).map { URL(string: "https://example.com/\($0)")! }
        browser.openInTabGroup(urls, named: "Reading")
        let group = browser.tabGroups.first { $0.name == "Reading" }
        #expect(group != nil)
        #expect(browser.editingGroupID == nil, "A group named already doesn't wait for a name")
        if let group {
            #expect(browser.tabs(in: group.id).count == 3)
        }
    }

    @Test func openInSplitNeedsSplitView() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = prefs.splitView
        defer { browser.closeAll(); prefs.splitView = saved }
        browser.active?.restore(url: URL(string: "about:blank#left")!, title: "Left")

        prefs.splitView = false
        let off = browser.tabs.count
        browser.openInSplit(URL(string: "https://example.com/off")!)
        #expect(browser.tabs.count == off)

        prefs.splitView = true
        browser.openInSplit(URL(string: "https://example.com/right")!)
        #expect(browser.activeSplit != nil, "The page opens paired with the one on screen")
    }
}
