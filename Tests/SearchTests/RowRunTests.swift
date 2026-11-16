import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct RowRunTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()

    @Test func nothingIsLitWithoutPicks() {
        let picked: Set<UUID> = []

        let lit = RowRun.lit(picked: picked, active: a)

        #expect(lit.isEmpty)
    }

    @Test func theActiveTabJoinsThePicks() {
        let picked: Set<UUID> = [b]

        let lit = RowRun.lit(picked: picked, active: a)

        #expect(lit == [a, b])
    }

    @Test func aPickedRunJoinsAboveAndBelow() {
        let order = [a, b, c, d]
        let lit: Set<UUID> = [a, b, c]

        let first = RowRun.join(a, in: order, lit: lit)
        let middle = RowRun.join(b, in: order, lit: lit)
        let last = RowRun.join(c, in: order, lit: lit)

        #expect(first == RowJoin(above: false, below: true))
        #expect(middle == RowJoin(above: true, below: true))
        #expect(last == RowJoin(above: true, below: false))
    }

    @Test func rowsApartInTheListStayApart() {
        let order = [a, b, c]
        let lit: Set<UUID> = [a, c]

        let first = RowRun.join(a, in: order, lit: lit)
        let last = RowRun.join(c, in: order, lit: lit)

        #expect(first == .none)
        #expect(last == .none)
    }

    @Test func aRowNotLitNeverJoins() {
        let order = [a, b, c]
        let lit: Set<UUID> = [a, c]

        let join = RowRun.join(b, in: order, lit: lit)

        #expect(join == .none)
    }

    @Test func aPairBreaksARun() {
        let order = [a, RowRun.apart, c]
        let lit: Set<UUID> = [a, b, c]

        let first = RowRun.join(a, in: order, lit: lit)
        let last = RowRun.join(c, in: order, lit: lit)

        #expect(first == .none)
        #expect(last == .none)
    }

    @Test func aRowInAnotherListDoesNotJoin() {
        let order = [a, b]
        let lit: Set<UUID> = [a, b, c]

        let join = RowRun.join(c, in: order, lit: lit)

        #expect(join == .none)
    }

    @Test func aPressSinksTheRow() {
        let pressed = true

        let scale = RowRun.sink(pressed: pressed, gives: true, calm: false)

        #expect(scale == Motion.give)
    }

    @Test func theReleaseOrACancelBringsItBack() {
        let pressed = false

        let scale = RowRun.sink(pressed: pressed, gives: true, calm: false)

        #expect(scale == 1)
    }

    @Test func noSinkWithTheSettingOff() {
        let gives = false

        let scale = RowRun.sink(pressed: true, gives: gives, calm: false)

        #expect(scale == 1)
    }

    @Test func noSinkUnderReduceMotionOrLowPower() {
        let calm = true

        let scale = RowRun.sink(pressed: true, gives: true, calm: calm)

        #expect(scale == 1)
    }

    @Test @MainActor func aSwitchWithinTheSpaceFades() {
        let (old, new) = (UUID(), UUID())
        SwitchFade.switching()

        let fades = SwitchFade.within(from: old, to: [new], among: [old, new])

        #expect(fades)
    }

    @Test @MainActor func aSpaceChangeOrClosedTabShowsTheGroundAtOnce() {
        let (old, new) = (UUID(), UUID())
        SwitchFade.switching()

        let elsewhere = SwitchFade.within(from: old, to: [new], among: [new])
        let fresh = SwitchFade.within(from: nil, to: [new], among: [new])
        let same = SwitchFade.within(from: new, to: [new], among: [new])

        #expect(!elsewhere)
        #expect(!fresh)
        #expect(!same)
    }

    @Test func theGroundAppearsInPlace() {
        let scale = SwitchFade.scale

        #expect(scale == 0.98)
    }

    @Test func theLiveRowAndPickedRowsAreLightSlabsInTheDark() {
        let dark = NSAppearance(named: .darkAqua)!
        var live = NSColor.clear
        var picked = NSColor.clear

        dark.performAsCurrentDrawingAppearance {
            live = Palette.NS.sideWash.usingColorSpace(.genericGray) ?? .clear
            picked = Palette.NS.sidePicked.usingColorSpace(.genericGray) ?? .clear
        }

        #expect(abs(live.whiteComponent - 1) <= 0.01)
        #expect(abs(picked.whiteComponent - 1) <= 0.01)
        #expect(live.alphaComponent > picked.alphaComponent)
    }

    @Test func theColumnsFillsStepUpFromTheGroundQuietly() {
        let dark = NSAppearance(named: .darkAqua)!
        var alphas: [CGFloat] = []

        dark.performAsCurrentDrawingAppearance {
            alphas = [Palette.NS.sideTile, Palette.NS.sideHover, Palette.NS.sidePicked, Palette.NS.sideWash]
                .map { $0.usingColorSpace(.genericGray)?.alphaComponent ?? 1 }
        }

        #expect(alphas == alphas.sorted())
        #expect(alphas[0] <= alphas[1])
        #expect(alphas[3] <= 0.21)
    }

    @Test func rowsSitAlmostTouching() {
        #expect(Metrics.sideGap <= 3)
        #expect(Metrics.sideGap > 0)
        #expect(Metrics.sideRowHeight == 34)
    }
}
