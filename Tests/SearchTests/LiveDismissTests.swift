import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LiveDismissTests {
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
        LiveFolders.shared.reader = { await LiveReader.read($0) }
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    private func pull(_ number: Int, base: String? = nil, head: String? = nil, stack: Int? = nil) -> LiveItem {
        LiveItem(key: "https://github.com/acme/rocket/pull/\(number)", title: "PR \(number)",
                 branch: head.map { LiveBranch(repository: "acme/rocket", base: base ?? "main", head: $0,
                                               stack: stack, position: stack == nil ? nil : number) })
    }

    private var stack: [LiveItem] {
        LiveStacks.arranged([pull(1, base: "main", head: "one", stack: 4), pull(2, base: "one", head: "two", stack: 4),
                             pull(3, base: "two", head: "three", stack: 4)])
    }

    private func prs() -> LiveFolder {
        LiveFolders.shared.add(name: "PRs", source: .pullRequests, space: browser.spaceID)
    }

    private func fill(_ made: LiveFolder, _ items: [LiveItem], complete: Bool = true) {
        if complete {
            LiveFolders.shared.apply(.items(items, nil), to: made.id)
        } else {
            LiveFolders.shared.apply(.sso(LiveSSO(org: "Acme", url: "https://github.com/orgs/acme/sso"), items), to: made.id)
        }
        browser.syncLive()
    }

    private func keys(_ made: LiveFolder) -> [String?] {
        browser.tabs(in: made.id).map(\.liveKey)
    }

    @Test func aRemovedPullRequestStaysOutAfterARefreshWithTheSameFeed() {
        let made = prs()
        fill(made, [pull(1), pull(2)])

        browser.close(browser.tabs(in: made.id)[0])
        fill(made, [pull(1), pull(2)])
        fill(made, [pull(1), pull(2)])

        #expect(keys(made) == [pull(2).key])
        #expect(LiveFolders.shared.folder(made.id)?.hidden == ["github:acme/rocket#1"])
    }

    @Test func aDismissalIsTheRepositoryAndNumberNotTheAddress() {
        var folder = LiveFolder(space: UUID(), name: "PRs", source: .pullRequests)
        folder.hidden = ["https://github.com/Acme/Rocket/pull/1/"]

        let next = LiveMerge.merged(folder, fetched: [pull(1), pull(2)])

        #expect(next.items.map(\.key) == [pull(2).key])
        #expect(next.hidden == ["github:acme/rocket#1"])
        #expect(LiveIdentity.of("https://linear.app/acme/issue/eng-12/a-title") == "linear:ENG-12")
        #expect(LiveIdentity.of("https://example.com/post") == "https://example.com/post")
    }

    @Test func theDismissalSurvivesASaveAndLoad() throws {
        let made = prs()
        fill(made, [pull(1), pull(2)])
        browser.close(browser.tabs(in: made.id)[0])
        let saved = try #require(LiveFolders.shared.folder(made.id))

        let loaded = try JSONDecoder().decode(LiveFolder.self, from: JSONEncoder().encode(saved))
        let next = LiveMerge.merged(loaded, fetched: [pull(1), pull(2)])

        #expect(loaded == saved)
        #expect(next.items.map(\.key) == [pull(2).key])
    }

    @Test func aFolderSavedBeforeDismissalsHadDatesStillLoads() throws {
        let made = prs()
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(LiveFolders.shared.folder(made.id))) as? [String: Any])
        old["hidden"] = ["https://github.com/acme/rocket/pull/1"]
        old.removeValue(forKey: "hiddenMissing")

        let loaded = try JSONDecoder().decode(LiveFolder.self, from: JSONSerialization.data(withJSONObject: old))

        #expect(loaded.hiddenMissing == nil)
        #expect(loaded.hides(pull(1).key))
    }

    @Test func theDismissalIsForgottenADayAfterTheItemLeavesTheFeed() {
        let now = Date()
        var folder = LiveFolder(space: UUID(), name: "PRs", source: .pullRequests)
        folder.hidden = ["github:acme/rocket#1"]

        let merged = LiveMerge.merged(folder, fetched: [pull(2)], now: now)
        let soon = LiveMerge.merged(merged, fetched: [pull(2)], now: now.addingTimeInterval(3_600))
        let later = LiveMerge.merged(soon, fetched: [pull(2)], now: now.addingTimeInterval(LiveMerge.gone))
        let reopened = LiveMerge.merged(later, fetched: [pull(1), pull(2)], now: now.addingTimeInterval(LiveMerge.gone + 60))

        #expect(merged.hidden == ["github:acme/rocket#1"])
        #expect(merged.hiddenMissing == ["github:acme/rocket#1": now])
        #expect(merged.hiddenInFeed == 0)
        #expect(soon.hidden == ["github:acme/rocket#1"])
        #expect(later.hidden.isEmpty)
        #expect(later.hiddenMissing == nil)
        #expect(reopened.items.map(\.key) == [pull(1).key, pull(2).key])
    }

    @Test func comingBackIntoTheFeedStopsTheClock() {
        let now = Date()
        var folder = LiveFolder(space: UUID(), name: "PRs", source: .pullRequests)
        folder.hidden = ["github:acme/rocket#1"]
        let gone = LiveMerge.merged(folder, fetched: [pull(2)], now: now)

        let back = LiveMerge.merged(gone, fetched: [pull(1), pull(2)], now: now.addingTimeInterval(60))
        let later = LiveMerge.merged(back, fetched: [pull(1), pull(2)], now: now.addingTimeInterval(LiveMerge.gone * 2))

        #expect(back.hiddenMissing == nil)
        #expect(back.hiddenInFeed == 1)
        #expect(later.items.map(\.key) == [pull(2).key])
    }

    @Test func aWindowOpenedAfterwardsBuildsTheFolderWithoutTheDismissedItem() {
        let made = prs()
        fill(made, [pull(1), pull(2)])
        browser.close(browser.tabs(in: made.id)[0])

        let other = Browser(record: WindowRecord(space: browser.spaceID))
        other.leaveFiles()
        defer { other.closeAll() }
        other.syncLive()
        LiveFolders.shared.apply(.items([pull(1), pull(2)], nil), to: made.id)
        other.syncLive()

        #expect(other.tabs(in: made.id).map(\.liveKey) == [pull(2).key])
    }

    @Test func aPartialOrEmptyReadForgetsNothing() {
        let made = prs()
        fill(made, [pull(1), pull(2)])
        browser.close(browser.tabs(in: made.id)[0])

        fill(made, [pull(2)], complete: false)
        fill(made, [])

        #expect(LiveFolders.shared.folder(made.id)?.hidden == ["github:acme/rocket#1"])
        #expect(LiveFolders.shared.folder(made.id)?.hiddenMissing == nil)
    }

    @Test func undoBringsTheItemBackIntoItsFolderAndClearsTheDismissal() throws {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        browser.window = window
        let undo = try #require(window.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        let made = prs()
        fill(made, [pull(1), pull(2), pull(3)])

        undo.beginUndoGrouping()
        browser.close(browser.tabs(in: made.id)[1])
        undo.endUndoGrouping()

        #expect(undo.undoMenuItemTitle == "Undo Close Tab")
        #expect(keys(made) == [pull(1).key, pull(3).key])

        undo.undo()
        fill(made, [pull(1), pull(2), pull(3)])

        #expect(keys(made) == [pull(1).key, pull(2).key, pull(3).key])
        #expect(browser.active?.liveKey == pull(2).key)
        #expect(LiveFolders.shared.folder(made.id)?.hidden == [])
        #expect(browser.tabs.filter { $0.liveKey == pull(2).key }.count == 1)
    }

    @Test func reopenClosedTabBringsBackSeveralClosedTogether() {
        let made = prs()
        fill(made, [pull(1), pull(2), pull(3)])
        browser.closingTogether(.tabs) { _ in
            for tab in browser.tabs(in: made.id).dropFirst().reversed() { browser.close(tab) }
        }

        browser.reopen()
        fill(made, [pull(1), pull(2), pull(3)])

        #expect(keys(made) == [pull(1).key, pull(2).key, pull(3).key])
        #expect(LiveFolders.shared.folder(made.id)?.hidden == [])
    }

    @Test func draggingAnItemOutDismissesItAndKeepsTheTabWhereItWasDropped() {
        let made = prs()
        fill(made, [pull(1), pull(2)])
        let tab = browser.tabs(in: made.id)[0]

        browser.move(tab, toGroup: nil)
        fill(made, [pull(1), pull(2)])

        #expect(browser.tabs.contains { $0 === tab })
        #expect(tab.groupID == nil)
        #expect(tab.liveKey == nil)
        #expect(keys(made) == [pull(2).key])
        #expect(!browser.tabs.contains { $0.liveKey == pull(1).key })
        #expect(LiveFolders.shared.folder(made.id)?.hidden == ["github:acme/rocket#1"])
    }

    @Test func pinningAnItemDismissesItWithoutADuplicate() {
        let made = prs()
        fill(made, [pull(1), pull(2)])
        let tab = browser.tabs(in: made.id)[0]

        browser.pin(tab)
        fill(made, [pull(1), pull(2)])

        #expect(tab.pin != nil)
        #expect(keys(made) == [pull(2).key])
        #expect(!browser.tabs.contains { $0.liveKey == pull(1).key })
    }

    @Test func droppingAnItemInTheTopStripDismissesIt() throws {
        let made = prs()
        fill(made, [pull(1), pull(2)])
        let tab = browser.tabs(in: made.id)[0]
        let loose = try #require(browser.tabs.first { $0.groupID == nil && $0.pin == nil })

        browser.dropTabIntoStrip(tab, before: loose)
        fill(made, [pull(1), pull(2)])

        #expect(tab.liveKey == nil)
        #expect(keys(made) == [pull(2).key])
        #expect(LiveFolders.shared.folder(made.id)?.hidden == ["github:acme/rocket#1"])
    }

    @Test func aDismissalBelongsToItsOwnFolder() {
        let mine = prs()
        let reviews = LiveFolders.shared.add(name: "Reviews", source: .reviewRequests, space: browser.spaceID)
        fill(mine, [pull(1)])
        fill(reviews, [pull(1)])

        browser.close(browser.tabs(in: mine.id)[0])
        fill(reviews, [pull(1)])

        #expect(keys(mine).isEmpty)
        #expect(keys(reviews) == [pull(1).key])
    }

    @Test func dismissingAStacksTopLeavesAStackOfTwoWithItsChevron() throws {
        let made = prs()
        fill(made, stack)
        let top = try #require(browser.tabs(in: made.id).first)

        browser.close(top)
        fill(made, stack)

        let group = try #require(browser.tabGroups.first { $0.id == made.id })
        let rows = browser.tabs(in: made.id)
        #expect(rows.map(\.liveKey) == [pull(2).key, pull(1).key])
        #expect(rows.map { $0.liveItem?.stack?.said } == ["2/2", "1/2"])
        #expect(browser.stackTops(in: group) == [rows[0].id: false])
    }

    @Test func dismissingAStacksMiddleLeavesTheRestOfGitHubsStackTogether() throws {
        let made = prs()
        fill(made, stack)
        let middle = try #require(browser.tabs(in: made.id).dropFirst().first)

        browser.close(middle)
        fill(made, stack)

        let group = try #require(browser.tabGroups.first { $0.id == made.id })
        let rows = browser.tabs(in: made.id)
        #expect(rows.map(\.liveKey) == [pull(3).key, pull(1).key])
        #expect(rows.map { $0.liveItem?.stack?.said } == ["2/2", "1/2"])
        #expect(browser.stackTops(in: group) == [rows[0].id: false])
    }

    @Test func dismissingTheRestOfATwoStackLeavesALoneRow() throws {
        let made = prs()
        let two = LiveStacks.arranged([pull(1, base: "main", head: "one", stack: 4), pull(2, base: "one", head: "two", stack: 4)])
        fill(made, two)

        browser.close(browser.tabs(in: made.id)[1])

        let group = try #require(browser.tabGroups.first { $0.id == made.id })
        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.stack) == [nil])
        browser.syncLive()
        #expect(browser.stackTops(in: group).isEmpty)
    }

    @Test func undoPutsAStacksTopBackOnTop() throws {
        let made = prs()
        fill(made, stack)

        browser.close(browser.tabs(in: made.id)[0])
        browser.reopen()

        let group = try #require(browser.tabGroups.first { $0.id == made.id })
        let rows = browser.tabs(in: made.id)
        #expect(rows.map(\.liveKey) == [pull(3).key, pull(2).key, pull(1).key])
        #expect(rows.map { $0.liveItem?.stack?.said } == ["3/3", "2/3", "1/3"])
        #expect(browser.stackTops(in: group).keys.first == rows[0].id)
    }

    @Test func showHiddenBringsDismissedItemsBackOnTheNextRead() async {
        let made = prs()
        fill(made, [pull(1), pull(2)])
        browser.close(browser.tabs(in: made.id)[0])
        LiveFolders.shared.reader = { _ in .items([self.pull(1), self.pull(2)], nil) }
        #expect(LiveFolders.shared.folder(made.id)?.hiddenInFeed == 1)

        LiveFolders.shared.showHidden(made.id)
        while LiveFolders.shared.reading.contains(made.id) { try? await Task.sleep(for: .milliseconds(20)) }
        browser.syncLive()

        #expect(LiveFolders.shared.folder(made.id)?.hidden == [])
        #expect(keys(made) == [pull(1).key, pull(2).key])
    }
}
