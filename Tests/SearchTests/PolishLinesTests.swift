import AppKit
import Testing
@testable import Search

@Suite
@MainActor
struct PolishLinesTests {
    init() {
        _ = NSApplication.shared
    }

    private func keys(in view: NSView) -> [FloatKeyView] {
        view.subviews.flatMap { ($0 as? FloatKeyView).map { [$0] } ?? keys(in: $0) }
    }

    private func image(top: CGFloat, bottom: CGFloat) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: bottom, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 9))
        context.setFillColor(CGColor(gray: top, alpha: 1))
        context.fill(CGRect(x: 0, y: 9, width: 32, height: 9))
        return try #require(context.makeImage())
    }

    @Test func kitBoxStrokeIsOneDevicePixelUnlessSet() {
        let box = KitBox(fill: nil, stroke: .black, corners: .radius(6))
        let bare = KitBox(fill: .white)

        let hairline = box.resolvedStrokeWidth
        box.strokeWidth = 2
        let ring = box.resolvedStrokeWidth

        #expect(hairline == 0.5)
        #expect(ring == 2)
        #expect(bare.resolvedStrokeWidth == 0)
    }

    @Test func switcherCornersNestAndPanelFitsTheStage() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 680)
        let stage = CGRect(x: 260, y: 10, width: 730, height: 660)

        let area = SwitcherGeometry.area(bounds: bounds, top: 0, stage: stage)
        let width = SwitcherGeometry.cardWidth(area: area.width, columns: 5)
        let panel = width * 5 + 8 * 4 + 24

        #expect(SwitcherGeometry.ringRadius == SwitcherGeometry.pictureRadius + SwitcherGeometry.inset)
        #expect(SwitcherGeometry.ringRadius == 11)
        #expect(SwitcherGeometry.inset == 6)
        #expect(area == stage)
        #expect(panel <= stage.width)
        #expect(SwitcherGeometry.area(bounds: bounds, top: 20, stage: nil) == CGRect(x: 0, y: 20, width: 1000, height: 660))
        #expect(SwitcherGeometry.legend == 11)
        #expect(SwitcherGeometry.caption == 12)
    }

    @Test func floatScrimIsLighterAndEased() {
        let stops = FloatLayout.scrim()

        #expect(stops.alphas.first == 0.32)
        #expect(stops.alphas.last == 0.36)
        #expect(stops.locations == stops.locations.sorted())
        #expect(stops.alphas.max() == 0.36)
        let clear = zip(stops.locations, stops.alphas).filter { $0.0 >= 0.35 && $0.0 <= 0.4 }
        #expect(!clear.isEmpty)
        #expect(clear.allSatisfy { $0.1 == 0 })
        let top = Array(stops.alphas.prefix(5))
        #expect(top == top.sorted(by: >))
        #expect(top[1] < 0.32 * 0.75)
    }

    @Test func floatShadeReadsBrightAreasOfThePicture() throws {
        let picture = try image(top: 0.95, bottom: 0.05)

        let shade = try #require(FloatShade(picture))

        #expect(shade.bright(in: CGRect(x: 0, y: 0, width: 1, height: 0.3)))
        #expect(!shade.bright(in: CGRect(x: 0, y: 0.7, width: 1, height: 0.3)))
        #expect(FloatShade(uniform: 0.9).bright(in: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)))
    }

    @Test func floatGlyphsAreShadedOnlyOverAPaleGround() {
        let pale = Float.surface(["name": "float-controls", "ground": "F2EEE6"])
        let black = Float.surface(["name": "float-controls", "ground": "000000"])

        pale.layoutSubtreeIfNeeded()
        black.layoutSubtreeIfNeeded()
        let shadedPale = keys(in: pale).filter(\.shaded)
        let shadedBlack = keys(in: black).filter(\.shaded)

        #expect(!keys(in: pale).isEmpty)
        #expect(shadedPale.count == keys(in: pale).count)
        #expect(shadedBlack.isEmpty)
        #expect(shadedPale.allSatisfy { $0.face.layer?.shadowOpacity == FloatShade.glyphOpacity })
    }

    @Test func captionsAndChevronShareOneCapsule() {
        let chrome = FloatChrome()
        chrome.captions = [FloatCaption(id: 0, name: "English", selected: true), FloatCaption(id: 1, name: "Deutsch", selected: false)]
        let view = FloatCaptionsView(chrome: chrome) { _ in }
        view.frame = NSRect(x: 0, y: 0, width: 64, height: 30)

        view.layoutSubtreeIfNeeded()
        let both = view.capsule
        let divided = view.divided
        chrome.captions = [FloatCaption(id: 0, name: "English", selected: true)]
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()

        #expect(both.size == NSSize(width: 56, height: 30))
        #expect(divided)
        #expect(view.dividerWidth == 0.5)
        #expect(keys(in: view).allSatisfy { $0.glass == nil })
        #expect(view.capsule.size == NSSize(width: 30, height: 30))
        #expect(!view.divided)
    }
}
