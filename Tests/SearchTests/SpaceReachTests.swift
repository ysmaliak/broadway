import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SpaceReachTests {
    @Test func aSlideCaughtPastHalfwayLandsAndKeepsItsPlace() {
        let width: CGFloat = 240

        let forward = SpaceReach.caught(-200, width: width)
        let back = SpaceReach.caught(180, width: width)

        #expect(forward.lands && forward.offset == 40)
        #expect(back.lands && back.offset == -60)
    }

    @Test func aSlideCaughtBeforeHalfwayStaysWithItsSpace() {
        let width: CGFloat = 240

        let caught = SpaceReach.caught(-100, width: width)

        #expect(!caught.lands)
        #expect(caught.offset == -100)
    }

    @Test func aSwipePastTheLastSpaceFindsNothingThere() {
        let reach = SpaceReach(count: 3, here: 2, making: false)

        let next = reach.neighbour(for: -40)
        let landed = reach.landing(travel: -200, speed: -900, cancelled: false)

        #expect(next == nil)
        #expect(landed == nil)
    }

    @Test func aSwipeBeforeTheFirstSpaceFindsNothingThere() {
        let reach = SpaceReach(count: 3, here: 0, making: false)

        let next = reach.neighbour(for: 40)
        let landed = reach.landing(travel: 200, speed: 900, cancelled: false)

        #expect(next == nil)
        #expect(landed == nil)
    }

    @Test func bothEndsGiveTheSameWayAndNeverPastTheBump() {
        let first = SpaceReach(count: 3, here: 0, making: false)
        let last = SpaceReach(count: 3, here: 2, making: false)

        let before = first.resisted(120, width: 240)
        let after = last.resisted(-120, width: 240)
        let far = last.resisted(-4000, width: 240)
        let farther = last.resisted(-40_000, width: 240)

        #expect(before == -after)
        #expect(before > 0 && before < SpaceReach.give)
        #expect(far < after && far >= -SpaceReach.give)
        #expect(farther <= far && farther >= -SpaceReach.give)
        #expect(SpaceReach.give == SpaceMotion.give)
    }

    @Test func betweenSpacesTheColumnFollowsTheFingers() {
        let reach = SpaceReach(count: 3, here: 1, making: false)

        let toNext = reach.neighbour(for: -10)
        let toBefore = reach.neighbour(for: 10)
        let shown = reach.resisted(-120, width: 240)
        let landed = reach.landing(travel: -120, speed: -100, cancelled: false)

        #expect(toNext == 2)
        #expect(toBefore == 0)
        #expect(shown == -120)
        #expect(landed == 2)
    }

    @Test func theWheelAndButtonsStopAtTheEnds() {
        let last = SpaceReach(count: 3, here: 2, making: false)
        let first = SpaceReach(count: 3, here: 0, making: false)

        let pastLast = last.step(1)
        let beforeFirst = first.step(-1)
        let back = last.step(-1)

        #expect(pastLast == nil)
        #expect(beforeFirst == nil)
        #expect(back == 1)
    }

    @Test func onTheNewSpacePageASwipeGoesNowhereEitherWay() {
        let reach = SpaceReach(count: 3, here: 3, making: true)

        let back = reach.neighbour(for: 60)
        let on = reach.neighbour(for: -60)
        let landedBack = reach.landing(travel: 220, speed: 900, cancelled: false)
        let shown = reach.resisted(80, width: 240)

        #expect(back == nil)
        #expect(on == nil)
        #expect(landedBack == nil)
        #expect(shown > 0 && shown < SpaceReach.give)
        #expect(reach.step(-1) == nil)
    }

    @Test func aOneSpaceListHasNowhereToGo() {
        let reach = SpaceReach(count: 1, here: 0, making: false)

        let either = [reach.neighbour(for: -50), reach.neighbour(for: 50), reach.step(1), reach.step(-1)]

        #expect(either == [nil, nil, nil, nil])
    }

    @Test func aFlickBackStaysPut() {
        let reach = SpaceReach(count: 3, here: 1, making: false)

        let landed = reach.landing(travel: -120, speed: 900, cancelled: false)
        let cancelled = reach.landing(travel: -200, speed: -900, cancelled: true)

        #expect(landed == nil)
        #expect(cancelled == nil)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SpaceBumpTests {
    @Test func aBumpAtTheEndGoesOutAndComesBackToRest() async throws {
        let motion = SpaceMotion()
        var furthest: CGFloat = 0

        motion.bump(-1, width: 240)
        let started = Date()
        while motion.moving, Date().timeIntervalSince(started) < 2 {
            furthest = min(furthest, motion.offset)
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(furthest < -4)
        #expect(!motion.moving)
        #expect(motion.offset == 0)
    }
}
