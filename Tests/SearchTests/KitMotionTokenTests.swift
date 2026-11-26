import AppKit
import QuartzCore
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(1)))
@MainActor
struct KitMotionTokenTests {
    private func reduced<T>(_ on: Bool, _ body: () -> T) -> T {
        Store.settings.set(on, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        return body()
    }

    private func pace(_ timing: CAMediaTimingFunction?) -> [Swift.Float] {
        guard let timing else { return [] }
        return (1...2).flatMap { index -> [Swift.Float] in
            var point = [Swift.Float](repeating: 0, count: 2)
            timing.getControlPoint(at: index, values: &point)
            return point
        }
    }

    @Test func theQuickTheSlideAndTheEdgeCurvesEaseOutOverTheirOwnTimes() {
        let curves = reduced(false) { [Motion.kitQuick, Motion.kitSlide, Motion.kitEdge] }

        #expect(curves == [.easeOut(0.12), .easeOut(0.16), .easeOut(0.18)])
        #expect(curves.map(\.seconds) == [0.12, 0.16, 0.18])
        #expect(reduced(false) { Motion.pane } == Motion.slide)
    }

    @Test func theStackedColumnScrollTravelsForAThirdOfASecond() {
        #expect(Motion.columnScroll == 0.32)
    }

    @Test func aFadeStaysUnderReduceMotionAndTakesALittleLongerThere() {
        let plain = reduced(false) { Motion.kitFade }
        let calm = reduced(true) { Motion.kitFade }

        #expect(plain == .easeOut(0.12))
        #expect(calm == .easeOut(0.16))
        #expect(Motion.staysUnderReduce(calm.animation("opacity", from: 0, to: 1)!))
    }

    @Test func theFieldLeavesOverAFifthOfASecondOrAtOnceUnderReduceMotion() {
        #expect(reduced(false) { Motion.fieldOutSeconds } == 0.2)
        #expect(reduced(true) { Motion.fieldOutSeconds } == nil)
    }

    @Test func aCurveNamesItsTimeAndPace() {
        #expect(KitCurve.none.seconds == 0)
        #expect(KitCurve.none.timing == nil)
        #expect(pace(KitCurve.easeOut(0.2).timing) == pace(CAMediaTimingFunction(name: .easeOut)))
        #expect(pace(KitCurve.easeInOut(0.26).timing) == pace(CAMediaTimingFunction(name: .easeInEaseOut)))
        #expect(KitCurve.spring(.glide).seconds == KitSpring.glide.animation("opacity", from: 0, to: 1).settlingDuration)
    }

    @Test func theRefusalShakeGoesSidewaysThreeTimesForHalfASecondAndComesBackToRest() throws {
        let layer = CALayer()
        reduced(false) { layer.kitShake() }
        let shake = try #require(layer.animation(forKey: "shake") as? CAKeyframeAnimation)
        let values = try #require(shake.values as? [Double])

        #expect(shake.keyPath == "transform.translation.x")
        #expect(shake.duration == 0.5)
        #expect(shake.isAdditive)
        #expect(pace(shake.timingFunction) == pace(CAMediaTimingFunction(name: .easeOut)))
        #expect(abs(values.first ?? 1) < 1e-9)
        #expect(abs(values.last ?? 1) < 1e-9)
        #expect(values.map(abs).max()! <= 7)
        #expect(values.map(abs).max()! > 5)
    }

    @Test func underReduceMotionThereIsNoShake() {
        let layer = CALayer()
        reduced(true) { layer.kitShake() }

        #expect(layer.animation(forKey: "shake") == nil)
    }

    @Test func aGroupWithNoCurveTakesNoTime() {
        var seen: (TimeInterval, Bool)?
        NSAnimationContext.kit(.none) {
            let context = NSAnimationContext.current
            seen = (context.duration, context.allowsImplicitAnimation)
        }

        #expect(seen?.0 == 0)
        #expect(seen?.1 == false)
    }

    @Test func aGroupTakesItsCurvesTimeAndPace() {
        var seen: (TimeInterval, CAMediaTimingFunction?, Bool)?
        NSAnimationContext.kit(.easeOut(0.18), implicit: true) {
            let context = NSAnimationContext.current
            seen = (context.duration, context.timingFunction, context.allowsImplicitAnimation)
        }

        #expect(seen?.0 == 0.18)
        #expect(pace(seen?.1) == pace(CAMediaTimingFunction(name: .easeOut)))
        #expect(seen?.2 == true)
    }
}
