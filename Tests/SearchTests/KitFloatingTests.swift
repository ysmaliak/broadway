import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct KitFloatingTests {
    private func point(_ point: CGPoint, through transform: CATransform3D) -> CGPoint {
        point.applying(CATransform3DGetAffineTransform(transform))
    }

    @Test func anArrivalIsTheIdentityOnceShown() {
        let arrival = KitArrival.unfold(from: KitArrival.topTrailing)

        let shown = arrival.transform(in: CGRect(x: 0, y: 0, width: 120, height: 40), shown: true, up: false)

        #expect(CATransform3DIsIdentity(shown))
    }

    @Test(arguments: [false, true])
    func anUnfoldingArrivalKeepsItsAnchorStill(up: Bool) {
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 40)
        let arrival = KitArrival.unfold(from: KitArrival.topTrailing)
        let anchor = CGPoint(x: 120, y: up ? 40 : 0)

        let hidden = arrival.transform(in: bounds, shown: false, up: up)
        let moved = point(anchor, through: hidden)

        #expect(abs(moved.x - anchor.x) < 0.001)
        #expect(abs(moved.y - anchor.y) < 0.001)
        #expect(abs(hidden.m11 - 0.92) < 0.001)
    }

    @Test func aRisingArrivalSinksTowardItsEdgeWhileHidden() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 30)
        let arrival = KitArrival.rise(by: 12)

        let flipped = point(CGPoint(x: 50, y: 30), through: arrival.transform(in: bounds, shown: false, up: false))
        let up = point(CGPoint(x: 50, y: 0), through: arrival.transform(in: bounds, shown: false, up: true))

        #expect(abs(flipped.y - (30 + 12 * 0.6)) < 0.001)
        #expect(abs(up.y - (0 - 12 * 0.6)) < 0.001)
    }

    @Test func arrivingWithoutAnimationLandsAtOnce() {
        let parent = KitFlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let view = NSView(frame: NSRect(x: 10, y: 10, width: 80, height: 30))
        parent.addSubview(view)

        view.kitArrive(false, .rise(by: 12), animated: false)
        let hiddenOpacity = view.layer?.opacity
        view.kitArrive(true, .rise(by: 12), animated: false)

        #expect(hiddenOpacity == 0)
        #expect(view.layer?.opacity == 1)
        #expect(CATransform3DIsIdentity(view.layer?.transform ?? CATransform3DMakeScale(2, 2, 1)))
        #expect(view.layer?.animation(forKey: "arrive") == nil)
    }

    @Test func greysOnTheFrameDifferFromGreysOnWhite() {
        let ink = KitInk.flat

        let white = KitGreys.white.hover(ink, dark: false)
        let frame = KitGreys.frame.hover(ink, dark: false)

        #expect(white != frame)
        #expect(KitGreys.white.tile(ink, dark: true).alphaComponent < 1)
    }

    @Test func aGlassGroupLaysItsFlippedContentOverItsBounds() {
        let group = KitGlassGroup(spacing: 4)

        group.frame = NSRect(x: 0, y: 0, width: 90, height: 30)
        group.layoutSubtreeIfNeeded()

        #expect(group.content.isFlipped)
        #expect(group.content.frame == group.bounds)
        #expect(group.contentView === group.content)
    }

    @Test func aGlassFaceCentresItsFaceInsideTheGlassAndLetsHitsThrough() {
        let symbol = KitSymbol("play.fill", style: KitSymbol.Style(size: 12))
        let glass = KitGlassFace(symbol)

        glass.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
        glass.layoutSubtreeIfNeeded()
        let size = symbol.intrinsicContentSize

        #expect(symbol.isDescendant(of: glass.contentView ?? NSView()))
        #expect(glass.cornerRadius == 15)
        #expect(abs(symbol.frame.midX - 15) <= 0.5)
        #expect(abs(symbol.frame.midY - 15) <= 0.5)
        #expect(symbol.frame.size == size)
        #expect(glass.hitTest(NSPoint(x: 15, y: 15)) == nil)
    }

    @Test func aGlassFaceNudgesItsFaceByHalfPoints() {
        let symbol = KitSymbol("play.fill", style: KitSymbol.Style(size: 12))
        let glass = KitGlassFace(symbol)
        glass.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
        glass.layoutSubtreeIfNeeded()
        let centred = symbol.frame

        glass.nudge = CGVector(dx: 1, dy: -1.5)
        glass.layoutSubtreeIfNeeded()

        #expect(symbol.frame.minX - centred.minX == 1)
        #expect(symbol.frame.minY - centred.minY == -1.5)
        #expect(symbol.frame.size == centred.size)
    }

    @Test func placingRoundsTiesTowardTheTopInFlippedViews() {
        let flipped = KitFlippedView()
        let plain = NSView()

        let down = flipped.kitPlace(NSRect(x: 2.25, y: 9.25, width: 4, height: 4))
        let up = plain.kitPlace(NSRect(x: 2.25, y: 9.25, width: 4, height: 4))

        #expect(down.minY == 9.0)
        #expect(up.minY == 9.5)
        #expect(down.minX == 2.5)
        #expect(up.minX == 2.5)
    }

    @Test func truncationKeepsBothEndsAroundOneEllipsis() {
        let font = NSFont.systemFont(ofSize: 12)
        let text = NSAttributedString(string: "https://developer.apple.com/documentation/appkit/nsglasseffectview", attributes: [.font: font])

        let cut = KitTruncate.cut(text, to: 200, mode: .middle)
        let head = KitTruncate.cut(text, to: 200, mode: .start)
        let whole = KitTruncate.cut(text, to: 1000, mode: .middle)

        let ends = cut.text.string.split(separator: "…", omittingEmptySubsequences: false).map(String.init)

        #expect(cut.width <= 200)
        #expect(ends.count == 2)
        #expect(ends.first.map { $0.count > 8 && text.string.hasPrefix($0) } == true)
        #expect(ends.last.map { $0.count > 8 && text.string.hasSuffix($0) } == true)
        #expect(head.text.string.hasPrefix("…"))
        #expect(text.string.hasSuffix(String(head.text.string.dropFirst())))
        #expect(whole.text.string == text.string)
    }

    @Test func middleTruncationKeepsTheMostThatFitsLessAFullStopBeforeTheEllipsis() {
        let text = "https://developer.apple.com/documentation/appkit/nsglasseffectview"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]

        let cut = KitTruncate.middle(text, attributes: attributes, to: 290)
        let whole = KitTruncate.middle(text, attributes: attributes, to: 1000)

        #expect(cut.text == "https://developer.apple…/appkit/nsglasseffectview")
        #expect(cut.width <= 290)
        #expect(whole.text == text)
    }

    @Test func aSymbolFadeLandsOnTheNewNameAtOnce() {
        let symbol = KitSymbol("play.fill", style: KitSymbol.Style(size: 12))

        symbol.fade(to: "pause.fill")

        #expect(symbol.name == "pause.fill")
        #expect(symbol.image != nil)
    }
}
