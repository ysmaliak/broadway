import AppKit
import Testing
@testable import Search

@Suite
@MainActor
struct SidebarStyleTests {
    struct Seen {
        let name: String
        let ground: NSColor
        let greys: KitGreys
        let ink: KitInk
        let dark: Bool
    }

    static let looks: [(String, SpaceLook)] = [
        ("gray", SpaceLook()),
        ("pale", SpaceLook(colours: ["F2EEE6"], intensity: 1)),
        ("vivid", SpaceLook(colours: ["3139FB"], intensity: 1)),
        ("deep", SpaceLook(colours: ["171616"], intensity: 1)),
        ("black", SpaceLook(colours: ["000000"], intensity: 2)),
        ("orange", SpaceLook(colours: ["FF8A1F"], intensity: 1)),
    ]

    static var grounds: [Seen] {
        looks.flatMap { name, look in
            [true, false].map { mode in
                let ground = look.ground(dark: mode)
                return Seen(name: "\(name) \(mode ? "dark" : "light")", ground: ground.stops[0].color,
                            greys: KitGreys.frame.lit(by: ground.stops), ink: KitInk(lift: ground.lift), dark: ground.lightInk)
            }
        }
    }

    private static func rgb(_ colour: NSColor) -> (Double, Double, Double, Double) {
        let c = colour.usingColorSpace(.sRGB) ?? colour
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }

    static func over(_ top: NSColor, _ under: NSColor) -> NSColor {
        let t = rgb(top), u = rgb(under)
        func mix(_ a: Double, _ b: Double) -> CGFloat { CGFloat(a * t.3 + b * (1 - t.3)) }
        return NSColor(srgbRed: mix(t.0, u.0), green: mix(t.1, u.1), blue: mix(t.2, u.2), alpha: 1)
    }

    static func luminance(_ colour: NSColor) -> Double {
        let c = rgb(colour)
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.0) + 0.7152 * linear(c.1) + 0.0722 * linear(c.2)
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func lightness(_ colour: NSColor) -> Double {
        let y = luminance(colour)
        return y > 216.0 / 24389 ? 116 * pow(y, 1.0 / 3) - 16 : y * 24389 / 27
    }

    private func slab(_ seen: Seen) -> NSColor {
        Self.over(seen.greys.well.resolved(seen.ink, dark: seen.dark), seen.ground)
    }

    private func hover(_ seen: Seen) -> NSColor {
        Self.over(seen.greys.hover.resolved(seen.ink, dark: seen.dark), seen.ground)
    }

    private func card(_ seen: Seen) -> NSColor {
        Self.over(seen.greys.card.resolved(seen.ink, dark: seen.dark), seen.ground)
    }

    private func inCard(_ tone: KitTone, _ seen: Seen) -> NSColor {
        Self.over(tone.resolved(seen.ink, dark: seen.dark), card(seen))
    }

    private static func level(_ colour: NSColor) -> Double {
        Double((colour.usingColorSpace(.sRGB) ?? colour).redComponent) * 255
    }

    @Test func theSelectedRowsTitleReadsAtFourAndAHalf() {
        for seen in Self.grounds {
            let under = slab(seen)

            let title = Self.over(KitTone.ink.resolved(seen.ink, dark: seen.dark), under)

            #expect(Self.contrast(title, under) >= 4.5, "\(seen.name)")
        }
    }

    @Test func aBylineReadsOnItsCard() {
        for seen in Self.grounds {
            let under = card(seen)

            let byline = Self.over(KitTone.muted.opacity(SideLook.bylineTone).resolved(seen.ink, dark: seen.dark), under)

            #expect(Self.contrast(byline, under) >= 3, "\(seen.name)")
        }
    }

