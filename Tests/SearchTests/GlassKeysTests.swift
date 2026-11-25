import AppKit
import Symbols
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

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theJoinKeyIsOneSystemGreenCapsuleWithNoGlassOrPlateBehindIt(look: NSAppearance.Name) {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 240, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: look)
        defer { window.contentView = nil }
        let key = MeetingJoinButton(symbol: "video.fill")
        key.frame = NSRect(x: 0, y: 0, width: 198, height: 32)
        window.contentView?.addSubview(key)
        key.layoutSubtreeIfNeeded()
        key.viewDidChangeEffectiveAppearance()

        var system = NSColor.systemGreen
        NSAppearance(named: look)?.performAsCurrentDrawingAppearance { system = NSColor.systemGreen.usingColorSpace(.sRGB) ?? .systemGreen }
        let drawn = key.subviews.filter { view in
            guard let box = view as? KitBox else { return !(view === key.content) }
            return box.fill != nil || box.stroke != nil || !box.gradient.isEmpty
        }

        #expect(key.kitSubviews(of: NSGlassEffectView.self).isEmpty)
        #expect(key.faceGlass == nil)
        #expect(drawn.count == 1 && drawn.first === key.face)
        #expect(key.face.corners == .capsule)
        #expect(key.face.frame == key.bounds)
        #expect(key.face.fill == system)
        #expect(key.layer?.backgroundColor == nil)
        #expect(key.content?.superview === key)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theJoinGreenIsTheSystemGreenAndDarkensALittleOnHoverAndMoreOnPress(look: NSAppearance.Name) throws {
        func light(_ color: NSColor) -> CGFloat {
            let c = color.usingColorSpace(.sRGB) ?? color
            func part(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * part(c.redComponent) + 0.7152 * part(c.greenComponent) + 0.0722 * part(c.blueComponent)
        }
        let appearance = try #require(NSAppearance(named: look))
        var system = NSColor.systemGreen
        appearance.performAsCurrentDrawingAppearance { system = NSColor.systemGreen.usingColorSpace(.sRGB) ?? .systemGreen }

        let rest = MeetingGreen.fill(in: appearance)
        let lit = MeetingGreen.fill(in: appearance, lit: true)
        let pressed = MeetingGreen.fill(in: appearance, pressed: true)

        #expect(rest == system)
        #expect(MeetingGreen.resolved(in: appearance) == system)
        #expect(light(lit) < light(rest))
        #expect(light(pressed) < light(lit))
        #expect(abs((lit.usingColorSpace(.sRGB)?.hueComponent ?? 0) - rest.hueComponent) < 0.01)
        #expect(abs((pressed.usingColorSpace(.sRGB)?.hueComponent ?? 0) - rest.hueComponent) < 0.01)
    }

    @Test func theJoinGreenFollowsTheLookItIsDrawnIn() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))

        #expect(MeetingGreen.fill(in: light) != MeetingGreen.fill(in: dark))
    }

    @Test func theSidebarJoinCapsuleWearsTheSameGreenAsTheMeetingCard() {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 80, height: 30), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.contentView = nil }
        let badge = PinMeetingBadgeView(browser: nil)
        window.contentView?.addSubview(badge)
        badge.viewDidChangeEffectiveAppearance()
        badge.show(.join, title: "Design sync")

        let ground = badge.subviews.compactMap { $0 as? KitBox }.first { $0.fill != nil }

        #expect(ground?.fill == MeetingGreen.fill(in: badge.effectiveAppearance))
        #expect(ground?.fill == MeetingGreen.resolved(in: NSAppearance(named: .darkAqua) ?? badge.effectiveAppearance))
    }

    @Test func aClickOnTheJoinKeyDarkensItWhileHeldAndRunsItsActionOnce() {
        var fired = 0
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 240, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        let key = MeetingJoinButton(symbol: "video.fill")
        key.action = { fired += 1 }
        key.frame = NSRect(x: 10, y: 10, width: 198, height: 32)
        window.contentView?.addSubview(key)
        window.benchShowBehind()
        key.layoutSubtreeIfNeeded()
        let middle = key.convert(NSPoint(x: key.bounds.midX, y: key.bounds.midY), to: nil)
        func send(_ type: NSEvent.EventType) {
            guard let event = NSEvent.mouseEvent(with: type, location: middle, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { return }
            window.sendEvent(event)
        }

        send(.leftMouseDown)
        let held = key.face.fill
        let pressed = key.pressed
        send(.leftMouseUp)

        #expect(pressed)
        #expect(held == MeetingGreen.fill(in: key.effectiveAppearance, lit: key.hovering, pressed: true))
        #expect(!key.pressed)
        #expect(fired == 1)
        #expect(key.face.fill == MeetingGreen.fill(in: key.effectiveAppearance, lit: key.hovering))
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
        let key = FloatKeyView(play: "pause.fill", label: "Pause") { pressed += 1 }

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
        let symbol = transport.toggle.glyph

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
        #expect(symbol?.swapped == true)
        #expect(transport.toggle.accessibilityLabel() == "Pause")
    }

    @Test func reducedMotionSwapsPlayAndPauseWithoutATransition() {
        Store.settings.set(true, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let glyph = PlayGlyph(style: PlayGlyph.float, tint: .white)
        glyph.frame = NSRect(x: 0, y: 0, width: 48, height: 48)
        glyph.show("pause.fill", animated: false)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 60, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(glyph)
        defer { window.contentView = nil }

        glyph.show("play.fill", animated: true)

        #expect(glyph.replaced == 0)
        #expect(!glyph.swapped)
        #expect(glyph.name == "play.fill")
        #expect(glyph.image === KitGlyph.image("play.fill", PlayGlyph.float))
        #expect(glyph.frame == NSRect(x: 0, y: 0, width: 48, height: 48))
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
        toggle.layoutSubtreeIfNeeded()
        let glyph = toggle.kitSubviews(of: PlayGlyph.self).first

        toggle.show(playing: true)
        toggle.show(playing: true)
        toggle.show(playing: false)

        #expect(glyph?.replaced == 2)
        #expect(glyph?.swapped == true)
        #expect(glyph?.image === KitGlyph.image("play.fill", PlayGlyph.sidebar))
        #expect(toggle.showing == "play")
    }

    @Test func theSidebarPlayersGlyphIsSimplyThereOnItsFirstShowAndWithReducedMotion() {
        Store.settings.set(false, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let toggle = MiniToggle {}
        toggle.frame = NSRect(x: 0, y: 0, width: MiniPlayerView.key, height: MiniPlayerView.key)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 60, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(toggle)
        defer { window.contentView = nil }
        toggle.layoutSubtreeIfNeeded()
        let glyph = toggle.kitSubviews(of: PlayGlyph.self).first

        toggle.show(playing: true, moving: false)
        let first = glyph?.replaced
        Store.settings.set(true, forKey: "motion.testReduced")
        toggle.show(playing: false)

        #expect(first == 0)
        #expect(glyph?.replaced == 0)
        #expect(glyph?.swapped == false)
        #expect(glyph?.image === KitGlyph.image("play.fill", PlayGlyph.sidebar))
        #expect(toggle.showing == "play")
    }

    @Test func aSecondPressOnTheSidebarPlayerEndsOnTheLastGlyph() {
        Store.settings.set(false, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let toggle = MiniToggle {}
        toggle.frame = NSRect(x: 0, y: 0, width: MiniPlayerView.key, height: MiniPlayerView.key)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 60, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(toggle)
        defer { window.contentView = nil }
        toggle.layoutSubtreeIfNeeded()
        let glyph = toggle.kitSubviews(of: PlayGlyph.self).first
        let key = toggle.frame

        toggle.show(playing: true)
        toggle.show(playing: false)
        toggle.show(playing: true)

        #expect(glyph?.replaced == 3)
        #expect(glyph?.image === KitGlyph.image("pause.fill", PlayGlyph.sidebar))
        #expect(toggle.showing == "pause")
        #expect(toggle.accessibilityLabel() == "Pause")
        #expect(toggle.frame == key)
    }
}
