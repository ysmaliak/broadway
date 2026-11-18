import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FloatRevealTests {
    @Test func controlsStayAwayUntilThePointerComes() {
        let reveal = FloatReveal()

        let shown = reveal.shown

        #expect(!shown)
        #expect(reveal.deadline == nil)
    }

    @Test func thePointerComingInShowsThemAtOnce() {
        var reveal = FloatReveal()

        reveal.enter(at: 10)

        #expect(reveal.shown)
    }

    @Test func leavingKeepsThemForAMomentThenTheyGo() {
        var reveal = FloatReveal()
        reveal.enter(at: 10)

        reveal.exit(at: 11)
        reveal.tick(at: 11 + FloatReveal.linger / 2)
        let midway = reveal.shown
        reveal.tick(at: 11 + FloatReveal.linger)

        #expect(midway)
        #expect(!reveal.shown)
        #expect(reveal.deadline == nil)
    }

    @Test func comingBackBeforeTheyGoKeepsThem() {
        var reveal = FloatReveal()
        reveal.enter(at: 10)
        reveal.exit(at: 11)

        reveal.enter(at: 11.2)
        reveal.tick(at: 11 + FloatReveal.linger + 0.1)

        #expect(reveal.shown)
    }

    @Test func aPointerRestingOverThePictureLetsThemGo() {
        var reveal = FloatReveal()
        reveal.enter(at: 10)

        reveal.tick(at: 10 + FloatReveal.idle)

        #expect(!reveal.shown)
    }

    @Test func movingAgainBringsThemBack() {
        var reveal = FloatReveal()
        reveal.enter(at: 10)
        reveal.tick(at: 10 + FloatReveal.idle)

        reveal.move(at: 20)

        #expect(reveal.shown)
        #expect(reveal.deadline == (20 + FloatReveal.idle))
    }

    @Test func aPointerOverAControlKeepsThemUp() {
        var reveal = FloatReveal()
        reveal.enter(at: 10)

        reveal.move(at: 11, overControl: true)
        reveal.tick(at: 60)

        #expect(reveal.shown)
        #expect(reveal.deadline == nil)
    }

    @Test func scrubbingHoldsThemEvenOutsideTheWindow() {
        var reveal = FloatReveal()
        reveal.enter(at: 10)
        reveal.hold(at: 10.5)

        reveal.exit(at: 11)
        reveal.tick(at: 30)
        let held = reveal.shown
        reveal.release(at: 31)
        reveal.tick(at: 31 + FloatReveal.linger)

        #expect(held)
        #expect(!reveal.shown)
    }

    @Test func aMoveWithoutAnEntryCountsAsOne() {
        var reveal = FloatReveal()

        reveal.move(at: 5)

        #expect(reveal.shown)
        #expect(reveal.inside)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FloatPlayTests {
    @Test func aPressTurnsTheGlyphAtOnce() {
        var play = FloatPlay()

        play.press(at: 1)

        #expect(!play.playing)
    }

    @Test func aPollFromBeforeThePressTookIsIgnored() {
        var play = FloatPlay()
        play.press(at: 1)

        play.polled(true, at: 1.2)

        #expect(!play.playing)
    }

    @Test func thePagesAnswerToThePressWins() {
        var play = FloatPlay()
        play.press(at: 1)

        play.answered(true)

        #expect(play.playing)
    }

    @Test func aPollRightAfterThePagesAnswerDoesNotUndoIt() {
        var play = FloatPlay()
        play.press(at: 1)
        play.answered(false)

        play.polled(true, at: 1.3)

        #expect(!play.playing)
    }

    @Test func pollsAreBelievedOnceThePressHasSettled() {
        var play = FloatPlay()
        play.press(at: 1)

        play.polled(true, at: 1 + FloatPlay.trust + 0.01)

        #expect(play.playing)
    }

    @Test func thePageStoppingOnItsOwnShows() {
        var play = FloatPlay()

        play.polled(false, at: 5)

        #expect(!play.playing)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FloatTimeTests {
    @Test func anUnknownTimelineSpanCannotBeScrubbed() {
        var time = FloatTime()

        time.polled(through: 0, duration: .infinity, at: 1)

        #expect(!time.seekable)
    }

    @Test func scrubbingShowsWhereTheFingerIsNotThePage() {
        var time = FloatTime()
        time.polled(through: 0.2, duration: 600, at: 1)

        time.scrub(to: 0.7)
        time.polled(through: 0.21, duration: 600, at: 1.25)

        #expect(time.shown == 0.7)
    }

    @Test func lettingGoHoldsThePlaceUntilThePageCatchesUp() {
        var time = FloatTime()
        time.polled(through: 0.2, duration: 600, at: 1)
        time.scrub(to: 0.7)

        time.letGo(at: 2)
        time.polled(through: 0.2, duration: 600, at: 2.25)
        let early = time.shown
        time.polled(through: 0.69, duration: 600, at: 2 + FloatTime.trust + 0.01)

        #expect(early == 0.7)
        #expect(time.shown == 0.69)
    }

    @Test func aSkipMovesTheLineByItsShareOfTheFilm() {
        var time = FloatTime()
        time.polled(through: 0.5, duration: 300, at: 1)

        time.skipped(by: 15, at: 2)

        #expect(abs(time.shown - 0.55) <= 0.0001)
    }

    @Test func theLineNeverRunsPastEitherEnd() {
        var time = FloatTime()
        time.polled(through: 0.99, duration: 60, at: 1)

        time.skipped(by: 15, at: 2)
        let end = time.shown
        time.scrub(to: -3)

        #expect(end == 1)
        #expect(time.shown == 0)
    }

    @Test func timesReadAsAPlayerWritesThem() {
        let samples: [Double] = [0, 9.7, 75, 3725, .nan]

        let labels = samples.map(FloatTime.label)

        #expect(labels == ["0:00", "0:09", "1:15", "1:02:05", "0:00"])
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FloatMotionTests {
    @Test func theSpringsStartAtRestAndArrive() {
        let curves: [(CGFloat, CGFloat)] = [(15, 0.78), (14, 1), (17, 0.62)]

        let ends = curves.map { (FloatTween.spring(0, omega: $0.0, zeta: $0.1), FloatTween.spring(2, omega: $0.0, zeta: $0.1)) }

        for (start, end) in ends {
            #expect(abs(start - 0) <= 0.0001)
            #expect(abs(end - 1) <= 0.001)
        }
    }

    @Test func theEntranceSettlesWithinItsTime() {
        let at = FloatMotion.arriving

        let rise = FloatTween.spring(at, omega: 15, zeta: 0.78)
        let scale = FloatTween.spring(at, omega: 17, zeta: 0.62)

        #expect(abs(rise - 1) <= 0.02)
        #expect(abs(scale - 1) <= 0.03)
    }

    @MainActor
    @Test func theLayoutKeepsTheControlsInsideTheSmallestWindow() {
        let bounds = CGRect(x: 0, y: 0, width: 260, height: 146)

        let parts = [
            FloatLayout.close(in: bounds), FloatLayout.back(in: bounds),
            FloatLayout.transport(in: bounds), FloatLayout.scrubHit(in: bounds),
            FloatLayout.speed(in: bounds), FloatLayout.feedback(in: bounds),
        ]

        for part in parts { #expect(bounds.contains(part), "\(part)") }
        #expect(!parts[0].intersects(parts[2]))
        #expect(!parts[1].intersects(parts[2]))
        #expect(!parts[2].intersects(parts[3]))
        #expect(!parts[0].intersects(parts[4]))
        #expect(!parts[1].intersects(parts[4]))
        #expect(!parts[2].intersects(parts[4]))
        #expect(!parts[2].intersects(parts[5]))
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FloatOpticsTests {
    private func transport(playing: Bool) -> (FloatTransportView, FloatChrome) {
        let chrome = FloatChrome()
        chrome.playing = playing
        let view = FloatTransportView(chrome: chrome, rewind: {}, toggle: {}, forward: {})
        view.frame = NSRect(origin: .zero, size: FloatLayout.transport)
        view.layoutSubtreeIfNeeded()
        return (view, chrome)
    }

    @Test func theSkipKeysTakeOneNudgeFromTheirWeightSoTheySitAlike() {
        let (view, _) = transport(playing: true)

        let rewind = view.rewind.nudge
        let forward = view.forward.nudge

        #expect(rewind == FloatOptics.nudge("gobackward.15", KitSymbol.Style(size: 16, weight: .semibold)))
        #expect(forward == rewind)
        #expect(rewind.dy < 0)
        #expect(view.rewind.symbol?.frame == view.forward.symbol?.frame)
    }

    @Test func theToggleGivesEachMarkTheNudgeThatSetsItsWeightOnTheCentre() {
        let style = KitSymbol.Style(size: 21, weight: .semibold)
        let (view, chrome) = transport(playing: true)
        let pause = view.toggle.nudge

        chrome.playing = false
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()

        #expect(pause == FloatOptics.nudge("pause.fill", style))
        #expect(view.toggle.nudge == FloatOptics.nudge("play.fill", style))
        #expect(view.toggle.symbol?.name == "play.fill")
        #expect(view.toggle.nudge.dx > pause.dx + 0.5)
        #expect(abs(pause.dx) < 0.5)
    }

    @Test func theToggleSwapsWithTheSystemsReplaceAndNoMotionOfBroadwaysOwn() {
        Store.settings.set(false, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        let (view, chrome) = transport(playing: true)
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()

        chrome.playing = false
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let layer = view.toggle.symbol?.layer

        #expect(view.toggle.symbol?.name == "play.fill")
        #expect(view.toggle.symbol?.replaced == 1)
        #expect(view.toggle.symbol?.played == KitSwap.downUp)
        #expect(layer?.animation(forKey: KitSwap.leave) == nil)
        #expect(layer?.animation(forKey: KitSwap.arrive) == nil)
        #expect(layer?.animation(forKey: KitSwap.crossKey) == nil)
    }

    @Test func glyphsWithoutAnOpticalOffsetStayCentred() {
        let names = ["xmark", "captions.bubble"]

        let nudges = names.map { FloatOptics.nudge($0, KitSymbol.Style(size: 12, weight: .semibold)) }

        #expect(nudges.allSatisfy { $0 == .zero })
    }
}
