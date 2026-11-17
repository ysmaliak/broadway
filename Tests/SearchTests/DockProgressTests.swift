import Foundation
import Testing
@testable import Search

struct DockProgressTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func oneDownloadIsItsOwnShare() {
        #expect(DockProgress.percent([DockLoad(received: 250, expected: 1_000, underWay: true)]) == 25)
    }

    @Test func severalAreAddedByTheirBytes() {
        let loads = [DockLoad(received: 100, expected: 100, underWay: true),
                     DockLoad(received: 0, expected: 300, underWay: true)]

        #expect(DockProgress.fraction(loads) == 0.25)
        #expect(DockProgress.percent(loads) == 25)
    }

    @Test func aDownloadOfUnknownSizeIsLeftOut() {
        let loads = [DockLoad(received: 50, expected: 100, underWay: true),
                     DockLoad(received: 9_000, expected: 0, underWay: true),
                     DockLoad(received: 9_000, expected: -1, underWay: true)]

        #expect(DockProgress.percent(loads) == 50)
    }

    @Test func noKnownSizeShowsNoBar() {
        let loads = [DockLoad(received: 50, expected: 0, underWay: true),
                     DockLoad(received: 10, expected: -1, underWay: true)]

        #expect(DockProgress.percent(loads) == nil)
        #expect(DockProgress.percent([]) == nil)
    }

    @Test func pausedOnesAreNotUnderWay() {
        let loads = [DockLoad(received: 10, expected: 100, underWay: true),
                     DockLoad(received: 0, expected: 900, underWay: false)]

        #expect(DockProgress.percent(loads) == 10)
        #expect(DockProgress.percent([DockLoad(received: 10, expected: 100, underWay: false)]) == nil)
    }

    @Test func aWholePercentIsOnlyReachedWhenItIsWhole() {
        #expect(DockProgress.percent([DockLoad(received: 999, expected: 1_000, underWay: true)]) == 99)
        #expect(DockProgress.percent([DockLoad(received: 1_000, expected: 1_000, underWay: true)]) == 100)
        #expect(DockProgress.percent([DockLoad(received: 2_000, expected: 1_000, underWay: true)]) == 100)
    }

    @Test func theBarAppearsAtOnce() {
        var pace = DockPace()

        #expect(pace.see(0, at: start) == .draw(0))
        #expect(pace.shown == 0)
    }

    @Test func theSamePercentDrawsNothing() {
        var pace = DockPace()
        _ = pace.see(40, at: start)

        #expect(pace.see(40, at: start.addingTimeInterval(1)) == .nothing)
        #expect(pace.see(40, at: start.addingTimeInterval(5)) == .nothing)
    }

    @Test func aNewPercentWithinAQuarterSecondWaitsForIt() {
        var pace = DockPace()
        _ = pace.see(40, at: start)

        let soon = pace.see(41, at: start.addingTimeInterval(0.1))
        let then = pace.see(41, at: start.addingTimeInterval(0.25))

        #expect(soon == .later(start.addingTimeInterval(0.25)))
        #expect(then == .draw(41))
        #expect(pace.shown == 41)
    }

    @Test func noMoreThanFourDrawsASecond() {
        var pace = DockPace()
        var draws = 0
        for step in 0..<100 {
            if case .draw = pace.see(step, at: start.addingTimeInterval(Double(step) * 0.01)) { draws += 1 }
        }

        #expect(draws == 4)
    }

    @Test func theLastOneEndingTakesTheBarAway() {
        var pace = DockPace()
        _ = pace.see(DockProgress.percent([DockLoad(received: 80, expected: 100, underWay: true)]), at: start)

        let gone = pace.see(DockProgress.percent([]), at: start.addingTimeInterval(1))

        #expect(gone == .draw(nil))
        #expect(pace.shown == nil)
    }

    @Test func theBarGoingStillKeepsTheQuarterSecond() {
        var pace = DockPace()
        _ = pace.see(80, at: start)

        #expect(pace.see(nil, at: start.addingTimeInterval(0.05)) == .later(start.addingTimeInterval(0.25)))
        #expect(pace.shown == 80)
    }
}