    @Test func inACardTheWellIsAClearlyBiggerStepThanHover() {
        for seen in Self.grounds {
            let base = Self.lightness(card(seen))

            let hovered = abs(Self.lightness(inCard(seen.greys.hover, seen)) - base)
            let selected = abs(Self.lightness(inCard(seen.greys.well, seen)) - base)

            #expect(selected >= hovered * 0.85, "\(seen.name): hover \(hovered), selected \(selected)")
        }
    }

    @Test func onTheGroundTheLightSlabIsAClearlyBiggerStepThanHover() {
        for seen in Self.grounds where !seen.dark {
            let ground = Self.lightness(seen.ground)

            let hovered = abs(Self.lightness(hover(seen)) - ground)
            let selected = abs(Self.lightness(slab(seen)) - ground)

            #expect(selected >= hovered * 1.8, "\(seen.name): hover \(hovered), selected \(selected)")
        }
    }

    @Test func theSelectedRowHasAnEdgeOrASheenAndALiftThatHoverHasNot() {
        for dark in [true, false] {
            let edge = KitGreys.frame.slabEdge.resolved(.flat, dark: dark).alphaComponent
            let sheen = KitGreys.frame.wellRim.resolved(.flat, dark: dark).alphaComponent

            let lift = dark ? SelectedLook.shadow.dark : SelectedLook.shadow.light

            #expect(dark ? (edge >= 0.17 && edge <= 0.24 && sheen >= 0.12) : (edge >= 0.08 && edge <= 0.18))
            #expect(dark ? lift == 0 : lift >= 0.06)
        }
        #expect(KitGreys.frame.hover != KitGreys.frame.well)
    }

    @Test func selectionLightensAndGoesFurtherThanHover() {
        for seen in Self.grounds {
            let base = Self.lightness(seen.ground)

            let hovered = Self.lightness(hover(seen)) - base
            let selected = Self.lightness(slab(seen)) - base

            #expect(selected > 0, "\(seen.name): selected \(selected)")
            if seen.dark {
                #expect(hovered > 0 && selected > hovered, "\(seen.name): hover \(hovered), selected \(selected)")
            } else {
                #expect(hovered * selected < 0, "\(seen.name): hover \(hovered), selected \(selected)")
            }
            #expect(abs(hovered) >= 1.5, "\(seen.name): hover \(hovered)")
        }
    }

    @Test func theSelectedPlateDrawsNoRimAndNoBorder() throws {
        for look in [NSAppearance.Name.darkAqua, .aqua] {
            let plate = KitPlate(radius: SideLook.rowRadius)
            plate.appearance = NSAppearance(named: look)
            plate.frame = NSRect(x: 0, y: 0, width: 240, height: 34)

            SelectedLook.dress(plate, greys: .frame, ink: .flat)
            plate.updateLayer()

            let layer = try #require(plate.layer)
            let rims = layer.sublayers?.compactMap { $0 as? KitRimLayer } ?? []
            #expect(rims.allSatisfy { $0.isHidden })
            #expect(layer.borderWidth == 0 && layer.borderColor == nil)
            #expect(layer.backgroundColor != nil)
        }
    }

    @Test func onTheSidebarTheSelectedPlateHasNoEdgeAndAFolderHasNoCard() {
        let selected = KitPlate(radius: SideLook.rowRadius)
        let onFrame = KitPlate(fill: KitGreys.white.card, stroke: KitGreys.white.cardEdge, radius: SideLook.cardRadius)
        let offFrame = KitPlate(radius: SideLook.cardRadius)

        SelectedLook.dress(selected, greys: .frame, ink: .flat)
        KitGreys.frame.card(onFrame)
        KitGreys.white.card(offFrame)

        #expect(selected.fill == KitGreys.frame.well)
        #expect(selected.stroke == nil && selected.rim == nil)
        #expect(selected.lift == SelectedLook.shadow)
        #expect(onFrame.fill == nil && onFrame.stroke == nil && onFrame.rim == nil)
        #expect(offFrame.fill == KitGreys.white.card && offFrame.stroke == KitGreys.white.cardEdge)
        #expect(offFrame.rim == nil)
    }

