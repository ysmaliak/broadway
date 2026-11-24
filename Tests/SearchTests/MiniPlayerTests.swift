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

    @Test func soundWithNothingToPlayOrPauseNeverTakesTheCard() {
        let early = MiniFacts(noisy: true, waited: false, reports: [])
        let later = MiniFacts(noisy: true, waited: true, reports: [])

        let first = MiniRule.role(early, was: .none)
        let then = MiniRule.role(later, was: .none)
        let held = MiniRule.role(later, was: .mini)

        #expect(first == .none)
        #expect(then == .none)
        #expect(held == .none)
    }

    @Test func webAudioThatDeclaresItselfStillTakesTheCardOnceItHasLasted() {
        var declared = MiniReport()
        declared.session.title = "Night Radio"
        declared.session.actions = ["play", "pause"]
        let facts = MiniFacts(noisy: true, waited: true, reports: [declared])

        let role = MiniRule.role(facts, was: .none)

        #expect(role == .mini)
    }

    private func chime(playing: Bool = true, duration: Double = 2, time: Double = 0.4) -> MiniReport {
        var made = MiniReport(sound: playing)
        made.reading = MiniReport.Reading(playing: playing, time: time, duration: duration, source: "audio")
        made.media = [MiniReport.Media(kind: "audio", duration: duration, time: time, paused: !playing, chosen: true)]
        return made
    }

    @Test func aShortSoundNeverTakesTheCardHoweverLongTheTabSounds() {
        var ding = MiniReport(sound: true)
        ding.reading = MiniReport.Reading(playing: true, time: 0.2, duration: 1)
        let early = MiniFacts(noisy: true, waited: false, reports: [ding])
        let lasted = MiniFacts(noisy: true, waited: true, reports: [ding])

        let first = MiniRule.role(early, was: .none)
        let then = MiniRule.role(lasted, was: .none)

        #expect(first == .none)
        #expect(then == .none)
    }

    @Test func aChimeUnderFiveSecondsNeverBringsTheCardUp() {
        let playing = MiniFacts(noisy: true, waited: true, reports: [chime(duration: 4.9)])
        let ended = MiniFacts(noisy: false, reports: [chime(playing: false, duration: 4.9, time: 4.9)])

        #expect(MiniRule.role(playing, was: .none) == .none)
        #expect(MiniRule.role(ended, was: .none) == .none)
    }

    @Test func aChimeNeverHoldsTheCardPlayingPausedOrEnded() {
        let playing = MiniFacts(noisy: true, reports: [chime()])
        let paused = MiniFacts(noisy: false, reports: [chime(playing: false, time: 1)])
        let ended = MiniFacts(noisy: false, reports: [chime(playing: false, time: 2)])

        #expect(MiniRule.role(playing, was: .mini) == .none)
        #expect(MiniRule.role(paused, was: .mini) == .none)
        #expect(MiniRule.role(ended, was: .mini) == .none)
    }

    @Test func aChimeOnAPageThatDeclaresMediaStillNeverBringsTheCardUp() {
        var report = chime()
        report.session.title = "Meeting"
        let facts = MiniFacts(noisy: true, waited: true, reports: [report])

        #expect(MiniRule.role(facts, was: .none) == .none)
        #expect(MiniRule.role(facts, was: .mini) == .none)
    }

    @Test func fiveSecondsIsLongEnough() {
        var report = chime(duration: 5)
        report.session.title = "Five"
        let facts = MiniFacts(noisy: true, reports: [report])

        #expect(MiniRule.role(facts, was: .none) == .mini)
    }

    @Test func aSoundOfUnknownLengthIsTreatedAsLongUntilItTurnsOutShort() {
        var unknown = chime(duration: 0)
        unknown.session.title = "Loading"
        let known = { var made = unknown; made.reading?.duration = 2; made.media[0].duration = 2; return made }()

        let before = MiniRule.role(MiniFacts(noisy: true, waited: true, reports: [unknown]), was: .none)
        let after = MiniRule.role(MiniFacts(noisy: true, waited: true, reports: [known]), was: before)

        #expect(before == .mini)
        #expect(after == .none)
    }

    @Test func anEndlessStreamIsTreatedAsLong() {
        var stream = MiniReport(sound: true)
        stream.reading = MiniReport.Reading(playing: true, time: 40, duration: 0, live: true, source: "audio")
        stream.media = [MiniReport.Media(kind: "audio", duration: -1, time: 40, paused: false, chosen: true)]
        let facts = MiniFacts(noisy: true, reports: [stream])

        #expect(MiniRule.role(facts, was: .none) == .mini)
    }

    @Test func aCallsLeavingChimeDoesNotKeepTheCardTheStreamHeld() {
        let facts = MiniFacts(noisy: false, reports: [chime(playing: false, time: 2)])

        let role = MiniRule.role(facts, was: .mini)

        #expect(role == .none)
    }

    @Test func aMeetingPageNeverGetsTheCardForItsStreamOrItsChimes() {
        var stream = MiniReport(sound: true)
        stream.reading = MiniReport.Reading(playing: true, time: 40, duration: 0, live: true, source: "audio")
        stream.media = [MiniReport.Media(kind: "audio", duration: -1, time: 40, paused: false, chosen: true)]
        var left = stream
        left.sound = false
        left.reading?.playing = false
        left.media[0].paused = true
        let during = MiniFacts(noisy: true, waited: true, call: true, reports: [stream])
        let after = MiniFacts(noisy: false, call: true, reports: [left])
        let radio = MiniFacts(noisy: false, call: false, reports: [left])

        #expect(MiniRule.role(during, was: .none) == .none)
        #expect(MiniRule.role(during, was: .mini) == .none)
        #expect(MiniRule.role(after, was: .mini) == .none)
        #expect(MiniRule.role(radio, was: .mini) == .mini)
    }

    @Test func aChimeBesideAPausedTrackLeavesTheTrackItsCard() {
        var report = MiniReport(sound: true)
        report.reading = MiniReport.Reading(playing: false, time: 60, duration: 200, source: "audio")
        report.media = [MiniReport.Media(kind: "audio", duration: 200, time: 60, paused: true, chosen: true),
                        MiniReport.Media(kind: "audio", duration: 2, time: 0.5, paused: false)]
        let facts = MiniFacts(noisy: true, waited: true, reports: [report])

        #expect(MiniRule.role(facts, was: .none) == .none)
        #expect(MiniRule.role(facts, was: .mini) == .mini)
    }

    @Test func aLongTrackBesideAChimeKeepsTheCard() {
        var report = MiniReport(sound: true)
        report.reading = MiniReport.Reading(playing: true, time: 60, duration: 200, source: "audio")
        report.media = [MiniReport.Media(kind: "audio", duration: 200, time: 60, paused: false, chosen: true),
                        MiniReport.Media(kind: "audio", duration: 2, time: 0.5, paused: false)]
        let facts = MiniFacts(noisy: true, reports: [report])

        #expect(MiniRule.role(facts, was: .none) == .mini)
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

    private func film(paused: Bool = true, muted: Bool = false, chosen: Bool = true, picture: Bool = true) -> MiniReport.Media {
        MiniReport.Media(kind: "video", duration: 4914, time: 1800, paused: paused, muted: muted, chosen: chosen, picture: picture)
    }

    private func watched(_ media: [MiniReport.Media], sound: Bool = false, playing: Bool = false) -> MiniReport {
        var made = report(sound: sound, playing: playing, title: "A Long Drive")
        made.media = media
        return made
    }

    @Test func aPausedVideoWithAPictureLosesTheCardItHeld() {
        let facts = MiniFacts(noisy: false, reports: [watched([film()])])

        let role = MiniRule.role(facts, was: .mini)

        #expect(role == .none)
    }

    @Test func aVideoWhoseBoxFailsTheFloatTestNeverTakesTheCard() {
        let fromMedia = MiniFacts(noisy: true, reports: [watched([film(paused: false)], sound: true, playing: true)])
        var hidden = MiniReport(unseen: true)
        hidden.reading = MiniReport.Reading(playing: true, time: 1800, duration: 4914, rate: 1.5)
        hidden.session.title = "A Long Drive"
        let fromRelay = MiniFacts(noisy: true, reports: [hidden])

        #expect(MiniRule.role(fromMedia, was: .none) == .none)
        #expect(MiniRule.role(fromMedia, was: .mini) == .none)
        #expect(MiniRule.role(fromRelay, was: .none) == .none)
        #expect(MiniRule.role(fromRelay, was: .float) == .float)
    }

    @Test func soundWithNothingReportedNeverGivesAVideoTabTheCard() {
        let facts = MiniFacts(noisy: true, waited: true, reports: [watched([film(paused: false)])])

        let role = MiniRule.role(facts, was: .none)

        #expect(role == .none)
    }

    @Test func aHeldVideoTabLetsTheCardGo() {
        let facts = MiniFacts(noisy: false, held: true, reports: [watched([film()])])

        let role = MiniRule.role(facts, was: .mini)

        #expect(role == .none)
    }

    @Test func aStillUndecidedVideoKeepsNoCardOnceItsPictureIsKnown() {
        var report = watched([film(paused: false)])
        report.undecided = true
        let facts = MiniFacts(noisy: true, reports: [report])

        let role = MiniRule.role(facts, was: .mini)

        #expect(role == .none)
    }

    @Test func aVideoWithAPictureThatCanFloatStillFloats() {
        var report = watched([film(paused: false)], playing: true)
        report.picture = true
        let facts = MiniFacts(noisy: true, reports: [report])

        let role = MiniRule.role(facts, was: .mini)

        #expect(role == .float)
    }

    @Test func aVideoElementWithNoPictureStaysTheCards() {
        let playing = MiniFacts(noisy: true, reports: [watched([film(paused: false, picture: false)], sound: true, playing: true)])
        let paused = MiniFacts(noisy: false, reports: [watched([film(picture: false)])])

        #expect(MiniRule.role(playing, was: .none) == .mini)
        #expect(MiniRule.role(paused, was: .mini) == .mini)
    }

    @Test func aMutedDecorativeVideoBesideTheSoundLeavesItTheCard() {
        let tone = MiniReport.Media(kind: "audio", duration: 200, time: 10, paused: false, chosen: true)
        let facts = MiniFacts(noisy: true, reports: [watched([film(paused: false, muted: true, chosen: false), tone], sound: true, playing: true)])

        let role = MiniRule.role(facts, was: .none)

        #expect(role == .mini)
    }

    @Test func aPausedVideoBesideTheSoundThatIsNotChosenLeavesItTheCard() {
        let tone = MiniReport.Media(kind: "audio", duration: 200, time: 10, paused: false, chosen: true)
        let facts = MiniFacts(noisy: true, reports: [watched([film(chosen: false), tone], sound: true, playing: true)])

        let role = MiniRule.role(facts, was: .mini)

        #expect(role == .mini)
    }

    @Test func aMutedVideoInAnotherFrameLeavesTheSoundTheCard() {
        let tone = MiniReport.Media(kind: "audio", duration: 200, time: 10, paused: false, chosen: true)
        let sound = watched([tone], sound: true, playing: true)
        let advert = watched([film(paused: false, muted: true)], playing: true)
        let facts = MiniFacts(noisy: true, reports: [sound, advert])

        let role = MiniRule.role(facts, was: .none)

        #expect(role == .mini)
    }

    @Test func aPausedVideoInAnotherFrameLeavesTheSoundTheCard() {
        let tone = MiniReport.Media(kind: "audio", duration: 200, time: 10, paused: false, chosen: true)
        let sound = watched([tone], sound: true, playing: true)
        let embed = watched([film()])
        let facts = MiniFacts(noisy: true, reports: [sound, embed])

        let role = MiniRule.role(facts, was: .mini)

        #expect(role == .mini)
    }

    @Test func aPausedTrackInAnotherFrameKeepsTheCardBesideAPausedVideo() {
        let tone = MiniReport.Media(kind: "audio", duration: 200, time: 10, paused: true, chosen: true)
        let track = watched([tone])
        let embed = watched([film()])
        let facts = MiniFacts(noisy: false, reports: [track, embed])

        let role = MiniRule.role(facts, was: .mini)

        #expect(role == .mini)
    }

    @Test func aMutedVideoAloneInAFrameBesideTheVideoTabStillGivesNoCard() {
        let video = watched([film()])
        let advert = watched([film(paused: false, muted: true)], playing: true)
        let facts = MiniFacts(noisy: false, reports: [video, advert])

        let role = MiniRule.role(facts, was: .mini)

        #expect(role == .none)
    }

    @Test func eachElementSaysWhetherItHasAPicture() {
        let body: [String: Any] = ["media": [["kind": "video", "duration": 4914, "time": 1800, "paused": true, "chosen": true, "picture": true],
                                             ["kind": "video", "duration": 200, "picture": false]], "unseen": true]

        let made = MiniReport.parse(body)

        #expect(made.media.map(\.picture) == [true, false])
        #expect(made.unseen)
        #expect(made.video)
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
