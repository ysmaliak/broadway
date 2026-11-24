import AppKit
import Testing
@testable import Search

@Suite
@MainActor
struct FieldPlateTests {
    private static func parts(_ colour: NSColor) -> (white: Double, alpha: Double) {
        let c = colour.usingColorSpace(.sRGB) ?? colour
        return (Double(c.redComponent), Double(c.alphaComponent))
    }

    static var grounds: [(name: String, ground: NSColor, dark: Bool)] {
        [false, true].flatMap { dark in
            let panel = (name: "panel \(dark ? "dark" : "light")", ground: Palette.NS.fieldPanel.kitResolved(dark: dark), dark: dark)
            let spaces = SidebarStyleTests.looks.map { name, look in
                let glass = Palette.NS.glassGround.kitResolved(dark: dark)
                return (name: "\(name) \(dark ? "dark" : "light")",
                        ground: SidebarStyleTests.over(glass, look.ground(dark: dark).stops[0].color), dark: dark)
            }
            return [panel] + spaces
        }
    }

    @Test func theSelectedPlateIsNeutralInkAtLowStrength() {
        let light = Self.parts(FieldPlate.tone(dark: false))
        let dark = Self.parts(FieldPlate.tone(dark: true))

        #expect(light.white < 0.01 && abs(light.alpha - 0.07) < 0.001)
        #expect(dark.white > 0.99 && abs(dark.alpha - 0.10) < 0.001)
    }

    @Test func theHoveredPlateIsHalfTheSelectedOneAndTheSidebarsHover() {
        for dark in [false, true] {
            let full = Self.parts(FieldPlate.tone(dark: dark))
            let hover = Self.parts(FieldPlate.tone(dark: dark, faint: true))
            let side = Self.parts(Palette.NS.sideHover.kitResolved(dark: dark))

            #expect(abs(hover.alpha - full.alpha / 2) < 0.001)
            #expect(abs(hover.white - side.white) < 0.01 && abs(hover.alpha - side.alpha) < 0.001)
        }
    }

    @Test func thePlateHasTheRowCorner() {
        let art = FieldSlabArt()

        #expect(FieldPlate.radius == 10)
        #expect(art.cornerRadius == FieldPlate.radius && art.cornerCurve == .continuous)
        #expect(art.shadowOpacity == 0 && art.sublayers == nil)
    }

    @Test func aTitleReadsAtFourAndAHalfOnTheSelectedPlate() {
        for seen in Self.grounds {
            let plate = SidebarStyleTests.over(FieldPlate.tone(dark: seen.dark), seen.ground)

            let title = SidebarStyleTests.over(KitColor.ink.kitResolved(dark: seen.dark), plate)

            #expect(SidebarStyleTests.contrast(title, plate) >= 4.5, "\(seen.name)")
        }
    }

    @Test func aSecondLineLosesLittleToThePlate() {
        for seen in Self.grounds {
            let plate = SidebarStyleTests.over(FieldPlate.tone(dark: seen.dark), seen.ground)
            let muted = KitColor.muted.kitResolved(dark: seen.dark)

            let onPlate = SidebarStyleTests.contrast(SidebarStyleTests.over(muted, plate), plate)
            let bare = SidebarStyleTests.contrast(SidebarStyleTests.over(muted, seen.ground), seen.ground)

            #expect(onPlate >= 3, "\(seen.name)")
            #expect(onPlate >= bare * 0.85, "\(seen.name)")
        }
    }
}