    @Test func theWellsRingIsLitFromAbove() {
        for seen in Self.grounds where seen.dark {
            let well = inCard(seen.greys.well, seen)

            let ring = Self.over(seen.greys.wellRim.resolved(seen.ink, dark: true), Self.over(seen.greys.slabEdge.resolved(seen.ink, dark: true), well))

            let cardRing = Self.over(seen.greys.cardEdge.resolved(seen.ink, dark: true), card(seen))
            #expect(Self.lightness(ring) > Self.lightness(cardRing), "\(seen.name)")
            #expect(Self.lightness(ring) > Self.lightness(well) + 15, "\(seen.name)")
        }
        #expect(KitGreys.frame.wellRim.resolved(.flat, dark: false).alphaComponent == 0)
    }

    @Test func theRimsVividGainIsCapped() throws {
        for seen in Self.grounds where seen.name.hasPrefix("vivid") || seen.name.hasPrefix("orange") {
            let card = try #require(seen.greys.card.tint)

            let rim = try #require(seen.greys.wellRim.tint)

            #expect(rim.boost <= card.boost * 1.25 + 0.0001, "\(seen.name)")
            #expect(rim.boost > card.boost, "\(seen.name)")
        }
    }

    @Test func cardsAndTilesShareOneRaisedMaterial() {
        for seen in Self.grounds {
            let ground = Self.lightness(seen.ground)

            let cardStep = Self.lightness(card(seen)) - ground
            let edge = Self.over(seen.greys.cardEdge.resolved(seen.ink, dark: seen.dark), card(seen))
            let edgeStep = abs(Self.lightness(edge) - Self.lightness(card(seen)))
            let tile = Self.over(PinLook.colour(seen.greys, seen.ink, part: .fill, state: .resting, dark: seen.dark), seen.ground)
            let tileStep = Self.lightness(tile) - ground

            #expect(edgeStep >= 3, "\(seen.name): card edge \(edgeStep)")
            #expect(cardStep > 1 && tileStep > 1, "\(seen.name): card \(cardStep), tile \(tileStep)")
            #expect(tileStep >= cardStep - 0.5, "\(seen.name): card \(cardStep), tile \(tileStep)")
            #expect(tileStep <= 14, "\(seen.name): tile \(tileStep)")
        }
    }

    @Test func onNearBlackTheLevelsLandOnTheReference() {
        let ground = NSColor(srgbRed: 22 / 255, green: 22 / 255, blue: 22 / 255, alpha: 1)
        let greys = KitGreys.frame

        let tile = Self.over(greys.raised.resolved(.flat, dark: true), ground)
        let tileEdge = Self.over(greys.raisedEdge.resolved(.flat, dark: true), tile)
        let card = Self.over(greys.card.resolved(.flat, dark: true), ground)
        let cardEdge = Self.over(greys.cardEdge.resolved(.flat, dark: true), card)
        let well = Self.over(greys.well.resolved(.flat, dark: true), ground)

        #expect(abs(Self.level(tile) - 45) <= 4)
        #expect(abs(Self.level(tileEdge) - Self.level(tile)) <= 1)
        #expect(abs(Self.level(card) - 45) <= 4)
        #expect(abs(Self.level(cardEdge) - 77) <= 4)
        #expect(abs(Self.level(well) - 50) <= 4)
        #expect(Self.level(well) > Self.level(tile))
    }

    @Test func theWellIsWhiteInBothModesAndFaintInDark() {
        let greys = KitGreys.frame

        let dark = greys.well.resolved(.flat, dark: true).usingColorSpace(.sRGB)!
        let light = greys.well.resolved(.flat, dark: false).usingColorSpace(.sRGB)!

        #expect(dark.redComponent > 0.99 && dark.alphaComponent >= 0.12 && dark.alphaComponent <= 0.16)
        #expect(light.redComponent > 0.99 && light.alphaComponent > 0.99)
    }

