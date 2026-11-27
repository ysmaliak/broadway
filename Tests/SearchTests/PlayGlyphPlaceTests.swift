import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct PlayGlyphPlaceTests {
    private final class Scaled: NSWindow {
        var scale: CGFloat = 2
        override var backingScaleFactor: CGFloat { scale }
    }

    @Test(arguments: [1, 2])
    func theRestingMarkSitsOnTheDevicePixelNearestTheMiddleOfItsKey(scale: Int) throws {
        for (style, side) in [(PlayGlyph.float, FloatLayout.play), (PlayGlyph.sidebar, CGFloat(20))] {
            for name in ["play.fill", "pause.fill"] {
                let window = Scaled(contentRect: NSRect(x: -20_000, y: -20_000, width: 100, height: 100), styleMask: .borderless,
                                    backing: .buffered, defer: false)
                window.scale = CGFloat(scale)
                window.isReleasedWhenClosed = false
                let glyph = PlayGlyph(style: style)
                glyph.frame = NSRect(x: 0, y: 0, width: side, height: side)
                window.contentView?.addSubview(glyph)
                defer { window.contentView = nil }
                glyph.show(name, animated: false)
                let image = try #require(glyph.image)

                let placed = glyph.placed(image.size)
                let exact = glyph.drawn.origin

                let pixel = 1 / CGFloat(scale)
                #expect((placed.x * CGFloat(scale)).rounded() == placed.x * CGFloat(scale))
                #expect((placed.y * CGFloat(scale)).rounded() == placed.y * CGFloat(scale))
                #expect(abs(placed.x - exact.x) <= pixel / 2 && abs(placed.y - exact.y) <= pixel / 2, "\(name) at \(scale)x: \(placed) for \(exact)")
            }
        }
    }

    @Test(arguments: [true, false])
    func theArrivingMarkOfASwapSitsWhereTheRestingMarkIsDrawn(playing: Bool) throws {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (transport, chrome) = FloatKeyBench.transport(playing: playing)
        let window = FloatKeyBench.host(transport)
        defer { window.contentView = nil }
        let glyph = try #require(transport.toggle.glyph)

        chrome.playing = !playing
        FloatKeyBench.settle(transport)

        let image = try #require(glyph.image)
        let arriving = try #require(glyph.arriving)
        let origin = CGPoint(x: arriving.position.x - arriving.bounds.width / 2, y: arriving.position.y - arriving.bounds.height / 2)
        #expect(glyph.swapped)
        #expect(origin == glyph.placed(image.size))
    }
}
