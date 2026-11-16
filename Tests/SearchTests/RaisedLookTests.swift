import AppKit
import Testing
@testable import Search

@Suite
@MainActor
struct RaisedLookTests {
    private let inks = [KitInk.flat, KitInk(lift: 0.5), KitInk(lift: 1)]

    private func same(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.001 && abs(a.greenComponent - b.greenComponent) < 0.001
            && abs(a.blueComponent - b.blueComponent) < 0.001 && abs(a.alphaComponent - b.alphaComponent) < 0.001
    }

    @Test func aRestingPinWearsTheFolderCardsMaterial() {
        for greys in [KitGreys.frame, KitGreys.white] {
            for dark in [true, false] {
                for ink in inks {
                let card = (fill: greys.raised.resolved(ink, dark: dark), foot: greys.raisedFoot.resolved(ink, dark: dark),
                            edge: greys.raisedEdge.resolved(ink, dark: dark), rim: greys.raisedRim.resolved(ink, dark: dark))

                let pin = (fill: PinLook.colour(greys, ink, part: .fill, state: .resting, dark: dark),
                           foot: PinLook.foot(greys, ink, state: .resting, dark: dark),
                           edge: PinLook.colour(greys, ink, part: .edge, state: .resting, dark: dark),
                           rim: PinLook.rim(greys, ink, dark: dark))

                #expect(same(pin.fill, card.fill))
                #expect(same(pin.foot, card.foot))
                #expect(same(pin.edge, card.edge))
                #expect(same(pin.rim, card.rim))
                }
            }
        }
    }

    @Test func aLiftedGroundStrengthensPinsAsItDoesCards() {
        let flat = PinLook.colour(.frame, .flat, part: .fill, state: .resting, dark: true)

        let lifted = PinLook.colour(.frame, KitInk(lift: 1), part: .fill, state: .resting, dark: true)

        #expect(lifted.alphaComponent > flat.alphaComponent)
        #expect(same(lifted, KitGreys.frame.raised.resolved(KitInk(lift: 1), dark: true)))
    }

    @Test func hoverAndPickStepUpFromTheSameMaterial() {
        for dark in [true, false] {
            for part in [PinLook.Part.fill, .edge] {
                let resting = PinLook.colour(.frame, .flat, part: part, state: .resting, dark: dark).alphaComponent
                guard resting > 0 else { continue }

                let hovered = PinLook.colour(.frame, .flat, part: part, state: .hovered, dark: dark).alphaComponent
                let picked = PinLook.colour(.frame, .flat, part: part, state: .picked, dark: dark).alphaComponent

                #expect(resting < hovered && hovered < picked)
                #expect(picked <= resting * 3)
            }
        }
    }

    @Test func theRimLightsTheTopInDarkAndShadesTheFootInLight() {
        let greys = KitGreys.frame

        let dark = greys.raisedRim.resolved(.flat, dark: true).usingColorSpace(.sRGB)!
        let light = greys.raisedRim.resolved(.flat, dark: false).usingColorSpace(.sRGB)!

        #expect(dark.alphaComponent > 0 && dark.redComponent > 0.99)
        #expect(dark.alphaComponent <= 0.04)
        #expect(light.alphaComponent > 0 && light.alphaComponent <= 0.04 && light.redComponent < 0.01)
        #expect(greys.raisedRamp.resolved(.flat, dark: true).alphaComponent == 0)
    }

    @Test func aTileIsFlat() {
        for dark in [true, false] {
            for state in [PinLook.State.resting, .hovered, .picked] {
                let top = PinLook.colour(.frame, .flat, part: .fill, state: state, dark: dark).usingColorSpace(.sRGB)!

                let foot = PinLook.foot(.frame, .flat, state: state, dark: dark).usingColorSpace(.sRGB)!

                #expect(abs(top.redComponent - foot.redComponent) < 0.001)
                #expect(abs(top.alphaComponent - foot.alphaComponent) < 0.001)
            }
        }
    }

    @Test func aTileOverADarkGroundIsAFilledKeyWithNoHairline() {
        let greys = KitGreys.frame

        let fill = greys.raised.resolved(.flat, dark: true).usingColorSpace(.sRGB)!
        let edge = greys.raisedEdge.resolved(.flat, dark: true)

        #expect(fill.redComponent > 0.99)
        #expect(fill.alphaComponent >= 0.09 && fill.alphaComponent <= 0.11)
        #expect(edge.alphaComponent == 0)
    }

    @Test func lightModeLiftsWithWhiteNotGrey() {
        let greys = KitGreys.frame

        let top = greys.raised.resolved(.flat, dark: false).usingColorSpace(.sRGB)!
        let edge = greys.raisedEdge.resolved(.flat, dark: false)

        #expect(top.redComponent > 0.99 && top.alphaComponent >= 0.45)
        #expect(edge.alphaComponent == 0)
    }

    @Test func theSelectedRowIsTheLightestThingInLightAndAWhiteLiftInDark() {
        let light = KitGreys.frame.well.resolved(.flat, dark: false)
        let dark = KitGreys.frame.well.resolved(.flat, dark: true).usingColorSpace(.sRGB)!

        let hovered = PinLook.colour(.frame, .flat, part: .fill, state: .hovered, dark: false).alphaComponent
        let picked = PinLook.colour(.frame, .flat, part: .fill, state: .picked, dark: false).alphaComponent
        let tile = PinLook.colour(.frame, .flat, part: .fill, state: .resting, dark: true).alphaComponent
        let hover = KitGreys.frame.hover.resolved(.flat, dark: true).alphaComponent

        #expect(hovered < light.alphaComponent)
        #expect(picked < light.alphaComponent)
        #expect(dark.redComponent > 0.99 && abs(dark.alphaComponent - 0.12) <= 0.005)
        #expect(tile < dark.alphaComponent && hover < dark.alphaComponent)
    }

