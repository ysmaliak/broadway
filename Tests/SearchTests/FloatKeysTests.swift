import AppKit
import Symbols
import Testing
@testable import Search

@MainActor
enum FloatKeyBench {
    static func still() -> () -> Void {
        Store.settings.set(false, forKey: "motion.testReduced")
        Store.settings.set(false, forKey: "motion.testLowPower")
        return {
            Store.settings.removeObject(forKey: "motion.testReduced")
            Store.settings.removeObject(forKey: "motion.testLowPower")
        }
    }

    static func host(_ view: NSView, size: NSSize = NSSize(width: 420, height: 240)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: .borderless, backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        return window
    }

    static let middle = KitSymbol.Style(size: 21, weight: .semibold)

    static func transport(playing: Bool) -> (FloatTransportView, FloatChrome) {
        let chrome = FloatChrome()
        chrome.shown = true
        chrome.playing = playing
        let view = FloatTransportView(chrome: chrome, rewind: {}, toggle: {}, forward: {})
        view.frame = NSRect(origin: .zero, size: FloatLayout.transport)
        return (view, chrome)
    }

    static func settle(_ view: NSView) {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    static func canvas(_ size: NSSize, scale: CGFloat, ground: NSColor? = nil, draw: (CGContext) -> Void) -> CGImage? {
        let wide = max(1, Int((size.width * scale).rounded())), high = max(1, Int((size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: wide * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let ground {
            context.setFillColor(ground.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: wide, height: high))
        }
        context.translateBy(x: 0, y: CGFloat(high))
        context.scaleBy(x: scale, y: -scale)
        draw(context)
        return context.makeImage()
    }

    static func weight(of image: CGImage, scale: CGFloat) -> CGPoint? {
        let wide = image.width, high = image.height
        var pixels = [UInt8](repeating: 0, count: wide * high * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: wide * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: wide, height: high))
            return true
        }
        guard drawn else { return nil }
        var sum = 0.0, across = 0.0, down = 0.0
        for y in 0..<high {
            for x in 0..<wide {
                let alpha = Double(pixels[(y * wide + x) * 4 + 3])
                sum += alpha
                across += alpha * (Double(x) + 0.5)
                down += alpha * (Double(y) + 0.5)
            }
        }
        guard sum > 0 else { return nil }
        return CGPoint(x: across / sum / Double(scale), y: down / sum / Double(scale))
    }

    struct Place {
        let key: String
        let face: String
        let scale: Int
        let disc: CGFloat
        let frame: NSRect
        let image: CGPoint
        let weight: CGPoint
        let ring: CGPoint?

        var off: CGVector { CGVector(dx: weight.x - disc / 2, dy: weight.y - disc / 2) }
        var ringOff: CGVector? { ring.map { CGVector(dx: $0.x - disc / 2, dy: $0.y - disc / 2) } }

        var line: String {
            let ringed = ringOff.map { String(format: ", ring %+.2f, %+.2f", $0.dx, $0.dy) } ?? ""
            return String(format: "%@ %@ at %dx: drawn from %.1f, %.1f in a %.0f disc, weight %+.2f, %+.2f from the centre%@",
                          key, face, scale, image.x, image.y, disc, off.dx, off.dy, ringed)
        }
    }

    static func ring(of image: NSImage, at origin: CGPoint) -> CGPoint? {
        let fine = 8
        let wide = Int(ceil(image.size.width)) * fine, high = Int(ceil(image.size.height)) * fine
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32) else { return nil }
        rep.size = NSSize(width: CGFloat(wide) / CGFloat(fine), height: CGFloat(high) / CGFloat(fine))
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        var left = wide, right = -1, bottom = -1
        for y in 0..<high {
            let row = data + y * rep.bytesPerRow
            for x in 0..<wide where row[x * 4 + 3] > 127 {
                left = min(left, x)
                right = max(right, x)
                bottom = max(bottom, y)
            }
        }
        guard right >= left else { return nil }
        let unit = CGFloat(fine)
        let across = CGFloat(right + 1 - left) / unit
        return CGPoint(x: origin.x + CGFloat(left + right + 1) / 2 / unit, y: origin.y + CGFloat(bottom + 1) / unit - across / 2)
    }

