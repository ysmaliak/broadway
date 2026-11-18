import Foundation
import Testing
@testable import Search

struct LivePaceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func folder(read: Date?, space: UUID = UUID(), paused: Bool = false) -> LiveFolder {
        LiveFolder(space: space, name: "PRs", source: .pullRequests, paused: paused, read: read)
    }

    @Test func aPersonAtTheMacGetsTheirIntervalWhicheverSpaceOrAppIsInFront() {
        let here = LiveMoment(active: true, away: 10, idle: 10)
        let elsewhere = LiveMoment(active: false, away: 40 * 60, idle: 10)

        for every in LiveEvery.allCases {
            #expect(LivePace.interval(here, every: every.interval) == every.interval)
            #expect(LivePace.interval(elsewhere, every: every.interval) == every.interval)
        }
        #expect(LivePace.interval(here) == 300.0)
        #expect(LiveEvery.allCases.map(\.interval) == [60, 300, 900, 1800, 3600])
        #expect(LiveEvery.allCases.map(\.title) == ["Every minute", "Every 5 minutes", "Every 15 minutes", "Every 30 minutes", "Every hour"])
    }

    @Test func anInstallationWithNoStoredIntervalReadsAsFiveMinutes() {
        let settings = UserDefaults(suiteName: "live-pace-tests-\(UUID().uuidString)")!

        #expect(LiveEvery.stored(settings.integer(forKey: LiveEvery.key)) == .five)
        #expect(LiveEvery.stored(7) == .five)
        #expect(LiveEvery.stored(30) == .half)
        #expect(LiveEvery.usual.interval == 300)
    }

    @Test func aFolderInASpaceNobodyLooksAtKeepsTheSameInterval() {
        let shown = UUID()
        let seen = folder(read: now.addingTimeInterval(-6 * 60), space: shown)
        let unseen = folder(read: now.addingTimeInterval(-6 * 60))
        let recent = folder(read: now.addingTimeInterval(-2 * 60))
        let here = LiveMoment(active: true, away: 0, idle: 0)

        let five = LivePace.wanted([seen, unseen, recent], moment: here, looked: [shown], returned: false, now: now)
        let quarter = LivePace.wanted([seen, unseen, recent], moment: here, looked: [shown], returned: false, now: now, every: 900)
        let minute = LivePace.wanted([seen, unseen, recent], moment: here, looked: [shown], returned: false, now: now, every: 60)

        #expect(five == [seen.id, unseen.id])
        #expect(quarter.isEmpty)
        #expect(minute == [seen.id, unseen.id, recent.id])
    }

    @Test func aFolderIsReadAtTheTickBeforeItWouldPassItsInterval() {
        let here = LiveMoment(active: true, away: 0, idle: 0)
        let ages: [TimeInterval] = [239, 241, 299]

        let due = ages.map { age in
            !LivePace.wanted([folder(read: now.addingTimeInterval(-age))], moment: here, looked: nil, returned: false, now: now).isEmpty
        }
        let minute = !LivePace.wanted([folder(read: now.addingTimeInterval(-5))], moment: here, looked: nil, returned: false, now: now, every: 60).isEmpty

        #expect(due == [false, true, true])
        #expect(minute)
        #expect(LivePace.tick == 60)
    }

    @Test func awayFromTheMacFoldersSlowDownButNeverGoFasterThanTheIntervalAndStopAfterTwoHours() {
        let inactive = LiveMoment(active: false, away: 10 * 60, idle: 10 * 60)
        let idle = LiveMoment(active: true, away: 6 * 60, idle: 6 * 60)
        let gone = LiveMoment(active: false, away: 3 * 60 * 60, idle: 3 * 60 * 60)

        #expect(LivePace.interval(inactive) == 1200.0)
        #expect(LivePace.interval(idle) == 1200.0)
        #expect(LivePace.interval(idle, every: 60) == 1200.0)
        #expect(LivePace.interval(idle, every: 3600) == 3600.0)
        #expect(LivePace.interval(gone) == nil)
    }

    @Test func comingBackReadsEveryFolderThatIsPastTheInterval() {
        let shown = UUID()
        let old = folder(read: now.addingTimeInterval(-40 * 60), space: shown)
        let elsewhere = folder(read: now.addingTimeInterval(-40 * 60))
        let away = LiveMoment(active: false, away: 40 * 60, idle: 40 * 60)
        let back = LiveMoment(active: true, away: 0, idle: 0)

        let wanted = LivePace.wanted([old, elsewhere], moment: back, looked: [shown], returned: LivePace.returned(from: away, to: back),
                                     now: now, every: 1800)

        #expect(wanted == [old.id, elsewhere.id])
    }

    @Test func aSleepingLockedOrOfflineMacNeverPolls() {
        let asleep = LiveMoment(active: true, away: 0, asleep: true)
        let offline = LiveMoment(active: true, away: 0, online: false)

        #expect(LivePace.interval(asleep) == nil)
        #expect(LivePace.interval(offline) == nil)
        #expect(!LivePace.due(nil, now: now, every: nil))
    }

    @Test func awayCountsFromWhenBroadwayWasLeft() {
        let left = now.addingTimeInterval(-900)

        let away = LivePace.away(active: false, idle: 3, resigned: left, now: now)
        let here = LivePace.away(active: true, idle: 3, resigned: left, now: now)

        #expect(away == 900)
        #expect(here == 3)
    }

    @Test func aFolderIsDueOnceItsIntervalHasPassed() {
        let every: TimeInterval = 300

        #expect(LivePace.due(nil, now: now, every: every))
        #expect(!LivePace.due(now.addingTimeInterval(-299), now: now, every: every))
        #expect(LivePace.due(now.addingTimeInterval(-300), now: now, every: every))
        #expect(LivePace.due(now.addingTimeInterval(60), now: now, every: every))
    }

    @Test func comingBackIsOnlyTheTurnFromAwayToHere() {
        let here = LiveMoment(active: true, away: 1)
        let away = LiveMoment(active: false, away: 400)
        let asleep = LiveMoment(active: true, away: 1, asleep: true)

        #expect(LivePace.returned(from: away, to: here))
        #expect(LivePace.returned(from: asleep, to: here))
        #expect(LivePace.returned(from: nil, to: here))
        #expect(!LivePace.returned(from: here, to: here))
        #expect(!LivePace.returned(from: here, to: away))
    }

    @Test func comingBackCatchesUpWhatIsOlderThanAMinuteOnScreenOnly() {
        let shown = UUID()
        let old = folder(read: now.addingTimeInterval(-90), space: shown)
        let recent = folder(read: now.addingTimeInterval(-30), space: shown)
        let elsewhere = folder(read: now.addingTimeInterval(-90))
        let paused = folder(read: nil, space: shown, paused: true)
        var failed = folder(read: now.addingTimeInterval(-5), space: shown)
        failed.state = .failed
        let here = LiveMoment(active: true, away: 0)

        let back = LivePace.wanted([old, recent, elsewhere, paused, failed], moment: here, looked: [shown], returned: true, now: now)
        let steady = LivePace.wanted([old, recent, elsewhere, paused, failed], moment: here, looked: [shown], returned: false, now: now)

        #expect(back == [old.id, failed.id])
        #expect(steady.isEmpty)
    }

    @Test func aPageEventIsReadAgainOnlyAfterItsGap() {
        let last = now.addingTimeInterval(-3)

        #expect(LiveTouch.wanted(.landed, last: nil, now: now))
        #expect(!LiveTouch.wanted(.landed, last: last, now: now))
        #expect(LiveTouch.wanted(.acted, last: last, now: now))
        #expect(!LiveTouch.wanted(.shown, last: now.addingTimeInterval(-59), now: now))
        #expect(LiveTouch.wanted(.shown, last: now.addingTimeInterval(-61), now: now))
    }

    @Test func aFreshReadKeepsTheRowsListAndArrival() {
        let arrived = now.addingTimeInterval(-500)
        var row = LiveItem(key: "https://github.com/acme/rocket/pull/1", title: "Old", label: "To review", checks: .pending,
                           arrived: arrived, list: .reviewRequests, draft: true)
        row.opened = arrived
        let fresh = LiveItem(key: row.key, title: "New", label: PullState.approved, checks: .passing, updated: now,
                             branch: LiveBranch(repository: "acme/rocket", base: "main", head: "x"))

        let patched = LiveTouch.patched(row, with: fresh, in: .pullRequests)

        #expect(patched.title == "New")
        #expect(patched.label == "To review")
        #expect(patched.checks == .passing)
        #expect(patched.draft == nil)
        #expect(patched.list == .reviewRequests)
        #expect(patched.arrived == arrived)
        #expect(patched.opened == arrived)
        #expect(patched.branch?.head == "x")
    }

    @Test func aLinearInboxRowKeepsItsNoticeWord() {
        let row = LiveItem(key: "https://linear.app/acme/issue/ABC-1/x", title: "Old", label: "Mention", author: "ABC-1")
        let fresh = LiveItem(key: row.key, title: "New", label: "Done", author: "ABC-1")

        let inbox = LiveTouch.patched(row, with: fresh, in: .linear(.inbox, workspace: "acme"))
        let mine = LiveTouch.patched(row, with: fresh, in: .linear(.assigned, workspace: "acme"))

        #expect(inbox.label == "Mention")
        #expect(inbox.title == "New")
        #expect(mine.label == "Done")
    }

    @Test func aConditionalReadReplaysTheKeptAnswerOnNotModified() throws {
        var store = LiveConditional()
        var request = URLRequest(url: try #require(URL(string: "https://github.com/notifications?page=1")))
        request.setValue("user_session=one", forHTTPHeaderField: "Cookie")
        let body = Data("[1]".utf8)
        _ = store.answered(request, data: body, status: 200, tag: "W/\"abc\"", modified: nil)

        let asked = store.asking(request)
        let replayed = store.answered(request, data: Data(), status: 304, tag: nil, modified: nil)

        #expect(asked.value(forHTTPHeaderField: "If-None-Match") == "W/\"abc\"")
        #expect(replayed.0 == body)
        #expect(replayed.1 == 200)
    }

    @Test func aConditionalReadIsKeptPerSignInAndNeverForPosts() throws {
        var store = LiveConditional()
        let url = try #require(URL(string: "https://github.com/notifications"))
        var mine = URLRequest(url: url)
        mine.setValue("user_session=one", forHTTPHeaderField: "Cookie")
        var theirs = URLRequest(url: url)
        theirs.setValue("user_session=two", forHTTPHeaderField: "Cookie")
        var post = URLRequest(url: url)
        post.httpMethod = "POST"
        _ = store.answered(mine, data: Data("x".utf8), status: 200, tag: "\"t\"", modified: nil)
        _ = store.answered(post, data: Data("y".utf8), status: 200, tag: "\"p\"", modified: nil)

        let other = store.asking(theirs)
        let posted = store.asking(post)

        #expect(other.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(posted.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(store.kept.count == 1)
    }

    @Test func oneRequestAsksForEveryTouchedLinearIssue() throws {
        let keys = ["https://linear.app/acme/issue/ABC-12/ship-it", "https://github.com/acme/rocket/pull/7"]
        let answer = """
        {"data":{"viewer":{"id":"u1"},"i0":{"identifier":"ABC-12","title":"Ship it","url":"https://linear.app/acme/issue/ABC-12/ship-it",
          "updatedAt":"2026-11-12T10:00:00Z","state":{"name":"In Review","type":"started","position":2},
          "comments":{"nodes":[]},"history":{"nodes":[]}}}}
        """

        let body = String(decoding: LinearAPI.pointBody(keys), as: UTF8.self)
        let items = try #require(LinearAPI.pointItems(from: Data(answer.utf8), keys: keys))

        #expect(body.contains("i0: issue(id: $i0)"))
        #expect(body.contains("\"i0\":\"ABC-12\""))
        #expect(!body.contains("i1:"))
        #expect(items.first?.label == "In Review")
    }

    @Test func inputAfterALockMeansTheMacIsInUseAgain() {
        let locked = now.addingTimeInterval(-600)

        #expect(!LivePace.woke(since: locked, idle: 601, now: now))
        #expect(!LivePace.woke(since: now, idle: 0, now: now))
        #expect(LivePace.woke(since: locked, idle: 5, now: now))
    }

    @Test func anActionReadsItsFolderAtMostOnceAMinute() {
        #expect(LiveTouch.rereads(last: nil, now: now))
        #expect(!LiveTouch.rereads(last: now.addingTimeInterval(-59), now: now))
        #expect(LiveTouch.rereads(last: now.addingTimeInterval(-60), now: now))
    }
}
