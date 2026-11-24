import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class ReviewAgainTests {
    private var browser: Browser!
    private var read: [LiveSource] = []
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

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
        LiveFolders.shared.reader = { [weak self] folder in
            self?.read.append(folder.source)
            return .items([], nil)
        }
    }

    private func tearDown() async {
        LiveFolders.shared.reader = { await LiveReader.read($0) }
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    private func pull(_ number: Int) -> String { "https://github.com/acme/rocket/pull/\(number)" }

    private func row(_ number: Int, activity: Date? = nil) -> LiveItem {
        LiveItem(key: pull(number), title: "#\(number)", activity: activity)
    }

    private func numbers(_ items: [LiveItem]) -> [Int] {
        items.compactMap { $0.key.split(separator: "/").last.flatMap { Int($0) } }
    }

    private func lists(_ lists: [PullList], reviews: [Int], reviewed: [Int], assigned: [Int] = [], back: Set<Int>,
                       asked: ((URL) -> Void)? = nil, judged: (([LiveItem], [LiveItem]) -> Void)? = nil) async -> LiveRead? {
        var source = LiveSource.pullRequests
        source.lists = lists
        let answer = await LiveReader.readLists(source, pause: .zero, judge: { others, rows in
            judged?(others, rows)
            return (others + rows).map { row in
                var read = row
                read.signsRead = true
                read.back = back.contains(Int(row.key.split(separator: "/").last ?? "") ?? 0) ? true : nil
                return read
            }
        }) { url in
            asked?(url)
            let words = url.absoluteString
            let numbers = words.contains("reviewed-by") ? reviewed : words.contains("review-requested") ? reviews : words.contains("assignee") ? assigned : []
            return .read(LiveRead(items: numbers.map { self.row($0) }, marked: true))
        }
        guard case .read(let read) = answer else { return nil }
        return read
    }

    @Test func theListAsksForPullRequestsYouReviewedThatAreNotYours() {
        #expect(PullList.changed.title == "Changed Since Your Review")
        #expect(PullList.changed.label == "Review again")
        #expect(PullList.changed.query(hidingDrafts: true) == "is:open is:pr archived:false reviewed-by:@me -author:@me")
        #expect(PullState.rank("Review again") == PullState.rank("To review"))
        #expect(PullList.allCases.firstIndex(of: .changed) == (PullList.allCases.firstIndex(of: .teamReviews) ?? 0) + 1)
    }

    @Test func theListIsNamedByItsShortNameItsTitleOrItsLabel() {
        #expect(PullList.named("changed") == .changed)
        #expect(PullList.named("Changed Since Your Review") == .changed)
        #expect(PullList.named("review-again") == .changed)
        #expect(PullList.named("nonsense") == nil)
    }

    @Test func theListIsReadLast() async {
        var asked: [URL] = []

        _ = await lists([.reviewRequests, .changed, .created], reviews: [1], reviewed: [2], back: [2]) { asked.append($0) }

        #expect(asked.count == 3)
        #expect(asked.last?.absoluteString.contains("reviewed-by") == true)
    }

    @Test func theOtherListsArePageReadFirstInTheSameBudget() async {
        var others: [Int] = []
        var rows: [Int] = []

        _ = await lists([.reviewRequests, .changed], reviews: [1, 2], reviewed: [2, 3], back: [3]) { given, asked in
            others = self.numbers(given)
            rows = self.numbers(asked)
        }

        #expect(others == [1, 2])
        #expect(rows == [3])
    }

    @Test func rowsNotBackAndRowsNotYetReadStayAway() async throws {
        var source = LiveSource.pullRequests
        source.lists = [.changed]
        let unread = await LiveReader.readLists(source, pause: .zero, judge: { _, rows in rows }) { _ in
            .read(LiveRead(items: [self.row(1), self.row(2)], marked: true))
        }
        let judged = await lists([.changed], reviews: [], reviewed: [1, 2, 3], back: [2])

        #expect(unread.found?.isEmpty == true)
        #expect(numbers(try #require(judged).items) == [2])
        #expect(judged?.items.first?.label == "Review again")
        #expect(judged?.items.first?.list == .changed)
    }

    @Test func rowsThatStayAwayUseNoSlotOfTheCap() async throws {
        let read = try #require(await lists([.reviewRequests, .changed], reviews: Array(1...29), reviewed: Array(100...105), back: [105]))

        #expect(read.items.count == 30)
        #expect(numbers(read.items).contains(105))
        #expect(read.more == nil)
    }

    @Test func aRowOnAnotherListStillShowsThroughThatList() async throws {
        let read = try #require(await lists([.reviewRequests, .changed], reviews: [7], reviewed: [7, 8], back: []))

        #expect(numbers(read.items) == [7])
        #expect(read.items.first?.label == "To review")
        #expect(read.items.first?.on == [.reviewRequests])
    }

    @Test func aRowNotBackOnAListShownAfterThisOneIsNeverLabeledReviewAgain() async throws {
        let read = try #require(await lists([.changed, .assigned], reviews: [], reviewed: [7], assigned: [7], back: []))

        #expect(numbers(read.items) == [7])
        #expect(read.items.first?.list == .assigned)
        #expect(read.items.first?.label != "Review again")
    }

    @Test func aBackRowOnAListShownAfterThisOneIsLabeledReviewAgain() async throws {
        let read = try #require(await lists([.changed, .assigned], reviews: [], reviewed: [7], assigned: [7], back: [7]))

        #expect(numbers(read.items) == [7])
        #expect(read.items.first?.list == .changed)
        #expect(read.items.first?.label == "Review again")
    }

    @Test func aBackRowNobodyOpenedJoinsNowAsReviewAgain() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("now-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        var source = LiveSource.pullRequests
        source.lists = [.changed, .created]
        var folder = LiveFolder(space: UUID(), name: "PRs", source: source)
        folder.state = .fine
        var back = row(5)
        back.list = .changed
        back.author = "dana"
        var opened = row(6)
        opened.list = .changed
        opened.opened = at(1)
        var mine = row(7)
        mine.list = .created
        folder.items = [back, opened, mine]

        let rows = IntegrationNow.rows(from: [folder], on: true, at: at(2), memory: NowMemory(file: file))

        #expect(rows.map(\.id) == ["integration:\(pull(5))"])
        #expect(rows.first?.detail == "Review again · dana")
    }

    @Test func theListsFirstReadLightsNothingAndLaterNewsDoes() {
        var source = LiveSource.pullRequests
        source.lists = PullList.standard
        var folder = LiveFolder(space: UUID(), name: "PRs", source: source)
        folder.state = .fine
        folder.noticing = true
        folder.listsOn = [PullList.changed.rawValue: at(10)]
        func back(_ number: Int, _ minutes: Double) -> LiveItem {
            var item = row(number, activity: at(minutes))
            item.on = [.changed]
            item.list = .changed
            return item
        }

        let first = LiveMerge.merged(folder, fetched: [back(1, 5)], now: at(11))
        let later = LiveMerge.merged(first, fetched: [back(1, 5), back(2, 20)], now: at(21))

        #expect(first.items.map(\.fresh) == [false])
        #expect(later.items.map(\.fresh) == [false, true])
    }

    @Test func theStandardListsIncludeTheNewOne() {
        #expect(PullList.standard == [.reviewRequests, .changed, .created, .assigned])
        #expect(LiveSource.pullRequests.pullLists == PullList.standard)
    }

    @Test func aFolderWithTheOldThreeListsGainsTheNewOneOnce() {
        var source = LiveSource.pullRequests
        source.lists = [.reviewRequests, .created, .assigned]
        let folder = LiveFolder(space: UUID(), name: "PRs", source: source)

        let moved = LiveFolders.reviewingAgain([folder], now: at(1))

        #expect(moved.first?.source.lists == [.reviewRequests, .changed, .created, .assigned])
        #expect(moved.first?.listsOn == [PullList.changed.rawValue: at(1)])
    }

    @Test func aPresetFolderWithNoStoredListsGainsItQuietly() {
        let folder = LiveFolder(space: UUID(), name: "PRs", source: .pullRequests)

        let moved = LiveFolders.reviewingAgain([folder], now: at(1))

        #expect(moved.first?.source.lists == nil)
        #expect(moved.first?.source.pullLists == PullList.standard)
        #expect(moved.first?.listsOn == [PullList.changed.rawValue: at(1)])
    }

    @Test func aFolderWithAnyOtherSetIsLeftAsItIs() {
        var custom = LiveSource.pullRequests
        custom.lists = [.reviewRequests, .drafts]
        let folders = [LiveFolder(space: UUID(), name: "Mine", source: custom),
                       LiveFolder(space: UUID(), name: "Reviews", source: .reviewRequests),
                       LiveFolder(space: UUID(), name: "Feed", source: LiveSource(kind: .feed, address: "https://example.com/feed.xml"))]

        #expect(LiveFolders.reviewingAgain(folders, now: at(1)) == folders)
    }

    @Test func theShorthandsKeepTheirMeaning() {
        #expect(LiveSource.from("github:reviews") == .reviewRequests)
        #expect(LiveSource.from("github:reviews")?.pullLists == nil)
        #expect(LiveSource.from("github:mine") == .myPullRequests)
    }

    private func removed(_ identity: String, at minutes: Double?) -> LiveFolder {
        var folder = LiveFolder(space: UUID(), name: "PRs", source: .pullRequests)
        folder.state = .fine
        folder.noticing = true
        folder.hidden = [identity]
        folder.hiddenAt = minutes.map { [identity: at($0)] }
        return folder
    }

    @Test func aRemovedRowReturnsWhenSomeoneElseDoesSomethingAfter() {
        let identity = LiveIdentity.of(pull(1))

        let next = LiveMerge.merged(removed(identity, at: 5), fetched: [row(1, activity: at(6))], now: at(7))

        #expect(numbers(next.items) == [1])
        #expect(next.items.first?.fresh == true)
        #expect(next.hidden.isEmpty)
        #expect(next.hiddenAt == nil)
    }

    @Test func aRemovedRowStaysAwayOnItsOwnOldActivity() {
        let identity = LiveIdentity.of(pull(1))

        let next = LiveMerge.merged(removed(identity, at: 5), fetched: [row(1, activity: at(4))], now: at(7))

        #expect(next.items.isEmpty)
        #expect(next.hidden == [identity])
    }

    @Test func aBotNeverBringsARemovedRowBack() {
        let identity = LiveIdentity.of(pull(1))
        let signs = PullSigns.read([PullSigns.Said(at: at(4), who: "dana"), PullSigns.Said(at: at(8), who: "codecov", bot: true)],
                                   threads: [], viewer: "octo-sam")

        let next = LiveMerge.merged(removed(identity, at: 5), fetched: [row(1, activity: signs.activity)], now: at(9))

        #expect(signs.activity == at(4))
        #expect(next.items.isEmpty)
    }

    @Test func aRowRemovedBeforeThisBuildIsTimedAtTheFirstReadAfterIt() {
        let identity = LiveIdentity.of(pull(1))

        let first = LiveMerge.merged(removed(identity, at: nil), fetched: [row(1, activity: at(6))], now: at(7))
        let later = LiveMerge.merged(first, fetched: [row(1, activity: at(8))], now: at(9))

        #expect(first.items.isEmpty)
        #expect(first.hiddenAt == [identity: at(7)])
        #expect(numbers(later.items) == [1])
    }

    @Test func aFeedKeepsItsRemovedRowAway() {
        let key = "https://example.com/post/1"
        var folder = LiveFolder(space: UUID(), name: "News", source: LiveSource(kind: .feed, address: "https://example.com/feed.xml"))
        folder.state = .fine
        folder.hidden = [LiveIdentity.of(key)]

        let next = LiveMerge.merged(folder, fetched: [LiveItem(key: key, title: "Post", activity: at(9))], now: at(10))

        #expect(next.items.isEmpty)
        #expect(next.hiddenAt == nil)
    }

    @Test func removingARowKeepsWhenAndShowHiddenForgetsIt() {
        let live = LiveFolders.shared
        let made = live.add(name: "PRs", source: .pullRequests, space: browser.spaceID)
        live.apply(.items([row(1)], nil), to: made.id)

        live.hide(pull(1), in: made.id)
        let kept = live.folder(made.id)?.hiddenAt?[LiveIdentity.of(pull(1))]
        live.showHidden(made.id)

        #expect(kept != nil)
        #expect(live.folder(made.id)?.hiddenAt == nil)
        #expect(live.folder(made.id)?.hidden.isEmpty == true)
    }

}