    static func drawnWeight(of view: NSView, scale: CGFloat) -> CGPoint? {
        guard let layer = view.layer else { return nil }
        return canvas(view.bounds.size, scale: scale) { context in layer.render(in: context) }.flatMap { weight(of: $0, scale: scale) }
    }

    static func places(scale: Int) -> [Place] {
        var out: [Place] = []
        let style = KitSymbol.Style(size: 16, weight: .semibold)
        for (key, name) in [("back", "gobackward.15"), ("forward", "goforward.15")] {
            guard let image = KitGlyph.image(name, style) else { continue }
            let frame = FloatOptics.frame(image.size, nudge: FloatOptics.nudge(name, style), in: FloatLayout.skip, scale: CGFloat(scale))
            guard let weight = KitGlyph.weight(of: image, backing: scale, at: frame.origin) else { continue }
            out.append(Place(key: key, face: name, scale: scale, disc: FloatLayout.skip, frame: frame, image: frame.origin, weight: weight,
                             ring: ring(of: image, at: frame.origin)))
        }
        for name in ["play.fill", "pause.fill"] {
            guard let image = KitGlyph.image(name, middle) else { continue }
            let frame = NSRect(x: (FloatLayout.play - image.size.width) / 2, y: (FloatLayout.play - image.size.height) / 2,
                               width: image.size.width, height: image.size.height)
            guard let weight = KitGlyph.weight(of: image, backing: scale, at: frame.origin) else { continue }
            out.append(Place(key: "middle", face: name, scale: scale, disc: FloatLayout.play, frame: frame, image: frame.origin, weight: weight,
                             ring: nil))
        }
        return out
    }
}

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct FloatPlayKeyTests {
    private func image(_ name: String) -> NSImage? { KitGlyph.image(name, PlayGlyph.float) }

    private let disc = NSRect(x: 0, y: 0, width: FloatLayout.play, height: FloatLayout.play)

    private func centred(_ glyph: PlayGlyph, _ name: String) -> Bool {
        guard let size = image(name)?.size else { return false }
        return glyph.drawn == NSRect(x: (disc.width - size.width) / 2, y: (disc.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func pastTheSwap() async {
        try? await Task.sleep(for: .milliseconds(700))
    }

    @Test(arguments: [true, false])
    func theFirstTimeTheKeyIsShownItsMarkIsSimplyThereWithNoMotion(playing: Bool) throws {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (transport, _) = FloatKeyBench.transport(playing: playing)
        let window = FloatKeyBench.host(transport)
        defer { window.contentView = nil }
        let name = playing ? "pause.fill" : "play.fill"

        let glyph = try #require(transport.toggle.glyph)

        #expect(glyph.name == name)
        #expect(glyph.image === image(name))
        #expect(glyph.replaced == 0)
        #expect(!glyph.swapped)
        #expect(transport.toggle.nudge == .zero)
        #expect(glyph.frame == disc)
        #expect(centred(glyph, name))
        #expect(glyph.layer.map(BenchGlassFrames.animations) == 0)
    }

    @Test func aChangeOfStateSwapsTheMarkOnceInsideAKeyThatStaysStill() throws {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (transport, chrome) = FloatKeyBench.transport(playing: true)
        let window = FloatKeyBench.host(transport)
        defer { window.contentView = nil }
        let glyph = try #require(transport.toggle.glyph)
        let key = transport.toggle.frame

        chrome.playing = false
        FloatKeyBench.settle(transport)

        #expect(glyph.name == "play.fill")
        #expect(glyph.image === image("play.fill"))
        #expect(glyph.replaced == 1)
        #expect(glyph.swapped)
        #expect(glyph.arriving?.animation(forKey: PlaySwap.arrive) != nil)
        #expect(glyph.layer?.animation(forKey: KitSwap.leave) == nil)
        #expect(glyph.layer?.animation(forKey: KitSwap.crossKey) == nil)
        #expect(transport.toggle.frame == key)
        #expect(transport.toggle.layer?.animationKeys() ?? [] == [])
    }

    @Test(arguments: [true, false])
    func theGlyphsFrameDoesNotMoveFromTheStartOfASwapToItsEnd(playing: Bool) async throws {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (transport, chrome) = FloatKeyBench.transport(playing: playing)
        let window = FloatKeyBench.host(transport)
        defer { window.contentView = nil }
        let glyph = try #require(transport.toggle.glyph)
        let before = glyph.frame

        chrome.playing = !playing
        FloatKeyBench.settle(transport)
        let starting = (frame: glyph.frame, nudge: transport.toggle.nudge)
        try? await Task.sleep(for: .milliseconds(120))
        transport.layoutSubtreeIfNeeded()
        let midway = (frame: glyph.frame, nudge: transport.toggle.nudge)
        await pastTheSwap()
        transport.layoutSubtreeIfNeeded()

        #expect(glyph.replaced == 1)
        #expect(before == disc)
        #expect(starting.frame == disc && midway.frame == disc && glyph.frame == disc)
        #expect(starting.nudge == .zero && midway.nudge == .zero && transport.toggle.nudge == .zero)
        #expect(centred(glyph, playing ? "play.fill" : "pause.fill"))
    }

    @Test func aSecondPressBeforeTheOldMarkIsGoneEndsOnTheLastState() async throws {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (transport, chrome) = FloatKeyBench.transport(playing: true)
        let window = FloatKeyBench.host(transport)
        defer { window.contentView = nil }
        let glyph = try #require(transport.toggle.glyph)

        chrome.playing = false
        FloatKeyBench.settle(transport)
        chrome.playing = true
        FloatKeyBench.settle(transport)
        await pastTheSwap()
        transport.layoutSubtreeIfNeeded()

        #expect(glyph.name == "pause.fill")
        #expect(glyph.image === image("pause.fill"))
        #expect(glyph.replaced == 2)
        #expect(glyph.frame == disc)
        #expect(transport.toggle.accessibilityLabel() == "Pause")
    }

    @Test func theKeyFlickeringWithTheChromeEndsOnTheLastWord() async throws {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (transport, chrome) = FloatKeyBench.transport(playing: true)
        let window = FloatKeyBench.host(transport)
        defer { window.contentView = nil }
        let glyph = try #require(transport.toggle.glyph)

        for turn in 0..<9 {
            chrome.playing = turn % 2 == 1
            FloatKeyBench.settle(transport)
        }
        await pastTheSwap()
        transport.layoutSubtreeIfNeeded()

        #expect(glyph.name == "play.fill")
        #expect(glyph.image === image("play.fill"))
        #expect(glyph.replaced == 9)
        #expect(glyph.frame == disc)
        #expect(transport.toggle.accessibilityLabel() == "Play")
    }

    @Test func showingTheMarkItAlreadyHasDoesNothing() throws {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (transport, _) = FloatKeyBench.transport(playing: true)
        let window = FloatKeyBench.host(transport)
        defer { window.contentView = nil }
        let glyph = try #require(transport.toggle.glyph)

        transport.toggle.show("pause.fill", animated: true)
        transport.toggle.show("play.fill", animated: true)
        transport.toggle.show("play.fill", animated: true)

        #expect(glyph.replaced == 1)
        #expect(glyph.name == "play.fill")
    }

    @Test func reduceMotionChangesTheMarkAtOnce() throws {
        Store.settings.set(true, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let (transport, chrome) = FloatKeyBench.transport(playing: true)
        let window = FloatKeyBench.host(transport)
        defer { window.contentView = nil }
        let glyph = try #require(transport.toggle.glyph)

        chrome.playing = false
        FloatKeyBench.settle(transport)

        #expect(glyph.name == "play.fill")
        #expect(glyph.image === image("play.fill"))
        #expect(glyph.replaced == 0)
        #expect(!glyph.swapped)
        #expect(glyph.frame == disc)
    }

    @Test func reduceMotionTurnedOnMidwayEndsTheSwapAtOnce() throws {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (transport, chrome) = FloatKeyBench.transport(playing: true)
        let window = FloatKeyBench.host(transport)
        defer { window.contentView = nil }
        let glyph = try #require(transport.toggle.glyph)
        chrome.playing = false
        FloatKeyBench.settle(transport)

        Store.settings.set(true, forKey: "motion.testReduced")
        chrome.playing = true
        FloatKeyBench.settle(transport)

        #expect(glyph.name == "pause.fill")
        #expect(glyph.image === image("pause.fill"))
        #expect(glyph.replaced == 1)
        #expect(glyph.frame == disc)
    }

    @Test func aKeyInNoWindowChangesItsMarkAtOnce() throws {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (transport, chrome) = FloatKeyBench.transport(playing: true)
        transport.layoutSubtreeIfNeeded()
        let glyph = try #require(transport.toggle.glyph)

        chrome.playing = false
        FloatKeyBench.settle(transport)

        #expect(glyph.name == "play.fill")
        #expect(glyph.image === image("play.fill"))
        #expect(glyph.replaced == 0)
        #expect(!glyph.swapped)
        #expect(glyph.frame == disc)
    }

    @Test func theFloatingKeyAndTheSidebarKeyAreTheSameGlyphWithTheSameSwap() throws {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (transport, chrome) = FloatKeyBench.transport(playing: true)
        let window = FloatKeyBench.host(transport)
        defer { window.contentView = nil }
        let sidebar = MiniToggle {}
        sidebar.frame = NSRect(x: 300, y: 20, width: MiniPlayerView.key, height: MiniPlayerView.key)
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        let float = try #require(transport.toggle.glyph)

        chrome.playing = false
        FloatKeyBench.settle(transport)
        sidebar.show(playing: true)

        #expect(transport.toggle.face === float)
        #expect(type(of: float) == type(of: sidebar.glyph))
        #expect(sidebar.glyph.superview != nil && sidebar.glyph.frame == sidebar.bounds)
        #expect(float.swapped && sidebar.glyph.swapped)
        #expect(float.replaced == 1 && sidebar.glyph.replaced == 1)
        #expect(float.imageScaling == sidebar.glyph.imageScaling && float.imageAlignment == sidebar.glyph.imageAlignment)
        #expect(float.style == KitSymbol.Style(size: 21, weight: .semibold))
        #expect(sidebar.glyph.style == KitSymbol.Style(size: 11, weight: .bold))
    }

    @Test func theKeysLabelAndHelpStillFlipBetweenPlayAndPause() {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (transport, chrome) = FloatKeyBench.transport(playing: true)
        let window = FloatKeyBench.host(transport)
        defer { window.contentView = nil }
        let key = transport.toggle

        let first = [key.accessibilityLabel(), key.accessibilityHelp(), key.toolTip]
        chrome.playing = false
        FloatKeyBench.settle(transport)
        let paused = [key.accessibilityLabel(), key.accessibilityHelp(), key.toolTip]
        chrome.playing = true
        FloatKeyBench.settle(transport)

        #expect(first == ["Pause", "Pause", "Pause"])
        #expect(paused == ["Play", "Play", "Play"])
        #expect([key.accessibilityLabel(), key.accessibilityHelp(), key.toolTip] == ["Pause", "Pause", "Pause"])
        #expect(key.accessibilityRole() == .button)
        #expect(key.glyph?.isAccessibilityElement() == false)
    }

    @Test func theMarkSitsWithTheSkipMarksInColourAndLight() {
        let (transport, _) = FloatKeyBench.transport(playing: true)
        transport.layoutSubtreeIfNeeded()

        #expect(transport.toggle.glyph?.tint == .white)
        #expect(transport.toggle.glyph?.contentTintColor == .white)
        #expect(transport.rewind.symbol?.tint == .white)
        #expect(transport.toggle.glyph?.style == FloatKeyBench.middle)
        #expect(transport.toggle.face.layer?.opacity == transport.rewind.face.layer?.opacity)
        #expect(transport.toggle.face.layer?.opacity == 0.92)
    }

    @Test func aMarkOverABrightFrameIsShadedLikeTheOthers() {
        let (transport, _) = FloatKeyBench.transport(playing: true)
        transport.layoutSubtreeIfNeeded()

        transport.toggle.shaded = true
        transport.rewind.shaded = true

        #expect(transport.toggle.face.layer?.shadowOpacity == FloatShade.glyphOpacity)
        #expect(transport.toggle.face.layer?.shadowRadius == transport.rewind.face.layer?.shadowRadius)
    }
}

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct FloatGlassStateTests {
    private func surface(_ request: [String: Any] = [:]) -> (NSView, NSWindow) {
        let view = Float.surface(request)
        return (view, FloatKeyBench.host(view))
    }

    private func owner(_ view: NSView) -> String {
        var at = view.superview
        while let here = at {
            if here is FloatCaptionsView || here is FloatScrubView || here is FloatFeedbackView || here is FloatWaitingView {
                return String(describing: type(of: here))
            }
            at = here.superview
        }
        return ""
    }

    @Test func everyGlassPieceOfTheFloatingVideoIsPlainSystemGlassAsIn044() {
        let (view, window) = surface(["live": true, "feedback": "1.5×", "waiting": true])
        defer { window.contentView = nil }

        let glasses = view.kitSubviews(of: NSGlassEffectView.self)
        let faces = glasses.compactMap { $0 as? KitGlassFace }
        let plain = glasses.filter { type(of: $0) == NSGlassEffectView.self }
        let keys = view.kitSubviews(of: FloatKeyView.self)

        #expect(faces.count == 7)
        #expect(plain.count == 4)
        #expect(glasses.count == 11)
        #expect(view.kitSubviews(of: KitGlass.self).isEmpty)
        #expect(view.kitSubviews(of: KitGlassGround.self).isEmpty)
        #expect(view.kitSubviews(of: KitCenteringView.self).allSatisfy { $0.plate == nil && $0.layer?.backgroundColor == nil })
        #expect(faces.allSatisfy { $0.plate == nil && $0.style == .regular && $0.effectIsInteractive && $0.tintColor == nil })
        #expect(Set(keys.compactMap { $0.accessibilityLabel() })
            == ["Close", "Back to Tab", "Back 15 Seconds", "Pause", "Forward 15 Seconds", "Playback Speed", "Go Live", "Subtitles", "Subtitle Language"])
        #expect(keys.filter { $0.glass != nil }.count == 7)
        #expect(plain.allSatisfy { $0.style == .regular && $0.tintColor == nil })
        #expect(Dictionary(plain.map { (owner($0), $0.effectIsInteractive) }, uniquingKeysWith: { first, _ in first })
            == ["FloatCaptionsView": true, "FloatScrubView": false, "FloatFeedbackView": false, "FloatWaitingView": false])
    }

    @Test func theCallWindowsCornerKeysAreTheSamePlainGlass() {
        let corners = CallCorners(frame: NSRect(x: 0, y: 0, width: 320, height: 180), close: {}, back: {})
        corners.layoutSubtreeIfNeeded()

        let faces = corners.kitSubviews(of: KitGlassFace.self)

        #expect(faces.count == 2)
        #expect(faces.allSatisfy { $0.plate == nil && $0.style == .regular && $0.effectIsInteractive && $0.tintColor == nil })
    }

    @Test func theFloatingVideosMarksAreListedForTheInkMeasureAndNotJudgedByIt() {
        let (view, window) = surface(["live": true, "feedback": "1.5×", "waiting": true])
        defer { window.contentView = nil }

        let said = BenchInk.said(view)
        let notes = Set(said.compactMap { $0["note"] as? String })
        let kinds = Set(said.compactMap { $0["kind"] as? String })
        let live = said.filter { ($0["text"] as? String)?.hasPrefix("−") == true || $0["text"] as? String == "Live" }

        #expect(said.count >= 9, "\(said)")
        #expect(notes == ["float", "video"], "\(said)")
        #expect(kinds.contains("KitSymbol"))
        #expect(said.contains { $0["kind"] as? String == "PlayGlyph" && $0["text"] as? String == "pause.fill" && $0["note"] as? String == "float" })
        #expect(live.count == 1 && live.allSatisfy { $0["note"] as? String == "video" })
        #expect(said.filter { $0["text"] as? String == "Go Live" }.allSatisfy { $0["note"] as? String == "float" })
    }
}

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct FloatKeyPlacesTests {
    @Test(arguments: [1, 2])
    func eachMarksWeightSitsOnItsDiscsCentreAsNearAsAPixelAllows(scale: Int) {
        let places = FloatKeyBench.places(scale: scale)
        let back = places.first { $0.key == "back" }
        let forward = places.first { $0.key == "forward" }
        let middle = places.filter { $0.key == "middle" }

        #expect(places.count == 4)
        #expect(Set(middle.map(\.face)) == ["play.fill", "pause.fill"])
        for place in middle {
            #expect(abs(place.frame.midX - place.disc / 2) < 0.001 && abs(place.frame.midY - place.disc / 2) < 0.001, "\(place.line)")
            #expect(place.frame.size == KitGlyph.image(place.face, FloatKeyBench.middle)?.size)
        }
        let pause = middle.first { $0.face == "pause.fill" }
        #expect(abs(pause?.off.dx ?? 9) <= 0.5 && abs(pause?.off.dy ?? 9) <= 0.5, "\(pause?.line ?? "")")
        for place in [back, forward].compactMap({ $0 }) {
            #expect(abs(place.off.dx) <= 0.5 && abs(place.off.dy) <= 0.5, "\(place.line)")
            #expect(abs(place.ringOff?.dx ?? 9) <= 0.5 / CGFloat(scale) + 0.01 && abs(place.ringOff?.dy ?? 9) <= 0.5 / CGFloat(scale) + 0.01, "\(place.line)")
        }
        #expect(back?.frame == forward?.frame)
        #expect(abs(((back?.off.dx ?? 9) + (forward?.off.dx ?? 9)) / 2) <= 0.5 / CGFloat(scale) + 0.01)
        #expect(abs((back?.ringOff?.dx ?? 9) - (forward?.ringOff?.dx ?? -9)) <= 0.13)
        #expect(abs((back?.ringOff?.dy ?? 9) - (forward?.ringOff?.dy ?? -9)) <= 0.13)
    }

    @Test func theLaidOutKeysUseThePlacesTheNumbersAreTakenFrom() {
        let (transport, chrome) = FloatKeyBench.transport(playing: true)
        transport.layoutSubtreeIfNeeded()
        let places = FloatKeyBench.places(scale: 2)

        let pause = transport.toggle.glyph?.drawn
        chrome.playing = false
        FloatKeyBench.settle(transport)

        #expect(transport.rewind.symbol?.frame == places.first { $0.key == "back" }?.frame)
        #expect(transport.forward.symbol?.frame == places.first { $0.key == "forward" }?.frame)
        #expect(transport.rewind.symbol?.whole == true && transport.forward.symbol?.whole == true)
        #expect(transport.rewind.symbol?.frame.size == transport.rewind.symbol?.image?.size)
        #expect(pause == places.first { $0.face == "pause.fill" }?.frame)
        #expect(transport.toggle.glyph?.drawn == places.first { $0.face == "play.fill" }?.frame)
        #expect(transport.toggle.glyph?.frame == NSRect(x: 0, y: 0, width: FloatLayout.play, height: FloatLayout.play))
        #expect(transport.toggle.nudge == .zero)
    }

    @Test(arguments: [true, false])
    func theRealKeysDrawTheirMarksWhereTheNumbersSay(playing: Bool) throws {
        let (transport, _) = FloatKeyBench.transport(playing: playing)
        let window = FloatKeyBench.host(transport)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        window.benchShowBehind()
        transport.layoutSubtreeIfNeeded()
        transport.displayIfNeeded()
        CATransaction.flush()
        let scale = Int(window.backingScaleFactor)
        let places = FloatKeyBench.places(scale: scale)

        for (key, view) in [("back", transport.rewind), ("middle", transport.toggle), ("forward", transport.forward)] {
            let holder = try #require(view.face.superview)
            let drawn = try #require(FloatKeyBench.drawnWeight(of: holder, scale: CGFloat(scale)))
            let place = try #require(places.first { $0.key == key && $0.face != (playing ? "play.fill" : "pause.fill") })
            let near = key == "middle" ? 0.5 / CGFloat(scale) + 0.05 : 0.05
            #expect(holder.bounds.width == place.disc)
            #expect(abs(drawn.x - place.weight.x) < near && abs(drawn.y - place.weight.y) < near, "\(key) drawn at \(drawn), \(place.line)")
        }
    }

    @Test func theSkipMarksTakeOneNudgeFromTheirWeightAndTheOtherKeysKeepTheirs() {
        let style = KitSymbol.Style(size: 16, weight: .semibold)

        let back = FloatOptics.nudge("gobackward.15", style)
        let forward = FloatOptics.nudge("goforward.15", style)

        #expect(back == forward)
        #expect(back.dy < 0 && back.dy > -2)
        #expect(abs(back.dx) < 1)
        #expect(FloatOptics.nudge("pip.exit", KitSymbol.Style(size: 12, weight: .bold)) == CGVector(dx: 0, dy: -0.5))
        #expect(FloatOptics.nudge("chevron.down", KitSymbol.Style(size: 10, weight: .semibold)) == CGVector(dx: 0, dy: -1))
        #expect(FloatOptics.nudge("xmark", KitSymbol.Style(size: 12, weight: .bold)) == .zero)
        let close = FloatKeyView(symbol: "xmark", size: 12, weight: .bold, label: "Close", action: {})
        #expect(close.symbol?.whole == false)
    }

    @Test(arguments: ["float", "sidebar"])
    func playAndPauseTakeNoNudgeOfTheirOwnBecauseTheSymbolCarriesItsShift(key: String) throws {
        let style = key == "float" ? PlayGlyph.float : PlayGlyph.sidebar
        let play = try #require(KitGlyph.image("play.fill", style))
        let pause = try #require(KitGlyph.image("pause.fill", style))

        let triangle = KitGlyph.ink(of: play)
        let bars = KitGlyph.ink(of: pause)

        #expect(FloatOptics.nudge("play.fill", style) == .zero && FloatOptics.nudge("pause.fill", style) == .zero)
        #expect(!FloatOptics.weighed("play.fill") && !FloatOptics.weighed("pause.fill") && FloatOptics.weighed("gobackward.15"))
        #expect(!FloatOptics.weighed("xmark"))
        #expect(triangle.midX - play.size.width / 2 >= 0.2, "play \(triangle) in \(play.size)")
        #expect(abs(bars.midX - pause.size.width / 2) < 0.35, "pause \(bars) in \(pause.size)")
    }

    @Test(arguments: [NSSize(width: 400, height: 225), NSSize(width: 320, height: 180), NSSize(width: 641, height: 361)])
    func theRowIsThreeDiscsWithEqualGapsInTheMiddleOfTheWindow(size: NSSize) {
        let bounds = NSRect(origin: .zero, size: size)
        let row = FloatLayout.transport(in: bounds)
        let (transport, _) = FloatKeyBench.transport(playing: true)
        transport.frame = row
        transport.layoutSubtreeIfNeeded()
        let frames = [transport.rewind, transport.toggle, transport.forward].map(\.frame)

        #expect(frames.map(\.size) == [NSSize(width: 40, height: 40), NSSize(width: 48, height: 48), NSSize(width: 40, height: 40)])
        #expect(frames[1].minX - frames[0].maxX == 12 && frames[2].minX - frames[1].maxX == 12)
        #expect(Set(frames.map(\.midY)) == [24])
        #expect(frames[0].minX == 0 && frames[2].maxX == row.width)
        #expect(frames[1].midX == row.width / 2)
        #expect(abs(row.midX - bounds.midX) <= 0.5 && abs(row.midY - bounds.midY) <= 0.5)
        #expect(size.width.truncatingRemainder(dividingBy: 2) != 0 || row.midX == bounds.midX)
    }
}

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)),
       .enabled(if: ProcessInfo.processInfo.environment["SEARCH_FILM"] != nil, "SEARCH_FILM names a folder for the pictures the keys draw of themselves"))
