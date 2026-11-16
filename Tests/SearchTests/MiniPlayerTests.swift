import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct MiniPlayerTests {
    private let a = UUID(), b = UUID(), c = UUID()

    private func report(picture: Bool = false, sound: Bool = false, undecided: Bool = false, playing: Bool? = nil,
                        title: String = "") -> MiniReport {
        var made = MiniReport(picture: picture, sound: sound, undecided: undecided)
        if let playing { made.reading = MiniReport.Reading(playing: playing, time: 10, duration: 200) }
        made.session.title = title
        return made
    }

    @Test func audioElementTakesTheMiniPlayer() {
        let facts = MiniFacts(noisy: true, reports: [report(sound: true, playing: true)])

        let role = MiniRule.role(facts, was: .none)

        #expect(role == .mini)
    }

    @Test func videoWithAPictureFloats() {
        let facts = MiniFacts(noisy: true, reports: [report(picture: true, playing: true)])

        let role = MiniRule.role(facts, was: .none)

        #expect(role == .float)
    }

    @Test func pictureInAFrameFloatsEvenWhenThePageHasSound() {
        let facts = MiniFacts(noisy: true, reports: [report(sound: true, playing: true), report(picture: true, playing: true)])

        let role = MiniRule.role(facts, was: .mini)

        #expect(role == .float)
    }

    @Test func soundBesideAMutedDecorativeVideoIsTheMiniPlayers() {
        let facts = MiniFacts(noisy: true, reports: [report(picture: false, sound: true, playing: true)])

        let role = MiniRule.role(facts, was: .none)

        #expect(role == .mini)
    }

    @Test func videoWithoutMetadataYetIsUndecided() {
        let facts = MiniFacts(noisy: true, reports: [report(undecided: true, playing: true)])

        let fresh = MiniRule.role(facts, was: .none)
        let held = MiniRule.role(facts, was: .mini)

        #expect(fresh == .none)
        #expect(held == .mini)
    }

    @Test func soundNoFrameCanSeeIsTheMiniPlayersOnceItHasLasted() {
        let early = MiniFacts(noisy: true, waited: false, reports: [])
        let later = MiniFacts(noisy: true, waited: true, reports: [])

        let first = MiniRule.role(early, was: .none)
        let then = MiniRule.role(later, was: .none)

        #expect(first == .none)
        #expect(then == .mini)
    }

    @Test func aShortSoundDoesNotTakeThePlayerUntilItLasts() {
        var ding = MiniReport(sound: true)
        ding.reading = MiniReport.Reading(playing: true, time: 0.2, duration: 1)
        let early = MiniFacts(noisy: true, waited: false, reports: [ding])
        let lasted = MiniFacts(noisy: true, waited: true, reports: [ding])

        let first = MiniRule.role(early, was: .none)
        let then = MiniRule.role(lasted, was: .none)

        #expect(first == .none)
        #expect(then == .mini)
    }

    @Test func aResumingVideoWithAStaleReportWaitsForItsOwn() {
        var stale = MiniReport()
        stale.reading = MiniReport.Reading(playing: false, time: 30, duration: 600)
        let facts = MiniFacts(noisy: true, waited: false, reports: [stale])

        let role = MiniRule.role(facts, was: .float)

        #expect(role == .float)
    }

    @Test func aTabThePlayerSuspendedKeepsTheCard() {
        let facts = MiniFacts(noisy: false, held: true, reports: [])

        let role = MiniRule.role(facts, was: .mini)

        #expect(role == .mini)
    }

    @Test func pausedTrackKeepsTheMiniPlayer() {
        let facts = MiniFacts(noisy: false, reports: [report(playing: false, title: "Chapter 3")])

        let kept = MiniRule.role(facts, was: .mini)
        let never = MiniRule.role(facts, was: .none)

        #expect(kept == .mini)
        #expect(never == .none)
    }

    @Test func pageWithNothingLeftLetsGo() {
        let facts = MiniFacts(noisy: false, reports: [])

        let role = MiniRule.role(facts, was: .mini)

        #expect(role == .none)
    }

    @Test func musicGetsTracks() {
        let actions: Set<String> = ["play", "pause", "previoustrack", "nexttrack"]

        let pair = MiniRule.pair(actions: actions, duration: 240, live: false, spoken: .seconds)

        #expect(pair == .tracks)
    }

    @Test func longAudioGetsSecondsUnlessAskedForTracks() {
        let actions: Set<String> = ["previoustrack", "nexttrack", "seekto"]

        let seconds = MiniRule.pair(actions: actions, duration: 3 * 3600, live: false, spoken: .seconds)
        let tracks = MiniRule.pair(actions: actions, duration: 3 * 3600, live: false, spoken: .tracks)
        let noTracks = MiniRule.pair(actions: ["seekto"], duration: 3 * 3600, live: false, spoken: .tracks)

        #expect(seconds == .seconds)
        #expect(tracks == .tracks)
        #expect(noTracks == .seconds)
    }

    @Test func bareShortAudioGetsSecondsAndLiveGetsNothing() {
        let none: Set<String> = []

        let bare = MiniRule.pair(actions: none, duration: 90, live: false, spoken: .seconds)
        let live = MiniRule.pair(actions: none, duration: 0, live: true, spoken: .seconds)

        #expect(bare == .seconds)
        #expect(live == .none)
    }

    @Test func latestPlayWinsAndOlderPausedGoes() {
        let entries = [(id: a, playing: false, started: 1.0), (id: b, playing: true, started: 5.0), (id: c, playing: true, started: 9.0)]

        let kept = MiniRule.kept(entries)
        let chosen = MiniRule.chosen(entries.filter { kept.contains($0.id) })

        #expect(kept == [b, c])
        #expect(chosen == c)
    }

    @Test func pausedFromTheCardKeepsItUntilAnotherStarts() {
        let entries = [(id: a, playing: false, started: 7.0), (id: b, playing: true, started: 5.0)]

        let kept = MiniRule.kept(entries)
        let chosen = MiniRule.chosen(entries)
        let later = MiniRule.chosen([(id: a, playing: false, started: 7.0), (id: b, playing: true, started: 8.0)])

        #expect(kept == [a, b])
        #expect(chosen == a)
        #expect(later == b)
    }

    @Test func positionRunsAtItsRate() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let position = MiniPosition(time: 10, duration: 100, rate: 1.5, playing: true, at: start)

        let elapsed = position.elapsed(now: start.addingTimeInterval(10))

        #expect(elapsed == 25)
        #expect(position.left(now: start.addingTimeInterval(10)) == 75)
    }

    @Test func reportFromThePageIsClamped() {
        let body: [String: Any] = [
            "kind": "sound", "id": "x", "sound": true,
            "reading": ["playing": true, "time": 12, "duration": 300, "rate": 99, "live": false, "source": "audio", "why": "the one playing"],
            "session": ["title": String(repeating: "t", count: 1000), "actions": ["play", "nexttrack", "evil"], "art": "https://a/b.png"],
        ]

        let made = MiniReport.parse(body)

        #expect(made.session.title.count == MiniReport.most)
        #expect(made.session.actions == ["play", "nexttrack"])
        #expect(made.reading?.rate == 16)
        #expect(made.reading?.source == "audio")
        #expect(made.sound)
    }

    @Test func aPageTitlesPlayingMarkIsNotPartOfTheTitle() {
        let playing = "▶\u{FE0E} Minecraft - Volume Alpha | C418"
        let plain = "Chapter 7: The Long Way Round"
        let only = "▶"

        let a = MiniRule.bare(playing), b = MiniRule.bare(plain), c = MiniRule.bare(only)

        #expect(a == "Minecraft - Volume Alpha | C418")
        #expect(b == plain)
        #expect(c == only)
    }

    @Test func aMissedFloatKeepsItsFirstMomentAndRunsOut() {
        let tab = UUID(), start = Date(timeIntervalSinceReferenceDate: 0)
        let first = FloatMiss(tab: tab, quietly: true, now: start)

        let again = FloatMiss(tab: tab, quietly: true, since: first, now: start.addingTimeInterval(3))
        let other = FloatMiss(tab: UUID(), quietly: true, since: first, now: start.addingTimeInterval(3))

        #expect(again.at == start)
        #expect(other.at == start.addingTimeInterval(3))
        #expect(again.fresh(now: start.addingTimeInterval(FloatMiss.lasts - 1)))
        #expect(!again.fresh(now: start.addingTimeInterval(FloatMiss.lasts + 1)))
    }

    @Test func clockReadsHoursOnlyWhenThereAreSome() {
        let short = 75.4, long = 3725.0

        let a = MiniRule.clock(short), b = MiniRule.clock(long)

        #expect(a == "1:15")
        #expect(b == "1:02:05")
    }

    @Test func skipSymbolsFollowTheSetting() {
        let seconds = 30

        let back = MiniRule.symbol(back: true, seconds: seconds)
        let odd = MiniRule.symbol(back: false, seconds: 7)

        #expect(back == "gobackward.30")
        #expect(odd == "goforward.15")
    }

    @Test func speedStepsAreTempoStepsAndIncludeTheCurrentRate() {
        let rate = 1.3

        let steps = MiniRule.steps(around: rate)

        #expect(steps.contains(1.3))
        #expect(steps.allSatisfy { Tempo.allows($0) && abs(Tempo.rounded($0) - $0) < 0.0001 })
    }

    @Test func settingsStartOnWithFifteenSecondsAndSeconds() {
        let prefs = Preferences()

        let defaults = (prefs.miniPlayer, prefs.miniSkip, prefs.miniSpoken, prefs.miniSpeed)

        #expect(defaults.0)
        #expect(defaults.1 == 15)
        #expect(defaults.2 == .seconds)
        #expect(defaults.3)
    }

    @Test func settingsAreReadableAndWritableByTheCommand() {
        let prefs = Preferences()
        let before = (prefs.miniSkip, prefs.miniSpoken)
        defer { prefs.miniSkip = before.0; prefs.miniSpoken = before.1 }

        let wrote = SettingsIndex.apply(Preferences.miniSkipKey, 30, to: prefs)
        let refused = SettingsIndex.apply(Preferences.miniSkipKey, 20, to: prefs)
        let spoken = SettingsIndex.apply(Preferences.miniSpokenKey, "tracks", to: prefs)

        #expect(wrote && !refused && spoken)
        #expect(prefs.miniSkip == 30)
        #expect(prefs.miniSpoken == .tracks)
        #expect(SettingsIndex.values(prefs)[Preferences.miniSkipKey] as? Int == 30)
    }
}
