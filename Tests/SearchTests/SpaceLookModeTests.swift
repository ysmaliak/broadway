import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5)))
struct SpaceLookModeTests {
    struct OldLook: Decodable, Equatable {
        var colour = "gray"
        var custom: String?
        var colours: [String]?
        var intensity: Double?
        var transparency: Double = 0
        var grain: Double = 0
        var glass = false

        private enum Keys: String, CodingKey { case colour, custom, colours, intensity, transparency, grain, glass, v }

        init(from decoder: Decoder) throws {
            let saved = try decoder.container(keyedBy: Keys.self)
            colour = try saved.decodeIfPresent(String.self, forKey: .colour) ?? "gray"
            custom = try saved.decodeIfPresent(String.self, forKey: .custom)
            colours = try saved.decodeIfPresent([String].self, forKey: .colours).flatMap { $0.count > 1 ? Array($0.prefix(3)) : nil }
            intensity = try saved.decodeIfPresent(Double.self, forKey: .intensity).map { min(2, max(0, $0)) }
            let version = try saved.decodeIfPresent(Int.self, forKey: .v) ?? 1
            let oldDefaults = version < 2
            transparency = try saved.decodeIfPresent(Double.self, forKey: .transparency) ?? (oldDefaults ? 0.3 : 0)
            grain = try saved.decodeIfPresent(Double.self, forKey: .grain) ?? (oldDefaults ? 0.2 : 0)
            glass = try saved.decodeIfPresent(Bool.self, forKey: .glass) ?? oldDefaults
        }
    }

    struct OldSpace: Decodable {
        var id: UUID
        var name: String
        var colour: Int
        var look: OldLook?
    }

    static let stored: [String] = [
        #"{"colour":"graphite","transparency":0,"grain":0,"glass":false,"v":4}"#,
        #"{"colour":"sky","transparency":0,"grain":0,"glass":false,"v":4}"#,
        #"{"colour":"custom","custom":"3139FB","intensity":1,"transparency":0,"grain":0,"glass":false,"v":4}"#,
        #"{"colour":"custom","custom":"FF89B3","colours":["FF89B3","FF8A1F"],"intensity":0.75,"transparency":0,"grain":0,"glass":false,"v":4}"#,
        #"{"colour":"custom","custom":"000000","intensity":2,"transparency":0,"grain":0.3,"glass":false,"v":4}"#,
        #"{"colour":"custom","custom":"7B3FE4","transparency":0,"grain":0,"glass":false,"v":4}"#,
        #"{"colour":"sky","transparency":0.5,"grain":0,"glass":false,"v":4}"#,
        #"{"colour":"gray","transparency":0,"grain":0,"glass":true,"v":4}"#,
        #"{"colour":"coral"}"#,
    ]

    static func decoded(_ json: String) throws -> SpaceLook {
        try JSONDecoder().decode(SpaceLook.self, from: Data(json.utf8))
    }

    static func legacyGround(_ look: SpaceLook, dark: Bool) -> Paint.Ground {
        if let preset = look.palettePreset {
            let stop = dark ? Oklch(l: preset.dark.l, c: preset.dark.c, h: preset.hue) : Oklch(l: preset.light.l, c: preset.light.c, h: preset.hue)
            return Paint.Ground(stops: [stop], lightInk: Paint.lightInkLean(stop, dark: dark) > 0)
        }
        return Paint.ground(look.picked, intensity: look.strength, dark: dark)
    }

    @Test(arguments: stored)
    func aLookStoredBeforeModesPaintsAsItDidInBothAppearances(_ json: String) throws {
        let look = try Self.decoded(json)

        #expect(look.mode == nil)
        #expect(look.darkTone == nil && look.lightTone == nil)
        for dark in [false, true] {
            #expect(look.ground(dark: dark) == Self.legacyGround(look, dark: dark))
            #expect(look.shade(dark: dark) == dark)
        }
    }

    @Test(arguments: stored)
    @MainActor
    func aLookStoredBeforeModesTintsTheFieldAndPageAsBefore(_ json: String) throws {
        let look = try Self.decoded(json)
        let old = look.colour == "custom" ? SpaceLook(colours: look.picked, intensity: min(look.strength, SpaceLook.calm)).tint : look.tint

        for dark in [false, true] {
            #expect(look.pageTint.kitResolved(dark: dark).hexString == old.kitResolved(dark: dark).hexString)
            #expect(look.page(dark: dark) == PageGround.made(SpaceLook(tone: look.tone), dark: dark))
        }
    }

