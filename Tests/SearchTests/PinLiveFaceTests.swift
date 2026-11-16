import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PinLiveFaceTests {
    @Test func aPinSelectedAgainShowsItsSelection() async throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        let tab = try #require(browser.tabs.last)
        let pin = PinSquareView(frame: NSRect(x: 0, y: 0, width: 50, height: 40))
        var live = RowState()
        live.live = true
        var resting = RowState()
        resting.live = false
        pin.show(tab, in: browser, state: live)

        pin.state = resting
        try await Task.sleep(nanoseconds: 200_000_000)
        pin.state = live

        let layer = try #require(pin.liveFace.layer)
        #expect(!pin.liveFace.isHidden)
        #expect(layer.animation(forKey: "leave") == nil, "no finished fade-out holds the selection at zero")
        #expect(layer.opacity == 1)
    }

    @Test func aPinWhoseIconArrivesLateTakesItsColours() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        let tab = try #require(browser.tabs.last)
        tab.icon = nil
        let pin = PinSquareView(frame: NSRect(x: 0, y: 0, width: 50, height: 40))
        var live = RowState()
        live.live = true
        pin.show(tab, in: browser, state: live)
        let before = pin.liveFace.tint
        let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1).setFill()
            rect.fill()
            return true
        }

        tab.icon = icon
        pin.show(tab, in: browser, state: live)
        let after = pin.liveFace.tint
        pin.show(tab, in: browser, state: live)

        #expect(before.hues.isEmpty)
        #expect(after.hues.count == 1)
        #expect(pin.liveFace.tint == after)
    }
}
