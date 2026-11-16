import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PullRefreshTests {
    private func ready(continues: Bool = false) -> PullReading {
        var reading = PullReading()
        reading.continues = continues
        reading.begin()
        _ = reading.hear(top: "")
        _ = reading.hear(chain: "free", frame: false)
        return reading
    }

    private func pull(_ reading: inout PullReading, by travel: CGFloat, from start: TimeInterval = 0, over seconds: TimeInterval = 0.4) -> [PullReading.Step] {
        let count = 20
        return (0...count).map { index in
            reading.move(dx: 0, dy: index == 0 ? 8 : travel / CGFloat(count), at: start + seconds * Double(index) / Double(count))
        }
    }

    @Test func aPullPastThePointHeldLongEnoughReloads() {
        var reading = ready()

        let steps = pull(&reading, by: 180)
        let end = reading.end(at: 0.5)

        #expect(steps.first?.held == true)
        #expect(steps.allSatisfy { $0.held })
        #expect(steps.compactMap(\.tick) == [true])
        #expect(end == .reload)
    }

    @Test func theFirstHeldEventStartsFromNought() {
        var reading = ready()

        let first = reading.move(dx: 0, dy: 30, at: 0)

        #expect(first.held)
        #expect(first.change == .pulled)
        #expect(reading.travel == 0)
    }

    @Test func aPullShortOfThePointGoesBack() {
        var reading = ready()

        _ = pull(&reading, by: 80)
        let end = reading.end(at: 0.5)

        #expect(!reading.armed)
        #expect(end == .back)
        #expect(reading.why == "short")
    }

    @Test func pastThePointAndBackTicksTwiceAndGoesBack() {
        var reading = ready()
        _ = pull(&reading, by: 160)

        let back = reading.move(dx: 0, dy: -90, at: 0.5)
        let end = reading.end(at: 0.7)

        #expect(back.held)
        #expect(back.tick == false)
        #expect(end == .back)
    }

    @Test func pushedBackPastTheStartGivesTheEventsToThePageAgain() {
        var reading = ready()
        _ = pull(&reading, by: 60)

        let back = reading.move(dx: 0, dy: -80, at: 0.5)
        let after = reading.move(dx: 0, dy: 40, at: 0.6)
        let end = reading.end(at: 0.8)

        #expect(!back.held)
        #expect(back.change == .dropped)
        #expect(!after.held)
        #expect(reading.spent)
        #expect(end == .nothing)
    }

    @Test func aFlickHoweverFarGoesBack() {
        var reading = ready()

        _ = pull(&reading, by: 400, over: 0.08)
        let end = reading.end(at: 0.09)

        #expect(reading.armed)
        #expect(end == .back)
        #expect(reading.why == "flick")
    }

    @Test func noAnswerMeansNoPull() {
        var reading = PullReading()
        reading.begin()

        let steps = pull(&reading, by: 300)
        let end = reading.end(at: 0.5)

        #expect(steps.allSatisfy { !$0.held && $0.change == .none })
        #expect(end == .nothing)
    }

    @Test func oneAnswerOfTheTwoIsNotEnough() {
        var onlyPage = PullReading()
        onlyPage.begin()
        _ = onlyPage.hear(top: "")
        var onlyPointer = PullReading()
        onlyPointer.begin()
        _ = onlyPointer.hear(chain: "free", frame: false)

        let page = pull(&onlyPage, by: 300)
        let pointer = pull(&onlyPointer, by: 300)

        #expect(page.allSatisfy { !$0.held })
        #expect(pointer.allSatisfy { !$0.held })
    }

    @Test func aPageThatSaysNoSpendsTheGesture() {
        var reading = PullReading()
        reading.begin()

        _ = reading.hear(top: "scrolled")
        _ = reading.hear(chain: "free", frame: false)
        let steps = pull(&reading, by: 300)

        #expect(reading.spent)
        #expect(reading.why == "scrolled")
        #expect(steps.allSatisfy { !$0.held })
    }

    @Test func aLateNoDropsAPullAlreadyHeld() {
        var reading = ready()
        _ = pull(&reading, by: 150)

        let heard = reading.hear(chain: "prevented", frame: false)
        let next = reading.move(dx: 0, dy: 20, at: 0.5)
        let end = reading.end(at: 0.6)

        #expect(heard == .dropped)
        #expect(!next.held)
        #expect(end == .nothing)
    }

    @Test func aSidewaysStartIsNotAPull() {
        var reading = ready()

        let first = reading.move(dx: 20, dy: 4, at: 0)
        let steps = pull(&reading, by: 300, from: 0.1)

        #expect(!first.held)
        #expect(reading.why == "sideways")
        #expect(steps.allSatisfy { !$0.held })
    }

    @Test func scrollingDownFirstSpendsTheGesture() {
        var reading = ready()

        _ = reading.move(dx: 0, dy: -20, at: 0)
        let steps = pull(&reading, by: 300, from: 0.1)

        #expect(reading.why == "scrolling")
        #expect(steps.allSatisfy { !$0.held })
    }

    @Test func withTheOtherRuleComingToTheTopInOneGestureCounts() {
        var reading = PullReading()
        reading.continues = true
        reading.begin()
        _ = reading.move(dx: 0, dy: -20, at: 0)
        let early = reading.hear(chain: "scrolled", frame: false)

        let late = reading.hear(chain: "free", frame: false)
        let steps = pull(&reading, by: 180, from: 0.2)
        let end = reading.end(at: 0.7)

        #expect(early == .nothing)
        #expect(late == .nothing)
        #expect(!reading.spent)
        #expect(steps.last?.held == true)
        #expect(end == .reload)
    }

    @Test func withTheOtherRuleAFrameAnswerAsksThePage() {
        var reading = PullReading()
        reading.continues = true
        reading.begin()

        let heard = reading.hear(chain: "free", frame: true)
        let before = reading.ready
        _ = reading.hear(top: "")

        #expect(heard == .ask)
        #expect(!before)
        #expect(reading.ready)
    }

    @Test func aRefusalAtTheStartReadsNothing() {
        var reading = PullReading()

        reading.begin(refused: "off")
        _ = reading.hear(top: "")
        _ = reading.hear(chain: "free", frame: false)
        let steps = pull(&reading, by: 300)

        #expect(reading.why == "off")
        #expect(steps.allSatisfy { !$0.held })
    }

    @Test func aCancelledGestureGoesBack() {
        var reading = ready()
        _ = pull(&reading, by: 200)

        let end = reading.cancel()

        #expect(end == .back)
        #expect(reading.why == "cancelled")
    }

    @Test func theDiscStartsOutsideItsEdgeAndNeverPassesItsReach() {
        let travels: [CGFloat] = [0, 1, 55, 110, 220, 2000]

        let gaps = travels.map { GestureDisc.gap(PullRefresh.progress($0)) }

        #expect(gaps[0] == -GestureDisc.size)
        #expect(zip(gaps, gaps.dropFirst()).allSatisfy { $0 < $1 })
        #expect(gaps[5] <= GestureDisc.reach - GestureDisc.size)
        #expect(PullRefresh.progress(110) == 1)
        #expect(PullRefresh.progress(55) == 0.5)
    }

    @Test func theThreeDiscsShareOneLife() {
        let armedRefresh = PullRefresh.progress(PullRefresh.arm)

        #expect(armedRefresh == 1)
        #expect(GestureDisc.gap(1) > GestureDisc.rest)
        #expect(GestureDisc.gap(0.15) < -GestureDisc.size / 2)
        #expect(GestureDisc.scale(0) == GestureDisc.least)
        #expect(GestureDisc.scale(1) == 1)
        #expect(GestureDisc.scale(3) == 1)
        #expect(PullRefresh.lingers == GestureDisc.lingers)
    }

    @Test func theSwitchIsOnUnlessTurnedOff() {
        let name = "pull-refresh-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name) ?? .standard
        store.removePersistentDomain(forName: name)

        let fresh = PullRefresh.on(in: store)
        store.set(false, forKey: PullRefresh.key)
        let off = PullRefresh.on(in: store)

        #expect(fresh)
        #expect(!off)
        #expect(SettingsIndex.items.contains { $0.id == PullRefresh.key && $0.group == "pages" })
        store.removePersistentDomain(forName: name)
    }
}