    @Test func eachLookStoredBeforeModesOpensInTheModeThatReproducesIt() throws {
        for preset in SpaceLook.palette {
            #expect(!SpaceLook(colour: preset.id).oneColour, "\(preset.id) changes with macOS")
        }
        for theme in SpaceLook.themes {
            #expect(theme.look.oneColour == (theme.intensity == SpaceLook.real), "\(theme.id)")
        }
        for offer in SpaceLook.offers {
            let constant = offer.look.ground(dark: true) == offer.look.ground(dark: false)
            #expect(offer.look.oneColour == constant, "\(offer.id)")
        }
        #expect(!SpaceLook(colours: ["0F9D94"], intensity: 1.5).oneColour)
        #expect(SpaceLook(colours: ["0F9D94"], intensity: SpaceLook.real).oneColour)
    }

    @Test func aLookWithModesIsReadBackAsWritten() throws {
        var look = SpaceLook(colour: "sky", transparency: 0.25, grain: 0.4)
        look.paint(SpaceLook.Tone(colours: ["3139FB", "FB3A4D"], intensity: 0.9), dark: true)
        look.paint(SpaceLook.Tone(colour: "peach"), dark: false)
        var one = SpaceLook(colour: "sage")
        one.choose(oneColour: true, dark: true)

        for written in [look, one] {
            let back = try JSONDecoder().decode(SpaceLook.self, from: try JSONEncoder().encode(written))
            #expect(back == written)
            for dark in [false, true] { #expect(back.ground(dark: dark) == written.ground(dark: dark)) }
        }
    }

    @Test func anOlderBroadwayReadsANewerLookAsItsLastColourAndKeepsTheSpace() throws {
        var look = SpaceLook(colour: "sky", grain: 0.4)
        look.paint(SpaceLook.Tone(colours: ["3139FB"], intensity: 0.9), dark: true)
        look.paint(SpaceLook.Tone(colour: "peach"), dark: false)
        let space = Space(id: UUID(), name: "Work", colour: 0, look: look)

        let old = try JSONDecoder().decode([OldSpace].self, from: try JSONEncoder().encode([space]))

        #expect(old.count == 1)
        #expect(old[0].name == "Work")
        #expect(old[0].look?.colour == "peach")
        #expect(old[0].look?.grain == 0.4)
    }

    @Test func unreadableNewFieldsAreDroppedAndTheLookStillReads() throws {
        let look = try Self.decoded(#"{"colour":"sky","v":4,"mode":"sometimes","fixed":7,"dark":"blue","light":{"colour":3}}"#)

        #expect(look.colour == "sky")
        #expect(look.mode == nil)
        #expect(look.fixed == nil)
        #expect(look.darkTone == nil)
        #expect(look.lightTone == SpaceLook.Tone())
    }

    @Test func theSideNotTouchedFollowsTheOneEditedUntilItIsEditedItself() {
        let blue = SpaceLook.Tone(colours: ["3139FB"], intensity: 1)
        let peach = SpaceLook.Tone(colour: "peach")
        var look = SpaceLook()

        look.paint(blue, dark: true)

        #expect(look.mode == .both)
        #expect(look.ground(dark: true) == blue.ground(dark: true))
        #expect(look.ground(dark: false) == blue.ground(dark: false))
        #expect(look.follows(dark: false))

        look.paint(peach, dark: false)

        #expect(look.ground(dark: true) == blue.ground(dark: true))
        #expect(look.ground(dark: false) == peach.ground(dark: false))
        #expect(!look.follows(dark: true) && !look.follows(dark: false))

        look.follow(dark: false)

        #expect(look.follows(dark: false))
        #expect(look.ground(dark: false) == blue.ground(dark: false))
        #expect(look.ground(dark: true) == blue.ground(dark: true))
    }

    @Test(arguments: [false, true])
    func oneColourKeepsWhatIsShownAndStopsChanging(_ dark: Bool) {
        var look = SpaceLook(colour: "sky", grain: 0.2)
        let before = look.ground(dark: dark)

        look.choose(oneColour: true, dark: dark)

        #expect(look.oneColour)
        #expect(look.ground(dark: dark) == before)
        #expect(look.ground(dark: !dark) == before)
        #expect(look.inkLight(dark: !dark) == before.lightInk)
        #expect(look.page(dark: !dark) == look.page(dark: dark))
        #expect(look.grain == 0.2)
    }

    @Test func oneColourKeepsANewColourTheSameInBothAppearances() {
        var look = SpaceLook()
        look.choose(oneColour: true, dark: false)

        look.paint(SpaceLook.Tone(colours: ["FB3A4D"], intensity: 0.5), dark: true)

        #expect(look.fixed == .light)
        #expect(look.ground(dark: true) == look.ground(dark: false))
        #expect(look.ground(dark: false) == SpaceLook.Tone(colours: ["FB3A4D"], intensity: 0.5).ground(dark: false))
    }

    @Test(arguments: [false, true])
    func goingBackToLightAndDarkFollowsMacOSFromTheSameColour(_ dark: Bool) {
        var look = SpaceLook(colour: "rose")
        look.choose(oneColour: true, dark: true)

        look.choose(oneColour: false, dark: dark)

        #expect(!look.oneColour)
        #expect(look.follows(dark: true) && look.follows(dark: false))
        #expect(look.ground(dark: true) == SpaceLook.Tone(colour: "rose").ground(dark: true))
        #expect(look.ground(dark: false) == SpaceLook.Tone(colour: "rose").ground(dark: false))
    }

    @Test func theGridHasAtMostTwelveSwatchesAndNoNearTwins() {
        func lab(_ o: Oklch) -> (Double, Double, Double) { (o.l, o.c * cos(o.h * .pi / 180), o.c * sin(o.h * .pi / 180)) }
        func apart(_ a: SpaceLook.Tone, _ b: SpaceLook.Tone) -> Double {
            [false, true].map { dark -> Double in
                let x = lab(a.ground(dark: dark).average), y = lab(b.ground(dark: dark).average)
                return ((x.0 - y.0) * (x.0 - y.0) + (x.1 - y.1) * (x.1 - y.1) + (x.2 - y.2) * (x.2 - y.2)).squareRoot()
            }.max() ?? 0
        }
        let swatches = SpaceLook.swatches

        #expect(swatches.count == 12)
        #expect(swatches.first?.tone == SpaceLook().tone)
        for (index, swatch) in swatches.enumerated() {
            for other in swatches.dropFirst(index + 1) {
                #expect(apart(swatch.tone, other.tone) > 0.035, "\(swatch.id) and \(other.id)")
            }
        }
    }

    @Test func moreOpensForAnythingTheGridCannotShow() {
        #expect(!SpaceLookEditorView.needsMore(SpaceLook()))
        #expect(!SpaceLookEditorView.needsMore(SpaceLook.themes.first { $0.id == "sunset" }!.look))
        #expect(SpaceLookEditorView.needsMore(SpaceLook(colours: ["123456"], intensity: 0.8)))
        #expect(SpaceLookEditorView.needsMore(SpaceLook(colours: ["FF89B3", "3139FB"], intensity: 0.8)))
        #expect(SpaceLookEditorView.needsMore(SpaceLook(colour: "sky", transparency: 0.3)))
        #expect(SpaceLookEditorView.needsMore(SpaceLook(colour: "sky", grain: 0.3)))
        #expect(SpaceLookEditorView.needsMore(SpaceLook(colour: "gray", glass: true)))
        var side = SpaceLook()
        side.paint(SpaceLook.Tone(colours: ["123456"], intensity: 0.8), dark: true)
        #expect(SpaceLookEditorView.needsMore(side))
    }

    @Test func everyLookOfferedElsewhereIsOneTheCardCanShow() {
        for offer in SpaceLook.offers {
            let look = offer.look
            let inGrid = [look.side(dark: true), look.side(dark: false)].allSatisfy { SpaceLook.swatch(for: $0) != nil }
            #expect(inGrid || SpaceLookEditorView.needsMore(look), "\(offer.id)")
        }
    }
}

extension SpaceLook {
    var palettePreset: Preset? { colour == "custom" ? nil : SpaceLook.palette.first { $0.id == colour } ?? SpaceLook.palette[1] }
}
