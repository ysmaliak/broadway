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

    @Test func theJoinKeyCarriesItsOwnGreenInsideItsGlassSoAWindowThatIsNeverKeyKeepsIt() {
        let key = MeetingJoinButton(symbol: "video.fill", drawn: false)
        key.frame = NSRect(x: 0, y: 0, width: 120, height: 28)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 140, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(key)
        defer { window.contentView = nil }
        key.layoutSubtreeIfNeeded()

        let glass = key.faceGlass
        let holder = glass?.contentView
        let green = key.face.fill?.usingColorSpace(.sRGB)

        #expect(!window.canBecomeKey && !window.isKeyWindow)
        #expect(glass?.effectIsInteractive == true)
        #expect(glass?.tintColor == nil)
        #expect(key.face.superview === holder)
        #expect(holder?.subviews.first === key.face)
        #expect(key.content?.superview === holder)
        #expect(key.face.frame == glass?.bounds)
        #expect((green?.alphaComponent ?? 0) == 1)
        #expect((green.map { $0.greenComponent - max($0.redComponent, $0.blueComponent) } ?? 0) > 0.3)
    }

    @Test func theJoinGreenLightsOnHoverDarkensOnPressAndKeepsItsWhiteWordsReadableWithMoreContrast() {
        func light(_ color: NSColor) -> CGFloat {
            let c = color.usingColorSpace(.sRGB) ?? color
            func part(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * part(c.redComponent) + 0.7152 * part(c.greenComponent) + 0.0722 * part(c.blueComponent)
        }
        func contrast(_ color: NSColor) -> CGFloat { 1.05 / (light(color) + 0.05) }
        for dark in [false, true] {
            let rest = MeetingJoinButton.fill(dark: dark)
            #expect(light(MeetingJoinButton.fill(dark: dark, lit: true)) > light(rest))
            #expect(light(MeetingJoinButton.fill(dark: dark, pressed: true)) < light(rest))
            #expect(contrast(MeetingJoinButton.fill(dark: dark, raised: true)) >= 4.5)
            #expect(contrast(MeetingJoinButton.fill(dark: dark, raised: true, lit: true)) >= 4.5)
        }
        Store.settings.set(true, forKey: "contrast.testRaised")
        defer { Store.settings.removeObject(forKey: "contrast.testRaised") }

        let key = MeetingJoinButton(symbol: "video.fill", drawn: false)

        #expect(key.face.fill == MeetingJoinButton.fill(dark: key.kitDark, raised: true))
    }

    @Test func noGlassKeyCarriesItsColourOnlyInTheGlassTint() {
        let gallery = GlassKeyGallery(dark: false)
        defer { gallery.close() }

        for key in gallery.keys {
            guard let tint = (key.glass() as? NSGlassEffectView)?.tintColor?.usingColorSpace(.sRGB) else { continue }
            let top = max(tint.redComponent, tint.greenComponent, tint.blueComponent)
            let spread = top - min(tint.redComponent, tint.greenComponent, tint.blueComponent)
            #expect(tint.alphaComponent < 0.2 || top == 0 || spread / top < 0.3, "\(key.name) carries its colour in the glass tint, which a window that is not key drops: \(tint)")
        }
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

    @Test func playAndPauseChangeOnceForEachRealChangeWithTheMarksOwnSwap() async {
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
        let mark = transport.mark

        let first = mark.swaps
        chrome.playing = false
        settle()
        let clicked = mark.swaps
        try? await Task.sleep(for: .milliseconds(80))
        chrome.playing = false
        settle()
        let twice = mark.swaps
        chrome.playing = true
        settle()

        #expect(first == 0)
        #expect(clicked == 1)
        #expect(twice == 1)
        #expect(mark.swaps == 2)
        #expect(mark.face == .pause)
        #expect(transport.toggle.symbol == nil)
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
