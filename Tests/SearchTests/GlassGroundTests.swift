import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct GlassGroundTests {
    private func light(_ colour: NSColor) -> Double {
        func line(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * line(colour.redComponent) + 0.7152 * line(colour.greenComponent) + 0.0722 * line(colour.blueComponent)
    }

    private func over(_ top: NSColor, _ under: NSColor) -> NSColor {
        let a = top.alphaComponent
        return NSColor(srgbRed: top.redComponent * a + under.redComponent * (1 - a), green: top.greenComponent * a + under.greenComponent * (1 - a),
                       blue: top.blueComponent * a + under.blueComponent * (1 - a), alpha: 1)
    }

    private func contrast(_ ink: NSColor, on ground: NSColor) -> Double {
        let a = light(over(ink, ground))
        let b = light(ground)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test func aFloatingPlateHoldsItsContentOnBroadwaysGround() throws {
        let glass = KitGlass.floating(radius: 12)
        let content = KitFlippedView()

        glass.hold(content)
        glass.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        glass.layoutSubtreeIfNeeded()

        let ground = try #require(glass.contentView as? KitGlassGround)
        #expect(ground.fill == Palette.NS.glassGround)
        #expect(content.superview === ground)
        #expect(ground.frame == glass.bounds)
        #expect(content.frame == ground.bounds)
        #expect(ground.radius == 12)
    }

    @Test func aCapsulePlatesGroundTakesTheCapsulesCorner() throws {
        let glass = KitGlass.floating(capsule: true)

        glass.frame = NSRect(x: 0, y: 0, width: 200, height: 36)
        glass.layoutSubtreeIfNeeded()

        let ground = try #require(glass.contentView as? KitGlassGround)
        #expect(ground.radius == 18)
    }

    @Test func aPlainGlassHasNoGround() {
        let glass = KitGlass(radius: 12)
        let content = KitFlippedView()

        glass.hold(content)

        #expect(glass.contentView === content)
        #expect(glass.ground == nil)
    }

    @Test func aGroundGivenLaterKeepsWhatWasHeld() throws {
        let glass = KitGlass(radius: 12)
        let content = KitFlippedView()
        glass.hold(content)

        glass.ground = Palette.NS.glassGround
        let ground = try #require(glass.contentView as? KitGlassGround)
        #expect(content.superview === ground)

        glass.ground = nil
        #expect(glass.contentView === content)
    }

    @Test func wordsKnowWhenTheySitOnAPlate() {
        let glass = KitGlass.floating(radius: 12)
        let content = KitFlippedView()
        let onPlate = KitLabel("Words", color: KitColor.muted)
        let off = KitLabel("Words", color: KitColor.muted)
        let bar = AgentDrivingBarView {}
        let onBar = KitLabel("Words", color: KitColor.muted)
        glass.hold(content)
        content.addSubview(onPlate)
        bar.addSubview(onBar)

        #expect(onPlate.kitOnGlass)
        #expect(!off.kitOnGlass)
        #expect(onBar.kitOnGlass)
    }

    @Test(arguments: [false, true])
    func quietInkOnAPlateIsTheStrongerOne(dark: Bool) {
        let ink = KitInk.flat.onGlass(true)

        #expect(ink.color(KitColor.muted, .quiet, dark: dark) == KitColor.glassMuted.kitResolved(dark: dark))
        #expect(ink.color(KitColor.faint, .stronger(0.6), dark: dark) == KitColor.glassFaint.kitResolved(dark: dark))
        #expect(ink.color(KitColor.ink, .ink, dark: dark) == KitColor.ink.kitResolved(dark: dark))
        #expect(KitInk.flat.color(KitColor.muted, .quiet, dark: dark) == KitColor.muted.kitResolved(dark: dark))
    }

    @Test(arguments: [false, true])
    func aQuietLabelOnAPlateDrawsTheStrongerInk(dark: Bool) throws {
        let glass = KitGlass.floating(radius: 12)
        let content = KitFlippedView()
        let label = KitLabel("Words", color: KitColor.muted)
        glass.hold(content)
        content.addSubview(label)
        glass.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let drawn = try #require(label.benchDrawn)

        #expect(abs(drawn.alphaComponent - KitColor.glassMuted.kitResolved(dark: dark).alphaComponent) < 0.001)
    }

    @Test(arguments: [false, true])
    func everyInkReadsOnThePlatesOwnGround(dark: Bool) {
        let ground = Palette.NS.ground.kitResolved(dark: dark)

        #expect(contrast(KitColor.ink.kitResolved(dark: dark), on: ground) >= 4.5)
        #expect(contrast(KitColor.glassMuted.kitResolved(dark: dark), on: ground) >= 4.5)
        #expect(contrast(KitColor.glassFaint.kitResolved(dark: dark), on: ground) >= 4.5)
        #expect(contrast(Palette.NS.glassAlert.kitResolved(dark: dark), on: ground) >= 4.5)
        #expect(contrast(Palette.NS.glassSafe.kitResolved(dark: dark), on: ground) >= 4.5)
    }

    @Test(arguments: [false, true])
    func thePlateStaysOnItsOwnSideOverTheOppositePage(dark: Bool) {
        let fill = Palette.NS.glassGround.kitResolved(dark: dark)
        let page = dark ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let plate = over(fill, page)

        #expect(contrast(KitColor.ink.kitResolved(dark: dark), on: plate) >= 4.5)
        #expect(contrast(KitColor.glassMuted.kitResolved(dark: dark), on: plate) >= 4.5)
    }

    private func boxes(in view: NSView) -> [KitBox] {
        view.subviews.flatMap { ($0 as? KitBox).map { [$0] } ?? [] + boxes(in: $0) }
    }

    private func fields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields(in: $0) }
    }

    @Test func aGroundedGlassKeyIsFilledWithBroadwaysGroundInBothLooks() {
        for dark in [false, true] {
            let key = KitGlassKey(symbol: "arrow.down", circle: 28)
            key.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            key.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
            key.layoutSubtreeIfNeeded()

            #expect(boxes(in: key).allSatisfy { $0.fill == nil })

            key.grounded = true

            let fill = boxes(in: key).compactMap(\.fill).first?.usingColorSpace(.sRGB)
            let ground = Palette.NS.glassGround.kitResolved(dark: dark).usingColorSpace(.sRGB)
            #expect(fill != nil)
            #expect(fill == ground)
            #expect(contrast(KitColor.ink.kitResolved(dark: dark).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
                             on: over(ground ?? .clear, NSColor(srgbRed: dark ? 1 : 0, green: dark ? 1 : 0, blue: dark ? 1 : 0, alpha: 1))) >= 4.5)
        }
    }

    @Test func aPickedDownloadTurnsItsWordsWithTheSelection() {
        let cell = DownloadCell()
        cell.frame = NSRect(x: 0, y: 0, width: 320, height: DownloadCell.short)
        let gone = NSTemporaryDirectory() + UUID().uuidString + "/pond-notes.txt"
        cell.show(.kept(Keep(name: "pond-notes.txt", from: "files.example.test", path: gone, date: Date(timeIntervalSince1970: 0))))
        let words = fields(in: cell)

        #expect(words.count == 2)
        #expect(Set(words.compactMap(\.textColor)) == [Palette.NS.glassFaint, Palette.NS.glassMuted])

        cell.backgroundStyle = .emphasized

        #expect(words.allSatisfy { $0.textColor == .alternateSelectedControlTextColor })

        cell.backgroundStyle = .normal

        #expect(Set(words.compactMap(\.textColor)) == [Palette.NS.glassFaint, Palette.NS.glassMuted])
    }
}
