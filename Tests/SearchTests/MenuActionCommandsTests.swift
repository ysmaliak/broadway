import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct MenuActionCommandsTests {
    private static let added: [(id: String, title: String, section: Command.Section)] = [
        ("tabs.muteToggle", "Mute Tab", .tabs),
        ("tabs.keep", "Keep Tab", .tabs),
        ("tabs.openInSidePanel", "Open in Side Panel", .tabs),
        ("tabs.removeFromFolder", "Remove from Folder", .tabs),
        ("tabs.changeIcon", "Change Icon…", .tabs),
        ("tabs.toNewWindow", "Move Tab to New Window", .tabs),
        ("tabs.newFolder", "New Folder", .tabs),
        ("tabs.renameFolder", "Rename Folder", .tabs),
        ("tabs.shutFolder", "Shut Folder", .tabs),
        ("tabs.pinFolder", "Pin Folder", .tabs),
        ("tabs.closeFolder", "Close Folder and Tabs", .tabs),
        ("spaces.new", "New Space…", .spaces),
        ("spaces.rename", "Rename Space…", .spaces),
        ("spaces.editLook", "Edit Look…", .spaces),
        ("view.translate", "Translate Page", .view),
    ]

    init() {
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        keepSettings("shortcuts")
        Store.settings.removeObject(forKey: "shortcuts")
    }

    private func withBrowser(_ body: (Browser, [Tab]) throws -> Void) rethrows {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = prefs.splitView
        defer {
            browser.editingLook = false
            browser.closeAll()
            prefs.splitView = saved
        }
        prefs.splitView = false
        for number in 1...3 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        try body(browser, browser.tabs)
    }

    private func folder(of tabs: [Tab], in browser: Browser) -> UUID {
        let id = browser.addTabGroup(containing: tabs[0])
        browser.move(tabs[1], toGroup: id)
        browser.editingGroupID = nil
        browser.select(tabs[0])
        return id
    }

    @Test func eachMenuOnlyActionIsACommandUnderItsMenuTitleWithNoKeyButMoveToNewWindow() throws {
        for expected in Self.added {
            let command = try #require(Command.named(expected.id), "\(expected.id)")

            let key = command.defaultKey

            #expect(command.title == expected.title)
            #expect(command.section == expected.section, "\(expected.id)")
            #expect(key == (expected.id == "tabs.toNewWindow" ? KeyCombo("n", shift: true, option: true) : nil), "\(expected.id)")
        }
    }

    @Test func eachNewCommandIsOnTheShortcutsPageInItsSection() {
        withBrowser { browser, _ in
            browser.prefs.usesSpaces = true

            for expected in Self.added {
                let listed = ShortcutsList.commands(in: expected.section, hunt: "", browser: browser,
                                                    store: ShortcutStore.shared, prefs: browser.prefs)

                #expect(listed.contains { $0.id == expected.id }, "\(expected.id)")
            }
        }
    }

    @Test func eachNewCommandIsFoundByNameInTheField() {
        withBrowser { browser, _ in
            browser.prefs.usesSpaces = true

            for expected in Self.added {
                let rows = FieldCommands.rows(for: FieldName.plain(expected.title), in: browser, limit: 8)

                let found = rows.contains { row in
                    if case .action(let id) = row.kind { return id == "command:" + expected.id }
                    return false
                }
                #expect(found, "\(expected.title)")
            }
        }
    }

    @Test func optionShiftCommandNMovesTheTabToANewWindow() {
        let store = ShortcutStore()

        let command = store.customCommand(on: KeyCombo("n", shift: true, option: true))

        #expect(command?.id == "tabs.toNewWindow")
    }

    @Test func muteTabMutesAndUnmutesTheTabInFront() throws {
        try withBrowser { browser, _ in
            let tab = try #require(browser.active)
            let was = tab.muted

            Command.named("tabs.muteToggle")?.run(browser)
            let once = tab.muted
            Command.named("tabs.muteToggle")?.run(browser)

            #expect(once == !was)
            #expect(tab.muted == was)
        }
    }

    @Test func removeFromFolderTakesTheTabInFrontOutOfItsFolder() {
        withBrowser { browser, tabs in
            let id = folder(of: tabs, in: browser)

            Command.named("tabs.removeFromFolder")?.run(browser)

            #expect(tabs[0].groupID == nil)
            #expect(tabs[1].groupID == id)
        }
    }

    @Test func renameFolderEditsTheNameOfTheFolderOfTheTabInFront() {
        withBrowser { browser, tabs in
            let id = folder(of: tabs, in: browser)

            Command.named("tabs.renameFolder")?.run(browser)

            #expect(browser.editingGroupID == id)
        }
    }

    @Test func shutFolderShutsAndOpensTheFolderOfTheTabInFront() {
        withBrowser { browser, tabs in
            let id = folder(of: tabs, in: browser)

            Command.named("tabs.shutFolder")?.run(browser)
            let shut = browser.tabGroups.first { $0.id == id }?.collapsed
            Command.named("tabs.shutFolder")?.run(browser)

            #expect(shut == true)
            #expect(browser.tabGroups.first { $0.id == id }?.collapsed == false)
        }
    }

    @Test func pinFolderPinsAndUnpinsTheFolderOfTheTabInFront() {
        withBrowser { browser, tabs in
            let id = folder(of: tabs, in: browser)
            let was = browser.tabGroups.first { $0.id == id }?.pinned

            Command.named("tabs.pinFolder")?.run(browser)

            #expect(browser.tabGroups.first { $0.id == id }?.pinned == was.map { !$0 })
        }
    }

    @Test func closeFolderAndTabsClosesTheFolderOfTheTabInFront() {
        withBrowser { browser, tabs in
            let id = folder(of: tabs, in: browser)

            Command.named("tabs.closeFolder")?.run(browser)

            #expect(!browser.tabGroups.contains { $0.id == id })
            #expect(!browser.tabs.contains { $0.id == tabs[0].id || $0.id == tabs[1].id })
        }
    }

    @Test func folderCommandsDoNothingWhenTheTabInFrontIsInNoFolder() {
        withBrowser { browser, tabs in
            let id = folder(of: tabs, in: browser)
            browser.select(tabs[2])

            for name in ["tabs.renameFolder", "tabs.shutFolder", "tabs.pinFolder", "tabs.closeFolder", "tabs.removeFromFolder"] {
                Command.named(name)?.run(browser)
            }

            #expect(browser.editingGroupID == nil)
            #expect(browser.tabGroups.first { $0.id == id }?.collapsed == false)
            #expect(browser.tabs.count == 3)
        }
    }

    @Test func newFolderMakesAFolder() {
        withBrowser { browser, _ in
            let count = browser.tabGroups.count

            Command.named("tabs.newFolder")?.run(browser)

            #expect(browser.tabGroups.count == count + 1)
        }
    }

    @Test func editLookOpensTheLookOfTheSpaceOnScreen() {
        withBrowser { browser, _ in
            browser.prefs.usesSpaces = true

            Command.named("spaces.editLook")?.run(browser)

            #expect(browser.editingLook)
        }
    }

    @Test func pageAndTabCommandsDoNothingOnABlankTab() throws {
        try withBrowser { browser, _ in
            browser.newTab()
            let blank = try #require(browser.active)
            #expect(blank.isBlank)

            Command.named("view.translate")?.run(browser)
            Command.named("tabs.changeIcon")?.run(browser)
            Command.named("tabs.keep")?.run(browser)

            #expect(blank.translator == nil)
            #expect(browser.tabs.contains { $0.id == blank.id })
        }
    }
}
