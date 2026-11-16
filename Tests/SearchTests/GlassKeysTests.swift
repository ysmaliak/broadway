import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct GlassKeysTests {
    @Test(arguments: [true, false])
    func everyPressableGlassTakesItsPressInsideItsGlassAndRunsItsActionOnce(dark: Bool) async {
        let gallery = GlassKeyGallery(dark: dark)
        defer { gallery.close() }
        try? await Task.sleep(for: .milliseconds(300))
        let counted: Set<String> = ["update card hide", "choice thumb", "look glass bead", "system glass button"]

        var rows: [[String: Any]] = []
        for key in gallery.keys { rows.append(await gallery.press(key, hold: .milliseconds(40), settle: .milliseconds(80))) }

        #expect(rows.count == gallery.keys.count)
        for row in rows {
            let name = row["name"] as? String ?? ""
            let off = name == "glass key off"
            if name != "system glass button" {
                #expect(row["hitInGlass"] as? Bool == !off, "\(name) takes the press inside its glass: \(row)")
            }
            if !counted.contains(name) {
                #expect(row["fired"] as? Int == (off ? 0 : 1), "\(name) runs its action once: \(row)")
            }
        }
    }

    @Test func aGlassKeyKeepsItsLabelAndFillInsideTheGlass() {
        let key = KitGlassKey(title: "Save", kind: .primary)
        key.frame = NSRect(x: 0, y: 0, width: 80, height: 22)
        key.layoutSubtreeIfNeeded()

        let glass = key.faceGlass
        let label = key.content

        #expect(glass?.effectIsInteractive == true)
        #expect(label.map { view in glass.map { view.isDescendant(of: $0) } ?? false } == true)
        #expect(key.hitTest(NSPoint(x: 40, y: 11)) === glass?.contentView)
        #expect(label?.frame.midX == 40)
    }

    @Test func aGlassKeyIsStillOneVoiceOverButtonWithItsNameAndPress() {
        var pressed = 0
        let key = KitGlassKey(title: "Allow Once", kind: .primary) { pressed += 1 }
        key.frame = NSRect(x: 0, y: 0, width: 90, height: 22)
        key.layoutSubtreeIfNeeded()

        let performed = key.accessibilityPerformPress()

        #expect(key.isAccessibilityElement())
        #expect(key.accessibilityRole() == .button)
        #expect(key.accessibilityLabel() == "Allow Once")
        #expect(performed)
        #expect(pressed == 1)
    }

    @Test func aFloatKeyIsStillOneVoiceOverButtonWithItsNameAndPress() {
        var pressed = 0
        let key = FloatKeyView(symbol: "pause.fill", size: 21, weight: .semibold, label: "Pause") { pressed += 1 }

        let performed = key.accessibilityPerformPress()

        #expect(key.isAccessibilityElement())
        #expect(key.accessibilityRole() == .button)
        #expect(key.accessibilityLabel() == "Pause")
        #expect(performed)
        #expect(pressed == 1)
    }

    @Test func aGlassKeyThatIsOffTakesItsOwnClickAndKeepsTheGlassStill() {
        let key = KitGlassKey(title: "Off")
        key.frame = NSRect(x: 0, y: 0, width: 80, height: 22)
        key.isEnabled = false

        #expect(key.glassCatcher == nil)
        #expect(key.hitTest(NSPoint(x: 40, y: 11)) !== key.faceGlass?.contentView)
    }

    @Test func theGlassContentAsksItsKeyAboutTheFirstClick() {
        let key = FloatKeyView(symbol: "xmark", size: 12, weight: .bold, label: "Close") {}
        key.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
        key.layoutSubtreeIfNeeded()

        let hit = key.hitTest(NSPoint(x: 15, y: 15))

        #expect(hit === key.glass?.contentView)
        #expect(hit?.acceptsFirstMouse(for: nil) == true)
        #expect(hit?.mouseDownCanMoveWindow == key.mouseDownCanMoveWindow)
    }

    @Test func playAndPauseChangeOnceForEachRealChangeWithTheSymbolsReplace() {
        Store.settings.set(false, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let chrome = FloatChrome()
        chrome.shown = true
        let transport = FloatTransportView(chrome: chrome, rewind: {}, toggle: {}, forward: {})
        transport.frame = NSRect(origin: .zero, size: FloatLayout.transport)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 200, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(transport)
        defer { window.contentView = nil }
        func settle() {
            transport.needsLayout = true
            transport.layoutSubtreeIfNeeded()
        }
        settle()
        let symbol = transport.toggle.symbol

        let first = symbol?.replaced
        chrome.playing = false
        settle()
        let clicked = symbol?.replaced
        chrome.playing = false
        settle()
        let twice = symbol?.replaced
        chrome.playing = true
        settle()

        #expect(first == 0)
        #expect(clicked == 1)
        #expect(twice == 1)
        #expect(symbol?.replaced == 2)
        #expect(symbol?.name == "pause.fill")
        #expect(transport.toggle.accessibilityLabel() == "Pause")
    }

    @Test func reducedMotionSwapsPlayAndPauseWithoutATransition() {
        Store.settings.set(true, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let symbol = KitSymbol("pause.fill", style: KitSymbol.Style(size: 21, weight: .semibold))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 60, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(symbol)
        defer { window.contentView = nil }

        symbol.replace(to: "play.fill")

        #expect(symbol.replaced == 0)
        #expect(symbol.name == "play.fill")
        #expect(symbol.image === KitSymbol.image("play.fill", symbol.style))
    }

    @Test func theSidebarPlayerReplacesItsGlyphOnceForEachChange() {
        Store.settings.set(false, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let toggle = MiniToggle {}
        toggle.frame = NSRect(x: 0, y: 0, width: MiniPlayerView.key, height: MiniPlayerView.key)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 60, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(toggle)
        defer { window.contentView = nil }
        let glyph = toggle.kitSubviews(of: MiniGlyph.self).first

        toggle.show(playing: true)
        toggle.show(playing: true)
        toggle.show(playing: false)

        #expect(glyph?.replaced == 2)
        #expect(toggle.showing == "play")
    }
}
