import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct TabKeysTests {
    @Test func pickAllTakesTheListButNotPinsAndAgainLetsGo() {
        withBrowser { browser, tabs in
            browser.pin(tabs[0])

            browser.pickAllTabs()

            #expect(browser.pickedTabs.map(\.id) == tabs[1...].map { $0.id })
            #expect(browser.keyTabs.map(\.id) == tabs[1...].map { $0.id })

            browser.pickAllTabs()

            #expect(browser.selectedTabIDs.isEmpty)
            #expect(browser.keyTabs.map(\.id) == [browser.activeID].compactMap { $0 })
            browser.unpin(tabs[0])
        }
    }

    @Test func menuActsOnPickedOnlyWhenTheRightClickedTabIsPicked() {
        withBrowser { browser, tabs in
            browser.select(tabs[0])
            browser.extendTabSelection(to: tabs[2], modifiers: .command)

            let inside = browser.menuTabs(for: tabs[2])
            let outside = browser.menuTabs(for: tabs[3])

            #expect(inside.map(\.id) == [tabs[0].id, tabs[2].id])
            #expect(outside.map(\.id) == [tabs[3].id])
        }
    }

    @Test func moveUpAndDownStaysInTheLooseList() {
        withBrowser { browser, tabs in
            browser.pin(tabs[0])
            browser.select(tabs[1])

            browser.moveTab(by: -1)

            #expect(browser.tabs.map(\.id) == tabs.map { $0.id })

            browser.moveTab(by: 1)
            browser.moveTab(by: 1)

            #expect(browser.tabs.map(\.id) == [tabs[0], tabs[2], tabs[3], tabs[1]].map { $0.id })

            browser.moveTab(by: 1)

            #expect(browser.tabs.last?.id == tabs[1].id)
            browser.unpin(tabs[0])
        }
    }

    @Test func moveUpAndDownAmongPins() {
        withBrowser { browser, tabs in
            browser.pin(tabs[0])
            browser.pin(tabs[1])
            browser.select(tabs[0])

            browser.moveTab(by: 1)

            #expect(browser.tabs.prefix(2).map(\.id) == [tabs[1].id, tabs[0].id])

            browser.moveTab(by: 1)

            #expect(browser.tabs.prefix(2).map(\.id) == [tabs[1].id, tabs[0].id])
            #expect(tabs[0].pin != nil)
            browser.unpin(tabs[0])
            browser.unpin(tabs[1])
        }
    }

    @Test func moveUpAndDownStaysInItsFolder() {
        withBrowser { browser, tabs in
            let folder = browser.addTabGroup(containing: tabs[1])
            browser.move(tabs[2], toGroup: folder)
            browser.select(tabs[2])
            let inFolder = { browser.tabs(in: folder).map(\.id) }

            browser.moveTab(by: -1)

            #expect(inFolder() == [tabs[2].id, tabs[1].id])

            browser.moveTab(by: -1)

            #expect(inFolder() == [tabs[2].id, tabs[1].id])
            #expect(browser.group(of: tabs[2]) == folder)
        }
    }

    @Test func pickedPinDuplicateAndFolderActOnEveryPickedTab() {
        withBrowser { browser, tabs in
            browser.select(tabs[1])
            browser.extendTabSelection(to: tabs[3], modifiers: .command)
            let chosen = browser.menuTabs(for: tabs[3])

            browser.duplicate(chosen)

            #expect(browser.tabs.count == 6)
            #expect(browser.tabs.compactMap { $0.address }.filter { $0 == tabs[1].address }.count == 2)
            #expect(browser.tabs.compactMap { $0.address }.filter { $0 == tabs[3].address }.count == 2)
            #expect(browser.activeID == tabs[1].id)

            browser.togglePin(chosen, like: tabs[3])

            #expect(browser.tabs.prefix(2).map(\.id) == [tabs[1].id, tabs[3].id])

            browser.togglePin(chosen, like: tabs[1])

            #expect(tabs[1].pin == nil)
            #expect(tabs[3].pin == nil)
            #expect(browser.tabs.firstIndex { $0.id == tabs[1].id }! < browser.tabs.firstIndex { $0.id == tabs[3].id }!)

            let folder = browser.addTabGroup(containing: tabs[0])
            browser.move(chosen, toGroup: folder)

            #expect(Set(browser.tabs(in: folder).map { $0.id }) == Set([tabs[0].id, tabs[1].id, tabs[3].id]))
        }
    }

    @Test func duplicateCommandUsesThePickedTabs() throws {
        try withBrowser { browser, tabs in
            browser.select(tabs[1])
            browser.extendTabSelection(to: tabs[3], modifiers: .command)
            let command = try #require(Command.all.first { $0.id == "tabs.duplicate" })

            command.run(browser)

            #expect(browser.tabs.count == 6)
            #expect(browser.tabs.compactMap { $0.address }.filter { $0 == tabs[1].address }.count == 2)
            #expect(browser.tabs.compactMap { $0.address }.filter { $0 == tabs[3].address }.count == 2)
            #expect(browser.activeID == tabs[1].id)
        }
    }

    @Test func copyPickedFolderAndPageLinks() {
        withBrowser { browser, tabs in
            let board = LinkCopy.board
            browser.select(tabs[0])
            browser.extendTabSelection(to: tabs[2], modifiers: .command)

            browser.copyLinks(.markdown)

            #expect(board != NSPasteboard.general)
            #expect(board.string(forType: .string) == "[Tab 1](https://one.example/)\n[Tab 3](https://three.example/)")

            browser.copyPage(.rich)

            #expect(board.string(forType: .string) == "https://one.example/")
            #expect(board.string(forType: .html)?.contains(">Tab 1</a>") == true)

            let folder = browser.addTabGroup(containing: tabs[1])
            browser.move(tabs[3], toGroup: folder)
            browser.copyFolderLinks(folder, as: .address)

            #expect(board.string(forType: .string) == "https://two.example/\nhttps://four.example/")
        }
    }

    @Test func commandsKeysAndSearch() {
        let store = ShortcutStore.shared

        #expect(store.key(for: "tabs.pickAll") == KeyCombo("a", shift: true))
        #expect(store.key(for: "tabs.moveUp") == KeyCombo("up", shift: true, option: true))
        #expect(store.key(for: "tabs.moveDown") == KeyCombo("down", shift: true, option: true))
        #expect(store.key(for: "spaces.send.3") == KeyCombo("3", command: false, shift: true, control: true))
        #expect(store.customCommand(on: KeyCombo("up", shift: true, option: true))?.id == "tabs.moveUp")
        #expect(store.customCommand(on: KeyCombo("a", shift: true))?.id == "tabs.pickAll")
        #expect(store.customCommand(on: KeyCombo("7", command: false, shift: true, control: true))?.id == "spaces.send.7")
        #expect(store.customCommand(on: KeyCombo("7", command: false, control: true))?.id == "spaces.7")
        #expect(!KeyCombo.isReserved(KeyCombo("2", command: false, shift: true, control: true)))
        #expect(Command.spaceNumber("spaces.send.4") == 4)
        #expect(Command.spaceNumber("spaces.4") == 4)
        #expect(Command.spaceNumber("tabs.moveUp") == nil)
        #expect(Set(Command.all.map { $0.id }).count == Command.all.count)
    }

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
        let tabs = ["one", "two", "three", "four"].enumerated().map { index, word in
            let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
            tab.restore(url: URL(string: "https://\(word).example/" + (index == 0 ? "?utm_source=x" : ""))!, title: "Tab \(index + 1)")
            return tab
        }
        browser.showRow(tabs, active: tabs[0].id)
        try body(browser, tabs)
    }
}
