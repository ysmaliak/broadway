import AppKit
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

    static func weight(of shape: KitPlayShape, progress: Double, in side: CGFloat, scale: CGFloat) -> CGPoint? {
        let middle = CGPoint(x: side / 2, y: side / 2)
        return canvas(NSSize(width: side, height: side), scale: scale) { context in
            shape.draw(progress, around: middle, colour: NSColor.white.cgColor, in: context)
        }.flatMap { weight(of: $0, scale: scale) }
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
        let shape = KitPlayShape(size: 21)
        let frame = FloatOptics.frame(NSSize(width: shape.side, height: shape.side), nudge: .zero, in: FloatLayout.play, scale: CGFloat(scale))
        for face in [KitPlayMark.Face.play, .pause] {
            guard let inside = weight(of: shape, progress: face.rest, in: shape.side, scale: CGFloat(scale)) else { continue }
            out.append(Place(key: "middle", face: face.rawValue, scale: scale, disc: FloatLayout.play, frame: frame, image: frame.origin,
                             weight: CGPoint(x: frame.minX + inside.x, y: frame.minY + inside.y), ring: nil))
        }
        return out
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct KitPlayTurnTests {
    @Test func aTurnStartsAtRestWhereTheMarkWasAndArrivesOnTheOtherFace() {
        let turn = KitPlayTurn(from: 1, to: 0, began: 40, spring: KitPlayTurn.lively)

        #expect(turn.value(at: 40) == 1)
        #expect(turn.speed(at: 40) == 0)
        #expect(turn.value(at: 40.05) < 1 && turn.value(at: 40.05) > 0)
        #expect(abs(turn.value(at: 40 + turn.length)) <= KitPlayTurn.near * 2)
        #expect(turn.length > 0.15 && turn.length <= KitPlayTurn.longest)
        #expect(!turn.settled(at: 40.05))
        #expect(turn.settled(at: 40 + turn.length))
    }

    @Test func theFramesOfATurnBeginWhereItWasAndEndExactlyOnTheFace() {
        for spring in [KitPlayTurn.lively, KitPlayTurn.calm] {
            let turn = KitPlayTurn(from: 0, to: 1, began: 7, spring: spring)

            let frames = turn.frames

            #expect(frames.first == 0)
            #expect(frames.last == 1)
            #expect(frames.count == Int((turn.length / KitPlayTurn.step).rounded()) + 1)
            #expect(zip(frames, frames.dropFirst()).allSatisfy { abs($1 - $0) < 0.12 })
        }
    }

    @Test func aTurnBackStartsWhereTheMarkIsAndKeepsItsSpeedBeforeItTurns() {
        let first = KitPlayTurn(from: 1, to: 0, began: 0, spring: KitPlayTurn.lively)
        let cut = 0.06
        let here = first.value(at: cut)
        let speed = first.speed(at: cut)

        let back = first.turned(to: 1, at: cut, spring: KitPlayTurn.lively)

        #expect(here > 0.05 && here < 0.95)
        #expect(speed < 0)
        #expect(back.from == here)
        #expect(back.to == 1)
        #expect(back.began == cut)
        #expect(abs(back.speed(at: cut) - speed) < 0.0001)
        #expect(back.value(at: cut + 0.004) < here)
        #expect(back.value(at: cut + 0.004) > 0)
        #expect(abs(back.value(at: cut + back.length) - 1) <= KitPlayTurn.near * 2)
        #expect(back.frames.first == here)
        #expect(back.frames.last == 1)
    }

    @Test func aTurnThatIsAlreadyThereDoesNotBlowUp() {
        let first = KitPlayTurn(from: 1, to: 0, began: 0, spring: KitPlayTurn.lively)

        let back = first.turned(to: 1, at: 0, spring: KitPlayTurn.lively)

        #expect(back.lean == 0)
        #expect(back.frames.allSatisfy { $0 == 1 })
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct KitPlayShapeTests {
    @Test func thePlayTrianglesWeightSitsOnTheCentreAndItsBackOnAWholePoint() {
        let play = KitPlayShape.play

        #expect(abs(KitPlayShape.lead - 4.5) < 0.001)
        #expect(abs(play[0].x - KitPlayShape.round + 6) < 0.001)
        #expect(play[0].x == play[3].x)
        #expect(play[5] == play[6])
        #expect(play[5].y == 0)
        #expect(play[1] == play[4] && play[2] == play[7])
    }

    @Test func thePauseBarsAreCentredAsAPairOnHalfPoints() {
        let pause = KitPlayShape.pause
        let round = KitPlayShape.round

        #expect(pause[0].x - round == -7 && pause[1].x + round == -1.5)
        #expect(pause[4].x - round == 1.5 && pause[5].x + round == 7)
        #expect(pause[0].y - round == -9 && pause[3].y + round == 9)
        #expect((0..<4).allSatisfy { pause[$0].x == -pause[[5, 4, 7, 6][$0]].x })
    }

    @Test func everyFrameOfTheSwapIsTheSameAboveAndBelowTheCentre() {
        let shape = KitPlayShape(size: 21)

        for step in 0...10 {
            let points = shape.points(Double(step) / 10)
            #expect(points[0].y == -points[3].y && points[1].y == -points[2].y)
            #expect(points[4].y == -points[7].y && points[5].y == -points[6].y)
        }
    }

    @Test func everyFrameOfTheSwapIsOneTaperingOutlineWithASlit() {
        let shape = KitPlayShape(size: 21)

        for step in 0...10 {
            let points = shape.points(Double(step) / 10)
            let top = [points[0], points[1], points[4], points[5]]
            let lean = (top[3].y - top[0].y) / (top[3].x - top[0].x)
            #expect(top.allSatisfy { abs($0.y - (top[0].y + lean * ($0.x - top[0].x))) < 0.0001 })
            #expect(points[1].x == -points[4].x && points[1].x <= 0)
            #expect(points[0].x < points[1].x && points[4].x < points[5].x)
        }
        #expect(shape.points(0)[1].x == 0)
        #expect(shape.points(1)[4].x - shape.round == KitPlayShape.gap / 2)
    }

    @Test(arguments: [1, 2, 8])
    func theDrawnWeightOfBothFacesIsOnTheCentre(scale: Int) throws {
        let shape = KitPlayShape(size: 21)

        let play = try #require(FloatKeyBench.weight(of: shape, progress: 0, in: shape.side, scale: CGFloat(scale)))
        let pause = try #require(FloatKeyBench.weight(of: shape, progress: 1, in: shape.side, scale: CGFloat(scale)))

        #expect(abs(play.x - shape.side / 2) < 0.03 && abs(play.y - shape.side / 2) < 0.03, "play \(play)")
        #expect(abs(pause.x - shape.side / 2) < 0.03 && abs(pause.y - shape.side / 2) < 0.03, "pause \(pause)")
    }

    @Test func aSmallerMarkKeepsItsProportionsAndAnEvenBox() {
        let small = KitPlayShape(size: 10.5)

        #expect(small.round == 0.75)
        #expect(small.side == 12)
        #expect(small.points(1)[0].x == KitPlayShape.pause[0].x / 2)
    }
}

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct KitPlayMarkTests {
    private func hosted(_ face: KitPlayMark.Face) -> (KitPlayMark, NSWindow) {
        let mark = KitPlayMark(face, size: 21)
        mark.frame = NSRect(origin: .zero, size: mark.intrinsicContentSize)
        return (mark, FloatKeyBench.host(mark))
    }

    private func path(_ mark: KitPlayMark, _ progress: Double) -> CGPath {
        mark.shape.path(progress, around: CGPoint(x: mark.bounds.midX, y: mark.bounds.midY))
    }

    @Test(arguments: [true, false])
    func theFirstTimeTheKeyIsShownItsMarkIsSimplyThereWithNoMotion(playing: Bool) {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (transport, _) = FloatKeyBench.transport(playing: playing)
        let window = FloatKeyBench.host(transport)
        defer { window.contentView = nil }

        let mark = transport.mark

        #expect(mark.face == (playing ? .pause : .play))
        #expect(mark.turn == nil)
        #expect(mark.swaps == 0)
        #expect(mark.ink.animationKeys() ?? [] == [])
        #expect(mark.ink.path == path(mark, playing ? 1 : 0))
    }

    @Test func aSwapInterruptedMidwayTurnsBackFromWhereItIs() throws {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (mark, window) = hosted(.pause)
        defer { window.contentView = nil }
        let start = CACurrentMediaTime()

        mark.show(.play, at: start)
        let first = try #require(mark.turn)
        let cut = start + 0.06
        let here = first.value(at: cut)
        mark.show(.pause, at: cut)
        let back = try #require(mark.turn)
        let film = try #require(mark.ink.animation(forKey: KitPlayMark.key) as? CAKeyframeAnimation)
        let frames = try #require(film.values).map { $0 as! CGPath }

        #expect(here > 0.05 && here < 0.95)
        #expect(back == first.turned(to: 1, at: cut, spring: KitPlayTurn.lively))
        #expect(back.from == here)
        #expect(mark.face == .pause)
        #expect(mark.swaps == 2)
        #expect(frames.count == back.frames.count)
        #expect(frames.first == path(mark, here))
        #expect(frames.last == path(mark, 1))
        #expect(film.duration == back.length)
        #expect(mark.ink.path == path(mark, 1))
    }

    @Test func playingFlickeringSeveralTimesDoesNotStackAnimations() throws {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (mark, window) = hosted(.pause)
        defer { window.contentView = nil }
        let layer = try #require(mark.layer)
        let start = CACurrentMediaTime()

        for turn in 0..<7 {
            mark.show(turn % 2 == 0 ? .play : .pause, at: start + Double(turn) * 0.03)
            #expect(mark.ink.animationKeys() ?? [] == [KitPlayMark.key])
            #expect(BenchGlassFrames.animations(layer) == 1)
        }

        #expect(mark.swaps == 7)
        #expect(mark.face == .play)
        #expect(mark.turn?.to == 0)
        #expect(mark.ink.path == path(mark, 0))
        #expect(layer.sublayers?.count == 1)
    }

    @Test func theKeyFlickeringWithTheChromeEndsOnTheLastWordWithOneAnimationAtMost() {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (transport, chrome) = FloatKeyBench.transport(playing: true)
        let window = FloatKeyBench.host(transport)
        defer { window.contentView = nil }
        let mark = transport.mark

        for turn in 0..<9 {
            chrome.playing = turn % 2 == 1
            FloatKeyBench.settle(transport)
            #expect((mark.ink.animationKeys() ?? []).count <= 1)
        }

        #expect(mark.face == .play)
        #expect(mark.ink.path == path(mark, 0))
        #expect(transport.toggle.accessibilityLabel() == "Play")
    }

    @Test func showingTheFaceItAlreadyHasDoesNothing() {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (mark, window) = hosted(.pause)
        defer { window.contentView = nil }

        mark.show(.pause)
        mark.show(.play)
        let turn = mark.turn
        mark.show(.play)

        #expect(mark.swaps == 1)
        #expect(mark.turn == turn)
    }

    @Test func reduceMotionGivesAPlainSwap() {
        Store.settings.set(true, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let (transport, chrome) = FloatKeyBench.transport(playing: true)
        let window = FloatKeyBench.host(transport)
        defer { window.contentView = nil }
        let mark = transport.mark

        chrome.playing = false
        FloatKeyBench.settle(transport)

        #expect(mark.face == .play)
        #expect(mark.turn == nil)
        #expect(mark.swaps == 0)
        #expect(mark.ink.animationKeys() ?? [] == [])
        #expect(mark.ink.path == path(mark, 0))
    }

    @Test func reduceMotionTurnedOnMidwayEndsTheSwapAtOnce() {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let (mark, window) = hosted(.pause)
        defer { window.contentView = nil }
        let start = CACurrentMediaTime()
        mark.show(.play, at: start)

        Store.settings.set(true, forKey: "motion.testReduced")
        mark.show(.pause, at: start + 0.05)

        #expect(mark.turn == nil)
        #expect(mark.ink.animationKeys() ?? [] == [])
        #expect(mark.ink.path == path(mark, 1))
    }

    @Test func aMarkThatIsInNoWindowSwapsPlainly() {
        let restore = FloatKeyBench.still()
        defer { restore() }
        let mark = KitPlayMark(.pause, size: 21)
        mark.frame = NSRect(origin: .zero, size: mark.intrinsicContentSize)
        mark.layoutSubtreeIfNeeded()

        mark.show(.play)

        #expect(mark.face == .play)
        #expect(mark.turn == nil)
        #expect(mark.ink.path == path(mark, 0))
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
        #expect(!transport.mark.isAccessibilityElement())
    }

    @Test func theMarkSitsWithTheSkipMarksInColourAndLight() {
        let (transport, _) = FloatKeyBench.transport(playing: true)
        transport.layoutSubtreeIfNeeded()
        let mark = transport.mark

        #expect(mark.tint == .white)
        #expect(transport.rewind.symbol?.tint == .white)
        #expect(mark.ink.fillColor?.components == [1, 1, 1, 1])
        #expect(mark.ink.strokeColor == mark.ink.fillColor)
        #expect(mark.layer?.opacity == transport.rewind.face.layer?.opacity)
        #expect(mark.layer?.opacity == 0.92)
    }

    @Test func aMarkOverABrightFrameIsShadedLikeTheOthers() {
        let (transport, _) = FloatKeyBench.transport(playing: true)
        transport.layoutSubtreeIfNeeded()

        transport.toggle.shaded = true
        transport.rewind.shaded = true

        #expect(transport.mark.layer?.shadowOpacity == FloatShade.glyphOpacity)
        #expect(transport.mark.layer?.shadowRadius == transport.rewind.face.layer?.shadowRadius)
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
        #expect(kinds.contains("KitPlayMark"))
        #expect(said.first { $0["kind"] as? String == "KitPlayMark" }?["text"] as? String == "pause")
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
        for place in middle {
            #expect(abs(place.off.dx) < 0.03 && abs(place.off.dy) < 0.03, "\(place.line)")
        }
        #expect(middle.first?.frame == middle.last?.frame)
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

        let pause = transport.mark.frame
        chrome.playing = false
        FloatKeyBench.settle(transport)

        #expect(transport.rewind.symbol?.frame == places.first { $0.key == "back" }?.frame)
        #expect(transport.forward.symbol?.frame == places.first { $0.key == "forward" }?.frame)
        #expect(transport.rewind.symbol?.whole == true && transport.forward.symbol?.whole == true)
        #expect(transport.rewind.symbol?.frame.size == transport.rewind.symbol?.image?.size)
        #expect(pause == places.first { $0.key == "middle" }?.frame)
        #expect(transport.mark.frame == pause)
        #expect(transport.toggle.nudge == .zero)
        #expect(transport.toggle.symbol == nil)
    }

    @Test func theRealKeysDrawTheirMarksWhereTheNumbersSay() throws {
        let (transport, _) = FloatKeyBench.transport(playing: true)
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
            let place = try #require(places.first { $0.key == key && $0.face != "play" })
            #expect(holder.bounds.width == place.disc)
            #expect(abs(drawn.x - place.weight.x) < 0.05 && abs(drawn.y - place.weight.y) < 0.05, "\(key) drawn at \(drawn), \(place.line)")
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

    private func words(_ text: String, at point: CGPoint, in context: CGContext) {
        let pen = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = pen
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular),
                                                            .foregroundColor: NSColor(white: 1, alpha: 0.7)])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func cross(at centre: CGPoint, reach: CGFloat, in context: CGContext) {
        context.setFillColor(Self.guide.cgColor)
        context.fill(CGRect(x: centre.x - reach, y: centre.y - 0.05, width: reach * 2, height: 0.1))
        context.fill(CGRect(x: centre.x - 0.05, y: centre.y - reach, width: 0.1, height: reach * 2))
    }

    private func strip(_ frames: [(time: Double, progress: Double)], name: String, in folder: URL) throws {
        let shape = KitPlayShape(size: 21)
        let side = FloatLayout.play + 8
        let columns = 10
        let rows = (frames.count + columns - 1) / columns
        let image = FloatKeyBench.canvas(NSSize(width: side * CGFloat(columns), height: (side + 10) * CGFloat(rows)), scale: 6, ground: Self.ground) { context in
            for (index, frame) in frames.enumerated() {
                let origin = CGPoint(x: CGFloat(index % columns) * side, y: CGFloat(index / columns) * (side + 10))
                let centre = CGPoint(x: origin.x + side / 2, y: origin.y + side / 2)
                context.setFillColor(Self.disc.cgColor)
                context.fillEllipse(in: CGRect(x: centre.x - FloatLayout.play / 2, y: centre.y - FloatLayout.play / 2, width: FloatLayout.play, height: FloatLayout.play))
                shape.draw(frame.progress, around: centre, colour: NSColor.white.cgColor, in: context)
                words(String(format: "%3.0f ms  %.2f", frame.time * 1000, frame.progress), at: CGPoint(x: origin.x + 8, y: origin.y + side - 1), in: context)
            }
        }
        try save(image, name, in: folder)
    }

    private func frames(_ turn: KitPlayTurn, from start: Double, until end: Double? = nil) -> [(time: Double, progress: Double)] {
        let last = end ?? turn.began + turn.length
        var out: [(time: Double, progress: Double)] = []
        var time = start
        while time < last - 0.0001 {
            out.append((time, turn.value(at: time)))
            time += 1.0 / 60
        }
        return out
    }

    @Test func theMarksOwnLayersAtALargeScale() throws {
        let folder = try home()
        for face in [KitPlayMark.Face.play, .pause] {
            let mark = KitPlayMark(face, size: 21)
            mark.frame = NSRect(origin: .zero, size: mark.intrinsicContentSize)
            mark.layoutSubtreeIfNeeded()
            let layer = try #require(mark.layer)
            let side = FloatLayout.play
            let inset = (side - mark.bounds.width) / 2
            let image = FloatKeyBench.canvas(NSSize(width: side, height: side), scale: 16, ground: Self.ground) { context in
                context.setFillColor(Self.disc.cgColor)
                context.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
                context.saveGState()
                context.translateBy(x: inset, y: inset)
                layer.render(in: context)
                context.restoreGState()
                cross(at: CGPoint(x: side / 2, y: side / 2), reach: side / 2, in: context)
            }
            try save(image, "mark-\(face.rawValue)-16x.png", in: folder)
        }
    }

    @Test func aRowOfFramesThroughTheSwapEachWayAndOneTurnedBack() throws {
        let folder = try home()
        let toPlay = KitPlayTurn(from: 1, to: 0, began: 0, spring: KitPlayTurn.lively)
        let toPause = KitPlayTurn(from: 0, to: 1, began: 0, spring: KitPlayTurn.lively)
        let back = toPlay.turned(to: 1, at: 0.07, spring: KitPlayTurn.lively)
        let calm = KitPlayTurn(from: 1, to: 0, began: 0, spring: KitPlayTurn.calm)

        try strip(frames(toPlay, from: 0) + [(toPlay.length, 0)], name: "swap-to-play.png", in: folder)
        try strip(frames(toPause, from: 0) + [(toPause.length, 1)], name: "swap-to-pause.png", in: folder)
        try strip(frames(toPlay, from: 0, until: 0.07) + frames(back, from: 0.07) + [(back.began + back.length, 1)], name: "swap-turned-back.png", in: folder)
        try strip(frames(calm, from: 0) + [(calm.length, 0)], name: "swap-to-play-low-power.png", in: folder)
        let lines = [("to play", toPlay), ("to pause", toPause), ("turned back at 70 ms", back), ("to play in low power", calm)].map { name, turn in
            String(format: "%@: %.0f ms long, %d frames at 120 a second, furthest past its end %.3f", name, turn.length * 1000, turn.frames.count,
                   turn.frames.map { turn.to == 1 ? $0 - 1 : -$0 }.max() ?? 0)
        }
        try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("swap.txt"), atomically: true, encoding: .utf8)
    }

    @Test(arguments: [1, 2])
    func theThreeKeysAtRest(scale: Int) throws {
        let folder = try home()
        let pad: CGFloat = 8
        let style = KitSymbol.Style(size: 16, weight: .semibold)
        let shape = KitPlayShape(size: 21)
        let size = NSSize(width: FloatLayout.transport.width + pad * 2, height: FloatLayout.transport.height + pad * 2)
        let discs: [(key: String, x: CGFloat, side: CGFloat)] = [("back", 0, FloatLayout.skip), ("middle", FloatLayout.skip + FloatLayout.gap, FloatLayout.play),
                                                               ("forward", FloatLayout.skip + FloatLayout.play + FloatLayout.gap * 2, FloatLayout.skip)]
        let places = FloatKeyBench.places(scale: scale)
        for face in [KitPlayMark.Face.play, .pause] {
            let small = FloatKeyBench.canvas(size, scale: CGFloat(scale), ground: Self.ground) { context in
                for disc in discs {
                    let top = pad + (FloatLayout.play - disc.side) / 2
                    let box = CGRect(x: pad + disc.x, y: top, width: disc.side, height: disc.side)
                    context.setFillColor(Self.disc.cgColor)
                    context.fillEllipse(in: box)
                    if disc.key == "middle" {
                        shape.draw(face.rest, around: CGPoint(x: box.midX, y: box.midY), colour: NSColor.white.cgColor, in: context)
                    } else if let place = places.first(where: { $0.key == disc.key }), let image = KitGlyph.image(place.face, style) {
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
            try save(large, "keys-at-rest-\(face.rawValue)-\(scale)x.png", in: folder)
        }
        let text = places.map(\.line).joined(separator: "\n")
        try text.write(to: folder.appendingPathComponent("places-\(scale)x.txt"), atomically: true, encoding: .utf8)
    }
}
