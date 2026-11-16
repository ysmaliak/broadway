import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5))) struct SpacePaintTests {
    static let swatches = [
        "FFFFFF", "FFFCEC", "FFD3E0", "FFF0A6", "E8FF1A", "8BE33A", "0F9D94", "7CC4F2",
        "3139FB", "000354", "7B3FE4", "FB3A4D", "FF8A1F", "7A4B2C", "808080", "000000",
        "FF89B3", "F0B4FF", "8CACFF", "2404AA", "96C4FF", "FF0000", "00FF00", "0000FF",
        "00FFFF", "FF00FF", "FFFF00", "C0C0C0", "404040", "556B2F", "B8860B", "4B0082",
    ]
    static let strengths = [0, SpaceLook.calm, 0.3, 0.45, 0.6, 0.7, 0.8, 0.9, 1]

    private func ink(_ ground: Paint.Ground) -> Double { ground.lightInk ? Paint.lightInk : Paint.darkInk }

    @Test(arguments: [false, true])
    func everySwatchKeepsTitlesReadable(dark: Bool) {
        let looks = Self.swatches.flatMap { hex in Self.strengths.map { (hex, $0) } }

        let worst = looks.map { hex, strength -> (String, Double, Double) in
            let ground = Paint.ground([hex], intensity: strength, dark: dark)
            return (hex, strength, Paint.contrast(ink: ink(ground), alpha: Paint.title, on: ground.stops[0]))
        }.min { $0.2 < $1.2 }!

        #expect(worst.2 >= 4.5, "\(worst.0) at \(worst.1): \(worst.2)")
    }

    @Test(arguments: [false, true])
    func everySwatchKeepsQuietTextAndIconsVisible(dark: Bool) {
        let looks = Self.swatches.flatMap { hex in Self.strengths.map { (hex, $0) } }

        let contrasts = looks.map { hex, strength -> Double in
            let ground = Paint.ground([hex], intensity: strength, dark: dark)
            return Paint.contrast(ink: ink(ground), alpha: Paint.quiet, on: ground.stops[0])
        }

        #expect(contrasts.min()! >= 3.0)
    }

    @Test func titlesAreReadableAtFullStrengthOnTheResolvedPalette() {
        let dark = NSAppearance(named: .darkAqua)!
        let light = NSAppearance(named: .aqua)!

        let pairs: [(NSAppearance, Bool)] = [(light, false), (dark, true)]
        let ratios = pairs.flatMap { appearance, isDark in
            Self.swatches.map { hex -> Double in
                let ground = Paint.ground([hex], intensity: 1, dark: isDark)
                var ink = 0.0
                appearance.performAsCurrentDrawingAppearance {
                    let scheme = NSAppearance(named: ground.lightInk ? .darkAqua : .aqua)!
                    scheme.performAsCurrentDrawingAppearance {
                        ink = Double(Palette.NS.ink.usingColorSpace(.sRGB)!.redComponent)
                    }
                }
                return Paint.contrast(ink: ink, alpha: Paint.title, on: ground.stops[0])
            }
        }

        #expect(ratios.min()! >= 4.5)
    }

    @Test func mutedGreysStayAsTheyWereOnTheirOwnGrounds() {
        func over(_ colour: NSColor, ground: CGFloat, dark: Bool) -> CGFloat {
            var out: CGFloat = 0
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                let c = colour.usingColorSpace(.sRGB)!
                out = c.redComponent * c.alphaComponent + ground * (1 - c.alphaComponent)
            }
            return out
        }

        let muted = (over(Palette.NS.muted, ground: 1, dark: false), over(Palette.NS.muted, ground: 0.22, dark: true))
        let faint = (over(Palette.NS.faint, ground: 1, dark: false), over(Palette.NS.faint, ground: 0.22, dark: true))
        let hairline = (over(Palette.NS.hairline, ground: 1, dark: false), over(Palette.NS.hairline, ground: 0.22, dark: true))

        #expect(abs(muted.0 - 0.55) < 0.01 && abs(muted.1 - 0.58) < 0.01)
        #expect(abs(faint.0 - 0.83) < 0.01 && abs(faint.1 - 0.42) < 0.01)
        #expect(abs(hairline.0 - 0.91) < 0.01 && abs(hairline.1 - 0.30) < 0.01)
    }

    @Test(arguments: [false, true])
    func aBlendSharesOneInkAndStaysReadableBetweenItsColours(dark: Bool) {
        let blends = SpaceLook.themes.map(\.colours) + [["000354", "FFF0A6"], ["FFFFFF", "000000", "FB3A4D"], ["3139FB", "E8FF1A"]]

        let worst = blends.flatMap { colours -> [Double] in
            let ground = Paint.ground(colours, intensity: 1, dark: dark)
            let stops = LookBlend.three(ground).map { $0.usingColorSpace(.sRGB)! }
            let between = zip(stops, stops.dropFirst()).flatMap { a, b in
                stride(from: 0.0, through: 1, by: 0.125).map { share -> Double in
                    let mixed = LookBlend.mix(a, b, share).usingColorSpace(.sRGB)!
                    let ground = Oklch(hex: mixed.hexString)
                    return Paint.contrast(ink: ink(Paint.ground(colours, intensity: 1, dark: dark)), alpha: Paint.title, on: ground)
                }
            }
            return between
        }.min()!

        #expect(worst >= 4.4)
    }

    @Test func darkAppearanceDeepensEveryColour() {
        let grounds = Self.swatches.map { Paint.ground([$0], intensity: 1, dark: true) }

        let lightest = grounds.map { $0.stops[0].l }.max()!

        #expect(grounds.allSatisfy { $0.lightInk })
        #expect(lightest <= 0.36)
    }

    @Test func aBoldColourReachesTheWindowAsItself() {
        let blue = Oklch(hex: "3139FB")

        let ground = Paint.ground(["3139FB"], intensity: 1, dark: false)

        #expect(ground.lightInk)
        #expect(ground.stops[0].c > 0.12)
        #expect(abs(ground.stops[0].h - blue.h) < 8)
    }

    @Test func darkPicksStayDarkAndPalePicksStayPaleInLight() {
        let navy = Paint.ground(["000354"], intensity: 1, dark: false)
        let black = Paint.ground(["000000"], intensity: 1, dark: false)
        let butter = Paint.ground(["FFF0A6"], intensity: 1, dark: false)

        let lightness = (navy.stops[0].l, black.stops[0].l, butter.stops[0].l)

        #expect(lightness.0 < 0.3 && navy.lightInk)
        #expect(lightness.1 < 0.25 && black.lightInk)
        #expect(lightness.2 > 0.9 && !butter.lightInk)
    }

    @Test func neonIsTamed() {
        let neon = Oklch(hex: "E8FF1A")

        let ground = Paint.ground(["E8FF1A"], intensity: 1, dark: false).stops[0]

        #expect(ground.c < neon.c * 0.8)
        #expect(ground.l < neon.l)
    }

    @Test func midTonesLeaveTheMiddle() {
        let mids = ["808080", "0F9D94", "FB3A4D", "7CC4F2", "FF8A1F", "8BE33A"]

        let grounds = mids.map { Paint.ground([$0], intensity: 1, dark: false) }

        for ground in grounds {
            #expect(Paint.contrast(ink: ink(ground), alpha: 1, on: ground.stops[0]) >= 5.5)
        }
    }

    @Test func aSavedCustomColourWithoutStrengthKeepsItsCalmLook() throws {
        let json = #"{"colour":"custom","custom":"3366CC","transparency":0,"grain":0,"glass":false,"v":2}"#

        let look = try JSONDecoder().decode(SpaceLook.self, from: Data(json.utf8))
        let light = look.ground(dark: false).stops[0]

        #expect(look.intensity == nil)
        #expect(look.strength == SpaceLook.calm)
        #expect(look.picked == ["3366CC"])
        #expect(light.l > 0.85)
        #expect(!look.inkLight(dark: false))
    }

    @Test func aBlendAndItsStrengthAreReadBackAsWritten() throws {
        let look = SpaceLook(colours: ["FF89B3", "FF8A1F", "7B3FE4"], intensity: 0.7, grain: 0.3)

        let back = try JSONDecoder().decode(SpaceLook.self, from: JSONEncoder().encode(look))

        #expect(back == look)
        #expect(back.picked == ["FF89B3", "FF8A1F", "7B3FE4"])
        #expect(back.hex == "FF89B3")
    }

    @Test func aPresetKeepsItsOwnCalmTint() {
        let looks = SpaceLook.palette.map { SpaceLook(colour: $0.id) }

        let light = looks.map { $0.ground(dark: false) }
        let dark = looks.map { $0.ground(dark: true) }

        #expect(light.allSatisfy { !$0.lightInk })
        #expect(dark.allSatisfy { $0.lightInk })
    }

    @Test func aSlideHandsTheInkOverHalfway() {
        let pale = SpaceLook(colours: ["FFF0A6"], intensity: 1)
        let deep = SpaceLook(colours: ["000354"], intensity: 1)

        let early = LookBlend(from: pale, to: deep, share: 0.4).inkLight(dark: false)
        let late = LookBlend(from: pale, to: deep, share: 0.6).inkLight(dark: false)

        #expect(!early)
        #expect(late)
    }
}

