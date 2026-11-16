import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PinTintTests {
    private func fill(_ count: Int, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> [PinTint.Pixel] {
        Array(repeating: PinTint.Pixel(red: r, green: g, blue: b, alpha: a), count: count)
    }

    private func image(_ draw: @escaping (CGRect) -> Void) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            draw(rect)
            return true
        }
    }

    @Test func solidRedIsRed() {
        let tint = PinTint.derive(fill(256, 0.9, 0.1, 0.1))
        #expect(abs((tint.hue ?? -1) - 0) <= 0.02)
        #expect(tint.saturation > 0.8)
        #expect(tint.mark == .asIs)
    }

    @Test func redAroundTheWrapStaysRed() {
        let tint = PinTint.derive(fill(128, 0.9, 0.1, 0.2) + fill(128, 0.9, 0.2, 0.1))
        let hue = tint.hue ?? 0.5
        #expect(min(hue, 1 - hue) < 0.03)
    }

    @Test func blueOnWhiteIsBlue() {
        let tint = PinTint.derive(fill(200, 1, 1, 1) + fill(56, 0.15, 0.4, 0.95))
        #expect(abs((tint.hue ?? -1) - 0.6) <= 0.04)
    }

    @Test func greyHasNoHue() {
        #expect(PinTint.derive(fill(256, 0.5, 0.5, 0.5)) == PinTint(hue: nil, saturation: 0, mark: .asIs))
    }

    @Test func blackMarkIsADarkGlyph() {
        let tint = PinTint.derive(fill(120, 0.05, 0.05, 0.06) + fill(136, 0, 0, 0, 0))
        #expect(tint.hue == nil)
        #expect(tint.mark == .darkGlyph)
    }

    @Test func whiteMarkIsALightGlyph() {
        let tint = PinTint.derive(fill(100, 1, 1, 1) + fill(156, 0, 0, 0, 0))
        #expect(tint.hue == nil)
        #expect(tint.mark == .lightGlyph)
    }

    @Test func transparentIsNeutral() {
        #expect(PinTint.derive(fill(256, 1, 0, 0, 0)) == .neutral)
        #expect(PinTint.derive([]) == .neutral)
    }

    @Test func aSpeckOfColourIsNotEnough() {
        let tint = PinTint.derive(fill(250, 0.1, 0.1, 0.1) + fill(6, 1, 0.8, 0))
        #expect(tint.hue == nil)
        #expect(tint.mark == .darkGlyph)
    }

    @Test func darkColourIsIgnored() {
        #expect(PinTint.derive(fill(256, 0.15, 0.02, 0.02)).hue == nil)
    }

    @Test func theMostCommonHueWins() {
        let tint = PinTint.derive(fill(160, 0.2, 0.8, 0.3) + fill(60, 0.95, 0.3, 0.1))
        #expect(abs((tint.hue ?? -1) - 0.37) <= 0.05)
    }

    @Test @MainActor func drawnImageIsReadAndCached() {
        let orange = image { rect in
            NSColor(srgbRed: 1, green: 0.55, blue: 0, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
        }
        let tint = PinTint.of(orange)
        #expect(abs((tint.hue ?? -1) - 0.09) <= 0.03)
        #expect(PinTint.of(orange) == tint)
    }

    @Test @MainActor func templateAndMissingIconsAreNeutral() {
        let mark = image { rect in NSBezierPath(rect: rect).fill() }
        mark.isTemplate = true
        #expect(PinTint.of(mark) == .neutral)
        #expect(PinTint.of(nil) == .neutral)
    }

    @Test func statesGetStronger() {
        let order: [PinLook.State] = [.resting, .hovered, .picked, .live]
        for dark in [true, false] {
            for part in [PinLook.Part.fill, .edge] {
                for (weaker, stronger) in zip(order, order.dropFirst()) {
                    #expect(PinLook.gain(dark: dark, part: part, state: weaker) < PinLook.gain(dark: dark, part: part, state: stronger))
                }
            }
        }
    }

    @Test func onlyTheLiveTileTakesTheSiteColour() {
        #expect(!PinLook.hued(.resting))
        #expect(!PinLook.hued(.hovered))
        #expect(!PinLook.hued(.picked))
        #expect(PinLook.hued(.live))
    }

    @Test func restingTilesLiftOffTheGround() {
        func alpha(_ part: PinLook.Part, dark: Bool) -> CGFloat {
            PinLook.colour(.frame, .flat, part: part, state: .resting, dark: dark).alphaComponent
        }

        #expect(abs(alpha(.fill, dark: true) - 0.10) <= 0.005)
        #expect(alpha(.edge, dark: true) == 0)
        #expect(abs(alpha(.fill, dark: false) - 0.55) <= 0.005)
        #expect(alpha(.edge, dark: false) == 0)
    }

    @Test func liveRingIsBrighterOutside() {
        for dark in [true, false] {
            #expect(PinLook.neutralRing(dark: dark, band: .outer) > PinLook.neutralRing(dark: dark, band: .inner))
        }
        #expect(PinLook.ring == 3)
    }

    @Test func aSecondStrongHueIsKept() {
        let pixels = fill(150, 0.1, 0.75, 0.7) + fill(90, 0.95, 0.55, 0.1)

        let tint = PinTint.derive(pixels)

        #expect(tint.hues.count == 2)
        #expect(abs(tint.hues[0].hue - 0.49) <= 0.05)
        #expect(abs(tint.hues[1].hue - 0.1) <= 0.05)
    }

    @Test func neighbouringHuesCountOnce() {
        let pixels = fill(150, 0.9, 0.1, 0.1) + fill(90, 0.9, 0.2, 0.1)

        let tint = PinTint.derive(pixels)

        #expect(tint.hues.count == 1)
    }

    @Test func theLiveRingGlowsFromOneCornerAndFadesToNeutral() {
        let tint = PinTint.derive(fill(256, 0.1, 0.75, 0.7))

        for dark in [true, false] {
            let stops = PinFaceView.ringColours(tint, .inner, dark: dark).map(Stop.init)

            let hot = stops[0], cold = stops[3]
            #expect((max(hot.red, hot.green, hot.blue) - min(hot.red, hot.green, hot.blue)) > 0.3)
            #expect(abs(cold.red - cold.green) <= 0.01)
            #expect(abs(cold.green - cold.blue) <= 0.01)
            #expect(cold.opacity < hot.opacity)
            #expect(stops.first == stops.last)
        }
    }

    @Test func aMonochromeMarkGetsALightToGreyRing() {
        let tint = PinTint.derive(fill(256, 0.05, 0.05, 0.05))

        let stops = PinFaceView.ringColours(tint, .outer, dark: true).map(Stop.init)

        #expect(tint.hues.isEmpty)
        #expect(abs(stops[0].red - 1) <= 0.01)
        #expect(stops[0].opacity > stops[3].opacity)
    }

    private struct Stop: Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let opacity: CGFloat

        init(_ colour: CGColor) {
            let c = NSColor(cgColor: colour)?.usingColorSpace(.sRGB) ?? .clear
            red = c.redComponent
            green = c.greenComponent
            blue = c.blueComponent
            opacity = c.alphaComponent
        }
    }

    private static let oneHue = PinTint(hue: 0.48, saturation: 0.85, mark: .asIs)
    private static let twoHues = PinTint(hue: 0.07, saturation: 0.9, mark: .asIs, others: [PinTint.Hue(hue: 0.52, saturation: 0.8)])
    private static let threeHues = PinTint(hue: 0, saturation: 0.85, mark: .asIs,
                                           others: [PinTint.Hue(hue: 0.36, saturation: 0.8), PinTint.Hue(hue: 0.63, saturation: 0.85)])

    private func seeds(_ count: Int) -> [String] { (0..<count).map { "https://site\($0).example/path" } }

    @Test func theSameSeedGivesTheSameMesh() {
        for dark in [true, false] {
            let tint = Self.twoHues.seeded("https://example.com/a")

            let one = PinMesh.draw(tint, dark: dark)
            let again = PinMesh.draw(tint, dark: dark)

            #expect(one == again)
            #expect(one.points.count == PinMesh.width * PinMesh.height && one.tones.count == PinMesh.width * PinMesh.height)
        }
    }

    @Test func differentSeedsGiveDifferentPlacements() {
        for dark in [true, false] {
            let draws = seeds(40).map { PinMesh.draw(Self.oneHue.seeded($0), dark: dark) }

            let placements = Set(draws.map { $0.points.map { "\($0.x),\($0.y)" }.joined(separator: " ") })
            let arrangements = Set(draws.map { $0.tones.map { "\($0.hue)/\($0.saturation)/\($0.brightness)" }.joined(separator: " ") })

            #expect(placements.count == draws.count)
            #expect(arrangements.count >= draws.count * 3 / 4)
        }
    }

    @Test func aZeroSeedStillGivesAWholeMesh() {
        for dark in [true, false] {
            let draw = PinMesh.draw(Self.oneHue, dark: dark)

            #expect(PinMesh.flaws(draw, dark: dark) == 0)
        }
    }

    @Test func everyColourKeepsCloseToOneOfTheIconsHues() {
        for tint in [Self.oneHue, Self.twoHues, Self.threeHues, PinTint(hue: 0.99, saturation: 0.8, mark: .asIs)] {
            for dark in [true, false] {
                let palette = PinMesh.palette(tint, dark: dark)

                for tone in palette {
                    let nearest = tint.hues.map { PinMesh.hueGap($0.hue, tone.hue) }.min() ?? 1
                    #expect(nearest <= 0.03)
                    #expect(tone.saturation > 0.05)
                }
            }
        }
    }

    @Test func aOneHueIconGetsFiveFields() {
        for dark in [true, false] {
            let palette = PinMesh.palette(Self.oneHue, dark: dark)

            #expect(palette.count == 5)
            #expect(PinMesh.distinct(palette) == 5)
        }
    }

    @Test func aNeutralIconGivesNoHue() {
        for pixels in [fill(256, 0.52, 0.52, 0.52), fill(100, 1, 1, 1) + fill(156, 0, 0, 0, 0), fill(120, 0.05, 0.05, 0.06)] {
            let tint = PinTint.derive(pixels).seeded("https://example.com")

            for dark in [true, false] {
                let draw = PinMesh.draw(tint, dark: dark)

                #expect(tint.hues.isEmpty)
                for tone in draw.tones {
                    #expect(tone.saturation == 0)
                }
                #expect(PinMesh.distinct(draw.tones) >= 3)
            }
        }
    }

    @Test(arguments: [0, 1, 2, 3])
    func noDullDrawOverFiveHundredSeeds(kind: Int) {
        let tint = [Self.oneHue, Self.twoHues, Self.threeHues, .neutral][kind]

        for dark in [true, false] {
            let rules = PinMesh.rules(dark: dark)
            for seed in seeds(500) {
                let draw = PinMesh.draw(tint.seeded(seed), dark: dark)

                #expect(PinMesh.distinct(draw.tones) >= 3)
                #expect(PinMesh.steepest(draw, dark: dark) <= rules.step)
                #expect(rules.mean.contains(PinMesh.mean(draw, dark: dark)))
                #expect(PinMesh.inner.allSatisfy { PinMesh.calm(draw.tones[$0].level) })
                #expect(PinMesh.innerSpread(draw, dark: dark) <= rules.calm)
                #expect(PinMesh.highlights(draw) >= PinMesh.fewestHighlights)
                #expect(PinMesh.openings(draw) >= PinMesh.fewestOpenings)
            }
        }
    }

    @Test func thePatchNeverFoldsOverItself() {
        for seed in seeds(500) {
            let points = PinMesh.draw(Self.twoHues.seeded(seed), dark: true).points

            let w = PinMesh.width, h = PinMesh.height
            for row in 0..<(h - 1) {
                for column in 0..<(w - 1) {
                    let corners = [points[row * w + column], points[row * w + column + 1], points[(row + 1) * w + column + 1], points[(row + 1) * w + column]]
                    let turns = (0..<4).map { index -> Swift.Float in
                        let a = corners[index], b = corners[(index + 1) % 4], c = corners[(index + 2) % 4]
                        return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
                    }
                    #expect(turns.allSatisfy { $0 > 0 })
                }
            }
            for index in PinMesh.rim {
                let row = index / w, column = index % w
                if row == 0 || row == h - 1 { #expect(points[index].y == Swift.Float(row) / Swift.Float(h - 1)) }
                if column == 0 || column == w - 1 { #expect(points[index].x == Swift.Float(column) / Swift.Float(w - 1)) }
            }
        }
    }

    @Test @MainActor func theMeshIsRenderedOncePerTintAndAppearance() throws {
        let tint = PinTint.derive(fill(256, 0.08, 0.68, 0.7)).seeded("https://example.com/kept")

        let dark = try #require(PinLook.mesh(tint, dark: true))
        let again = try #require(PinLook.mesh(tint, dark: true))
        let light = try #require(PinLook.mesh(tint, dark: false))

        #expect(dark === again)
        #expect(!(dark === light))
        #expect(dark.width == Int(PinMesh.size.width * 2) && dark.height == Int(PinMesh.size.height * 2))
    }

    @Test @MainActor func theMeshCacheDropsItsOldestPictureOnly() throws {
        let first = Self.oneHue.seeded("https://example.com/first-kept")
        let kept = try #require(PinLook.mesh(first, dark: true))

        for seed in seeds(PinLook.meshesKept * 2) {
            _ = PinLook.mesh(Self.twoHues.seeded(seed + "/churn"), dark: true)
        }
        let recent = Self.twoHues.seeded(seeds(PinLook.meshesKept * 2).last! + "/churn")
        let stillKept = try #require(PinLook.mesh(recent, dark: true))
        let again = try #require(PinLook.mesh(recent, dark: true))

        #expect(PinLook.meshCount <= PinLook.meshesKept)
        #expect(stillKept === again)
        #expect(!(try #require(PinLook.mesh(first, dark: true)) === kept))
    }

    @Test func onlyAPickedTileIsOutlinedInDark() {
        func edge(_ state: PinLook.State, dark: Bool) -> CGFloat {
            PinLook.colour(.frame, .flat, part: .edge, state: state, dark: dark).alphaComponent
        }

        #expect(edge(.resting, dark: true) == 0 && edge(.hovered, dark: true) == 0)
        #expect(edge(.picked, dark: true) >= 0.15)
        #expect(edge(.picked, dark: false) > edge(.hovered, dark: false))
    }

    @Test func aBlackSilhouetteFollowsTheInk() {
        let tint = PinTint.derive(fill(120, 0.05, 0.05, 0.06) + fill(136, 0, 0, 0, 0))

        #expect(tint.shape == .glyph)
        #expect(tint.dress(dark: true) == .ink)
        #expect(tint.dress(dark: false) == .plain)
        #expect(tint.chip(dark: true) == nil)
    }

    @Test func aWhiteSilhouetteFollowsTheInkOnALightGround() {
        let tint = PinTint.derive(fill(100, 1, 1, 1) + fill(156, 0, 0, 0, 0))

        #expect(tint.dress(dark: false) == .ink)
        #expect(tint.dress(dark: true) == .plain)
    }

    @Test func aDarkTileKeepsItsFaceAndGetsAnEdge() {
        let tile = PinTint.derive(fill(220, 0.05, 0.05, 0.06) + fill(30, 1, 1, 1) + fill(6, 0, 0, 0, 0))
        let square = PinTint.derive(fill(256, 0.05, 0.05, 0.05))
        let disc = PinTint.derive(fill(170, 0.05, 0.05, 0.06) + fill(30, 1, 1, 1) + fill(56, 0, 0, 0, 0))

        for tint in [tile, square, disc] {
            #expect(tint.mark == .darkGlyph)
            #expect(tint.shape == .solid)
            #expect(tint.dress(dark: true) == .edge)
            #expect(tint.dress(dark: false) == .plain)
            #expect(tint.backing(dark: true) == nil)
        }
    }

    @Test func aWhiteTileGetsAnEdgeOnALightGround() {
        let tint = PinTint.derive(fill(240, 1, 1, 1) + fill(10, 0.3, 0.3, 0.3) + fill(6, 0, 0, 0, 0))

        #expect(tint.mark == .lightGlyph)
        #expect(tint.dress(dark: false) == .edge)
        #expect(tint.dress(dark: true) == .plain)
    }

    @Test func aTwoToneCutGlyphSitsOnAChip() {
        let tint = PinTint.derive(fill(90, 0.05, 0.05, 0.06) + fill(20, 1, 1, 1) + fill(146, 0, 0, 0, 0))

        #expect(tint.mark == .darkGlyph)
        #expect(tint.shape == .mixed)
        #expect(tint.dress(dark: true) == .chip)
        #expect((tint.chip(dark: true)?.alphaComponent ?? 0) > 0.85)
        #expect(tint.dress(dark: false) == .plain)
    }

    @Test func aColouredMarkIsLeftAsItIs() {
        let tint = PinTint.derive(fill(256, 0.9, 0.16, 0.14))

        for dark in [true, false] {
            #expect(tint.dress(dark: dark) == .plain)
        }
    }

    @Test @MainActor func aRowMarkDressesItsIconByShape() {
        let silhouette = image { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 6, dy: 6)).fill()
        }
        let tile = image { rect in
            NSColor.black.setFill()
            NSBezierPath(rect: rect).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 12, dy: 12)).fill()
        }
        let mark = RowMarkView()
        mark.frame = NSRect(x: 0, y: 0, width: 16, height: 16)

        for (icon, dark, dress) in [(silhouette, true, PinTint.Dress.ink), (silhouette, false, .plain), (tile, true, .edge), (tile, false, .plain)] {
            mark.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            mark.icon = icon
            mark.updateLayer()
            #expect(mark.dress == dress)
            let sized = mark.layer?.sublayers?.filter { !$0.isHidden && $0.contents != nil }.map(\.frame.width) ?? []
            #expect(sized.allSatisfy { $0 <= 16 + 1.01 }, "nothing reaches past the icon's own box and its hairline")
        }
    }

    @Test @MainActor func theEdgeIsAHairlineOutsideTheIconsShape() throws {
        let tile = image { rect in
            NSColor.black.setFill()
            NSBezierPath(rect: rect).fill()
        }

        let outline = try #require(RowMarkView.outlined(tile, PinTint.edge(dark: true), side: 16, scale: 2))

        #expect(outline.width == 34 && outline.height == 34)
        #expect(PinTint.edge(dark: true).alphaComponent <= 0.35)
        #expect(PinTint.edge(dark: false).alphaComponent <= 0.2)
    }

    @Test func anAddressShapesTheMeshAndLeavesTheIconsColoursAlone() {
        var tint = PinTint(hue: 0.58, saturation: 0.7, mark: .asIs)
        tint.others = [PinTint.Hue(hue: 0.1, saturation: 0.6)]

        let one = tint.seeded("https://example.com/a")
        let other = tint.seeded("https://example.com/b")

        #expect(one.hues == tint.hues && other.hues == tint.hues)
        #expect(one.seed != 0 && one.seed != other.seed)
        #expect(PinMesh.draw(one, dark: true) != PinMesh.draw(other, dark: true))
        #expect(tint.seeded("") == tint)
    }
}
