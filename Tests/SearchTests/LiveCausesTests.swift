import Foundation
import Testing
@testable import Search

@MainActor
struct LiveCausesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func folder(_ items: [LiveItem] = [LiveItem(key: "https://github.com/acme/rocket/pull/1", title: "One")]) -> LiveFolder {
        var made = LiveFolder(space: UUID(), name: "PRs", source: .pullRequests)
        made.items = items
        made.state = .fine
        made.noticing = true
        made.good = now.addingTimeInterval(-60)
        made.read = now.addingTimeInterval(-60)
        return made
    }

    @Test func tooManyRequestsIsALimitAndNeverASignOut() {
        #expect(LiveLimit.miss(status: 429, headers: [:], page: false) == LiveMiss(cause: .limited))
        #expect(LiveLimit.miss(status: 403, headers: ["Retry-After": "120"], page: false) == LiveMiss(cause: .limited, wait: 120))
        #expect(LiveLimit.miss(status: 403, headers: ["X-RateLimit-Remaining": "0"], page: false)?.cause == .limited)
        #expect(LiveLimit.miss(status: 403, headers: [:], page: true)?.cause == .limited)
        #expect(LiveLimit.miss(status: 403, headers: [:], page: false) == nil)
        #expect(LiveLimit.miss(status: 403, headers: ["X-RateLimit-Remaining": "12"], page: false) == nil)
        #expect(LiveLimit.miss(status: 200, headers: [:], page: false) == nil)
    }

    @Test func aRetryAfterDateIsReadAsTheWaitUntilThen() {
        let wait = LiveLimit.retryAfter(["retry-after": "Fri, 15 Jan 2027 08:05:00 GMT"], now: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(wait == 300)
    }

    @Test func aLimitWithoutAWaitDoublesUpToAnHour() {
        var waits: [TimeInterval] = []
        var previous: TimeInterval?
        for _ in 0..<5 {
            let wait = LiveLimit.wait(LiveMiss(cause: .limited), previous: previous)
            waits.append(wait)
            previous = wait
        }

        #expect(waits == [600, 1200, 2400, 3600, 3600])
        #expect(LiveLimit.wait(LiveMiss(cause: .limited, wait: 90), previous: 2400) == 90)
    }

    @Test func aLimitedFolderIsNotReadBeforeItsWaitIsOver() {
        let limited = LiveTrust.after(folder(), .missed(LiveMiss(cause: .limited, wait: 600)), now: now)
        let moment = LiveMoment(active: true, away: 0)

        let soon = LivePace.wanted([limited], moment: moment, looked: nil, returned: true, now: now.addingTimeInterval(300))
        let later = LivePace.wanted([limited], moment: moment, looked: nil, returned: false, now: now.addingTimeInterval(601))

        #expect(limited.limitedUntil == now.addingTimeInterval(600))
        #expect(soon.isEmpty)
        #expect(later == [limited.id])
    }

    @Test func aGoodReadEndsTheLimitAndItsDoubling() {
        let limited = LiveTrust.after(folder(), .missed(LiveMiss(cause: .limited)), now: now)
        let again = LiveTrust.after(limited, .missed(LiveMiss(cause: .limited)), now: now.addingTimeInterval(700))
        let good = LiveTrust.after(again, .items([LiveItem(key: "https://github.com/acme/rocket/pull/1", title: "One")], nil),
                                   now: now.addingTimeInterval(2000))

        #expect(limited.limitWait == 600)
        #expect(again.limitWait == 1200)
        #expect(good.limitWait == nil && good.limitedUntil == nil && good.cause == nil)
    }

    @Test func aFailureWhileTheMacIsOfflineSaysOffline() {
        let after = LiveTrust.after(folder(), .failed, now: now, online: false)

        #expect(after.why == .offline)
        #expect(after.status == "Offline")
        #expect(LiveWords.failure(after, now: now) == "You're offline")
    }

    @Test func eachCauseHasItsOwnWords() {
        let limited = LiveTrust.after(folder(), .missed(LiveMiss(cause: .limited, wait: 600)), now: now)
        let unread = LiveTrust.after(folder(), .missed(LiveMiss(cause: .unread)), now: now)
        let other = LiveTrust.after(folder(), .failed, now: now)

        #expect(LiveWords.failure(limited, now: now) == "GitHub is limiting requests. Trying again in 10 minutes.")
        #expect(LiveWords.failure(limited, now: now.addingTimeInterval(570)) == "GitHub is limiting requests. Trying again in 1 minute.")
        #expect(LiveWords.failure(unread, now: now) == "Couldn't read GitHub")
        #expect(LiveWords.failure(other, now: now) == "Couldn't read GitHub")
        #expect([limited.status, unread.status, other.status] == ["Limited", "Can't read", "Can't read"])
    }

    @Test func aFailedReadKeepsTheLastGoodDateAndMovesTheLastTry() {
        let before = folder()

        let after = LiveTrust.after(before, .failed, now: now)

        #expect(after.good == before.good)
        #expect(after.read == now)
    }

    @Test func settingsShowsTheLastGoodReadAndWhyTheLastTryFailed() {
        var failed = LiveTrust.after(folder(), .failed, now: now)
        failed.good = now.addingTimeInterval(-7_200)

        #expect(LiveFolderRows.read(failed, reading: false, now: now) == "Read 2 hours ago. Couldn't read GitHub just now.")
        #expect(!LiveFolderRows.read(failed, reading: false, now: now).contains(";"))
    }

    @Test func aFolderSaysItsAgeOnlyOnceItIsOld() {
        var fresh = folder()
        fresh.good = now.addingTimeInterval(-300)
        var old = folder()
        old.good = now.addingTimeInterval(-7_200)
        var paused = old
        paused.paused = true

        #expect(LiveAge.words(fresh, at: now) == nil)
        #expect(LiveAge.words(old, at: now) == "Read 2 hours ago")
        #expect(LiveAge.words(paused, at: now) == nil)
        #expect(LiveAge.words(LiveTrust.after(old, .items(old.items, nil), now: now), at: now) == nil)
    }

    @Test func anOldSavedFolderTakesItsLastReadAsItsLastGoodRead() {
        var saved = folder()
        saved.good = nil

        let woken = LiveFolders.woken([saved])

        #expect(woken.first?.good == saved.read)
    }

    @Test func linearSayingItIsLimitedIsALimit() {
        let data = Data(#"{"errors":[{"message":"Rate limit exceeded","extensions":{"code":"RATELIMITED"}}]}"#.utf8)

        #expect(LinearAPI.limited(data))
        #expect(!LinearAPI.limited(Data(#"{"errors":[{"message":"Not authenticated"}]}"#.utf8)))
    }

    @Test func aLimitedNoteIsTwoShortLines() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let lines = LiveWords.limitedLines("GitHub", until: now.addingTimeInterval(600), now: now)

        #expect(lines.0 == "Limited by GitHub")
        #expect(lines.1 == "Trying again in 10 minutes")
        #expect(LiveWords.limitedLines("Linear", until: nil, now: now) == ("Limited by Linear", "Trying again in a moment"))
    }

    @Test func statusesLeftOutAreNamedOrCounted() {
        #expect(LiveWords.leftOut([.backlog]) == "Backlog left out")
        #expect(LiveWords.leftOut([.triage, .backlog, .unstarted]) == "3 statuses left out")
        #expect(LiveSource.linear(.assigned).nothingWording == "No issues")
    }
}
