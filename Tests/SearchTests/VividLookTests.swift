import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5))) struct VividLookTests {
    static let extremes = ["000000", "0A0A0A", "000354", "2404AA", "3139FB", "FB3A4D", "39FF14", "FFFFFF"]
    static let vivid = [1.0, 1.25, 1.5, 1.75, SpaceLook.real]

    @Test(arguments: [false, true])
    func everyExtremeReachesItsOwnColour(dark: Bool) {
        let picks = Self.extremes + [SpaceLook.volt]

        let painted = picks.map { Paint.ground([$0], intensity: SpaceLook.real, dark: dark).stops[0].code }

        #expect(painted == picks)
    }

    @Test(arguments: [false, true])
    func inkStaysReadableAtEveryExtreme(dark: Bool) {
        let picks = Self.extremes + SpacePaintTests.swatches + ["808080", "6E6E6E", "7B3FE4", SpaceLook.volt]

        let worst = picks.flatMap { hex in
            Self.vivid.map { strength -> (String, Double, Double, Double) in
                let ground = Paint.ground([hex], intensity: strength, dark: dark)
                let ink = Paint.ink(light: ground.lightInk, lift: ground.lift)
                return (hex, strength,
                        Paint.contrast(ink: ink, alpha: Paint.titleAlpha(ground.lift), on: ground.stops[0]),
                        Paint.contrast(ink: ink, alpha: Paint.quietAlpha(ground.lift), on: ground.stops[0]))
            }
        }

        for (hex, strength, title, quiet) in worst {
            #expect(title >= Paint.titleContrast, "\(hex) at \(strength): titles \(title)")
            #expect(quiet >= Paint.quietContrast, "\(hex) at \(strength): quiet \(quiet)")
        }
    }

    @Test(arguments: [false, true])
    func deepGroundsTakeLightInkAndBrightOnesDark(dark: Bool) {
        let deep = ["000000", "0A0A0A", "000354", "2404AA", "3139FB"]
        let bright = ["FFFFFF", "39FF14", "FB3A4D"]

        let deepInk = deep.map { Paint.ground([$0], intensity: SpaceLook.real, dark: dark).lightInk }
        let brightInk = bright.map { Paint.ground([$0], intensity: SpaceLook.real, dark: dark).lightInk }

        #expect(deepInk.allSatisfy { $0 })
        #expect(brightInk.allSatisfy { !$0 })
    }

    @Test func blackNeedsNoLiftedInk() {
        let black = SpaceLook(colours: ["000000"], intensity: SpaceLook.real)

        let grounds = [black.ground(dark: false), black.ground(dark: true)]

        #expect(grounds.allSatisfy { $0.lift == 0 && $0.lightInk })
        #expect(grounds.allSatisfy { $0.stops[0].hex == "000000" })
    }

    @Test func midTonesMoveTheInkNotTheGround() {
        let mids = ["3139FB", "FB3A4D", "808080"]

        let grounds = mids.map { Paint.ground([$0], intensity: SpaceLook.real, dark: false) }

        #expect(grounds.map { $0.stops[0].hex } == mids)
        #expect(grounds.allSatisfy { $0.lift > 0 })
    }

    @Test func savedLooksKeepTheirOwnInk() {
        let looks = SpaceLook.themes.prefix(9).map(\.look) + SpaceLook.palette.map { SpaceLook(colour: $0.id) }
            + SpacePaintTests.swatches.map { SpaceLook(colours: [$0], intensity: 1) }

        let lifts = looks.flatMap { look in [false, true].map { look.ground(dark: $0).lift } }

        #expect(lifts.allSatisfy { $0 == 0 })
    }

    @Test func theVividRangeIsSavedAndReadBack() throws {
        let look = SpaceLook(colours: ["000000"], intensity: SpaceLook.real, grain: 0.2)
        let tooFar = #"{"colour":"custom","custom":"000000","intensity":7,"transparency":0,"grain":0,"glass":false,"v":3}"#
        let bold = #"{"colour":"custom","custom":"3139FB","intensity":0.8,"transparency":0,"grain":0,"glass":false,"v":3}"#

        let back = try JSONDecoder().decode(SpaceLook.self, from: JSONEncoder().encode(look))
        let clamped = try JSONDecoder().decode(SpaceLook.self, from: Data(tooFar.utf8))
        let kept = try JSONDecoder().decode(SpaceLook.self, from: Data(bold.utf8))

        #expect(back == look)
        #expect(back.vivid(dark: true) == 1)
        #expect(clamped.intensity == SpaceLook.real)
        #expect(kept.intensity == 0.8)
        #expect(kept.vivid(dark: true) == 0)
    }

    @Test func aBlackSpaceKeepsACalmPageInLight() {
        let black = SpaceLook(colours: ["000000"], intensity: SpaceLook.real)
        let bold = SpaceLook(colours: ["000000"], intensity: SpaceLook.bold)

        var page = NSColor.black, before = NSColor.black
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            page = black.pageTint.usingColorSpace(.sRGB)!
            before = bold.pageTint.usingColorSpace(.sRGB)!
        }

        #expect(page == before)
        #expect(page.redComponent > 0.75)
    }

    @Test func theIntensityTrackHasAVividEnd() {
        let points = [0, 0.3, SpaceLook.knee, 0.8, 0.9, 1]

        let back = points.map { SpaceLook.position(of: SpaceLook.intensity(at: $0)) }

        #expect(SpaceLook.position(of: SpaceLook.bold) < SpaceLook.knee)
        #expect(SpaceLook.intensity(at: SpaceLook.knee) == 1)
        #expect(SpaceLook.intensity(at: 1) == SpaceLook.real)
        for (was, now) in zip(points, back) { #expect(abs(was - now) < 0.0001) }
        #expect(SpaceLook.spoken(1) == "Vivid 100%")
        #expect(SpaceLook.spoken(SpaceLook.position(of: SpaceLook.bold)) == "80%")
    }

    @Test func toneReachesBlackAndWhite() {
        let blue = ["3139FB"]

        let black = ThemePad.retoned(blue, 0)
        let white = ThemePad.retoned(blue, 1)

        #expect(black == ["000000"])
        #expect(white == ["FFFFFF"])
    }

    @Test func displayP3ColoursAreKeptAsThemselves() {
        let volt = Oklch(hex: SpaceLook.volt)
        let arc = Oklch(hex: "3139FB")

        let wide = NSColor(hexString: SpaceLook.volt)
        let narrow = NSColor(hexString: "3139FB")

        #expect(!volt.inGamut && volt.inP3)
        #expect(volt.c > arc.c)
        #expect(volt.code == SpaceLook.volt)
        #expect(wide.code == SpaceLook.volt)
        #expect(narrow.code == "3139FB")
        #expect(volt.color.colorSpace == .displayP3)
    }

    @Test func theNewThemesSitBesideTheOldOnes() {
        let ids = SpaceLook.themes.map(\.id)

        let added = Array(ids.dropFirst(9))

        #expect(ids.prefix(9) == ["cobalt", "ember", "midnight", "ink", "sunset", "lagoon", "lilac", "citrus", "aurora"])
        #expect(added == ["onyx", "abyss", "volt"])
        #expect(ids.count % 3 == 0)
    }

    @MainActor @Test func liftedInkIsThePaletteUntilTheGroundAsksForMore() {
        let calm = KitInk(lift: 0)
        let lifted = KitInk(lift: 1)

        let before = Palette.NS.muted.kitResolved(dark: true)
        let same = calm.color(KitColor.muted, .quiet, dark: true)
        let strong = lifted.color(KitColor.muted, .quiet, dark: true)
        let title = lifted.color(KitColor.title, .title, dark: true)

        let a = same.usingColorSpace(.sRGB)!
        let b = before.usingColorSpace(.sRGB)!
        #expect(abs(a.redComponent - b.redComponent) < 0.001 && abs(a.alphaComponent - b.alphaComponent) < 0.001)
        #expect(abs(Double(strong.alphaComponent) - Paint.liftedQuiet) < 0.001)
        #expect(abs(Double(title.alphaComponent) - Paint.liftedTitle) < 0.001)
        #expect(strong.usingColorSpace(.sRGB)!.redComponent > before.usingColorSpace(.sRGB)!.redComponent)
    }
}
