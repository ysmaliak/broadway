import AppKit
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5))) @MainActor struct KitGrainTests {
    @Test func theGrainIsTheSameOnEveryDraw() throws {
        let size = 96

        let first = try #require(KitMetal.pixels(KitGrain.source, width: size, height: size))
        let again = try #require(KitMetal.pixels(KitGrain.source, width: size, height: size))

        #expect(first == again)
    }

    @Test func aboutOnePointInTwentyEightIsADot() throws {
        let size = 256

        let pixels = try #require(KitMetal.pixels(KitGrain.source, width: size, height: size))
        let dots = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }.count

        let share = Double(dots) / Double(size * size)
        #expect(abs(share - KitGrain.density) < 0.008)
    }

    @Test func dotsAreSoftWhiteOrBlackAndNothingElse() throws {
        let pixels = try #require(KitMetal.pixels(KitGrain.source, width: 128, height: 128))

        var white = 0, black = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 0 {
            let rgb = pixels[index..<index + 3]
            let alpha = pixels[index + 3]
            #expect(abs(Double(alpha) - KitGrain.strength * 255) <= 1)
            if rgb.allSatisfy({ $0 == alpha }) { white += 1 } else if rgb.allSatisfy({ $0 == 0 }) { black += 1 }
        }
        let all = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }.count
        #expect(white + black == all)
        #expect(white > 0)
        #expect(black > 0)
    }

    @Test func theGrainViewOverlaysAtATenth() {
        let view = KitGrain.view()

        #expect(abs(view.alphaValue - 0.1) < 0.001)
        #expect(view.layer?.compositingFilter as? String == "overlayBlendMode")
        #expect(view.isAccessibilityElement() == false)
        #expect(view.hitTest(.zero) == nil)
    }

    @Test func aMetalViewInAWindowDrawsWithoutBeingAskedTwice() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
                              backing: .buffered, defer: false)
        let view = KitGrain.view()
        view.frame = NSRect(x: 0, y: 0, width: 64, height: 64)

        window.contentView?.addSubview(view)
        for _ in 0..<20 where view.frames == 0 { try await Task.sleep(for: .milliseconds(20)) }

        #expect(view.frames >= 1)
        let metal = try #require(view.layer as? CAMetalLayer)
        #expect(metal.drawableSize.width >= 64)
    }

    @Test func aMetalViewRedrawsWhenItsTintChanges() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32), styleMask: .borderless,
                              backing: .buffered, defer: false)
        let view = KitMetalView(source: "fragment float4 kitEffect(KitOut in [[stage_in]], constant KitUniforms& u [[buffer(0)]]) { return u.tint; }")
        view.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        window.contentView?.addSubview(view)
        for _ in 0..<20 where view.frames == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let before = view.frames

        view.tint = .systemRed
        for _ in 0..<20 where view.frames == before { try await Task.sleep(for: .milliseconds(20)) }

        #expect(view.frames == before + 1)
    }
}
