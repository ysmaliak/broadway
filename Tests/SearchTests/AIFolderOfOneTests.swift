import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct AIFolderOfOneTests {
    @Test func closingDownToOneTabDissolvesTheFolderInPlace() throws {
        try withBrowser { browser, tabs, undo, _ in
            let folder = aiFolder(browser, [tabs[1], tabs[2]])
            browser.select(tabs[1])

            act(undo) { browser.close(tabs[2]) }

            #expect(!browser.tabGroups.contains { $0.id == folder })
            #expect(tabs[1].groupID == nil)
            #expect(browser.activeID == tabs[1].id)
            #expect(browser.listItems(browser.displayedTabs) == [.tab(tabs[0].id), .tab(tabs[1].id), .tab(tabs[3].id)])
            #expect(undo.undoMenuItemTitle == "Undo Close Tab")
        }
    }

    @Test func undoAfterAClosePutsTheFolderBackWithItsNameIconAndBothTabs() throws {
        try withBrowser { browser, tabs, undo, _ in
            let folder = aiFolder(browser, [tabs[1], tabs[2]])
            let address = tabs[2].address
            browser.select(tabs[1])
            act(undo) { browser.close(tabs[2]) }

            undo.undo()

            let back = try #require(browser.tabGroups.first { $0.id == folder })
            #expect(back.name == "Lisbon")
            #expect(back.icon?.emoji == "✈️")
            #expect(back.ai)
            #expect(browser.tabs(in: folder).map(\.id).contains(tabs[1].id))
            #expect(browser.tabs(in: folder).compactMap(\.address).contains { $0 == address })
            #expect(browser.tabs(in: folder).count == 2)
            #expect(!undo.canUndo)
        }
    }

    @Test func theLastTabClosedAfterwardsComesBackIntoTheFolderToo() throws {
        try withBrowser { browser, tabs, undo, _ in
            let folder = aiFolder(browser, [tabs[1], tabs[2]])
            browser.select(tabs[0])
            act(undo) { browser.close(tabs[2]) }
            act(undo) { browser.close(tabs[1]) }

            undo.undo()
            undo.undo()

            #expect(browser.tabGroups.first { $0.id == folder }?.name == "Lisbon")
            #expect(browser.tabs(in: folder).count == 2)
        }
    }

    @Test func draggingOutDownToOneTabDissolvesTheFolderAndUndoBringsItBack() throws {
        try withBrowser { browser, tabs, undo, _ in
            let folder = aiFolder(browser, [tabs[1], tabs[2]])
            browser.select(tabs[0])

            act(undo) {
                browser.beginGesture()
                browser.move(tabs[2], toGroup: nil)
                browser.endGesture()
            }

            #expect(!browser.tabGroups.contains { $0.id == folder })
            #expect(tabs[1].groupID == nil)
            #expect(tabs[2].groupID == nil)
            #expect(browser.activeID == tabs[0].id)
            #expect(browser.listItems(browser.displayedTabs).first(where: { $0 != .tab(tabs[0].id) }) == .tab(tabs[1].id))

            undo.undo()

            let back = try #require(browser.tabGroups.first { $0.id == folder })
            #expect(back.name == "Lisbon")
            #expect(back.icon?.emoji == "✈️")
            #expect(Set(browser.tabs(in: folder).map(\.id)) == [tabs[1].id, tabs[2].id])
            #expect(!undo.canUndo)
        }
    }

    @Test func movingATabIntoAnotherFolderDownToOneDissolvesTheFolder() throws {
        try withBrowser { browser, tabs, undo, _ in
            let folder = aiFolder(browser, [tabs[1], tabs[2]])
            let other = browser.quietly { browser.addTabGroup(containing: tabs[3], pinned: false) }
            browser.editingGroupID = nil

            act(undo) { browser.move(tabs[2], toGroup: GroupDropTarget(group: other, member: tabs[3].id, after: true)) }

            #expect(!browser.tabGroups.contains { $0.id == folder })
            #expect(tabs[1].groupID == nil)
            #expect(tabs[2].groupID == other)
        }
    }

    @Test func closingSeveralTabsAtOnceDissolvesOnceAndUndoBringsThemAllBack() throws {
        try withBrowser { browser, tabs, undo, _ in
            let folder = aiFolder(browser, [tabs[1], tabs[2], tabs[3]])
            browser.select(tabs[1])

            act(undo) { browser.closeTabsBelow(tabs[1]) }

            #expect(!browser.tabGroups.contains { $0.id == folder })
            #expect(tabs[1].groupID == nil)
            #expect(browser.ghosts.allSatisfy { $0.groupID == folder })

            undo.undo()

            #expect(browser.tabGroups.first { $0.id == folder }?.name == "Lisbon")
            #expect(browser.tabs(in: folder).count == 3)
        }
    }

    @Test func aFolderMadeByHandKeepsItsLastTab() throws {
        try withBrowser { browser, tabs, undo, _ in
            let folder = browser.quietly { browser.addTabGroup(containing: tabs[1], pinned: false) }
            browser.editingGroupID = nil
            browser.quietly { browser.move(tabs[2], toGroup: folder) }

            act(undo) { browser.close(tabs[2]) }

            #expect(browser.tabGroups.contains { $0.id == folder })
            #expect(tabs[1].groupID == folder)
        }
    }

    @Test(arguments: ["renamed", "re-iconed", "filled", "pinned", "live"])
    func aFolderThePersonMadeTheirsKeepsItsLastTab(_ edit: String) throws {
        try withBrowser { browser, tabs, undo, _ in
            let folder = aiFolder(browser, [tabs[1], tabs[2]])
            let index = try #require(browser.tabGroups.firstIndex { $0.id == folder })
            var going = [tabs[2]]
            switch edit {
            case "renamed": act(undo) { browser.renameTabGroup(folder, to: "Trip") }
            case "re-iconed": browser.tabGroups[index].userIcon = true
            case "pinned": browser.tabGroups[index].pinned = true
            case "live": browser.tabGroups[index].live = true
            default:
                act(undo) { browser.move(tabs[3], toGroup: folder) }
                going.append(tabs[3])
            }

            for tab in going { act(undo) { browser.move(tab, toGroup: nil) } }

            #expect(browser.tabGroups.contains { $0.id == folder })
            #expect(tabs[1].groupID == folder)
        }
    }

    @Test func aTabMovedInByTheGrouperLeavesTheFolderItsOwn() throws {
        try withBrowser { browser, tabs, undo, _ in
            let folder = aiFolder(browser, [tabs[1], tabs[2]])

            tabs[3].groupID = folder

            #expect(browser.tabGroups.first { $0.id == folder }?.userFilled == false)
        }
    }

    @Test func undoingADragInMakesTheFolderBroadwaysAgain() throws {
        try withBrowser { browser, tabs, undo, _ in
            let folder = aiFolder(browser, [tabs[1], tabs[2]])
            act(undo) { browser.move(tabs[3], toGroup: folder) }

            undo.undo()
            act(undo) { browser.move(tabs[2], toGroup: nil) }

            #expect(!browser.tabGroups.contains { $0.id == folder })
        }
    }

    @Test func movingTheWholeFolderToAnotherSpaceKeepsItWhole() throws {
        try withBrowser { browser, tabs, undo, second in
            let folder = aiFolder(browser, [tabs[1], tabs[2]])
            let group = try #require(browser.tabGroups.first { $0.id == folder })

            browser.holdingLoneFolders {
                for tab in [tabs[1], tabs[2]] {
                    browser.finishMove(tab, toSpace: second, group: [group].first { $0.id == tab.groupID }, quietly: true)
                }
            }

            let row = try #require(browser.parked[second])
            #expect(row.groups?.contains { $0.id == folder } == true)
            #expect(row.tabs.filter { $0.groupID == folder }.count == 2)
        }
    }

    @Test func movingATabToAnotherSpaceDownToOneDissolvesTheFolder() throws {
        try withBrowser { browser, tabs, undo, second in
            let folder = aiFolder(browser, [tabs[1], tabs[2]])

            act(undo) { browser.finishMove(tabs[2], toSpace: second) }

            #expect(!browser.tabGroups.contains { $0.id == folder })
            #expect(tabs[1].groupID == nil)
        }
    }

    @Test func aFolderAlreadyDownToOneTabDissolvesWhenItsRowLoads() throws {
        try withBrowser { browser, tabs, undo, _ in
            let folder = aiFolder(browser, [tabs[1]])

            browser.dissolveLoneFolders()

            #expect(!browser.tabGroups.contains { $0.id == folder })
            #expect(tabs[1].groupID == nil)
            #expect(!undo.canUndo)
        }
    }

    private func aiFolder(_ browser: Browser, _ members: [Tab]) -> UUID {
        var group = TabGroup(id: UUID(), name: "Lisbon", collapsed: false)
        group.ai = true
        group.pinned = false
        group.icon = TabIcon(emoji: "✈️")
        group.aiEmoji = "✈️"
        browser.tabGroups.append(group)
        for tab in members { tab.groupID = group.id }
        browser.arrangeGroupedTabs()
        return group.id
    }

    private func withBrowser(_ body: (Browser, [Tab], UndoManager, UUID) throws -> Void) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.splitView, prefs.usesSpaces)
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
            prefs.splitView = saved.0
            prefs.usesSpaces = saved.1
        }
        prefs.splitView = false
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
