import AppKit
import QuartzCore
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct KitSymbolSwapTests {
    private func hosted(_ symbol: KitSymbol) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 80, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        host.wantsLayer = true
        symbol.frame = NSRect(x: 20, y: 20, width: 26, height: 26)
        host.addSubview(symbol)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        return window
    }

    @Test func theOldIconLeavesBeforeTheNewOneArrives() async throws {
        let symbol = KitSymbol("link")
        let window = hosted(symbol)
        defer { window.close() }
        let before = symbol.image

        symbol.swap(to: "checkmark", curve: .easeOut(0.12))

        #expect(symbol.name == "checkmark")
        #expect(symbol.image === before, "the old picture is still shown while it shrinks away")
        #expect(symbol.layer?.animation(forKey: KitSwap.leave) != nil)

        try await Task.sleep(for: .milliseconds(Int(KitSwap.out * 1000) + 120))

        #expect(symbol.image === KitSymbol.image("checkmark", symbol.style))
        #expect(symbol.layer?.animation(forKey: KitSwap.leave) == nil, "nothing is left holding the icon small or clear")
    }

    @Test func theIconPopsInAboutItsMiddle() async throws {
        let symbol = KitSymbol("speaker.wave.2")
        let window = hosted(symbol)
        defer { window.close() }

        symbol.swap(to: "speaker.slash", curve: .easeOut(0.12))
        try await Task.sleep(for: .milliseconds(Int(KitSwap.out * 1000) + 30))

        let arrive = try #require(symbol.layer?.animation(forKey: KitSwap.arrive) as? CAAnimationGroup)
        let spring = try #require(arrive.animations?.compactMap { $0 as? CASpringAnimation }.first)
        let from = try #require((spring.fromValue as? NSValue)?.caTransform3DValue)
        #expect(abs(from.m11 - KitSwap.small) < 0.001)
        #expect(abs(from.m41 - 13 * (1 - KitSwap.small)) < 0.01, "it grows from the icon's middle, not its corner")
        #expect(KitSwap.spring.damping < 1, "a small overshoot")
    }

    @Test func aSecondSwapInFlightEndsOnTheLastIcon() async throws {
        let symbol = KitSymbol("link")
        let window = hosted(symbol)
        defer { window.close() }

        symbol.swap(to: "checkmark", curve: .easeOut(0.12))
        symbol.swap(to: "link", curve: .easeOut(0.12))
        try await Task.sleep(for: .milliseconds(Int(KitSwap.out * 1000) + 150))

        #expect(symbol.name == "link")
        #expect(symbol.image === KitSymbol.image("link", symbol.style))
        #expect(symbol.layer?.animation(forKey: KitSwap.leave) == nil)
    }

    @Test func aSizeChangeDuringTheSwapLandsAtTheNewSize() async throws {
        let symbol = KitSymbol("xmark", style: KitSymbol.Style(size: 9))
        let window = hosted(symbol)
        defer { window.close() }

        symbol.swap(to: "speaker.wave.2", curve: .easeOut(0.12))
        symbol.style = KitSymbol.Style(size: 13.5)
        try await Task.sleep(for: .milliseconds(Int(KitSwap.out * 1000) + 150))

        #expect(symbol.image === KitSymbol.image("speaker.wave.2", KitSymbol.Style(size: 13.5)), "the picture drawn at the old size never comes back")
        #expect(symbol.layer?.animation(forKey: KitSwap.leave) == nil)
    }

    @Test func withNoMotionTheIconChangesAtOnce() {
        let symbol = KitSymbol("link")
        let window = hosted(symbol)
        defer { window.close() }

        symbol.swap(to: "checkmark", curve: .none)

        #expect(symbol.image === KitSymbol.image("checkmark", symbol.style))
        #expect(symbol.layer?.animation(forKey: KitSwap.leave) == nil)
        #expect(symbol.layer?.animation(forKey: KitSwap.arrive) == nil)
    }
}
