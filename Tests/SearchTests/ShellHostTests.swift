import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ShellHostTests {
    private func window(_ views: [NSView]) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        for view in views {
            view.frame = window.contentView!.bounds
            window.contentView?.addSubview(view)
            view.layoutSubtreeIfNeeded()
        }
        return window
    }

    @Test func anEmptyLayerPassesClicksThrough() {
        let layer = ShellLayer()
        let shown = window([layer])
        defer { shown.close() }

        let hit = layer.hitTest(NSPoint(x: 200, y: 150))

        #expect(hit == nil)
    }

    @Test func aLayerTakesClicksOnlyOnWhatItHolds() {
        let layer = ShellLayer()
        let bar = NSView(frame: NSRect(x: 150, y: 258, width: 100, height: 20))
        layer.addSubview(bar)
        let shown = window([layer])
        defer { shown.close() }

        let above = layer.hitTest(NSPoint(x: 200, y: 200))
        let on = layer.hitTest(NSPoint(x: 200, y: 32))

        #expect(above == nil)
        #expect(on === bar)
    }

    @Test func theShellsOverlayLayersPassClicksThroughWhenNothingIsUp() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let layers: [ShellLayer] = [ShellGroundLayer(browser: browser), ShellPanelLayer(browser: browser),
                                    ShellLowerLayer(browser: browser), ShellUpperLayer(browser: browser)]
        let shown = window(layers)
        defer { shown.close() }

        let hits = layers.map { $0.hitTest(NSPoint(x: 200, y: 150)) }

        for (layer, hit) in zip(layers, hits) {
            #expect(hit == nil, "\(type(of: layer)) took a click with nothing up")
        }
    }

    @Test func theLowerLayerGivesTheDeveloperOfferItsPaneOnlyInAPair() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let lower = ShellLowerLayer(browser: browser)
        let pane = CGRect(x: 220, y: 0, width: 180, height: 300)
        lower.paneSpot = { pane }
        let shown = window([lower])
        defer { shown.close() }

        let paired = lower.barPane(paned: true)
        let single = lower.barPane(paned: false)

        #expect(paired == pane)
        #expect(single == nil)
    }

    @Test func theLowerLayerStacksItsBarsAboveTheAgentsCard() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let lower = ShellLowerLayer(browser: browser)
        let shown = window([lower])
        defer { shown.close() }
        lower.layout()
        let alone = lower.barsBottom

        lower.agentCard = { CGRect(x: 100, y: 180, width: 200, height: 106) }
        lower.layout()

        #expect(alone == 30)
        #expect(lower.barsBottom == lower.bounds.height - 180 + 8, "\(lower.barsBottom) in \(lower.bounds)")
    }
}
