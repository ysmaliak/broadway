import AppKit
import UniformTypeIdentifiers
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FolderPinTests {
    private func browser(_ count: Int) -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesTabGroups = true
        for number in 0..<count {
            if number > 0 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://\(number).example/")!, title: "\(number)")
        }
        addTeardownBlock { @MainActor in browser.closeAll() }
        return browser
    }

    private func decode(_ json: String) throws -> TabGroup {
        try JSONDecoder().decode(TabGroup.self, from: Data(json.utf8))
    }

    private func names(_ browser: Browser) -> [String] {
        browser.tabs.map(\.title)
    }

    @Test func aManualFolderSavedBeforeTheFlagReadsAsPinned() throws {
        let group = try decode(#"{"id":"00000000-0000-0000-0000-00000000000A","name":"Work"}"#)

        #expect(group.pinned)
        #expect(group.isPinned)
    }

    @Test func anAIGroupSavedBeforeTheFlagReadsAsUnpinned() throws {
        let group = try decode(#"{"id":"00000000-0000-0000-0000-00000000000B","name":"Trip","ai":true}"#)

        #expect(!group.pinned)
        #expect(!group.isPinned)
    }

    @Test func aLiveFolderIsAlwaysPinned() throws {
        let group = try decode(#"{"id":"00000000-0000-0000-0000-00000000000C","name":"PRs","live":true,"pinned":false}"#)

        #expect(group.isPinned)
    }

    @Test func theFlagSurvivesASave() throws {
        let browser = browser(3)
        let tabs = browser.tabs
        let kept = browser.addTabGroup(containing: tabs[0], pinned: true)
        let loose = browser.addTabGroup(containing: tabs[1], pinned: false)
        browser.editingGroupID = nil
        browser.writeSession(now: true)

        let data = try JSONEncoder().encode(try #require(browser.record.rows[browser.spaceID.uuidString]))
        let shape = try JSONDecoder().decode(Session.Shape.self, from: data)
        let groups = shape.groups ?? []

        #expect(groups.first { $0.id == kept }?.pinned == true)
        #expect(groups.first { $0.id == loose }?.pinned == false)
    }

    @Test func anUnpinnedFolderStandsWhereItsFirstTabWas() {
        let browser = browser(5)
        let tabs = browser.tabs

        let id = browser.addTabGroup(containing: tabs[2], pinned: false)
        browser.move(tabs[4], toGroup: id)

        #expect(names(browser) == ["0", "1", "2", "4", "3"])
        #expect(browser.listItems(browser.displayedTabs) == [.tab(tabs[0].id), .tab(tabs[1].id), .folder(id), .tab(tabs[3].id)])
    }

    @Test func aPinnedFolderSitsAboveTheList() {
        let browser = browser(4)
        let tabs = browser.tabs

        let id = browser.addTabGroup(containing: tabs[2], pinned: true)

        #expect(names(browser) == ["2", "0", "1", "3"])
        #expect(browser.pinnedFolders().map(\.id) == [id])
        #expect(!browser.listItems(browser.displayedTabs).contains(.folder(id)))
    }

    @Test func arrangingTwiceChangesNothing() {
        let browser = browser(6)
        let tabs = browser.tabs
        let up = browser.addTabGroup(containing: tabs[4], pinned: true)
        let down = browser.addTabGroup(containing: tabs[1], pinned: false)
        let inner = browser.addTabGroup(containing: tabs[3], inside: down)
        browser.move(tabs[5], toGroup: up)
        let once = browser.tabs.map(\.id)

        browser.arrangeGroupedTabs()
        browser.arrangeGroupedTabs()

        #expect(browser.tabs.map(\.id) == once)
        #expect(names(browser) == ["4", "5", "0", "3", "1", "2"])
        #expect(browser.listItems(browser.displayedTabs) == [.tab(tabs[0].id), .folder(down), .tab(tabs[2].id)])
        #expect(browser.tabGroups.contains { $0.id == inner })
    }

    @Test func movingALooseTabElsewhereLeavesTheFolderInPlace() {
        let browser = browser(5)
        let tabs = browser.tabs
        let id = browser.addTabGroup(containing: tabs[1], pinned: false)
        browser.move(tabs[2], toGroup: id)

        browser.move(tabs[4], within: nil, to: 0)

        #expect(names(browser) == ["4", "0", "1", "2", "3"])
        #expect(browser.listItems(browser.displayedTabs) == [.tab(tabs[4].id), .tab(tabs[0].id), .folder(id), .tab(tabs[3].id)])
    }

    @Test func aTabJoiningFromFarAwayDoesNotPullTheFolder() {
        let browser = browser(5)
        let tabs = browser.tabs
        let id = browser.addTabGroup(containing: tabs[3], pinned: false)

        browser.move(tabs[0], toGroup: id)

        #expect(names(browser) == ["1", "2", "3", "0", "4"])
    }

    @Test func aFolderMadeFromALooseTabAndAnEmptyOneAreBothUnpinned() throws {
        let browser = browser(2)

        let formed = browser.addTabGroup(containing: browser.tabs[1])
        let empty = try #require(browser.newFolder(named: "Empty", editing: false))

        #expect(browser.tabGroups.first { $0.id == formed }?.pinned == false)
        #expect(browser.tabGroups.first { $0.id == empty }?.pinned == false)
    }

    @Test func unpinningPutsTheFolderAtTheTopOfTheListAndPinningPutsItBack() {
        let browser = browser(4)
        let tabs = browser.tabs
        let id = browser.addTabGroup(containing: tabs[3], pinned: true)

        browser.setFolderPinned(id, false)

        #expect(browser.tabGroups.first { $0.id == id }?.pinned == false)
        #expect(browser.listItems(browser.displayedTabs).first == .folder(id))
        #expect(names(browser) == ["3", "0", "1", "2"])

        browser.setFolderPinned(id, true)

        #expect(browser.pinnedFolders().map(\.id) == [id])
        #expect(!browser.listItems(browser.displayedTabs).contains(.folder(id)))
    }

    @Test func aFolderDroppedInTheListLandsBeforeTheItemUnderIt() {
        let browser = browser(4)
        let tabs = browser.tabs
        let id = browser.addTabGroup(containing: tabs[0], pinned: true)

        browser.placeFolder(id, pinned: false, before: .tab(tabs[3].id))

        #expect(names(browser) == ["1", "2", "0", "3"])
        #expect(browser.listItems(browser.displayedTabs) == [.tab(tabs[1].id), .tab(tabs[2].id), .folder(id), .tab(tabs[3].id)])
    }

    @Test func aFolderDroppedAmongThePinnedOnesIsPinnedInThatPlace() {
        let browser = browser(3)
        let tabs = browser.tabs
        let first = browser.addTabGroup(containing: tabs[0], pinned: true)
        let loose = browser.addTabGroup(containing: tabs[2], pinned: false)

        browser.placeFolder(loose, pinned: true, before: .folder(first))

        #expect(browser.pinnedFolders().map(\.id) == [loose, first])
        #expect(names(browser) == ["2", "0", "1"])
    }

    @Test func aLiveFolderCannotBeUnpinned() {
        let browser = browser(1)
        let id = UUID()
        browser.tabGroups.append(TabGroup(id: id, name: "PRs", collapsed: false, held: true, live: true))

        browser.setFolderPinned(id, false)

        #expect(browser.tabGroups.first { $0.id == id }?.isPinned == true)
    }

    @Test func aFolderMovedOutOfAnUnpinnedOneStaysInTheList() {
        let browser = browser(3)
        let tabs = browser.tabs
        let outer = browser.addTabGroup(containing: tabs[1], pinned: false)
        let inner = browser.addTabGroup(containing: tabs[2], inside: outer)

        browser.nest(inner, in: nil, before: outer)

        #expect(browser.tabGroups.first { $0.id == inner }?.pinned == false)
        #expect(browser.listItems(browser.displayedTabs) == [.tab(tabs[0].id), .folder(inner), .folder(outer)])
    }

    private func settle(_ seconds: Double = 0.6) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @Test func closingAnUnpinnedFolderAndReopeningItBringsItBackInPlace() {
        let browser = browser(5)
        let tabs = browser.tabs
        let id = browser.addTabGroup(containing: tabs[1], pinned: false)
        browser.move(tabs[2], toGroup: id)
        browser.renameTabGroup(id, to: "Trip")
        browser.editingGroupID = nil
        browser.select(tabs[4])

        browser.closeTabGroup(id)

        #expect(!browser.tabGroups.contains { $0.id == id })
        #expect(names(browser) == ["0", "3", "4"])
        #expect(browser.reopenTitle == "Reopen Closed Group")

        browser.reopen()

        let back = browser.tabGroups.first { $0.id == id }
        #expect(back?.name == "Trip")
        #expect(back?.pinned == false)
        #expect(names(browser) == ["0", "1", "2", "3", "4"])
        #expect(browser.listItems(browser.displayedTabs).map(\.id) == [tabs[0].id, id, browser.tabs[3].id, tabs[4].id])
        #expect(browser.tabs(in: id).count == 2)
    }

    @Test func aDroppedFolderNeverOpensATab() async {
        let browser = browser(2)
        let id = browser.addTabGroup(containing: browser.tabs[1], pinned: true)
        let count = browser.tabs.count

        let took = browser.take([InternalDrag.provider(InternalDrag.folder, id)])
        let tookOld = browser.take([NSItemProvider(object: "search-group:\(id.uuidString)" as NSString)])
        let tookBookmark = browser.take([InternalDrag.provider(InternalDrag.bookmark, UUID())])
        await settle()

        #expect(!took)
        #expect(tookOld)
        #expect(!tookBookmark)
        #expect(browser.tabs.count == count)
        #expect(!browser.tabs.contains { $0.title.contains("search-group") || ($0.pending ?? $0.address)?.absoluteString.contains("search-group") == true })
    }

    @Test func aFolderDroppedOnTheColumnMovesAndOpensNothing() async {
        let browser = browser(3)
        let tabs = browser.tabs
        let id = browser.addTabGroup(containing: tabs[0], pinned: true)
        let count = browser.tabs.count

        let took = browser.dropOnColumn([InternalDrag.provider(InternalDrag.folder, id)]) { _ in
            FolderDrop.Place(pinned: false, before: .tab(tabs[2].id))
        }
        await settle()

        #expect(took)
        #expect(browser.tabs.count == count)
        #expect(browser.tabGroups.first { $0.id == id }?.pinned == false)
        #expect(browser.listItems(browser.displayedTabs) == [.tab(tabs[1].id), .folder(id), .tab(tabs[2].id)])
    }

    @Test func theFolderPayloadIsPrivateAndCarriesNoText() {
        let provider = InternalDrag.provider(InternalDrag.folder, UUID())

        #expect(InternalDrag.isInternal(provider))
        #expect(!provider.canLoadObject(ofClass: String.self))
        #expect(!provider.canLoadObject(ofClass: URL.self))
        #expect(!provider.hasItemConformingToTypeIdentifier(UTType.text.identifier))
    }

    @Test func whereAFolderLandsOnTheColumn() {
        let up = UUID(), down = UUID(), moving = UUID(), tab = UUID()
        let raised = [(id: up, rect: CGRect(x: 0, y: 100, width: 200, height: 40))]
        let items: [(item: Browser.ListItem, rect: CGRect)] = [
            (.tab(tab), CGRect(x: 0, y: 200, width: 200, height: 30)),
            (.folder(down), CGRect(x: 0, y: 236, width: 200, height: 80)),
        ]

        let above = FolderDrop.place(y: 110, rowsTop: 90, raised: raised, items: items, moving: moving)
        let underPinned = FolderDrop.place(y: 135, rowsTop: 90, raised: raised, items: items, moving: moving)
        let onTab = FolderDrop.place(y: 205, rowsTop: 90, raised: raised, items: items, moving: moving)
        let lowOnFolder = FolderDrop.place(y: 300, rowsTop: 90, raised: raised, items: items, moving: moving)

        #expect(above == FolderDrop.Place(pinned: true, before: .folder(up)))
        #expect(underPinned == FolderDrop.Place(pinned: true, before: nil))
        #expect(onTab == FolderDrop.Place(pinned: false, before: .tab(tab)))
        #expect(lowOnFolder == FolderDrop.Place(pinned: false, before: nil))
    }

    @Test func theTabsAreWalkedInTheOrderTheyAreShown() {
        let browser = browser(5)
        let tabs = browser.tabs
        let up = browser.addTabGroup(containing: tabs[4], pinned: true)
        let down = browser.addTabGroup(containing: tabs[2], pinned: false)
        browser.editingGroupID = nil
        browser.toggleTabGroup(down)
        browser.select(tabs[0])

        let shown = browser.shownTabs.map(\.title)
        let targets = browser.tabShortcutTargets.map(\.id)

        #expect(shown == ["4", "0", "1", "3"])
        #expect(targets == [tabs[4].id, tabs[0].id, tabs[1].id, down, tabs[3].id])
        #expect(browser.tabGroups.contains { $0.id == up })
    }

    @Test func theFolderCloseSitsAsFarFromTheRightAsFromTopAndBottom() {
        let square = Metrics.closeSquare(FolderHeadingMetrics.height)

        let gap = FolderHeadingMetrics.closeInset

        #expect(gap == ((FolderHeadingMetrics.height - square) / 2))
        #expect((gap * 2 + square) == FolderHeadingMetrics.height)
    }

    @Test func aFolderLeftBehindByItsUnpinnedParentStaysInTheList() {
        let browser = browser(3)
        let tabs = browser.tabs
        let outer = browser.addTabGroup(containing: tabs[1], pinned: false)
        let inner = browser.addTabGroup(containing: tabs[2], inside: outer)
        let empty = browser.newFolder(inside: outer, named: "Later", editing: false)

        browser.removeTabGroup(outer)

        #expect(browser.tabGroups.first { $0.id == inner }?.isPinned == false)
        #expect(browser.tabGroups.first { $0.id == empty }?.isPinned == false)
        #expect(browser.listItems(browser.displayedTabs).contains(.folder(inner)))
        #expect(browser.pinnedFolders().isEmpty)
    }
}
