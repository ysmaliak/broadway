import AppKit
import Combine
import Observation
import Testing
@testable import Search

@Observable
private final class KitProbeModel {
    var text = "a"
    var shade = 0
}

private final class KitProbeView: NSView {
    let model: KitProbeModel
    var layouts = 0
    var shown = ""

    init(_ model: KitProbeModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layouts += 1
        shown = model.text
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct KitTests {
    @Test func appKitTracksObservableReadsInLayout() async throws {
        let model = KitProbeModel()
        let view = KitProbeView(model)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.needsLayout = true
        window.layoutIfNeeded()
        let before = view.layouts

        model.text = "b"
        let invalidated = view.needsLayout
        for step in 0..<5 { model.text = "c\(step)" }
        window.layoutIfNeeded()

        #expect(invalidated)
        #expect(view.layouts == before + 1)
        #expect(view.shown == "c4")
    }

    @Test func appKitIgnoresPropertiesLayoutNeverRead() {
        let model = KitProbeModel()
        let view = KitProbeView(model)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.needsLayout = true
        window.layoutIfNeeded()

        model.shade = 3

        #expect(!view.needsLayout)
    }

    @Test func springsMatchSwiftUIResponseAndDamping() {
        let spring = KitSpring(response: 0.2, damping: 0.84)

        let made = spring.animation("position.x", from: 0, to: 10)

        #expect(abs(made.stiffness - pow(2 * .pi / 0.2, 2)) < 0.0001)
        #expect(abs(made.damping - 4 * .pi * 0.84 / 0.2) < 0.0001)
        #expect(made.mass == 1)
        #expect(made.duration == made.settlingDuration)
    }

    @Test func reducedMotionMeansNoAnimation() {
        Store.settings.set(true, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let layer = CALayer()

        layer.kitAnimate("opacity", to: 0.5, curve: Motion.kitGlide)

        #expect(Motion.kitGlide == .none)
        #expect(layer.animation(forKey: "opacity") == nil)
        #expect(layer.opacity == 0.5)
    }

    @Test(arguments: [false, true])
    func liftedInkIsThePaletteUntilLiftedAndThenTheGroundsInk(dark: Bool) {
        let calm = KitInk(lift: 0)
        let lifted = KitInk(lift: 1)

        let base = Palette.NS.muted.kitResolved(dark: dark).usingColorSpace(.sRGB)!
        let same = calm.color(Palette.NS.muted, .quiet, opacity: 0.65, dark: dark).usingColorSpace(.sRGB)!
        let quiet = lifted.color(Palette.NS.muted, .quiet, opacity: 0.65, dark: dark).usingColorSpace(.sRGB)!
        let ink = lifted.color(Palette.NS.ink, .ink, dark: dark).usingColorSpace(.sRGB)!

        #expect(abs(same.redComponent - base.redComponent) < 0.002)
        #expect(abs(Double(same.alphaComponent) - Double(base.alphaComponent) * 0.65) < 0.002)
        #expect(abs(Double(quiet.alphaComponent) - Paint.liftedQuiet * 0.65) < 0.002)
        #expect(abs(Double(ink.redComponent) - Paint.ink(light: dark, lift: 1)) < 0.002)
    }

    @Test func labelMeasuresLikeItsFontAndTruncates() {
        let label = KitLabel("Hello there", font: .systemFont(ofSize: 13))

        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 0, y: 0, width: 30, height: size.height)

        let font = NSFont.systemFont(ofSize: 13)
        #expect(size.height == ceil(font.ascender - font.descender + font.leading))
        #expect(size.width > 30)
        #expect(label.accessibilityValue() as? String == "Hello there")
    }

    @Test func buttonPressesFireAndReachAccessibility() {
        var fired = 0
        let button = KitButton(.pill(.secondary), label: "Stop") { fired += 1 }

        let pressed = button.accessibilityPerformPress()
        button.isEnabled = false
        let refused = button.accessibilityPerformPress()

        #expect(pressed && !refused)
        #expect(fired == 1)
        #expect(button.accessibilityRole() == .button)
        #expect(button.accessibilityLabel() == "Stop")
        #expect(button.alphaValue == 0.45)
    }

    @Test func boxResolvesItsColoursForItsAppearance() {
        let box = KitBox(fill: Palette.NS.ground, stroke: Palette.NS.hairline, corners: .radius(18))
        box.frame = NSRect(x: 0, y: 0, width: 200, height: 34)

        for dark in [false, true] {
            box.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            box.updateLayer()
            box.layout()

            let fill = NSColor(cgColor: box.layer!.backgroundColor!)!.usingColorSpace(.sRGB)!
            #expect(abs(fill.whiteComponentApprox - (dark ? 0.22 : 1)) < 0.01)
            #expect(box.layer?.cornerRadius == 17)
            #expect(box.layer?.cornerCurve == .continuous)
            #expect(box.layer?.borderWidth == box.resolvedStrokeWidth)
            #expect(box.resolvedStrokeWidth > 0 && box.resolvedStrokeWidth <= 1)
        }
    }

    @Test func menusRunTheirItems() {
        var ran: [String] = []
        let menu = KitMenu.make([
            .action("Copy", symbol: "doc.on.doc", key: "c", run: { ran.append("copy") }),
            .separator,
            .submenu("More", [.action("Paste", run: { ran.append("paste") })]),
        ])

        menu.performActionForItem(at: 0)
        menu.item(at: 2)?.submenu?.performActionForItem(at: 0)

        #expect(ran == ["copy", "paste"])
        #expect(menu.item(at: 1)?.isSeparatorItem == true)
    }

    @Test func controlsWriteBackThroughTheirClosure() {
        var on = false
        let toggle = KitControls.toggle(id: "settings.example", label: "Example", isOn: false) { on = $0 }

        _ = toggle.accessibilityPerformPress()

        #expect(on)
        #expect(toggle.isOn)
        #expect(toggle.accessibilityIdentifier() == "settings.example")
    }

    @Test func metalHostDrawsItsShader() throws {
        let source = """
        fragment float4 kitEffect(KitOut in [[stage_in]], constant KitUniforms& u [[buffer(0)]]) {
            return float4(in.uv.x, 0, 1, 1);
        }
        """

        let pixels = try #require(KitMetal.pixels(source, width: 8, height: 2))

        let left = pixels[2], right = pixels[(8 - 1) * 4 + 2]
        #expect(pixels[0] == 255)
        #expect(left < 40 && right > 215)
    }

}

private extension NSColor {
    var whiteComponentApprox: Double { Double(redComponent + greenComponent + blueComponent) / 3 }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ShortcutNumberBridgeTests {
    @Test func theNumberIsASquareWithItsLabel() throws {
        let number = ShortcutNumberView(number: 3)

        number.ink = KitInk(lift: 0.4)
        number.layoutSubtreeIfNeeded()

        #expect(number.frame.size == NSSize(width: 15, height: 15))
        #expect(number.accessibilityLabel() == "Command 3")
        #expect(number.ink.lift == 0.4)
        #expect(number.hitTest(NSPoint(x: 7, y: 7)) == nil)
    }

    @Test func aTitledButtonShowsItsLabel() throws {
        let button = KitButton(title: "Create", font: .systemFont(ofSize: 13), look: .pill(.primary))

        let label = try #require(button.content)

        #expect(label.superview === button)
        #expect(button.intrinsicContentSize.width > 0)
        #expect(button.accessibilityLabel() == "Create")
    }

    @Test func contentSetAfterInitWearsTheLooksInk() throws {
        let button = KitButton(.pill(.primary), label: "Go")
        let label = KitLabel("Go", font: .systemFont(ofSize: 13))
        let symbol = KitSymbol("plus")

        button.content = label

        #expect(label.superview === button)
        #expect(label.color == KitPill.ink(.primary))

        button.content = symbol

        #expect(label.superview == nil)
        #expect(symbol.superview === button)
        #expect(symbol.tint == KitPill.ink(.primary))
    }
}
