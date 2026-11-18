import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LiveTouchTests {
    private let live = LiveFolders.shared
    private let reader = LiveFolders.shared.reader
    private let pointReader = LiveFolders.shared.pointReader
    private let looking = LiveFolders.shared.looking
    private let idleness = LiveFolders.shared.idleness
    private let frontmost = LiveFolders.shared.frontmost
    private let space = UUID()
    private var reads: [UUID] = []
    private var asks: [[LiveTouch.Ask]] = []
    private var answers: [LiveItem] = []
    private var active = true
    private var idle: TimeInterval = 0

    init() async throws {
        _ = NSApplication.shared
        addTeardownBlock { await self.tearDown() }
        for folder in live.folders { live.remove(folder.id) }
        live.resetPace()
        let shown = space
        live.reader = { [weak self] folder in
            self?.reads.append(folder.id)
            return .items(folder.items, nil)
        }
        live.pointReader = { [weak self] asked in
            self?.asks.append(asked)
            return self?.answers ?? []
        }
        live.looking = { [shown] }
        live.idleness = { [weak self] in self?.idle ?? 0 }
        live.frontmost = { [weak self] in self?.active ?? false }
    }

    private func tearDown() async {
        live.reader = reader
        live.pointReader = pointReader
        live.looking = looking
        live.idleness = idleness
        live.frontmost = frontmost
        live.mergedHold = LiveFolders.hold
        live.saidHold = LiveFolders.pageHold
        live.resetPace()
        for folder in live.folders { live.remove(folder.id) }
    }

    private func pull(_ number: Int, label: String? = nil, checks: LiveChecks? = nil, draft: Bool = false) -> LiveItem {
        LiveItem(key: "https://github.com/acme/rocket/pull/\(number)", title: "PR \(number)", label: label, author: "dana",
                 checks: checks, draft: draft ? true : nil)
    }

    private func url(_ number: Int) -> URL { URL(string: pull(number).key)! }

    private func folder(_ items: [LiveItem], source: LiveSource = .pullRequests, read: Date = Date().addingTimeInterval(-600),
                        in space: UUID? = nil) -> LiveFolder {
        let made = live.add(name: "Folder", source: source, space: space ?? self.space)
        live.apply(.items(items, nil), to: made.id, now: read)
        return made
    }

    private func row(_ made: LiveFolder, _ key: String) -> LiveItem? {
        live.folder(made.id)?.items.first { $0.key == key }
    }

    private func settle() async throws {
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(20))
            if live.reading.isEmpty { break }
        }
    }

    @Test func loadingAPullRequestsPageRefreshesItsRowFromOneRequest() async throws {
        let made = folder([pull(1, checks: .pending), pull(2)], read: Date())
        answers = [pull(1, checks: .passing)]

        live.touch(url(1), space: space, cause: .landed)
        await live.flush()
        try await settle()

        #expect(asks.count == 1)
        #expect(asks.first?.map(\.key) == [pull(1).key])
        #expect(row(made, pull(1).key)?.checks == .passing)
        #expect(reads.isEmpty)
    }

    @Test func aReviewSeenOnThePageChangesTheLabelAndReadsTheFolderSoon() async throws {
        let made = folder([pull(1)])
        answers = [pull(1, label: PullState.approved)]

        live.touch(url(1).appending(path: "files"), space: space, cause: .moved)
        await live.flush()
        try await settle()

        #expect(row(made, pull(1).key)?.label == PullState.approved)
        #expect(reads == [made.id])
    }

    @Test func pageEventsCloseTogetherAskOnce() async throws {
        _ = folder([pull(1), pull(2)], read: Date())
        answers = []

        live.touch(url(1), space: space, cause: .moved)
        live.touch(url(1), space: space, cause: .landed)
        live.touch(url(2), space: space, cause: .landed)
        await live.flush()
        live.touch(url(1), space: space, cause: .landed)
        await live.flush()

        #expect(asks.count == 1)
        #expect(Set(asks.first?.map(\.key) ?? []) == [pull(1).key, pull(2).key])
    }

    @Test func showingAPullRequestsPageAsksItsRowAgainAtMostOnceInTenMinutes() async throws {
        let made = folder([pull(1), pull(2)])
        let now = Date()
        let identity = LiveIdentity.of(pull(1).key)
        LiveRefs.known = [:]

        live.pageShown(url(1), space: space, now: now)
        try await settle()
        let asked = live.rereads
        let readThen = reads
        LiveRefs.known[LiveRefs.slot(pull(1).key, space: space)] = LiveRefs.Known(updated: nil, branch: nil, read: now.addingTimeInterval(1))
        live.pagesRead()
        let afterRead = live.rereads
        live.pageShown(url(1), space: space, now: now.addingTimeInterval(120))
        let tooSoon = live.rereads
        live.pageShown(url(1), space: space, now: now.addingTimeInterval(601))
        let later = live.rereads
        live.pageShown(url(9), space: space, now: now)
        LiveRefs.known = [:]

        #expect(asked.contains(identity))
        #expect(!asked.contains(LiveIdentity.of(pull(2).key)))
        #expect(readThen == [made.id])
        #expect(!afterRead.contains(identity))
        #expect(!tooSoon.contains(identity))
        #expect(later.contains(identity))
        #expect(!live.rereads.contains(LiveIdentity.of(pull(9).key)))
    }

    @Test func aPageOutsideEveryFolderAsksNothing() async throws {
        _ = folder([pull(1)], read: Date())
        _ = folder([pull(5)], read: Date(), in: UUID())

        live.touch(url(9), space: space, cause: .landed)
        live.touch(url(5), space: space, cause: .landed)
        live.touch(URL(string: "https://github.com/acme/rocket")!, space: space, cause: .landed)
        await live.flush()

        #expect(asks.isEmpty)
    }

    @Test func aPullRequestMergedOnItsPageTurnsAndLeaves() async throws {
        live.mergedHold = 0.05
        let made = folder([pull(1), pull(2)], read: Date())
        answers = [pull(1, label: PullState.merged)]

        live.touch(url(1), space: space, cause: .acted)
        await live.flush()
        let turning = live.turning(pull(1).key)
        try await Task.sleep(for: .milliseconds(200))

        #expect(turning)
        #expect(row(made, pull(1).key) == nil)
        #expect(live.departed(pull(1).key, from: made.id))
    }

    @Test func aClosedPullRequestSaysClosedAndTheFolderIsReadSoon() async throws {
        let made = folder([pull(1, draft: true)])
        answers = [pull(1, label: PullState.closed)]

        live.touch(url(1), space: space, cause: .landed)
        await live.flush()
        try await settle()

        #expect(row(made, pull(1).key)?.label == PullState.closed)
        #expect(row(made, pull(1).key)?.draft == nil)
        #expect(reads == [made.id])
    }

    @Test func actingOnAPageReadsTheFolderAtOnce() async throws {
        let made = folder([pull(1)])

        live.touch(url(1), space: space, cause: .acted)
        try await settle()

        #expect(reads == [made.id])
        #expect(live.asking.map(\.key) == [pull(1).key])
    }

    @Test func aLinearStatusChangeShowsOnItsRow() async throws {
        let key = "https://linear.app/acme/issue/ABC-1/ship-it"
        let made = folder([LiveItem(key: key, title: "Ship it", label: "Todo", author: "ABC-1")],
                          source: .linear(.assigned, workspace: "acme"), read: Date())
        answers = [LiveItem(key: key, title: "Ship it", label: "In Review", author: "ABC-1")]

        live.touch(URL(string: "https://linear.app/acme/issue/ABC-1")!, space: space, cause: .acted)
        await live.flush()

        #expect(row(made, key)?.label == "In Review")
    }

    @Test func theFirstTickCatchesUpTheSpaceOnScreenAndWhatIsPastTheIntervalElsewhereThenWaits() async throws {
        let old = folder([pull(1)], read: Date().addingTimeInterval(-6 * 60))
        let recent = folder([pull(2)], source: .reviewRequests, read: Date().addingTimeInterval(-2 * 60))
        let elsewhere = folder([pull(3)], read: Date().addingTimeInterval(-6 * 60), in: UUID())
        _ = folder([pull(5)], read: Date().addingTimeInterval(-2 * 60), in: UUID())
        _ = folder([pull(4)], read: Date().addingTimeInterval(-30))

        let first = live.tick()
        try await settle()
        let second = live.tick()

        #expect(Set(first) == [old.id, recent.id, elsewhere.id])
        #expect(Set(reads) == [old.id, recent.id, elsewhere.id])
        #expect(second.isEmpty)
    }

    @Test func theTickKnowsSinceWhenThePersonHasBeenAtTheMac() async throws {
        let start = Date()
        idle = 10 * 60
        _ = live.tick(at: start)
        let away = live.here

        idle = 0
        _ = live.tick(at: start.addingTimeInterval(60))
        let back = live.here
        _ = live.tick(at: start.addingTimeInterval(120))
        let still = live.here

        live.network(false)
        _ = live.tick(at: start.addingTimeInterval(180))
        let offline = live.here
        live.network(true)

        #expect(away == nil)
        #expect(back == start.addingTimeInterval(60))
        #expect(still == back)
        #expect(offline == back)
    }

    @Test func anIdleUserIsNotPolledAtTheActivePace() async throws {
        _ = folder([pull(1)], read: Date().addingTimeInterval(-6 * 60))
        idle = 10 * 60
        _ = live.tick()

        let wanted = live.tick()

        #expect(wanted.isEmpty)
    }

    @Test func comingBackToBroadwayCatchesUpWhatIsOlderThanAMinute() async throws {
        let old = folder([pull(1)], read: Date().addingTimeInterval(-90))
        _ = folder([pull(2)], read: Date().addingTimeInterval(-20))
        active = false
        live.wentAway(LiveFolders.awayFromApp)
        _ = live.tick()

        active = true
        live.cameBack(from: LiveFolders.awayFromApp)
        try await settle()

        #expect(reads == [old.id])
    }

    @Test func aLockedMacIsNeverPolledAndCatchesUpOnUnlock() async throws {
        let made = folder([pull(1)], read: Date().addingTimeInterval(-3600))
        idle = 0
        live.wentAway("lock")

        let locked = live.tick()
        live.cameBack(from: "lock")
        try await settle()

        #expect(locked.isEmpty)
        #expect(reads == [made.id])
    }

    @Test func noNetworkMeansNoPollsUntilItIsBack() async throws {
        let made = folder([pull(1)], read: Date().addingTimeInterval(-3600))
        live.network(false)

        let offline = live.tick()
        live.network(true)
        try await settle()

        #expect(offline.isEmpty)
        #expect(reads == [made.id])
    }

    @Test func aTargetedReadNeverOverridesWhatThePageJustSaid() async throws {
        let made = folder([pull(1, label: PullState.draft, draft: true)], read: Date())
        live.pageSays(.open, at: url(1), space: space)
        answers = [pull(1, label: PullState.draft, checks: .passing, draft: true)]

        live.touch(url(1), space: space, cause: .landed)
        await live.flush()

        #expect(row(made, pull(1).key)?.draft == nil)
        #expect(row(made, pull(1).key)?.label == nil)
        #expect(row(made, pull(1).key)?.checks == .passing)
    }

    @Test func aPageThatSendsRequestsWithNobodyAtTheMacReadsNothing() async throws {
        _ = folder([pull(1)])
        idle = 30

        live.touch(url(1), space: space, cause: .acted)
        try await settle()

        #expect(reads.isEmpty)
        #expect(live.asking.isEmpty)
    }

    @Test func actingAgainWithinAMinuteReadsTheFolderOnce() async throws {
        let made = folder([pull(1)])
        live.touch(url(1), space: space, cause: .acted)
        try await settle()
        live.apply(.items([pull(1)], nil), to: made.id, now: Date().addingTimeInterval(-600))

        live.touch(url(1), space: space, cause: .acted, now: Date().addingTimeInterval(10))
        try await settle()

        #expect(reads == [made.id])
    }

    @Test func comingBackWithNoWindowOnScreenWaitsForOne() async throws {
        let old = folder([pull(1)], read: Date().addingTimeInterval(-90))
        active = false
        live.wentAway(LiveFolders.awayFromApp)
        _ = live.tick()
        live.looking = { [] }
        active = true

        let hidden = live.tick()
        let shown = space
        live.looking = { [shown] }
        let seen = live.tick()
        try await settle()

        #expect(hidden.isEmpty)
        #expect(seen == [old.id])
    }
}