@Suite(.timeLimit(.minutes(5))) struct ThemePadTests {
    @Test func aToneDragThatComesBackKeepsTheColour() {
        let start = ["FFF0A6", "3139FB"]
        let home = ThemePad.toneValue(start)

        _ = ThemePad.retoned(start, 0)
        let back = ThemePad.retoned(start, home)

        for (was, now) in zip(start, back) {
            #expect(abs(Oklch(hex: was).c - Oklch(hex: now).c) < 0.03)
        }
    }

    @Test func aDotAddedBesideAColourIsAnotherColour() {
        let colours = ["3139FB"]

        let partner = Oklch(hex: ThemePad.partner(for: colours))

        #expect(abs(partner.h - Oklch(hex: colours[0]).h) > 60)
        #expect(partner.c > 0.05)
    }
}

@Suite(.timeLimit(.minutes(5))) struct ThemeToneTests {
    @Test func toneMovesABlendWithoutFlatteningIt() {
        let midnight = ["000354", "FFF0A6"]

        let lighter = ThemePad.retoned(midnight, min(1, ThemePad.toneValue(midnight) + 0.1)).map { Oklch(hex: $0).l }

        #expect(lighter[1] - lighter[0] > 0.4)
        #expect(lighter[0] > Oklch(hex: midnight[0]).l)
    }
}
