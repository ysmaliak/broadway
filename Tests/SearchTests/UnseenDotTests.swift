import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct UnseenDotTests {
    private static let scale = 8

    private func stage() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        return window
    }

    private func painted(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    private func alphas(_ view: NSView) -> [[UInt8]] {
        let side = Int(view.bounds.width) * Self.scale
        guard side > 0, let layer = view.layer,
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return [] }
        context.scaleBy(x: CGFloat(Self.scale), y: CGFloat(Self.scale))
        layer.render(in: context)
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        return (0..<side).map { y in (0..<side).map { x in bytes[(y * side + x) * 4 + 3] } }
    }

    private func round(_ pixels: [[UInt8]]) -> Bool {
        let side = pixels.count
        guard side > 2 else { return false }
        let corners = [pixels[0][0], pixels[0][side - 1], pixels[side - 1][0], pixels[side - 1][side - 1]]
        return pixels[side / 2][side / 2] > 240 && corners.allSatisfy { $0 < 16 }
    }

    @Test func aMarkPaintedBeforeItHasASizeIsADotOnceItHasOne() {
        let window = stage()
        let dot = UnseenDotView()
        window.contentView?.addSubview(dot)
        dot.tone = KitTone(base: .white)
        painted(window)

        dot.kitSetFrame(NSRect(x: 10, y: 10, width: 7, height: 7))
        painted(window)

        #expect(dot.layer?.cornerRadius == 3.5)
        #expect(round(alphas(dot)))
    }

    @Test func aMarkPaintedWhileHiddenAndZeroIsADotWhenItShows() {
        let window = stage()
        let dot = UnseenDotView()
        dot.isHidden = true
        window.contentView?.addSubview(dot)
        dot.tone = KitTone(base: .white)
        painted(window)

        dot.isHidden = false
        dot.kitSetFrame(NSRect(x: 10, y: 10, width: 7, height: 7))
        painted(window)

        #expect(dot.layer?.cornerRadius == 3.5)
        #expect(round(alphas(dot)))
    }

    @Test func aMarkThatGrowsAndShrinksStaysADotAtEverySize() {
        let window = stage()
        let dot = UnseenDotView(frame: NSRect(x: 10, y: 10, width: 7, height: 7))
        window.contentView?.addSubview(dot)
        painted(window)

        for side in [0.0, 5, 9, 7] as [CGFloat] {
            dot.kitSetFrame(NSRect(x: 10, y: 10, width: side, height: side))
            painted(window)

            #expect(dot.layer?.cornerRadius == side / 2)
            if side > 0 { #expect(round(alphas(dot))) }
        }
    }

    @Test func theAgentsRowsCapsuleMarkIsADotOnceItHasASize() {
        let window = stage()
        let dot = KitBox(fill: .white, corners: .capsule)
        window.contentView?.addSubview(dot)
        painted(window)

        dot.frame = NSRect(x: 10, y: 10, width: 5, height: 5)
        painted(window)

        #expect(dot.layer?.cornerRadius == 2.5)
        #expect(round(alphas(dot)))
    }
}
