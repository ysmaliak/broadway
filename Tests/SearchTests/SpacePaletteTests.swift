import Testing
import AppKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SpacePaletteTests {
    private func resolved(_ color: NSColor, dark: Bool) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var out = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0))
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            out = (c.redComponent, c.greenComponent, c.blueComponent)
        }
        return out
    }

    @Test func theDarkestChoiceIsNeutralAndDeeperThanATerminalGrey() {
        let graphite = SpaceLook(colour: "graphite")

        let c = resolved(graphite.tint, dark: true)

        #expect(abs(c.r - c.g) <= 0.004)
        #expect(abs(c.g - c.b) <= 0.004)
        #expect(c.r <= (0x28 / 255.0))
    }

    @Test func everyDarkChoiceStaysDarkAndEveryLightChoiceStaysLight() {
        let looks = SpaceLook.presets.map { SpaceLook(colour: $0.id) }

        let dark = looks.map { resolved($0.tint, dark: true) }
        let light = looks.map { resolved($0.tint, dark: false) }

        for c in dark { #expect(max(c.r, c.g, c.b) < 0.3) }
        for c in light { #expect(min(c.r, c.g, c.b) > 0.78) }
    }

    @Test func aNewLookIsFlat() {
        let look = SpaceLook()

        let flat = (look.transparency, look.grain, look.glass)

        #expect(flat.0 == 0)
        #expect(flat.1 == 0)
        #expect(!flat.2)
    }

    @Test func anOldLookOnTheOldDefaultsBecomesFlatAndKeepsItsColour() throws {
        let json = #"{"colour":"graphite","transparency":0.3,"grain":0.2,"glass":true}"#

        let look = try JSONDecoder().decode(SpaceLook.self, from: Data(json.utf8))

        #expect(look.colour == "graphite")
        #expect(look.transparency == 0)
        #expect(look.grain == 0)
        #expect(!look.glass)
    }

    @Test func anOldLookSomeoneChangedKeepsWhatTheyChose() throws {
        let json = #"{"colour":"custom","custom":"3366CC","transparency":0.6,"grain":0.2,"glass":true}"#

        let look = try JSONDecoder().decode(SpaceLook.self, from: Data(json.utf8))

        #expect(look.custom == "3366CC")
        #expect(look.transparency == 0.6)
        #expect(look.glass)
    }

    @Test func aNewLookIsReadBackAsWritten() throws {
        let look = SpaceLook(colour: "sky", transparency: 0.3, grain: 0.2, glass: true)

        let back = try JSONDecoder().decode(SpaceLook.self, from: JSONEncoder().encode(look))

        #expect(back == look)
    }

    @Test func aCustomColourKeepsItsHue() {
        let blue = SpaceLook(colour: "custom", custom: "2060E0")

        let c = resolved(blue.tint, dark: true)

        #expect(c.b > c.r)
        #expect(max(c.r, c.g, c.b) < 0.3)
    }
}
