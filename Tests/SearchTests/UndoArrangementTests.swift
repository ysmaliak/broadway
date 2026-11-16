import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct UndoArrangementTests {
    @Test func moveTabDownIsUndoneByUndo() throws {
        try withBrowser { browser, tabs, undo in
            browser.select(tabs[1])

            act(undo) { browser.moveTab(by: 1) }

            #expect(undo.undoMenuItemTitle == "Undo Move Tab")
            #expect(ids(browser) == [tabs[0], tabs[2], tabs[1], tabs[3]].map(\.id))

            undo.undo()

            #expect(ids(browser) == tabs.map(\.id))
            #expect(!undo.canUndo)
            #expect(!undo.canRedo)
        }
    }

    @Test func aDragThatMovesSeveralTimesIsOneStep() throws {
        try withBrowser { browser, tabs, undo in
            act(undo) {
                browser.beginGesture()
                browser.moveDisplayedTab(tabs[0], to: 1)
                browser.moveDisplayedTab(tabs[0], to: 2)
                browser.moveDisplayedTab(tabs[0], to: 3)
                browser.endGesture()
            }

            undo.undo()

            #expect(ids(browser) == tabs.map(\.id))
            #expect(!undo.canUndo)
        }
    }

    @Test func aDragLetGoWhereItBeganLeavesNothingToUndo() throws {
        try withBrowser { browser, tabs, undo in
            act(undo) {
                browser.beginGesture()
                browser.moveDisplayedTab(tabs[0], to: 2)
                browser.moveDisplayedTab(tabs[0], to: 0)
                browser.endGesture()
            }

            #expect(ids(browser) == tabs.map(\.id))
            #expect(browser.undoSteps.isEmpty)
        }
    }

    @Test func movingAFolderIsUndoneToItsPlace() throws {
        try withBrowser(groups: true) { browser, tabs, undo in
            let folder = browser.quietly { browser.addTabGroup(containing: tabs[2], pinned: false) }
            browser.editingGroupID = nil
            let before = browser.listItems(browser.displayedTabs)

            act(undo) { browser.placeFolder(folder, pinned: false, before: .tab(tabs[0].id)) }

            #expect(undo.undoMenuItemTitle == "Undo Move Folder")
            #expect(browser.listItems(browser.displayedTabs).first == .folder(folder))

            undo.undo()

            #expect(browser.listItems(browser.displayedTabs) == before)
            #expect(browser.tabGroups.first { $0.id == folder }?.pinned == false)
        }
    }

    @Test func closesAndMovesComeBackNewestFirst() throws {
        try withBrowser { browser, tabs, undo in
            act(undo) { browser.close(tabs[3]) }
            act(undo) { browser.moveDisplayedTab(tabs[0], to: 2) }

            undo.undo()

            #expect(ids(browser) == [tabs[0], tabs[1], tabs[2]].map(\.id))

            undo.undo()

            #expect(browser.tabs.compactMap(\.address) == tabs.compactMap(\.address))
            #expect(!undo.canUndo)
        }
    }

    @Test func aTabMovedThenClosedGoesBackToItsPlaceAfterItReopens() throws {
        try withBrowser { browser, tabs, undo in
            act(undo) { browser.moveDisplayedTab(tabs[0], to: 3) }
            act(undo) { browser.close(tabs[0]) }

            undo.undo()
            undo.undo()

            #expect(browser.tabs.compactMap(\.address) == tabs.compactMap(\.address))
        }
    }

    @Test func aTabOpenedSinceKeepsItsPlaceWhenAMoveIsUndone() throws {
        try withBrowser { browser, tabs, undo in
            act(undo) { browser.moveDisplayedTab(tabs[3], to: 0) }
            browser.newTab()
            let opened = try #require(browser.tabs.last)

            undo.undo()

            #expect(ids(browser) == tabs.map(\.id) + [opened.id])
        }
    }

    @Test func theListKeepsTheLastThirtyActions() throws {
        try withBrowser { browser, tabs, undo in
            for step in 0..<31 {
                act(undo) { browser.moveDisplayedTab(tabs[0], to: step % 2 == 0 ? 1 : 0) }
            }

            let kept = browser.undoSteps.count
            for _ in 0..<31 where undo.canUndo { undo.undo() }

            #expect(kept == 30)
            #expect(browser.undoSteps.isEmpty)
            #expect(ids(browser) == [tabs[1], tabs[0], tabs[2], tabs[3]].map(\.id))
        }
    }

    @Test func aSearchResultFiledIntoItsFolderLeavesNothingToUndo() throws {
        try withBrowser(groups: true) { browser, tabs, undo in
            tabs[0].restore(url: URL(string: "https://www.google.com/search?q=lisbon+hotels")!, title: "lisbon hotels - Google Search")

            act(undo) { browser.fileSearchResult(tabs[1], from: tabs[0]) }

            #expect(tabs[1].groupID != nil)
            #expect(browser.undoSteps.isEmpty)
        }
    }

    @Test func anExtensionMovingATabLeavesNothingToUndo() throws {
        try withBrowser { browser, tabs, undo in
            act(undo) { browser.quietly { browser.moveDisplayedTab(tabs[0], to: 2) } }

            #expect(browser.undoSteps.isEmpty)
        }
    }

    @Test func pinningIsUndoneBackToTheTabsPlace() throws {
        try withBrowser { browser, tabs, undo in
            act(undo) { browser.pin(tabs[2]) }

            #expect(undo.undoMenuItemTitle == "Undo Pin Tab")
            #expect(tabs[2].pin != nil)

            undo.undo()

            #expect(tabs[2].pin == nil)
            #expect(ids(browser) == tabs.map(\.id))
            #expect(!undo.canRedo)
        }
    }

    @Test func unpinningIsUndoneWithTheSameLetterPageAndPlace() throws {
        try withBrowser { browser, tabs, undo in
            browser.quietly {
                browser.pin(tabs[2])
                browser.pin(tabs[3])
                browser.letter("Q", for: tabs[3])
            }
            let pinned = ids(browser)
            let id = tabs[3].pinID
            let home = tabs[3].home

            act(undo) { browser.unpin(tabs[3]) }

            #expect(undo.undoMenuItemTitle == "Undo Unpin Tab")
            #expect(tabs[3].pin == nil)

            undo.undo()

            #expect(tabs[3].pin == "Q")
            #expect(tabs[3].pinID == id)
            #expect(tabs[3].home == home)
            #expect(ids(browser) == pinned)
        }
    }

    @Test func aTabPinnedFromAFolderGoesBackIntoIt() throws {
        try withBrowser(groups: true) { browser, tabs, undo in
            let folder = browser.quietly { browser.addTabGroup(containing: tabs[1]) }
            browser.quietly { browser.move(tabs[2], toGroup: folder) }
            browser.editingGroupID = nil
            let before = ids(browser)

            act(undo) { browser.pin(tabs[1]) }
            undo.undo()

            #expect(tabs[1].groupID == folder)
            #expect(tabs[1].pin == nil)
            #expect(ids(browser) == before)
        }
    }

    @Test func pinningPickedTabsIsOneStep() throws {
        try withBrowser { browser, tabs, undo in
            act(undo) { browser.togglePin([tabs[1], tabs[3]], like: tabs[1]) }

            #expect(undo.undoMenuItemTitle == "Undo Pin 2 Tabs")
            #expect(browser.undoSteps.count == 1)

            undo.undo()

            #expect(tabs.allSatisfy { $0.pin == nil })
            #expect(ids(browser) == tabs.map(\.id))
        }
    }

    @Test func movingATabIntoAFolderIsUndone() throws {
        try withBrowser(groups: true) { browser, tabs, undo in
            let folder = browser.quietly { browser.addTabGroup(containing: tabs[1]) }
            browser.editingGroupID = nil
            let before = ids(browser)

            act(undo) { browser.move(tabs[3], toGroup: folder) }

            #expect(undo.undoMenuItemTitle == "Undo Move to Folder")
            #expect(tabs[3].groupID == folder)

            undo.undo()

            #expect(tabs[3].groupID == nil)
            #expect(ids(browser) == before)
        }
    }

    @Test func takingATabOutOfAFolderPutsItBackInItsPlaceThere() throws {
        try withBrowser(groups: true) { browser, tabs, undo in
            let folder = browser.quietly { browser.addTabGroup(containing: tabs[1]) }
            browser.quietly {
                browser.move(tabs[2], toGroup: folder)
                browser.move(tabs[3], toGroup: folder)
            }
            browser.editingGroupID = nil
            let before = ids(browser)

            act(undo) { browser.move(tabs[2], toGroup: nil) }

            #expect(undo.undoMenuItemTitle == "Undo Remove from Folder")

            undo.undo()

            #expect(tabs[2].groupID == folder)
            #expect(ids(browser) == before)
        }
    }

    @Test func aFolderLeftEmptyByAMoveComesBackWithItsName() throws {
        try withBrowser(groups: true) { browser, tabs, undo in
            let folder = browser.quietly { browser.addTabGroup(containing: tabs[1]) }
            browser.quietly { browser.renameTabGroup(folder, to: "Work") }
            browser.editingGroupID = nil

            act(undo) { browser.move(tabs[1], toGroup: nil) }

            #expect(!browser.tabGroups.contains { $0.id == folder })

            undo.undo()

            #expect(browser.tabGroups.first { $0.id == folder }?.name == "Work")
            #expect(tabs[1].groupID == folder)
        }
    }

    @Test func makingAFolderFromATabIsUndone() throws {
        try withBrowser(groups: true) { browser, tabs, undo in
            var folder: UUID?
            act(undo) { folder = browser.addTabGroup(containing: tabs[2]) }

            #expect(undo.undoMenuItemTitle == "Undo New Folder")

            undo.undo()

            #expect(!browser.tabGroups.contains { $0.id == folder })
            #expect(tabs[2].groupID == nil)
            #expect(browser.editingGroupID == nil)
            #expect(ids(browser) == tabs.map(\.id))
        }
    }

    @Test func makingAFolderWithPickedTabsIsOneStep() throws {
        try withBrowser(groups: true) { browser, tabs, undo in
            act(undo) { _ = browser.newFolder(with: [tabs[1], tabs[3]]) }

            #expect(browser.undoSteps.count == 1)

            undo.undo()

            #expect(browser.tabGroups.isEmpty)
            #expect(tabs.allSatisfy { $0.groupID == nil })
            #expect(ids(browser) == tabs.map(\.id))
        }
    }

    @Test func makingAnEmptyFolderIsUndone() throws {
        try withBrowser(groups: true) { browser, _, undo in
            act(undo) { _ = browser.newFolder() }
            undo.undo()

            #expect(browser.tabGroups.isEmpty)
        }
    }

    @Test func ungroupingAFolderBringsItBackWithItsTabs() throws {
        try withBrowser(groups: true) { browser, tabs, undo in
            let folder = browser.quietly { browser.addTabGroup(containing: tabs[1]) }
            browser.quietly {
                browser.move(tabs[3], toGroup: folder)
                browser.renameTabGroup(folder, to: "Work")
            }
            browser.editingGroupID = nil
            let before = ids(browser)
            let groups = browser.tabGroups

            act(undo) { browser.removeTabGroup(folder) }

            #expect(undo.undoMenuItemTitle == "Undo Ungroup")
            #expect(browser.tabGroups.isEmpty)

            undo.undo()

            #expect(browser.tabGroups == groups)
            #expect(tabs[1].groupID == folder)
            #expect(tabs[3].groupID == folder)
            #expect(ids(browser) == before)
        }
    }

    @Test func closingAFolderStaysOneCloseStep() throws {
        try withBrowser(groups: true) { browser, tabs, undo in
            let folder = browser.quietly { browser.addTabGroup(containing: tabs[1]) }
            browser.editingGroupID = nil

            act(undo) { browser.closeTabGroup(folder) }

            #expect(undo.undoMenuItemTitle == "Undo Close Group")
            #expect(browser.undoSteps.count == 1)
        }
    }

    @Test func renamingATabIsUndone() throws {
        try withBrowser { browser, tabs, undo in
            browser.beginTabRename(tabs[1])
            browser.tabDraft = "Notes"

            act(undo) { browser.commitTabEdit() }

            #expect(undo.undoMenuItemTitle == "Undo Rename Tab")
            #expect(tabs[1].name == "Notes")

            undo.undo()

            #expect(tabs[1].name == nil)
        }
    }

    @Test func renamingAFolderIsUndone() throws {
        try withBrowser(groups: true) { browser, tabs, undo in
            let folder = browser.quietly { browser.addTabGroup(containing: tabs[1]) }
            browser.editingGroupID = nil
            let before = try #require(browser.tabGroups.first { $0.id == folder })

            act(undo) { browser.renameTabGroup(folder, to: "Work") }

            #expect(undo.undoMenuItemTitle == "Undo Rename Folder")

            undo.undo()

            let after = try #require(browser.tabGroups.first { $0.id == folder })
            #expect(after.name == before.name)
            #expect(!after.userNamed)
        }
    }

    @Test func aFolderFoldedSinceARenameStaysFoldedWhenTheRenameIsUndone() throws {
        try withBrowser(groups: true) { browser, tabs, undo in
            let folder = browser.quietly { browser.addTabGroup(containing: tabs[1]) }
            browser.editingGroupID = nil
            act(undo) { browser.renameTabGroup(folder, to: "Work") }
            browser.toggleTabGroup(folder)

            undo.undo()

            #expect(browser.tabGroups.first { $0.id == folder }?.collapsed == true)
        }
    }

    @Test func movingATabToAnotherSpaceIsUndone() throws {
        try withBrowser { browser, tabs, undo, second in
            act(undo) { browser.finishMove(tabs[1], toSpace: second) }

            #expect(undo.undoMenuItemTitle == "Undo Move to Space")
            #expect(!browser.tabs.contains { $0.id == tabs[1].id })

            undo.undo()

            #expect(ids(browser) == tabs.map(\.id))
            #expect(browser.parked[second]?.tabs.contains { $0.id == tabs[1].id } != true)
            #expect(!undo.canRedo)
        }
    }

    @Test func theTabInFrontComesBackInFront() throws {
        try withBrowser { browser, tabs, undo, second in
            browser.select(tabs[3])

            act(undo) { browser.finishMove(tabs[3], toSpace: second) }
            undo.undo()

            #expect(browser.activeID == tabs[3].id)
            #expect(ids(browser) == tabs.map(\.id))
        }
    }

    @Test func aTabMovedOutOfItsFolderToAnotherSpaceComesBackIntoIt() throws {
        try withBrowser(groups: true) { browser, tabs, undo, second in
            let folder = browser.quietly { browser.addTabGroup(containing: tabs[1]) }
            browser.quietly { browser.renameTabGroup(folder, to: "Work") }
            browser.editingGroupID = nil

            act(undo) { browser.finishMove(tabs[1], toSpace: second) }
            undo.undo()

            #expect(browser.tabGroups.first { $0.id == folder }?.name == "Work")
            #expect(tabs[1].groupID == folder)
        }
    }

    @Test func undoFromTheOtherSpaceGoesBackToTheTabsOwnSpace() throws {
        try withBrowser { browser, tabs, undo, second in
            let first = browser.spaceID
            act(undo) { browser.finishMove(tabs[1], toSpace: second) }
            browser.switchSpace(to: second)

            undo.undo()

            #expect(browser.spaceID == first)
            #expect(ids(browser) == tabs.map(\.id))
            #expect(browser.parked[second]?.tabs.contains { $0.id == tabs[1].id } != true)
        }
    }

    @Test func aMoveInOneSpaceIsUndoneThereFromAnother() throws {
        try withBrowser { browser, tabs, undo, second in
            let first = browser.spaceID
            act(undo) { browser.moveDisplayedTab(tabs[0], to: 2) }
            browser.switchSpace(to: second)

            undo.undo()

            #expect(browser.spaceID == first)
            #expect(ids(browser) == tabs.map(\.id))
        }
    }

    @Test func aTabDraggedOntoAnotherSpaceComesBackFromIt() throws {
        try withBrowser { browser, tabs, undo, second in
            act(undo) {
                browser.beginGesture()
                browser.moveDisplayedTab(tabs[1], to: 2)
                browser.finishMove(tabs[1], toSpace: second)
                browser.endGesture()
            }

            undo.undo()

            #expect(ids(browser) == tabs.map(\.id))
            #expect(browser.parked[second]?.tabs.contains { $0.id == tabs[1].id } != true)
        }
    }

    private func ids(_ browser: Browser) -> [Tab.ID] { browser.tabs.map(\.id) }

    private func withBrowser(groups: Bool = false, _ body: (Browser, [Tab], UndoManager) throws -> Void) throws {
        try withBrowser(groups: groups) { browser, tabs, undo, _ in try body(browser, tabs, undo) }
    }

    private func withBrowser(groups: Bool = false, _ body: (Browser, [Tab], UndoManager, UUID) throws -> Void) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.usesTabGroups, prefs.splitView, prefs.newTabPlace, prefs.usesSpaces)
        let first = browser.spaceID
        let second = UUID()
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            browser.window = nil
            browser.switchSpace(to: first)
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
            window.close()
            prefs.usesTabGroups = saved.0
            prefs.splitView = saved.1
            prefs.newTabPlace = saved.2
            prefs.usesSpaces = saved.3
        }
        prefs.usesTabGroups = groups
        prefs.splitView = false
        prefs.newTabPlace = .end
        prefs.usesSpaces = true
        browser.spaces = [Space(id: first, name: "First", colour: 0), Space(id: second, name: "Second", colour: 1)]
        for number in 1...4 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        browser.window = window
        let undo = try #require(window.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        try body(browser, browser.tabs, undo, second)
    }

    private func act(_ undo: UndoManager, _ action: () -> Void) {
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
    }
}
