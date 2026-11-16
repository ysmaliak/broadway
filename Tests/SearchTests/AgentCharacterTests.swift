import Foundation
import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AgentCharacterTests {
    private let seed: UInt64 = 0x1234_5678_9ABC_DEF0
    private let moods = AgentCharacter.Mood.allCases

    @Test func everyStateHasItsOwnFace() {
        let stills = moods.map(AgentCharacter.still)

        for (index, frame) in stills.enumerated() {
            for (other, next) in stills.enumerated() where other > index {
                #expect(frame != next, "\(moods[index]) and \(moods[other]) look the same")
            }
        }
    }

    @Test func eachFaceSaysItsState() {
        let still = AgentCharacter.still

        let hello = still(.hello), reading = still(.reading), typing = still(.typing), waving = still(.waving)
        let driving = still(.driving), done = still(.done), failed = still(.failed), ended = still(.ended)

        #expect(still(.idle) == AgentCharacter.Frame())
        #expect(hello.open > 1 && hello.wide > 1 && hello.look.y < 0 && hello.brows == .none)
        #expect(reading.look.y > 0 && typing.look.y > reading.look.y)
        #expect(waving.brows == .raised && waving.look.y < 0 && waving.tilt == AgentCharacter.askTilt)
        #expect(driving.look.x > 0 && driving.open < 1 && driving.brows == .none)
        #expect(done.smile == 1 && done.tick)
        #expect(failed.brows == .worried && failed.look.y > 0 && failed.squash > 0 && !failed.tick)
        #expect(ended.smile == -1 && ended.dim > 0 && !ended.tick)
    }

    @Test func theSessionsStateChoosesTheFace() {
        let now = Date()
        let fresh = now.addingTimeInterval(-1)
        let old = now.addingTimeInterval(-AgentCharacter.helloSpan - 1)
        let face = { (state: AgentLinkState, ended: AgentLinkEnding?, connected: Date) in
            AgentCharacter.face(state, ended: ended, connected: connected, now: now)
        }

        #expect(face(.idle, nil, fresh) == .hello)
        #expect(face(.idle, nil, old) == .idle)
        #expect(face(.working("Reading example.com"), nil, fresh) == .reading)
        #expect(face(.working("Typing on example.com"), nil, old) == .typing)
        #expect(face(.needsYou("Send?"), nil, old) == .waving)
        #expect(face(.driving, nil, old) == .driving)
        #expect(face(.done("Sent it"), .done("Sent it"), old) == .done)
        #expect(face(.failed(nil), .failed(nil), old) == .failed)
        #expect(face(.done(nil), .done(nil), old) == .ended)
        #expect(face(.done(nil), .left, fresh) == .ended)
        #expect(face(.needsYou(""), .left, old) == .waving)
    }

    @Test func everyFaceButAnEndedOneHasAGentleIdleLoop() {
        let looping = moods.filter { !AgentCharacter.loops($0).isEmpty }

        let idle = AgentCharacter.loops(.idle)

        #expect(looping == moods.filter { $0 != .ended })
        #expect(idle.contains(.blink) && idle.contains(.glance) && idle.contains { if case .breathe = $0 { return true } else { return false } })
        #expect(AgentCharacter.loops(.reading).contains(.scan))
        #expect(AgentCharacter.loops(.typing).contains(.tap))
        #expect(AgentCharacter.loops(.waving).contains(.sway))
    }

    @Test func noLoopRunsUnderReduceMotionOrLowPowerOrOffScreen() {
        let shown = moods.filter { AgentCharacter.loops($0, reduced: false, lowPower: false, window: true, column: true, scrolled: true) }

        let hidden = [
            AgentCharacter.loops(.idle, reduced: true, lowPower: false, window: true, column: true, scrolled: true),
            AgentCharacter.loops(.idle, reduced: false, lowPower: true, window: true, column: true, scrolled: true),
            AgentCharacter.loops(.idle, reduced: false, lowPower: false, window: false, column: true, scrolled: true),
            AgentCharacter.loops(.idle, reduced: false, lowPower: false, window: true, column: false, scrolled: true),
            AgentCharacter.loops(.idle, reduced: false, lowPower: false, window: true, column: true, scrolled: false)
        ]

        #expect(shown.count == moods.count - 1)
        #expect(hidden == [false, false, false, false, false])
    }

    @Test func everyLoopEndsWhereItStartsSoItNeverJumps() {
        let tracks = moods.flatMap { AgentCharacter.tracks($0, seed: seed) }

        for track in tracks {
            #expect(track.values.first == track.values.last, "\(track.part) jumps when its loop repeats")
            #expect(track.times.first == 0 && track.times.last == 1)
            #expect(track.times == track.times.sorted())
        }
    }

    @Test func facesMoveSmoothlyFromFrameToFrame() {
        let step = 1.0 / 60

        for mood in moods {
            let frames = stride(from: 0.0, to: 12, by: step).map { AgentCharacter.frame(mood, at: $0, seed: seed) }
            let jumps = zip(frames, frames.dropFirst()).map { one, two -> CGFloat in
                let look: CGFloat = abs(one.look.x - two.look.x)
                let tilt: CGFloat = abs(one.tilt - two.tilt)
                let nod: CGFloat = abs(one.nod - two.nod)
                let squash: CGFloat = abs(one.squash - two.squash) * 4
                return max(look, tilt, nod, squash)
            }
            #expect((jumps.max() ?? 0) < 0.025, "\(mood) jumps by \(jumps.max() ?? 0) in one frame")
        }
    }

    @Test func breathingAndSwayingStayCalm() {
        let times = stride(from: 0.0, to: 20, by: 0.05)

        let idle = times.map { AgentCharacter.frame(.idle, at: $0, seed: seed) }
        let waving = times.map { AgentCharacter.frame(.waving, at: $0, seed: seed) }
        let tracks: [AgentCharacter.Track] = moods.flatMap { AgentCharacter.tracks($0, seed: seed) }
        let slowest = tracks.filter { (track: AgentCharacter.Track) -> Bool in
            track.part == .squash || (track.part == .tilt && track.values.count == 3)
        }

        #expect((idle.map(\.squash).max() ?? 1) <= 0.035)
        #expect((idle.map(\.look.x).max() ?? 0) > 0.05)
        #expect(waving.allSatisfy { abs($0.tilt) <= AgentCharacter.askTilt + 0.0001 })
        #expect((waving.map(\.tilt).min() ?? 0) < -0.09 && (waving.map(\.tilt).max() ?? 0) > 0.09)
        #expect(slowest.allSatisfy { $0.period >= 3 })
    }

    @Test func blinksComeAtTheSeedsPeriodAndShutBriefly() throws {
        let track = try #require(AgentCharacter.tracks(.blink, seed: seed).first)
        let period = AgentCharacter.blinkPeriod(seed)

        let samples = stride(from: 0.0, to: period, by: 0.01).map { track.value(at: $0) }

        #expect((3...6).contains(period))
        #expect(track.period == period)
        #expect((samples.min() ?? 1) < 0.2)
        #expect(Double(samples.filter { $0 < 0.9 }.count) * 0.01 < 0.2)
        #expect(AgentCharacter.blinkPeriod(seed) != AgentCharacter.blinkPeriod(42))
    }

    @Test func movingBetweenStatesIsAnimatedAndHasItsOwnFlourish() {
        let arrival = AgentCharacter.arrival

        #expect(arrival(nil, .hello) == .pop)
        #expect(arrival(nil, .idle) == nil)
        #expect(arrival(.typing, .typing) == nil)
        #expect(arrival(.typing, .done) == .hop)
        #expect(arrival(.idle, .waving) == .hop)
        #expect(arrival(.reading, .failed) == .slump)
        #expect(arrival(.done, .ended) == .sleep)
        #expect(arrival(.hello, .reading) == .settle)
        #expect(arrival(.waving, .driving) == .settle)
        #expect(AgentCharacter.curve(.settle, reduced: false, lowPower: false) == .spring(AgentCharacter.spring))
        #expect(AgentCharacter.spring.damping < 1 && AgentCharacter.spring.damping > 0.6)
        #expect(AgentCharacter.hopHeights.first == 0 && AgentCharacter.hopHeights.last == 0)
    }

    @Test func reduceMotionChangesTheExpressionWithoutMovement() {
        let arrivals: [AgentCharacter.Arrival] = [.pop, .hop, .slump, .sleep, .settle]

        let reduced = arrivals.map { AgentCharacter.curve($0, reduced: true, lowPower: false) }
        let light = arrivals.map { AgentCharacter.curve($0, reduced: false, lowPower: true) }

        #expect(reduced.allSatisfy { $0 == .none })
        #expect(light.allSatisfy { $0 == .easeOut(0.2) })
        #expect(arrivals.allSatisfy { !AgentCharacter.flourishes($0, reduced: true, lowPower: false) })
        #expect(arrivals.allSatisfy { !AgentCharacter.flourishes($0, reduced: false, lowPower: true) })
    }

    @Test func aFaceShowsEachStatesExpressionAndRunsNothingOffScreen() {
        keepSettings("motion.testReduced")
        Store.settings.set(true, forKey: "motion.testReduced")
        let face = AgentCharacterFace(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        face.layoutSubtreeIfNeeded()
        var shown: [AgentCharacter.Frame] = []

        for mood in moods {
            face.mood = mood
            face.layoutSubtreeIfNeeded()
            shown.append(face.shownFrame)
        }

        #expect(shown == moods.map(AgentCharacter.still))
        #expect(!face.looping)
        #expect(face.loopKeys.isEmpty)
    }

    @Test func aShownFaceLoopsOnCoreAnimationAndStopsWhenHiddenOrEnded() {
        keepSettings("motion.testReduced", "motion.testLowPower")
        Store.settings.set(false, forKey: "motion.testReduced")
        Store.settings.set(false, forKey: "motion.testLowPower")
        AgentCharacterFace.shownInTests = true
        defer { AgentCharacterFace.shownInTests = false }
        let face = AgentCharacterFace(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(face)
        face.seed = seed

        face.layoutSubtreeIfNeeded()
        let idle = (face.looping, face.loopKeys.count)
        face.columnShown = false
        let hidden = (face.looping, face.loopKeys.count)
        face.columnShown = true
        face.mood = .waving
        let waving = (face.looping, face.loopKeys.count)
        face.mood = .ended
        let ended = (face.looping, face.loopKeys.count)
        face.removeFromSuperview()

        #expect(idle.0 && idle.1 >= 4)
        #expect(!hidden.0 && hidden.1 == 0)
        #expect(waving.0 && waving.1 >= 3)
        #expect(!ended.0 && ended.1 == 0)
    }

    @Test func eyesAndBrowsStayInsideTheHead() {
        let sizes: [CGFloat] = [14, 16, 18, 22]

        for side in sizes {
            for mood in moods {
                let pose = AgentCharacter.pose(AgentCharacter.still(mood), size: CGSize(width: side, height: side))
                for eye in pose.eyes {
                    let shown = CGRect(x: eye.x + pose.gaze.x - pose.eye.width / 2, y: eye.y + pose.gaze.y - pose.eye.height / 2,
                                       width: pose.eye.width, height: pose.eye.height)
                    #expect(pose.head.insetBy(dx: pose.line / 2, dy: pose.line / 2).contains(shown), "\(mood) at \(side) pt")
                }
                for brow in pose.brows where pose.browOpacity > 0 {
                    #expect(brow.y + pose.gaze.y > pose.head.minY, "\(mood) at \(side) pt")
                }
            }
        }
    }

    @Test func noFaceHasLimbs() {
        let fields = Mirror(reflecting: AgentCharacter.Frame()).children.compactMap(\.label)
        let parts = Mirror(reflecting: AgentCharacter.pose(AgentCharacter.still(.waving), size: CGSize(width: 20, height: 20))).children.compactMap(\.label)

        #expect(!fields.contains("hand"))
        #expect(!parts.contains("hand") && !parts.contains("arm"))
    }

    @Test func agentMoodsMapToFaces() {
        let given: [AgentMood?] = [nil, .reading, .typing, .waving, .done, .failed]

        let faces = given.map(AgentCharacter.Mood.init)

        #expect(faces == [.idle, .reading, .typing, .waving, .done, .failed])
    }

    @Test func noAgentWearsTheNeedsYouAmber() {
        let amber = Palette.NS.unsafe.usingColorSpace(.sRGB)!

        let hues = (0..<AgentLinks.accents).map { AgentCharacter.accentColor($0).usingColorSpace(.sRGB)!.hueComponent }

        #expect(hues.allSatisfy { abs($0 - amber.hueComponent) > 0.04 }, "\(hues) against \(amber.hueComponent)")
    }
}
