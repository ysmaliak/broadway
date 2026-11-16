import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LiveOrderTests {
    private var browser: Browser!

    init() async throws {
        _ = NSApplication.shared
        keepSetting(Shared.prefs, \.liveFolders, "live.on")
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesTabGroups = true
        browser.prefs.liveFolders = true
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
    }

    private func tearDown() async {
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    private func pull(_ number: Int, base: String? = nil, head: String? = nil, stack: Int? = nil) -> LiveItem {
        LiveItem(key: "https://github.com/harbor/lantern/pull/\(number)", title: "Lantern \(number)",
                 branch: head.map { LiveBranch(repository: "harbor/lantern", base: base ?? "main", head: $0,
                                               stack: stack, position: stack == nil ? nil : number) })
    }

    private var stacked: [LiveItem] {
        LiveStacks.arranged([pull(11, base: "main", head: "wick", stack: 9), pull(12, base: "wick", head: "flame", stack: 9),
                             pull(13, base: "flame", head: "glow", stack: 9)])
    }

    private func folder() -> LiveFolder {
        LiveFolders.shared.add(name: "Lantern", source: .pullRequests, space: browser.spaceID)
    }

    private func fill(_ made: LiveFolder, _ items: [LiveItem]) {
        LiveFolders.shared.apply(.items(items, nil), to: made.id)
        browser.syncLive()
    }

    private func numbers(_ made: LiveFolder) -> [Int] {
        browser.tabs(in: made.id).compactMap { $0.liveKey.flatMap { Int($0.split(separator: "/").last ?? "") } }
    }

    private func tab(_ made: LiveFolder, _ number: Int) -> Tab {
        browser.tabs(in: made.id).first { $0.liveKey == pull(number).key }!
    }

    private func drop(_ made: LiveFolder, _ number: Int, before other: Int? = nil, after: Int? = nil) {
        let member = (other ?? after).map { tab(made, $0).id }
        browser.move(tab(made, number), toGroup: GroupDropTarget(group: made.id, member: member, after: after != nil))
    }

    @Test func aFolderNeverMovedKeepsTheSourcesOrder() {
        let made = folder()
        fill(made, [pull(1), pull(2), pull(3)])
        fill(made, [pull(3), pull(1), pull(2)])

        #expect(numbers(made) == [3, 1, 2])
        #expect(LiveFolders.shared.folder(made.id)?.order == nil)
    }

    @Test func aDroppedRowStaysWhereItWasDropped() {
        let made = folder()
        fill(made, [pull(1), pull(2), pull(3)])

        drop(made, 3, before: 1)

        #expect(numbers(made) == [3, 1, 2])
        #expect(browser.tabs(in: made.id).count == 3)
        #expect(LiveFolders.shared.folder(made.id)?.hidden == [])
    }

    @Test func theOrderOutlastsARefreshThatShufflesTheSource() {
        let made = folder()
        fill(made, [pull(1), pull(2), pull(3)])
        drop(made, 1, after: 3)

        fill(made, [pull(2), pull(1), pull(3)])
        fill(made, [pull(3), pull(2), pull(1)])

        #expect(numbers(made) == [2, 3, 1])
    }

    @Test func aNewItemArrivesAtTheTop() {
        let made = folder()
        fill(made, [pull(1), pull(2), pull(3)])
        drop(made, 1, after: 3)

        fill(made, [pull(1), pull(2), pull(4), pull(3)])
        fill(made, [pull(5), pull(1), pull(2), pull(4), pull(3)])

        #expect(numbers(made) == [5, 4, 2, 3, 1])
    }

    @Test func anItemThatLeavesLeavesTheRestInTheirPlaces() {
        let made = folder()
        fill(made, [pull(1), pull(2), pull(3), pull(4)])
        drop(made, 4, before: 1)
        drop(made, 1, after: 3)

        fill(made, [pull(1), pull(3), pull(4)])

        #expect(numbers(made) == [4, 3, 1])
    }

    @Test func aStackMovesAsOneBlockInItsOwnOrder() {
        let made = folder()
        fill(made, [pull(1)] + stacked + [pull(2)])
        #expect(numbers(made) == [1, 13, 12, 11, 2])

        drop(made, 12, after: 2)

        #expect(numbers(made) == [1, 2, 13, 12, 11])
        #expect(browser.stackTops(in: browser.tabGroups.first { $0.id == made.id }!).count == 1)
    }

    @Test func aRowDroppedInsideAStackLandsBesideTheWholeStack() {
        let made = folder()
        fill(made, [pull(1)] + stacked + [pull(2)])

        drop(made, 2, before: 12)

        #expect(numbers(made) == [1, 2, 13, 12, 11] || numbers(made) == [1, 13, 12, 11, 2])
        #expect(Array(numbers(made).drop { $0 != 13 }.prefix(3)) == [13, 12, 11])
    }

    @Test func theCarryOffersTheStacksEdgeAndNothingInsideItsOwnStack() {
        let made = folder()
        fill(made, [pull(1)] + stacked + [pull(2)])
        let group = made.id

        let near = browser.liveDrop(GroupDropTarget(group: group, member: tab(made, 12).id), carrying: tab(made, 2))
        let own = browser.liveDrop(GroupDropTarget(group: group, member: tab(made, 11).id), carrying: tab(made, 13))
        let plain = browser.liveDrop(GroupDropTarget(group: group, member: tab(made, 2).id), carrying: tab(made, 1))

        #expect(near == GroupDropTarget(group: group, member: tab(made, 13).id))
        #expect(own == nil)
        #expect(plain == GroupDropTarget(group: group, member: tab(made, 2).id))
    }

    @Test func aRowDroppedBelowAFoldedStackLandsBelowIt() throws {
        let made = folder()
        fill(made, [pull(1), pull(2)] + stacked)
        let group = try #require(browser.tabGroups.first { $0.id == made.id })
        browser.toggleStack(tab(made, 13).id, in: made.id)
        let folded = try #require(browser.tabGroups.first { $0.id == made.id })
        #expect(Browser.unfoldedStacks(browser.drawnTabs(in: folded), in: folded, front: nil).count == 3)
        #expect(group.foldedStacks != folded.foldedStacks)

        let offered = browser.liveDrop(GroupDropTarget(group: made.id, member: tab(made, 13).id, after: true), carrying: tab(made, 1))
        #expect(offered == GroupDropTarget(group: made.id, member: tab(made, 13).id, after: true))
        drop(made, 1, after: 13)

        #expect(numbers(made) == [2, 13, 12, 11, 1])
    }

    @Test func aNewPullRequestInAMovedStackStaysWithItsStack() {
        let made = folder()
        fill(made, [pull(1)] + stacked + [pull(2)])
        drop(made, 13, after: 2)

        let grown = LiveStacks.arranged([pull(11, base: "main", head: "wick", stack: 9), pull(12, base: "wick", head: "flame", stack: 9),
                                         pull(13, base: "flame", head: "glow", stack: 9), pull(14, base: "glow", head: "ember", stack: 9)])
        fill(made, [pull(1)] + grown + [pull(2)])

        #expect(numbers(made) == [1, 2, 14, 13, 12, 11])
    }

    @Test func droppedOnItsOwnHeadingARowGoesToTheTop() {
        let made = folder()
        fill(made, [pull(1), pull(2), pull(3)])

        drop(made, 3)

        #expect(numbers(made) == [3, 1, 2])
    }

    @Test func aDropWhereTheRowAlreadyIsLeavesTheFolderAutomatic() {
        let made = folder()
        fill(made, [pull(1), pull(2), pull(3)])

        drop(made, 2, after: 1)

        #expect(LiveFolders.shared.folder(made.id)?.order == nil)
    }

    @Test func restoringTheAutomaticOrderTakesTheSourcesOrderAtOnce() {
        let made = folder()
        fill(made, [pull(1), pull(2), pull(3)])
        drop(made, 3, before: 1)
        #expect(numbers(made) == [3, 1, 2])

        LiveFolders.shared.setOrder(made.id, nil)
        browser.syncLive()

        #expect(numbers(made) == [1, 2, 3])
        #expect(LiveFolders.shared.folder(made.id)?.order == nil)
        fill(made, [pull(4), pull(2), pull(1), pull(3)])
        #expect(numbers(made) == [4, 2, 1, 3])
    }

    @Test func aTabFromOutsideIsStillNotTakenIn() {
        let made = folder()
        fill(made, [pull(1), pull(2)])
        let outside = browser.open(URL(string: "https://example.com/lamp")!, foreground: false)

        browser.move(outside, toGroup: GroupDropTarget(group: made.id, member: tab(made, 1).id))

        #expect(outside.groupID == nil)
        #expect(numbers(made) == [1, 2])
    }

    @Test func dismissedAndBroughtBackARowTakesItsPlaceAgain() throws {
        let made = folder()
        fill(made, [pull(1), pull(2), pull(3)])
        drop(made, 1, after: 3)

        let dismissal = try #require(LiveFolders.shared.hide(pull(3).key, in: made.id))
        browser.syncLive()
        LiveFolders.shared.restore(dismissal)
        browser.syncLive()

        #expect(numbers(made) == [2, 3, 1])
    }

    @Test func theOrderIsSavedAndReadBack() throws {
        let made = folder()
        fill(made, [pull(1), pull(2), pull(3)])
        drop(made, 3, before: 1)
        let saved = try #require(LiveFolders.shared.folder(made.id))

        let read = try JSONDecoder().decode(LiveFolder.self, from: JSONEncoder().encode(saved))

        #expect(read.order == ["github:harbor/lantern#3", "github:harbor/lantern#1", "github:harbor/lantern#2"])
        #expect(LiveOrder.shown(read.items, by: read.order).map(\.title) == ["Lantern 3", "Lantern 1", "Lantern 2"])
    }

    @Test func aFolderSavedBeforeOrdersStillLoads() throws {
        let made = folder()
        fill(made, [pull(1), pull(2)])
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(LiveFolders.shared.folder(made.id))) as? [String: Any])
        old["order"] = nil

        let read = try JSONDecoder().decode(LiveFolder.self, from: JSONSerialization.data(withJSONObject: old))

        #expect(read.order == nil)
        #expect(read.items.map(\.title) == ["Lantern 1", "Lantern 2"])
    }

    @Test func theMenuOffersTheWayBackOnlyOnceTheFolderHasAnOrder() {
        let made = folder()
        fill(made, [pull(1), pull(2), pull(3)])
        func titles() -> [String] { FolderMenus.menu(browser: browser, group: browser.tabGroups.first { $0.id == made.id }!).items.map(\.title) }
        #expect(!titles().contains("Restore Automatic Order"))

        drop(made, 3, before: 1)

        #expect(titles().contains("Restore Automatic Order"))
    }

    @Test func theKeptOrderForgetsTheOldestGoneItemsPastItsLimit() {
        let gone = (0..<LiveOrder.kept).map { "github:harbor/old#\($0)" }
        let items = [pull(1), pull(2)]

        let kept = LiveOrder.noted(["github:harbor/lantern#2"] + gone + ["github:harbor/lantern#1"], items: items)

        #expect(kept.count == LiveOrder.kept)
        #expect(kept.contains("github:harbor/lantern#1") && kept.contains("github:harbor/lantern#2"))
        #expect(kept.first == "github:harbor/lantern#2")
    }
}
