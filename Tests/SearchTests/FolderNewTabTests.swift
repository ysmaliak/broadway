import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FolderNewTabTests {
    init() {
        keepSetting(Shared.prefs, \.floatingNewTab, "newtab.floating")
    }

    private func withBrowser(_ body: (Browser, [Tab], UUID) throws -> Void) rethrows {
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
        prefs.floatingNewTab = false
        for number in 1...4 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        let tabs = browser.tabs
        let folder = browser.addTabGroup(containing: tabs[0])
        browser.move(tabs[1], toGroup: folder)
        browser.editingGroupID = nil
        try body(browser, tabs, folder)
    }

    @Test func newTabInFolderOpensABlankTabInTheFolderDirectlyUnderTheTabInFront() throws {
        try withBrowser { browser, tabs, folder in
            browser.select(tabs[0])

            Command.named("tabs.newInFolder")?.run(browser)

            let made = try #require(browser.active)
            #expect(made.isBlank)
            #expect(made.groupID == folder)
            #expect(browser.tabs.firstIndex { $0.id == made.id } == 1)
            #expect(browser.tabs(in: folder).map(\.id) == [tabs[0].id, made.id, tabs[1].id])
        }
    }

    @Test func withTheTabInFrontInNoFolderItDoesWhatNewTabDoes() throws {
        try withBrowser { browser, tabs, _ in
            browser.select(tabs[3])
            let count = browser.tabs.count

            Command.named("tabs.newInFolder")?.run(browser)

            let made = try #require(browser.active)
            #expect(made.isBlank)
            #expect(made.groupID == nil)
            #expect(browser.tabs.count == count + 1)
        }
    }

    @Test func theFolderMenuAddsTheTabAtTheEndOfThatFolder() throws {
        try withBrowser { browser, tabs, folder in
            browser.select(tabs[3])
            let menu = FolderMenus.menu(browser: browser, group: try #require(browser.tabGroups.first { $0.id == folder }))
            let item = try #require(menu.items.first { $0.title == "New Tab in Folder" })

            menu.performActionForItem(at: menu.index(of: item))

            let made = try #require(browser.active)
            #expect(made.isBlank)
            #expect(browser.tabs(in: folder).map(\.id) == [tabs[0].id, tabs[1].id, made.id])
        }
    }

    @Test func newTabInFolderHasNoDefaultKey() throws {
        let command = try #require(Command.named("tabs.newInFolder"))

        let key = command.defaultKey

        #expect(command.title == "New Tab in Folder")
        #expect(key == nil)
    }
}
