import Foundation
import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AgentCharacterTests {
    private let seed: UInt64 = 0x1234_5678_9ABC_DEF0

    @Test func onlyWorkingFacesMoveAndNeverUnderReduceMotionOrLowPower() {
        let moods = AgentCharacter.Mood.allCases

        let moving = moods.filter { AgentCharacter.animates($0, reduced: false, lowPower: false) }

        #expect(moving == [.reading, .typing, .waving])
        #expect(moods.allSatisfy { !AgentCharacter.animates($0, reduced: true, lowPower: false) })
        #expect(moods.allSatisfy { !AgentCharacter.animates($0, reduced: false, lowPower: true) })
    }

    @Test func stillFacesSayTheirState() {
        let still = AgentCharacter.still

        let typing = still(.typing), waving = still(.waving), done = still(.done), failed = still(.failed), driving = still(.driving)

        #expect(typing.look.y > 0)
        #expect(waving.look.y < driving.look.y)
        #expect(waving.tilt != 0 && waving.peer > 0 && driving.tilt == 0 && driving.peer == 0)
        #expect(driving.look.y < 0)
        #expect(done.happy && done.tick)
        #expect(failed.sad && failed.look.y > 0 && failed.squash > 0)
        #expect(still(.idle) == AgentCharacter.Frame())
    }

    @Test func everyMoodHasItsOwnStillFace() {
        let moods = AgentCharacter.Mood.allCases

        let stills = moods.map(AgentCharacter.still)

        for (index, frame) in stills.enumerated() {
            for (other, next) in stills.enumerated() where other > index {
                #expect(frame != next, "\(moods[index]) and \(moods[other]) look the same when still")
            }
        }
    }

    @Test func noFaceHasLimbs() {
        let frame = AgentCharacter.frame(.waving, at: 0.3, seed: seed)

        let fields = Mirror(reflecting: frame).children.compactMap(\.label)
        let parts = Mirror(reflecting: AgentCharacter.parts(frame, size: CGSize(width: 20, height: 20))).children.compactMap(\.label)

        #expect(!fields.contains("hand"))
        #expect(!parts.contains("hand") && !parts.contains("arm"))
    }

    @Test func stillMoodsIgnoreTime() {
        let times: [TimeInterval] = [0, 0.4, 1.7, 9.3]

        let frames = times.map { AgentCharacter.frame(.done, at: $0, seed: seed) }

        #expect(frames.allSatisfy { $0 == AgentCharacter.still(.done) })
    }

    @Test func readingEyesStepRightThenSweepBack() {
        let times: [TimeInterval] = [0.1, 0.6, 1.1, 1.6, 2.2, 2.39]

        let looks = times.map(AgentCharacter.scan(at:))

        #expect(Array(looks.prefix(4)) == [-0.09, -0.03, 0.03, 0.09])
        #expect(looks[4] < 0.09)
        #expect(looks[5] < looks[4])
    }

    @Test func blinksComeAtTheSeedsPeriodAndShutBriefly() {
        let period = AgentCharacter.blinkPeriod(seed)
        let lead = AgentCharacter.phase(seed) * period
        let blink = period - lead

        let middle = AgentCharacter.openness(at: blink + 0.08, seed: seed)
        let open = AgentCharacter.openness(at: blink + 0.5, seed: seed)
        let next = AgentCharacter.openness(at: blink + period + 0.08, seed: seed)

        #expect((3...6).contains(period))
        #expect(middle < 0.2)
        #expect(open == 1)
        #expect(abs(next - middle) <= 0.0001)
    }

    @Test func twoAgentsBlinkAtDifferentTimes() {
        let other: UInt64 = 42

        let mine = AgentCharacter.blinkPeriod(seed), theirs = AgentCharacter.blinkPeriod(other)

        #expect(mine != theirs)
    }

    @Test func needsYouHopsAndTiltsTheHeadAndTypingNods() {
        let times = stride(from: 0.0, to: AgentCharacter.askCycle * 2, by: 1.0 / AgentCharacter.rate).map { $0 }

        let asking = times.map { AgentCharacter.frame(.waving, at: $0, seed: seed) }
        let nods = times.map { AgentCharacter.frame(.typing, at: $0, seed: seed).nod }

        #expect((asking.map(\.nod).min() ?? 0) < -0.05)
        #expect((asking.map(\.squash).max() ?? 0) > 0.05)
        #expect((asking.map(\.tilt).max() ?? 0) > 0.1 && (asking.map(\.tilt).min() ?? 0) < -0.1)
        #expect(asking.allSatisfy { $0.look.y < 0 })
        #expect(asking.filter { $0.nod == 0 && $0.squash == 0 }.count > asking.count * 3 / 4)
        #expect(asking.filter { $0.nod != 0 || $0.squash != 0 }.allSatisfy { $0.open == 1 })
        #expect((nods.max() ?? 0) > 0)
        #expect((nods.min() ?? 1) == 0)
    }

    @Test func needsYouStartsItsLoopAtRestOnTheStillsSide() {
        let seeds: [UInt64] = [0, 42, 7919, seed, .max]
        let still = AgentCharacter.still(.waving)

        let starts = seeds.map { AgentCharacter.frame(.waving, at: 0, seed: $0) }

        #expect(starts.allSatisfy { $0.tilt == still.tilt && $0.nod == 0 && $0.squash == 0 && $0.peer == still.peer })
    }

    @Test func readingLeansWithTheScan() {
        let times: [TimeInterval] = [0.1, 1.6]

        let frames = times.map { AgentCharacter.frame(.reading, at: $0 - AgentCharacter.phase(seed) * 2.4, seed: seed) }

        #expect(frames[0].tilt < 0 && frames[1].tilt > 0)
    }

    @Test func doneBouncesOnceAndFailedSlumpsOnlyAfterWork() {
        let from: [AgentCharacter.Mood] = [.reading, .typing, .waving, .driving]

        let bounce = AgentCharacter.arrival(from: .typing, to: .done)
        let slump = AgentCharacter.arrival(from: .reading, to: .failed)
        let entrances = [AgentCharacter.arrival(from: .idle, to: .done), AgentCharacter.arrival(from: .idle, to: .failed)]

        let hop = try? #require(bounce)
        #expect((hop?.map(\.nod).min() ?? 0) < -0.05)
        #expect(hop?.last == AgentCharacter.still(.done))
        #expect(hop?.first?.tick == false && hop?.first?.happy == true)
        #expect(slump?.last == AgentCharacter.still(.failed))
        #expect(slump?.first?.squash == 0)
        #expect(from.allSatisfy { AgentCharacter.arrival(from: $0, to: .done) != nil })
        #expect(entrances.allSatisfy { $0 == nil })
        #expect(AgentCharacter.arrival(from: .typing, to: .waving) == nil)
    }

    @Test func agentMoodsMapToFaces() {
        let moods: [AgentMood?] = [nil, .reading, .typing, .waving, .done, .failed]

        let faces = moods.map(AgentCharacter.Mood.init)

        #expect(faces == [.idle, .reading, .typing, .waving, .done, .failed])
    }

    @Test func aFaceTicksOnlyWhileItMovesAndIsOnScreen() {
        let shown = AgentCharacter.ticks(moving: true, window: true, column: true, scrolled: true)

        let hidden = [
            AgentCharacter.ticks(moving: false, window: true, column: true, scrolled: true),
            AgentCharacter.ticks(moving: true, window: false, column: true, scrolled: true),
            AgentCharacter.ticks(moving: true, window: true, column: false, scrolled: true),
            AgentCharacter.ticks(moving: true, window: true, column: true, scrolled: false)
        ]

        #expect(shown)
        #expect(hidden == [false, false, false, false])
    }

    @Test func noAgentWearsTheNeedsYouAmber() {
        let amber = Palette.NS.unsafe.usingColorSpace(.sRGB)!

        let hues = (0..<AgentLinks.accents).map { AgentCharacter.accentColor($0).usingColorSpace(.sRGB)!.hueComponent }

        #expect(hues.allSatisfy { abs($0 - amber.hueComponent) > 0.04 }, "\(hues) against \(amber.hueComponent)")
    }
}
