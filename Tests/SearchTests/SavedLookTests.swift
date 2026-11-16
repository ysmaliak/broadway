import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5))) struct SavedLookTests {
    static func lines() -> [String] {
        var lines: [String] = []
        for dark in [false, true] {
            let side = dark ? "dark" : "light"
            func row(_ name: String, _ ground: Paint.Ground) -> String {
                "\(name) \(side) \(ground.stops.map(\.hex).joined(separator: ",")) \(ground.lightInk ? "L" : "D")"
            }
            for theme in SpaceLook.themes.prefix(9) {
                lines.append(row("theme \(theme.id)", theme.look.ground(dark: dark)))
            }
            for preset in SpaceLook.palette {
                lines.append(row("preset \(preset.id)", SpaceLook(colour: preset.id).ground(dark: dark)))
            }
            for hex in SpacePaintTests.swatches {
                for strength in [0, SpaceLook.calm, 0.5, SpaceLook.bold, 1] {
                    lines.append(row("swatch \(hex)@\(strength)", Paint.ground([hex], intensity: strength, dark: dark)))
                }
            }
        }
        return lines
    }

    @Test func everySavedLookPaintsTheGroundItPaintedBefore() {
        let before = SavedLookGrounds.table.split(separator: "\n").map(String.init)

        let now = Self.lines()

        #expect(now.count == before.count)
        for (was, is_) in zip(before, now) {
            #expect(was == is_)
        }
    }

}