    @Test func cardsNestInTheWindowAndRowsNestInCards() {
        #expect(Metrics.folderRadius == 14)
        #expect(SideLook.cardRowRadius == Metrics.folderRadius - Metrics.folderPad)
        #expect(PinPlaces.radius == 11 && Metrics.pinRadius == PinPlaces.radius)
        #expect(Metrics.sideRadius == 11)
        #expect(PinPlaces.radius < Metrics.folderRadius)
    }

    @Test func aRowInACardNestsInsideIt() {
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 200, height: Metrics.sideRowHeight))
        var state = RowState()
        state.live = true

        state.radius = SideLook.cardRowRadius
        row.state = state
        row.layoutSubtreeIfNeeded()

        let plates = row.subviews.compactMap { $0 as? KitPlate }
        #expect(!plates.isEmpty)
        #expect(plates.allSatisfy { $0.radius == SideLook.cardRowRadius })
    }

    @Test func aHostedCardDrawsItsGradientAndAFlatPlateItsFill() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let host = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = host
        let card = KitPlate(fill: KitGreys.frame.raised, radius: Metrics.folderRadius)
        card.foot = KitGreys.frame.raisedFoot
        card.frame = NSRect(x: 10, y: 10, width: 200, height: 120)
        let flat = KitPlate(fill: KitGreys.frame.wash, radius: Metrics.sideRadius)
        flat.frame = NSRect(x: 10, y: 140, width: 200, height: 32)

        host.addSubview(card)
        host.addSubview(flat)
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.orderOut(nil)

        let shade = card.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first { !($0 is KitRimLayer) }
        #expect(shade?.colors?.count == 2)
        #expect(shade?.isHidden == false)
        #expect(shade?.frame.size == card.bounds.size)
        #expect(card.layer?.backgroundColor == nil)
        #expect(flat.layer?.backgroundColor != nil)
    }

    @Test func aCardAndATileAreOneFilledMaterial() {
        for dark in [true, false] {
            let greys = KitGreys.frame

            let tile = greys.raised.resolved(.flat, dark: dark).alphaComponent
            let card = greys.card.resolved(.flat, dark: dark).alphaComponent
            let cardEdge = greys.cardEdge.resolved(.flat, dark: dark).alphaComponent
            let tileEdge = greys.raisedEdge.resolved(.flat, dark: dark).alphaComponent

            #expect(card > 0 && card <= tile)
            #expect(tileEdge == 0)
            #expect(cardEdge >= 0.05 && cardEdge <= 0.17)
        }
        #expect(same(KitGreys.frame.card.resolved(.flat, dark: true), KitGreys.frame.raised.resolved(.flat, dark: true)))
    }

    @Test func aCardPlateOnTheSidebarIsBare() {
        let plate = KitPlate(fill: KitGreys.white.card, stroke: KitGreys.white.cardEdge, radius: Metrics.folderRadius)
        plate.foot = KitGreys.frame.raisedFoot
        plate.rim = KitGreys.frame.raisedRim
        plate.ramp = KitGreys.frame.raisedRamp

        KitGreys.frame.card(plate)

        #expect(plate.fill == nil)
        #expect(plate.foot == nil && plate.ramp == nil)
        #expect(plate.rim == nil)
        #expect(plate.stroke == nil)
    }

    @Test func theHairlineIsLitOnOneSideAndQuietOnTheOther() {
        let rim = KitRimLayer()
        rim.place(CGRect(x: 0, y: 0, width: 50, height: 40), radius: 10, hair: 0.5)
        let white = NSColor(white: 1, alpha: 0.04)

        rim.paint(white, ramp: NSColor(white: 1, alpha: 0.04), fromTop: true)

        let alphas = (rim.colors as? [CGColor] ?? []).map(\.alpha)
        #expect(alphas.count == 3)
        #expect(alphas.count == 3 && alphas[0] > 0.04 && alphas[1] > 0 && alphas[1] < 0.04 && alphas[2] == 0)
        #expect(rim.locations?.count == 3)
    }

    @Test func aNeutralGroundKeepsTheWhiteLift() {
        let grey = [Oklch(hex: "171616"), Oklch(hex: "F2EEE6")]

        let lit = KitGreys.frame.lit(by: grey)

        #expect(KitTint.of(grey) == nil)
        #expect(lit == KitGreys.frame)
    }

    @Test func aVividGroundTintsTheLiftWithItsHue() {
        let blue = [Oklch(hex: "3139FB")]
        let flat = KitGreys.frame.raised.resolved(.flat, dark: true).usingColorSpace(.sRGB)!

        let lit = KitGreys.frame.lit(by: blue)
        let fill = lit.raised.resolved(.flat, dark: true).usingColorSpace(.sRGB)!
        let shade = lit.raisedRim.resolved(.flat, dark: false).usingColorSpace(.sRGB)!

        #expect(fill.blueComponent > fill.redComponent + 0.2)
        #expect(fill.blueComponent > 0.99)
        #expect(fill.alphaComponent > flat.alphaComponent)
        #expect(fill.alphaComponent < flat.alphaComponent * 1.7)
        #expect(shade.redComponent < 0.01 && shade.blueComponent < 0.01)
    }

    @Test func cardsOffTheGreysStayUntinted() {
        #expect(KitGreys.white.lit(by: [Oklch(hex: "3139FB")]) == KitGreys.white)
    }

    @Test func cardsOffTheEdgeStaysQuiet() {
        let edge = KitGreys.white.raisedEdge

        let dark = edge.resolved(.flat, dark: true).alphaComponent

        #expect(abs(dark - 0.12) < 0.001)
    }
}
