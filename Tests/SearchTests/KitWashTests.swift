import AppKit
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct KitWashTests {
    private func alpha(_ color: NSColor) -> CGFloat { color.alphaComponent }

    @Test(arguments: [false, true])
    func aSecondaryButtonAndTheSettingsDrillCircleShareOneControlWash(dark: Bool) {
        let pill = KitPill.fill(.secondary, dark: dark)

        #expect(abs(alpha(pill) - (dark ? 0.1 : 0.063)) < 0.0001)
        #expect(pill.whiteComponent == (dark ? 1 : 0))
        #expect(pill == KitWash.control.color(dark: dark))
    }

    @Test(arguments: [false, true])
    func aPrimaryButtonAndASwitchThatIsOnShareOneInk(dark: Bool) {
        let pill = KitPill.fill(.primary, dark: dark)
        let track = KitSwitch.colors(on: true, dark: dark, lit: false).track

        #expect(abs(alpha(pill) - (dark ? 0.9 : 0.86)) < 0.0001)
        #expect(pill == track)
    }

    @Test(arguments: [false, true])
    func aFieldTrackIsAFaintWashThatDeepensWhenLit(dark: Bool) {
        let rest = KitWash.track.color(dark: dark)
        let lit = KitWash.track.color(dark: dark, plus: 0.03)

        #expect(abs(alpha(rest) - (dark ? 0.075 : 0.055)) < 0.0001)
        #expect(abs(alpha(lit) - alpha(rest) - 0.03) < 0.0001)
    }

    @Test func aWashFollowsTheAppearanceItIsDrawnIn() {
        let wash = KitWash.plate.color()
        var light: NSColor?
        var dark: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { light = wash.usingColorSpace(.genericGray) }
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { dark = wash.usingColorSpace(.genericGray) }

        #expect(light.map { abs($0.alphaComponent - 0.08) < 0.0001 && $0.whiteComponent == 0 } == true)
        #expect(dark.map { abs($0.alphaComponent - 0.14) < 0.0001 && $0.whiteComponent == 1 } == true)
    }
}
