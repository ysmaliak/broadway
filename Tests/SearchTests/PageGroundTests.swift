import AppKit
import Foundation
import Testing
@testable import Search

@Suite struct PageGroundTests {
    static var looks: [(String, SpaceLook)] {
        SpaceLook.palette.map { ($0.id, SpaceLook(colour: $0.id)) }
            + SpaceLook.themes.map { ($0.id, $0.look) }
            + SpacePaintTests.swatches.flatMap { hex in
                [SpaceLook.calm, 0.6, 1, SpaceLook.real].map { ("\(hex)@\($0)", SpaceLook(colours: [hex], intensity: $0)) }
            }
    }

    private func hueGap(_ a: Double, _ b: Double) -> Double {
        let gap = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(gap, 360 - gap)
    }

    @Test(arguments: [false, true])
    func aCustomBlendKeepsItsColours(dark: Bool) {
        let blends = SpaceLook.themes.filter { $0.colours.count > 1 && $0.id != "midnight" }.map(\.look)

        let pages = blends.map { $0.page(dark: dark) }

        for (look, page) in zip(blends, pages) {
            #expect(page.stops.count == look.picked.count, "\(look.picked)")
            #expect(page.stops.allSatisfy { $0.c >= 0.015 }, "\(look.picked): \(page.stops)")
            let spread = { (stops: [Oklch]) in stops.flatMap { a in stops.map { hueGap(a.h, $0.h) } }.max() ?? 0 }
            let frame = spread(look.ground(dark: dark).stops)
            #expect(frame > 10 && abs(spread(page.stops) - frame) < 3, "\(look.picked): \(page.stops)")
        }
    }

    @Test(arguments: [false, true])
    func onyxIsANearBlackPageLiftedOffItsFrame(dark: Bool) {
        let look = SpaceLook.onyx

        let page = look.page(dark: dark)

        #expect(page.dark)
        #expect(page.stops.allSatisfy { $0.l >= PageGround.darkFloor - 0.01 && $0.l < 0.25 && $0.c < 0.01 }, "\(page.stops)")
        #expect(PageGround.contrast(page.accent, page.average) >= PageGround.accentContrast)
    }

    @Test(arguments: [false, true])
    func grayAndGraphiteStayNeutral(dark: Bool) {
        let looks = ["gray", "graphite"].map { SpaceLook(colour: $0) }

        let pages = looks.map { $0.page(dark: dark) }

        let blue = Oklch(hex: KitBrand.blue.hexString)
        for page in pages {
            #expect(page.dark == dark)
            #expect(page.stops.allSatisfy { $0.c < 0.002 }, "\(page.stops)")
            #expect(hueGap(page.accent.h, blue.h) < 8, "\(page.accent)")
        }
    }

    @Test(arguments: [false, true])
    func textOnEveryPageReads(dark: Bool) {
        let looks = Self.looks

        let worst = looks.flatMap { name, look -> [(String, Double, Double)] in
            let page = look.page(dark: dark)
            let ink = page.dark ? Paint.lightInk : Paint.darkInk
            return page.stops.map { stop in
                (name, Paint.contrast(ink: ink, alpha: Paint.title, on: stop), Paint.contrast(ink: ink, alpha: Paint.quiet, on: stop))
            }
        }

        let title = worst.min { $0.1 < $1.1 }!
        let quiet = worst.min { $0.2 < $1.2 }!
        #expect(title.1 >= 4.5, "\(title.0): \(title.1)")
        #expect(quiet.2 >= 3.0, "\(quiet.0): \(quiet.2)")
    }

    @Test(arguments: [false, true])
    func theAccentAndItsLabelRead(dark: Bool) {
        let looks = Self.looks

        let pages = looks.map { ($0.0, $0.1.page(dark: dark)) }

        for (name, page) in pages {
            #expect(PageGround.contrast(page.accent, page.average) >= PageGround.accentContrast, "\(name): \(page.accent)")
            let label = page.accentInkLight ? Oklch(l: 1, c: 0, h: 0) : Oklch(hex: KitBrand.night.hexString)
            #expect(PageGround.contrast(label, page.accent) >= 3, "\(name): \(page.accent)")
        }
    }

    @Test func thePageFollowsTheSpacesInk() {
        let midnight = SpaceLook.named("midnight")!
        let sky = SpaceLook(colour: "sky")

        let deepInLight = midnight.page(dark: false)
        let skyInDark = sky.page(dark: true)
        let skyInLight = sky.page(dark: false)

        #expect(deepInLight.dark)
        #expect(skyInDark.dark)
        #expect(!skyInLight.dark)
        #expect(hueGap(skyInLight.average.h, 245) < 25)
        #expect(skyInLight.average.l > sky.ground(dark: false).stops[0].l)
    }

    @Test(arguments: ["onyx", "midnight", "cobalt"])
    func aDarkPageNeverMatchesItsFrame(id: String) {
        let look = SpaceLook.named(id) ?? SpaceLook.onyx

        let page = look.page(dark: true)
        let frame = look.ground(dark: true).stops

        #expect(zip(page.stops, frame).allSatisfy { $0.l - $1.l >= PageGround.darkStep - 0.01 || $0.l >= PageGround.darkCeiling - 0.01 })
    }
}