@MainActor
struct FloatKeyPicturesTests {
    static let ground = NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1)
    static let disc = NSColor(white: 1, alpha: 0.16)
    static let guide = NSColor(srgbRed: 1, green: 0.3, blue: 0.25, alpha: 0.9)

    private func home() throws -> URL {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SEARCH_FILM"]), isDirectory: true)
            .appendingPathComponent("float-keys")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func save(_ image: CGImage?, _ name: String, in folder: URL) throws {
        let image = try #require(image)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent(name))
    }

    private func cross(at centre: CGPoint, reach: CGFloat, in context: CGContext) {
        context.setFillColor(Self.guide.cgColor)
        context.fill(CGRect(x: centre.x - reach, y: centre.y - 0.05, width: reach * 2, height: 0.1))
        context.fill(CGRect(x: centre.x - 0.05, y: centre.y - reach, width: 0.1, height: reach * 2))
    }

    @Test(arguments: [1, 2])
    func theThreeKeysAtRest(scale: Int) throws {
        let folder = try home()
        let pad: CGFloat = 8
        let style = KitSymbol.Style(size: 16, weight: .semibold)
        let size = NSSize(width: FloatLayout.transport.width + pad * 2, height: FloatLayout.transport.height + pad * 2)
        let discs: [(key: String, x: CGFloat, side: CGFloat)] = [("back", 0, FloatLayout.skip), ("middle", FloatLayout.skip + FloatLayout.gap, FloatLayout.play),
                                                               ("forward", FloatLayout.skip + FloatLayout.play + FloatLayout.gap * 2, FloatLayout.skip)]
        let places = FloatKeyBench.places(scale: scale)
        for face in ["play", "pause"] {
            let small = FloatKeyBench.canvas(size, scale: CGFloat(scale), ground: Self.ground) { context in
                for disc in discs {
                    let top = pad + (FloatLayout.play - disc.side) / 2
                    let box = CGRect(x: pad + disc.x, y: top, width: disc.side, height: disc.side)
                    context.setFillColor(Self.disc.cgColor)
                    context.fillEllipse(in: box)
                    let middle = disc.key == "middle"
                    if let place = places.first(where: { $0.key == disc.key && (!middle || $0.face == face + ".fill") }),
                       let image = KitGlyph.image(place.face, middle ? FloatKeyBench.middle : style) {
                        let white = NSImage(size: image.size, flipped: false) { rect in
                            image.draw(in: rect)
                            NSColor.white.set()
                            rect.fill(using: .sourceAtop)
                            return true
                        }
                        let pen = NSGraphicsContext(cgContext: context, flipped: true)
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = pen
                        white.draw(in: NSRect(x: box.minX + place.image.x, y: box.minY + place.image.y, width: image.size.width, height: image.size.height),
                                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                }
            }
            let small2 = try #require(small)
            let grow = CGFloat(16 / scale)
            let large = FloatKeyBench.canvas(NSSize(width: CGFloat(small2.width), height: CGFloat(small2.height)), scale: grow) { context in
                context.interpolationQuality = .none
                context.saveGState()
                context.translateBy(x: 0, y: CGFloat(small2.height))
                context.scaleBy(x: 1, y: -1)
                context.draw(small2, in: CGRect(x: 0, y: 0, width: small2.width, height: small2.height))
                context.restoreGState()
                for disc in discs {
                    let top = pad + (FloatLayout.play - disc.side) / 2
                    cross(at: CGPoint(x: (pad + disc.x + disc.side / 2) * CGFloat(scale), y: (top + disc.side / 2) * CGFloat(scale)),
                          reach: disc.side / 2 * CGFloat(scale), in: context)
                }
            }
            try save(large, "keys-at-rest-\(face)-\(scale)x.png", in: folder)
        }
        let text = places.map(\.line).joined(separator: "\n")
        try text.write(to: folder.appendingPathComponent("places-\(scale)x.txt"), atomically: true, encoding: .utf8)
    }
}
