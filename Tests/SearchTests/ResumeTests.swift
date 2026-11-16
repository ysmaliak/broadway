import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
struct ResumeTests {
    private let page = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func spot(_ time: Double, duration: Double = 634.6, url: String? = nil, score: Double = 1000, seen: TimeInterval = 0) -> VideoSpot {
        VideoSpot(url: url ?? page, time: time, duration: duration, src: "blob:https://www.youtube.com/x", score: score,
                  seen: start.addingTimeInterval(seen))
    }

    private func seek(_ saved: VideoSpot?, duration: Double = 634.6, current: Double = 0, after: TimeInterval = 2, page: String? = nil) -> Double? {
        Resume.seek(saved: saved, armedAt: start, page: page ?? self.page, duration: duration, current: current,
                    now: start.addingTimeInterval(after))
    }

    @Test func aReloadedVideoGoesBackToWhereItWas() {
        let saved = spot(84.6)

        let to = seek(saved)

        #expect(to == 84.6)
    }

    @Test func aDurationWithinASecondIsTheSameVideo() {
        let saved = spot(84.6, duration: 634.6)

        #expect(seek(saved, duration: 635.4) == 84.6)
        #expect(seek(saved, duration: 633.7) == 84.6)
        #expect(seek(saved, duration: 636) == nil)
        #expect(seek(saved, duration: 15) == nil)
    }

    @Test func theFirstTenSecondsAndTheLastFifteenAreLeftAlone() {
        #expect(seek(spot(10)) == nil)
        #expect(seek(spot(10.5)) == 10.5)
        #expect(seek(spot(619.7)) == nil)
        #expect(seek(spot(619.4)) == 619.4)
    }

    @Test func aSiteThatResumedItselfIsNotFought() {
        let saved = spot(84.6)

        #expect(seek(saved, current: 82) == nil)
        #expect(seek(saved, current: 87.5) == nil)
        #expect(seek(saved, current: 80) == 84.6)
    }

    @Test func onlyWithinTwentySecondsOfTheLoad() {
        let saved = spot(84.6)

        #expect(seek(saved, after: 19.9) == 84.6)
        #expect(seek(saved, after: 20.5) == nil)
        #expect(seek(saved, after: -1) == nil)
    }

    @Test func anotherPageOrALiveStreamIsLeftAlone() {
        let saved = spot(84.6)

        #expect(seek(saved, page: "https://www.youtube.com/watch?v=other") == nil)
        #expect(seek(saved, duration: .infinity) == nil)
        #expect(seek(spot(84.6, duration: .infinity), duration: .infinity) == nil)
        #expect(seek(nil) == nil)
        #expect(Resume.seek(saved: saved, armedAt: nil, page: page, duration: 634.6, current: 0) == nil)
    }

    @Test func theMainVideoIsKeptOverAShortAd() {
        let main = spot(84.6, score: 634.6 * 400_000)
        let ad = spot(3, duration: 15, score: 15 * 400_000)

        let kept = Resume.merge(main, ad)
        let moved = Resume.merge(main, spot(90, score: 1))
        let elsewhere = Resume.merge(main, spot(3, duration: 15, url: "https://www.youtube.com/watch?v=other", score: 1))

        #expect(kept == main)
        #expect(moved?.time == 90)
        #expect(elsewhere?.duration == 15)
        #expect(Resume.merge(main, spot(5, duration: .infinity)) == main)
    }

    @Test func aSpotNotHeardFromForFifteenSecondsGivesWay() {
        let left = spot(300, score: 634.6 * 400_000, seen: 0)
        let next = spot(4, duration: 200, score: 200 * 400_000, seen: 3)
        let later = spot(20, duration: 200, score: 200 * 400_000, seen: 16)

        let soon = Resume.merge(left, next)
        let after = Resume.merge(soon, later)

        #expect(soon == left)
        #expect(after == later)
    }

    @Test func aPlayerThatLoadsAnotherVideoReplacesItsSpot() {
        let left = spot(300, score: 634.6 * 400_000, seen: 0)
        let next = spot(4, duration: 200, score: 200 * 400_000, seen: 3)

        let kept = Resume.merge(left, next)
        let replaced = Resume.merge(left, next, replaced: true)

        #expect(kept == left)
        #expect(replaced == next)
    }

    @Test func thePageAddressIgnoresTheFragment() {
        #expect(VideoSpot.page(URL(string: "https://example.com/v?id=1#chapter"))! == "https://example.com/v?id=1")
        #expect(VideoSpot.page(URL(string: "about:blank")) == nil)
    }

    @Test @MainActor func aTabSeeksOnceAfterAReload() {
        let tab = Tab()
        tab.videoSpot = spot(84.6)
        tab.armResume(for: URL(string: page))

        let ad = tab.resumeAnswer(page: page, duration: 15, current: 0)
        let first = tab.resumeAnswer(page: page, duration: 634.6, current: 0)
        let second = tab.resumeAnswer(page: page, duration: 634.6, current: 0)

        #expect(ad == nil)
        #expect(first == 84.6)
        #expect(second == nil)
    }

    @Test @MainActor func aTabNotReloadedNeverSeeks() {
        let tab = Tab()
        tab.videoSpot = spot(84.6)
        tab.armResume(for: URL(string: "https://www.youtube.com/watch?v=other"))

        let answer = tab.resumeAnswer(page: page, duration: 634.6, current: 0)

        #expect(answer == nil)
    }

    @Test @MainActor func aSiteThatResumedItselfUsesUpTheTurn() {
        let tab = Tab()
        tab.videoSpot = spot(84.6)
        tab.armResume(for: URL(string: page))

        let resumed = tab.resumeAnswer(page: page, duration: 634.6, current: 84)
        let later = tab.resumeAnswer(page: page, duration: 634.6, current: 0)

        #expect(resumed == nil)
        #expect(later == nil)
    }

    @Test func theSavedSessionKeepsTheSpotAndOldOnesStillRead() throws {
        let entry = Session.Entry(url: page, title: "Video", video: spot(84.6))
        let old = Data(#"{"url":"https://example.com","title":"Old"}"#.utf8)

        let read = try JSONDecoder().decode(Session.Entry.self, from: JSONEncoder().encode(entry))
        let older = try JSONDecoder().decode(Session.Entry.self, from: old)

        #expect(read.video == spot(84.6))
        #expect(older.video == nil)
    }
}
