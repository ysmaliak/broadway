import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct UndoCloseTabTests {
    @Test func undoReopensTheLastClosedTabThenTheOneBefore() throws {
        try withBrowser { browser, tabs, undo in
            act(undo) { browser.close(tabs[1]) }
            act(undo) { browser.close(tabs[2]) }

            let title = undo.undoMenuItemTitle
            undo.undo()

            #expect(title == "Undo Close Tab")
            #expect(browser.tabs.compactMap(\.address) == [tabs[0], tabs[2], tabs[3]].compactMap(\.address))
            #expect(browser.active?.address == tabs[2].address)

            undo.undo()

            #expect(browser.tabs.compactMap(\.address) == tabs.compactMap(\.address))
            #expect(!undo.canUndo)
        }
    }

    @Test func oneUndoBringsBackABulkCloseWhole() throws {
        try withBrowser { browser, tabs, undo in
            browser.select(tabs[3])

            act(undo) { browser.closeTabsBelow(tabs[0]) }

            #expect(undo.undoMenuItemTitle == "Undo Close 3 Tabs")

            undo.undo()

            #expect(browser.tabs.compactMap(\.address) == tabs.compactMap(\.address))
            #expect(browser.active?.address == tabs[3].address)
            #expect(!undo.canUndo)
        }
    }

    @Test func closingAGroupIsUndoneAsAGroup() throws {
        try withBrowser { browser, tabs, undo in
            browser.prefs.usesTabGroups = true
            let group = browser.quietly { browser.addTabGroup(containing: tabs[1]) }
            browser.quietly { browser.move(tabs[2], toGroup: group) }

            act(undo) { browser.closeTabGroup(group) }

            #expect(undo.undoMenuItemTitle == "Undo Close Group")

            undo.undo()

            #expect(browser.tabGroups.contains { $0.id == group })
            #expect(Set(browser.tabs.compactMap(\.address)) == Set(tabs.compactMap(\.address)))
        }
    }

    @Test func aPinPutDownLeavesNothingToUndo() throws {
        try withBrowser { browser, tabs, undo in
            browser.quietly { browser.pin(tabs[1]) }
            defer { browser.quietly { browser.unpin(tabs[1]) } }

            undo.groupsByEvent = true
            browser.closeTab(tabs[1])

            #expect(browser.tabs.contains { $0.id == tabs[1].id })
            #expect(browser.ghosts.isEmpty)
            #expect(!undo.canUndo)
        }
    }

    @Test func reopenedFromHistoryFirstUndoTakesTheNextOne() throws {
        try withBrowser { browser, tabs, undo in
            act(undo) { browser.close(tabs[1]) }
            act(undo) { browser.close(tabs[2]) }
            browser.reopen()

            undo.undo()

            #expect(browser.tabs.compactMap(\.address) == tabs.compactMap(\.address))
        }
    }

    private func withBrowser(_ body: (Browser, [Tab], UndoManager) throws -> Void) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.usesTabGroups, prefs.splitView, prefs.newTabPlace)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            browser.closeAll()
            window.close()
            prefs.usesTabGroups = saved.0
            prefs.splitView = saved.1
            prefs.newTabPlace = saved.2
        }
        prefs.usesTabGroups = false
        prefs.splitView = false
        prefs.newTabPlace = .end
        for number in 1...4 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        browser.window = window
        let undo = try #require(window.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        try body(browser, browser.tabs, undo)
    }

    private func act(_ undo: UndoManager, _ action: () -> Void) {
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
    }
}
