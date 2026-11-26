import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FolderTests {
    private func folder(_ name: String, in parent: TabGroup? = nil, shut: Bool = false) -> TabGroup {
        TabGroup(id: UUID(), name: name, collapsed: shut, parent: parent?.id)
    }

    private func browser(_ count: Int) -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        for number in 0..<count {
            if number > 0 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://\(number).example/")!, title: "\(number)")
        }
        addTeardownBlock { @MainActor in browser.closeAll() }
        return browser
    }

    @Test func orderedPutsChildrenAfterParentAndDropsDanglingParents() {
        let top = folder("top")
        let child = folder("child", in: top)
        var orphan = folder("orphan")
        orphan.parent = UUID()

        let ordered = FolderTree.ordered([child, orphan, top])

        #expect(ordered.map(\.name) == ["orphan", "top", "child"])
        #expect(ordered[0].parent == nil)
    }

    @Test func orderedBreaksACycle() {
        var one = folder("one")
        let two = TabGroup(id: UUID(), name: "two", collapsed: false, parent: one.id)
        one.parent = two.id

        let ordered = FolderTree.ordered([one, two])

        #expect(ordered.count == 2)
        #expect(ordered.filter { $0.parent == nil }.count == 1)
    }

    @Test func rowsSkipWhatAShutFolderHolds() {
        let top = folder("top", shut: true)
        let child = folder("child", in: top)
        let other = folder("other")

        let rows = FolderTree.rows([top, child, other])

        #expect(rows.filter { $0.kind == .heading }.map(\.group.name) == ["top", "other"])
    }

    @Test func depthIsCappedAtFive() {
        var chain = [folder("0")]
        for level in 1..<5 { chain.append(folder("\(level)", in: chain.last)) }
        let lone = folder("lone")
        let groups = chain + [lone]

        #expect(!FolderTree.canNest(lone.id, in: chain[4].id, groups: groups))
        #expect(FolderTree.canNest(lone.id, in: chain[3].id, groups: groups))
        #expect(!FolderTree.canNest(chain[0].id, in: chain[2].id, groups: groups), "Not into its own child")
        #expect(!FolderTree.canAddChild(to: chain[4].id, groups: groups))
    }

    @Test func lastingKeepsAParentHoldingOnlyAFolder() {
        let top = folder("top")
        let child = folder("child", in: top)
        let empty = folder("empty")
        var waiting = folder("waiting")
        waiting.held = true

        let lasting = FolderTree.lasting([top, child, empty, waiting], holding: [child.id])

        #expect(lasting.map(\.name) == ["top", "child", "waiting"])
    }

    @Test func resolveFindsTheDeepestFolderUnderThePoint() {
        let top = folder("top")
        let inner = folder("inner", in: top)
        let a = UUID(), b = UUID()
        let frames: [UUID: GroupDropFrame] = [
            top.id: GroupDropFrame(group: top.id, rect: CGRect(x: 0, y: 0, width: 200, height: 40)),
            inner.id: GroupDropFrame(group: inner.id, rect: CGRect(x: 16, y: 45, width: 184, height: 40)),
            a: GroupDropFrame(group: inner.id, tab: a, rect: CGRect(x: 32, y: 90, width: 168, height: 40)),
            b: GroupDropFrame(group: top.id, tab: b, rect: CGRect(x: 16, y: 135, width: 184, height: 40)),
        ]

        let target = GroupDropFrames.resolve(CGPoint(x: 60, y: 60), frames: frames, groups: [top, inner],
                                              excluding: UUID(), vertical: true)

        #expect(target?.group == inner.id)
    }

    @Test func holdingOverANeighbourNeedsARealOverlap() {
        #expect(FolderTree.heldNeighbour(shift: 2, step: 46, index: 1, count: 3) == nil)
        #expect(FolderTree.heldNeighbour(shift: 14, step: 46, index: 1, count: 3) == 2)
        #expect(FolderTree.heldNeighbour(shift: -14, step: 46, index: 1, count: 3) == 0)
        #expect(FolderTree.heldNeighbour(shift: 14, step: 46, index: 2, count: 3) == nil)
    }

    @Test func rowOrderIsSubfoldersThenTabsThenLoose() {
        let browser = browser(4)
        let tabs = browser.tabs
        let top = browser.addTabGroup(containing: tabs[1], pinned: true)
        let inner = browser.addTabGroup(containing: tabs[2], inside: top)
        browser.editingGroupID = nil

        #expect(browser.tabGroups.map(\.id) == [top, inner])
        #expect(browser.tabs.map(\.id) == [tabs[2], tabs[1], tabs[0], tabs[3]].map { $0.id })
        #expect(browser.folderRows.map(\.depth) == [0, 1, 1, 0])
    }

    @Test func removingAFolderMovesItsContentsUpALevel() {
        let browser = browser(3)
        let tabs = browser.tabs
        let top = browser.addTabGroup(containing: tabs[0])
        let middle = browser.addTabGroup(containing: tabs[1], inside: top)
        let inner = browser.addTabGroup(containing: tabs[2], inside: middle)

        browser.removeTabGroup(middle)

        #expect(tabs[1].groupID == top)
        #expect(browser.tabGroups.first { $0.id == inner }?.parent == top)
        #expect(!browser.tabGroups.contains { $0.id == middle })
    }

    @Test func aParentGoesWithItsLastFolder() {
        let browser = browser(3)
        let tabs = browser.tabs
        let top = browser.addTabGroup(containing: tabs[0])
        let inner = browser.addTabGroup(containing: tabs[1], inside: top)
        browser.move(tabs[0], toGroup: nil)
        #expect(browser.tabGroups.contains { $0.id == top }, "It still holds a folder")

        browser.move(tabs[1], toGroup: nil)

        #expect(!browser.tabGroups.contains { $0.id == inner })
        #expect(!browser.tabGroups.contains { $0.id == top })
    }

    @Test func closingAFolderClosesEverythingInIt() {
        let browser = browser(4)
        let tabs = browser.tabs
        let top = browser.addTabGroup(containing: tabs[0])
        _ = browser.addTabGroup(containing: tabs[1], inside: top)
        browser.select(tabs[3])

        browser.closeTabGroup(top)

        #expect(Set(browser.tabs.map { $0.id }) == Set([tabs[2], tabs[3]].map { $0.id }))
        #expect(browser.tabGroups.isEmpty)
    }

    @Test func theCurrentTabStaysVisibleUnderAShutParent() {
        let browser = browser(3)
        let tabs = browser.tabs
        let top = browser.addTabGroup(containing: tabs[0])
        let inner = browser.addTabGroup(containing: tabs[1], inside: top)
        browser.select(tabs[1])

        browser.toggleTabGroup(top)
        let topFolder = browser.tabGroups.first { $0.id == top }!
        let innerFolder = browser.tabGroups.first { $0.id == inner }!

        #expect(browser.visibleTabs(in: topFolder).map(\.id) == [tabs[1].id])
        #expect(browser.visibleTabs(in: innerFolder).isEmpty)
        #expect(!browser.folderRows.contains { $0.group.id == inner })
    }

    @Test func goingToATabOpensEveryFolderAboveIt() {
        let browser = browser(3)
        let tabs = browser.tabs
        let top = browser.addTabGroup(containing: tabs[0])
        let inner = browser.addTabGroup(containing: tabs[1], inside: top)
        browser.select(tabs[2])
        browser.toggleTabGroup(inner)
        browser.toggleTabGroup(top)

        browser.select(tabs[1])

        #expect(!browser.tabGroups.contains { $0.collapsed })
    }

    @Test func optionClickOpensOrShutsEverythingInside() {
        let browser = browser(2)
        let tabs = browser.tabs
        let top = browser.addTabGroup(containing: tabs[0])
        _ = browser.addTabGroup(containing: tabs[1], inside: top)

        browser.toggleFolderWhole(top)

        #expect(browser.tabGroups.allSatisfy { $0.collapsed })

        browser.toggleFolderWhole(top)

        #expect(!browser.tabGroups.contains { $0.collapsed })
    }

    @Test func newFolderInsideWaitsEmptyUntilItHasHadATab() {
        let browser = browser(2)
        let tabs = browser.tabs
        let top = browser.addTabGroup(containing: tabs[0])

        let inner = try! #require(browser.newFolder(inside: top))

        #expect(browser.tabGroups.first { $0.id == inner }?.parent == top)
        #expect(browser.editingGroupID == inner)

        browser.move(tabs[1], toGroup: inner)
        browser.move(tabs[1], toGroup: nil)

        #expect(!browser.tabGroups.contains { $0.id == inner })
    }

    @Test func newFolderWithPickedTabs() {
        let browser = browser(3)
        let tabs = browser.tabs

        let id = browser.newFolder(with: [tabs[0], tabs[2]], editing: false)

        #expect(Set(browser.tabs(in: id).map { $0.id }) == Set([tabs[0], tabs[2]].map { $0.id }))
        #expect(browser.editingGroupID == nil)
    }

    @Test func draggingAFolderOntoAnotherNestsItOrPutsItBeside() {
        let browser = browser(3)
        let tabs = browser.tabs
        let a = browser.addTabGroup(containing: tabs[0], pinned: true)
        let b = browser.addTabGroup(containing: tabs[1], pinned: true)
        let c = browser.addTabGroup(containing: tabs[2], pinned: true)

        browser.dropFolder(c, on: a, inside: false)

        #expect(browser.tabGroups.map(\.id) == [c, a, b])

        browser.dropFolder(b, on: a, inside: true)

        #expect(browser.tabGroups.first { $0.id == b }?.parent == a)
        #expect(browser.tabGroups.map(\.id) == [c, a, b])
        #expect(browser.tabs.map(\.id) == [tabs[2], tabs[1], tabs[0]].map { $0.id })
        #expect(FolderHeadingMetrics.inside(x: 60, depth: 0))
        #expect(!FolderHeadingMetrics.inside(x: 10, depth: 0))
    }

    @Test func draggingSidewaysChangesLevel() {
        let browser = browser(3)
        let tabs = browser.tabs
        let top = browser.addTabGroup(containing: tabs[0])
        let inner = browser.addTabGroup(containing: tabs[1], inside: top)

        #expect(browser.shiftLevel(tabs[1], by: -1))

        #expect(tabs[1].groupID == top)

        #expect(browser.shiftLevel(tabs[2], by: 1))

        #expect(tabs[2].groupID == top)
        #expect(browser.tabGroups.contains { $0.id == inner } == false)
    }

    @Test func nestedFoldersSurviveASave() throws {
        let browser = browser(3)
        let tabs = browser.tabs
        let top = browser.addTabGroup(containing: tabs[0])
        let inner = browser.addTabGroup(containing: tabs[1], inside: top)
        browser.renameTabGroup(inner, to: "Inner")
        let waiting = try #require(browser.newFolder(inside: top, named: "Waiting", editing: false))
        browser.toggleTabGroup(inner)
        browser.writeSession(now: true)

        let data = try JSONEncoder().encode(try #require(browser.record.rows[browser.spaceID.uuidString]))
        let shape = try JSONDecoder().decode(Session.Shape.self, from: data)
        let groups = FolderTree.ordered(FolderTree.lasting(shape.groups ?? [], holding: Set(shape.tabs.compactMap(\.groupID))))

        #expect(groups.map(\.id) == [top, inner, waiting])
        #expect(groups[1].parent == top)
        #expect(groups[1].name == "Inner")
        #expect(groups[1].collapsed)
        #expect(groups[2].held)
    }

    @Test func anOldFolderWithoutTheNewKeysStillReads() throws {
        let json = #"{"id":"00000000-0000-0000-0000-00000000000A","name":"Old"}"#

        let group = try JSONDecoder().decode(TabGroup.self, from: Data(json.utf8))

        #expect(group.parent == nil)
        #expect(!group.held)
        #expect(!group.collapsed)
    }

    @Test func aParkedRowDrawsItsFoldersIndented() {
        let browser = browser(3)
        let tabs = browser.tabs
        let top = browser.addTabGroup(containing: tabs[0])
        _ = browser.addTabGroup(containing: tabs[1], inside: top)
        let parked = Parked(tabs: browser.tabs, active: tabs[2].id, groups: browser.tabGroups)

        let drawn = parked.drawn(splitView: false)

        #expect(drawn.groups.filter { $0.heading }.map(\.depth) == [0, 1])
        #expect(drawn.groups.flatMap { $0.tabs }.map(\.id) == [tabs[1].id, tabs[0].id])
        #expect(drawn.loose.map(\.id) == [tabs[2].id])
    }
}
