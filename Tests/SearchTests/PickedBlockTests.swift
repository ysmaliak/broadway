import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct PickedBlockTests {
    @Test func pickedLooseRowsLandAsOneBlockInColumnOrderAndStayPicked() throws {
        try withBrowser(count: 6) { browser, t, undo in
            browser.select(t[3])
            pick(browser, [t[4], t[1]])
            let picked = browser.selectedTabIDs

            act(undo) { browser.moveBlock(browser.menuTabs(for: t[3]), to: .loose(LoosePlace(before: .tab(t[0].id)))) }

            #expect(ids(browser) == [t[1], t[3], t[4], t[0], t[2], t[5]].map(\.id))
            #expect(browser.selectedTabIDs == picked)
            #expect(undo.undoMenuItemTitle == "Undo Move 3 Tabs")
        }
    }

    @Test func pickedRowsInsideAFolderLandAsABlockBetweenItsRows() throws {
        try withBrowser(count: 6, groups: true) { browser, t, undo in
            let folder = makeFolder(browser, [t[0], t[1], t[2], t[3], t[4]])
            browser.select(t[0])
            pick(browser, [t[1]])

            act(undo) { browser.moveBlock(browser.menuTabs(for: t[0]), to: .folder(GroupDropTarget(group: folder, member: t[4].id))) }

            #expect(members(browser, folder) == [t[2], t[3], t[0], t[1], t[4]].map(\.id))
            #expect(loose(browser) == [t[5].id])
        }
    }

    @Test func aDropLineBesideAnotherPickedRowPutsTheBlockThere() throws {
        try withBrowser(count: 6, groups: true) { browser, t, undo in
            let folder = makeFolder(browser, [t[0], t[1], t[2], t[3], t[4]])
            browser.select(t[0])
            pick(browser, [t[3]])

            act(undo) { browser.moveBlock(browser.menuTabs(for: t[0]), to: .folder(GroupDropTarget(group: folder, member: t[3].id, after: true))) }

            #expect(members(browser, folder) == [t[1], t[2], t[0], t[3], t[4]].map(\.id))
        }
    }

    @Test func pickedRowsLeaveTheirFolderForTheLooseRowsAsABlock() throws {
        try withBrowser(count: 6, groups: true) { browser, t, undo in
            let folder = makeFolder(browser, [t[0], t[1], t[2]])
            browser.select(t[1])
            pick(browser, [t[2]])

            act(undo) { browser.moveBlock(browser.menuTabs(for: t[1]), to: .loose(LoosePlace(before: .tab(t[5].id)))) }

            #expect(members(browser, folder) == [t[0].id])
            #expect(loose(browser) == [t[3], t[4], t[1], t[2], t[5]].map(\.id))
            #expect(undo.undoMenuItemTitle == "Undo Move 2 Tabs")
        }
    }

    @Test func aPickAcrossFoldersAndLooseRowsGathersAtTheDropPlaceInColumnOrder() throws {
        try withBrowser(count: 7, groups: true) { browser, t, undo in
            let first = makeFolder(browser, [t[0], t[1]])
            let second = makeFolder(browser, [t[2], t[3]])
            browser.select(t[5])
            pick(browser, [t[3], t[1]])

            act(undo) { browser.moveBlock(browser.menuTabs(for: t[5]), to: .loose(LoosePlace(before: .tab(t[4].id)))) }

            #expect(loose(browser) == [t[1], t[3], t[5], t[4], t[6]].map(\.id))
            #expect(members(browser, first) == [t[0].id])
            #expect(members(browser, second) == [t[2].id])
        }
    }

    @Test func aPickAcrossFoldersAndLooseRowsGathersInsideAFolderInColumnOrder() throws {
        try withBrowser(count: 7, groups: true) { browser, t, undo in
            let first = makeFolder(browser, [t[0], t[1]])
            let second = makeFolder(browser, [t[2], t[3]])
            browser.select(t[5])
            pick(browser, [t[3], t[1]])

            act(undo) { browser.moveBlock(browser.menuTabs(for: t[5]), to: .folder(GroupDropTarget(group: first, member: t[0].id))) }

            #expect(members(browser, first) == [t[1], t[3], t[5], t[0]].map(\.id))
            #expect(members(browser, second) == [t[2].id])
            #expect(loose(browser) == [t[4], t[6]].map(\.id))
        }
    }

    @Test func aSplitViewInThePickMovesWholeAsOneOfTheBlocksRows() throws {
        try withBrowser(count: 6) { browser, t, undo in
            browser.prefs.splitView = true
            browser.quietly { browser.pair(t[3], with: t[2], onLeft: false) }
            let pair = try #require(browser.split(for: t[2]))
            browser.select(t[5])
            pick(browser, [t[3]])

            act(undo) { browser.moveBlock(browser.menuTabs(for: t[5]), to: .loose(LoosePlace(before: .tab(t[0].id)))) }

            let order = ids(browser)
            #expect(Set(order.prefix(2)) == Set(pair.tabs))
            #expect(Array(order.dropFirst(2)) == [t[5], t[0], t[1], t[4]].map(\.id))
            #expect(browser.split(for: t[2])?.id == pair.id)
        }
    }

    @Test func aPickedPinStaysWhereItIsWhileTheRestMove() throws {
        try withBrowser(count: 6) { browser, t, undo in
            browser.quietly { browser.pin(t[0]) }

            act(undo) { browser.moveBlock([t[0], t[3], t[4]], to: .loose(LoosePlace(before: .tab(t[1].id)))) }

            #expect(t[0].pin != nil)
            #expect(browser.squarePins.map(\.id) == [t[0].id])
            #expect(ids(browser) == [t[0], t[3], t[4], t[1], t[2], t[5]].map(\.id))
            #expect(undo.undoMenuItemTitle == "Undo Move 2 Tabs")

            act(undo) { browser.moveBlock([t[0], t[5]], to: .loose(LoosePlace(before: .tab(t[3].id)))) }

            #expect(undo.undoMenuItemTitle == "Undo Move Tab")
            #expect(t[0].pin != nil)
        }
    }

    @Test func aLiveFolderTakesNoBlock() throws {
        try withBrowser(count: 6, groups: true) { browser, t, undo in
            var live = TabGroup(id: UUID(), name: "News", collapsed: false)
            live.live = true
            browser.tabGroups.append(live)
            browser.select(t[1])
            pick(browser, [t[2]])
            let before = browser.arrangement

            act(undo) {
                browser.moveBlock(browser.menuTabs(for: t[1]), to: .folder(GroupDropTarget(group: live.id)))
                browser.moveBlock(browser.menuTabs(for: t[1]), to: .folder(GroupDropTarget(group: live.id, member: t[0].id)))
            }

            #expect(!browser.arrangement.differs(from: before))
            #expect(browser.undoSteps.isEmpty)
        }
    }

    @Test func aPickHoldingALiveFoldersRowMovesNothing() throws {
        try withBrowser(count: 6, groups: true) { browser, t, undo in
            var live = TabGroup(id: UUID(), name: "News", collapsed: false)
            live.live = true
            browser.tabGroups.append(live)
            browser.quietly {
                t[0].groupID = live.id
                browser.arrangeGroupedTabs()
            }
            browser.select(t[0])
            pick(browser, [t[2]])
            let before = browser.arrangement
            #expect(browser.blockMovers(browser.menuTabs(for: t[0])) == nil)

            act(undo) { browser.moveBlock(browser.menuTabs(for: t[0]), to: .loose(LoosePlace(before: .tab(t[5].id)))) }

            #expect(!browser.arrangement.differs(from: before))
            #expect(browser.group(of: t[2]) == nil)
            #expect(browser.undoSteps.isEmpty)
        }
    }

    @Test func oneUndoTakesTheWholeMoveBackToEachRowsFolderAndPlace() throws {
        try withBrowser(count: 7, groups: true) { browser, t, undo in
            let first = makeFolder(browser, [t[1]])
            let second = makeFolder(browser, [t[2], t[3]])
            browser.quietly { browser.tabGroups = browser.tabGroups.map { var group = $0; group.held = false; return group } }
            browser.select(t[5])
            pick(browser, [t[3], t[1]])
            let before = browser.arrangement

            act(undo) {
                browser.beginGesture()
                browser.moveBlock(browser.menuTabs(for: t[5]), to: .loose(LoosePlace(before: .tab(t[0].id))))
                browser.endGesture()
            }

            #expect(undo.undoMenuItemTitle == "Undo Move 3 Tabs")
            #expect(browser.undoSteps.count == 1)
            #expect(!browser.tabGroups.contains { $0.id == first }, "the emptied folder goes")
            #expect(browser.group(of: t[3]) == nil)

            undo.undo()

            #expect(!browser.arrangement.differs(from: before))
            #expect(browser.group(of: t[1]) == first)
            #expect(browser.group(of: t[3]) == second)
            #expect(!undo.canUndo)
        }
    }

    @Test func aBlockLetGoOnAFolderHeadingJoinsItAsOneStep() throws {
        try withBrowser(count: 6, groups: true) { browser, t, undo in
            let folder = makeFolder(browser, [t[0]])
            browser.select(t[2])
            pick(browser, [t[4], t[3]])
            let before = browser.arrangement

            act(undo) {
                browser.beginGesture()
                browser.moveBlock(browser.menuTabs(for: t[2]), to: .folder(GroupDropTarget(group: folder)))
                browser.endGesture()
            }

            #expect(members(browser, folder) == [t[0], t[2], t[3], t[4]].map(\.id))
            #expect(undo.undoMenuItemTitle == "Undo Move 3 Tabs")
            #expect(browser.undoSteps.count == 1)

            undo.undo()

            #expect(!browser.arrangement.differs(from: before))
            #expect(!undo.canUndo)
        }
    }

    @Test func aDropWhereTheBlockAlreadyIsIsQuiet() throws {
        try withBrowser(count: 6, groups: true) { browser, t, undo in
            let folder = makeFolder(browser, [t[0], t[1], t[2]])
            browser.select(t[1])
            pick(browser, [t[2]])
            let inside = browser.arrangement

            act(undo) { browser.moveBlock(browser.menuTabs(for: t[1]), to: .folder(GroupDropTarget(group: folder, member: t[1].id))) }

            #expect(!browser.arrangement.differs(from: inside))
            browser.clearTabSelection()
            browser.select(t[3])
            pick(browser, [t[4]])
            let outside = browser.arrangement

            act(undo) {
                browser.beginGesture()
                browser.moveBlock(browser.menuTabs(for: t[3]), to: .loose(LoosePlace(before: .tab(t[5].id))))
                browser.endGesture()
            }

            #expect(!browser.arrangement.differs(from: outside))
            #expect(browser.undoSteps.isEmpty)
        }
    }

    private func pick(_ browser: Browser, _ tabs: [Tab]) {
        for tab in tabs { browser.extendTabSelection(to: tab, modifiers: .command) }
    }

    private func makeFolder(_ browser: Browser, _ tabs: [Tab]) -> UUID {
        let folder = browser.quietly { browser.addTabGroup(containing: tabs[0], pinned: false) }
        browser.quietly { for tab in tabs.dropFirst() { browser.move(tab, toGroup: folder) } }
        browser.editingGroupID = nil
        return folder
    }

    private func ids(_ browser: Browser) -> [Tab.ID] { browser.tabs.map(\.id) }

    private func members(_ browser: Browser, _ folder: UUID) -> [Tab.ID] {
        browser.displayedTabs.filter { browser.group(of: $0) == folder }.map(\.id)
    }

    private func loose(_ browser: Browser) -> [Tab.ID] {
        browser.displayedTabs.filter { $0.pin == nil && browser.group(of: $0) == nil }.map(\.id)
    }

    private func withBrowser(count: Int, groups: Bool = false, _ body: (Browser, [Tab], UndoManager) throws -> Void) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.usesTabGroups, prefs.splitView, prefs.newTabPlace, prefs.usesSpaces)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            browser.window = nil
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
        prefs.usesSpaces = false
        for number in 1...count {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#block-\(number)")!, title: "Block \(number)")
        }
        #expect(browser.tabs.count == count)
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