    @Test func theGeometryFollowsTheReference() {
        #expect(PinPlaces.height == 40)
        #expect(SideLook.pinRadius == 11 && PinPlaces.radius == 11)
        #expect(SideLook.cardRadius == 14 && Metrics.folderRadius == 14)
        #expect(SideLook.rowRadius == 11 && SideLook.cardRowRadius == 11)
        let height = Metrics.sideRowHeight
        let button = Metrics.closeCorner(Metrics.closeSquare(height)) + Metrics.closeInset(height)
        #expect(abs(SideLook.rowRadius - button) <= 0.5, "a row's corner is concentric with the button inside it")
        #expect(Metrics.sideRowHeight + Metrics.sideGap == 37)
        #expect(SidePageView.cardLead + Metrics.folderPad == SideLook.cardRowInset)
        #expect(SideLook.cardRowInset + SideLook.rowLead == 25)
        #expect(GroupHeadingView.height + 2 * Metrics.folderPad + 2 * (Metrics.sideRowHeight + Metrics.sideGap) == 108)
    }

    @Test func rowsPinsAndHeadingsShareOneIconAndTitleColumn() {
        let titleX = SideLook.rowLead + SideLook.rowMark + SideLook.markGap

        let headingLead = SideLook.rowLead - Metrics.folderPad
        let headingX = Metrics.folderPad + headingLead + SideLook.rowMark + SideLook.markGap

        #expect(TabRowView.iconLead == SideLook.rowLead)
        #expect(PinMorphView.rowMark == SideLook.rowMark)
        #expect(headingX == titleX)
    }

    @Test func theBylineIsReadableAndFitsUnderTheTitle() {
        #expect(Metrics.liveLine >= 11)
        #expect(SideLook.titleLine + SideLook.bylineLine <= Metrics.sideRowHeight - 2)
    }

    @Test func theLiftIsTheSlabsOwnShapedShadow() throws {
        let plate = KitPlate(radius: SideLook.rowRadius)
        plate.appearance = NSAppearance(named: .aqua)
        plate.frame = NSRect(x: 4, y: 2, width: 200, height: 34)

        SelectedLook.dress(plate, greys: .frame, ink: .flat)
        plate.updateLayer()
        plate.layout()

        let layer = try #require(plate.layer)
        #expect(layer.shadowOpacity == SelectedLook.shadow.light)
        #expect(layer.shadowPath?.boundingBox == plate.bounds)
        #expect(layer.mask == nil && !layer.masksToBounds && !plate.clipsToBounds)
        #expect(layer.sublayers?.contains { $0.mask != nil && $0.shadowOpacity > 0 } != true)
        #expect(!TabRowView(frame: plate.frame).clipsToBounds)
    }

    @Test func theDarkWellCastsNothingAndTheLightSlabShadesBlack() throws {
        let plate = KitPlate(radius: SideLook.rowRadius)
        plate.frame = NSRect(x: 0, y: 0, width: 200, height: 34)
        SelectedLook.dress(plate, greys: .frame, ink: .flat)

        plate.appearance = NSAppearance(named: .darkAqua)
        plate.updateLayer()
        let dark = plate.layer?.shadowOpacity
        plate.appearance = NSAppearance(named: .aqua)
        plate.updateLayer()
        let shade = plate.layer?.shadowColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }

        #expect(dark == 0)
        #expect((shade?.redComponent ?? 1) < 0.01)
        #expect(plate.layer?.shadowRadius == SelectedLook.shadow.radius)
    }

    @Test func aVividGroundKeepsItsHueInTheWell() {
        for seen in Self.grounds where seen.name.hasPrefix("vivid") {
            let well = inCard(seen.greys.well, seen).usingColorSpace(.sRGB)!

            let blue = well.blueComponent, red = well.redComponent

            #expect(blue > red + 0.05, "\(seen.name)")
        }
    }
}
