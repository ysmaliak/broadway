import AppKit
import Observation

@MainActor
@Observable
final class FloatChrome {
    var shown = false
    var playing = true
    var through: Double = 0
    var duration: Double = 0
    var scrubbing = false
    var rewinds = 0
    var forwards = 0
    var rate: Double = 1
    var controllable = false
    var feedback: String?

    var timeline = FloatTimeline()
    var current: Double = 0
    var captions: [FloatCaption] = []
    var chapters: [FloatChapter] = []
    var waiting = false

    var seekable: Bool { timeline.seekable }
    var captioned: Bool { captions.contains { $0.selected } }
    var position: Double { timeline.target(through) ?? current }
    var lag: Double { max(0, timeline.end - current) }
}

enum FloatOptics {
    static func nudge(_ symbol: String) -> CGVector {
        switch symbol {
        case "gobackward.15", "goforward.15": CGVector(dx: 0, dy: -1.5)
        case "pause.fill": CGVector(dx: 0, dy: -0.5)
        case "play.fill": CGVector(dx: 1, dy: -0.5)
        case "pip.exit": CGVector(dx: 0, dy: -0.5)
        case "chevron.down": CGVector(dx: 0, dy: -1)
        default: .zero
        }
    }
}

enum FloatLayout {
    static let corner: CGFloat = 16
    static let inset: CGFloat = 10
    static let circle: CGFloat = 30
    static let skip: CGFloat = 40
    static let play: CGFloat = 48
    static let gap: CGFloat = 12
    static let transport = CGSize(width: skip * 2 + play + gap * 2, height: play)
    static let scrubSide: CGFloat = 14
    static let scrubLine: CGFloat = 12
    static let scrubReach: CGFloat = 26
    static let scrubRoom: CGFloat = 60
    static let slop: CGFloat = 4

    static let scrimTop = (alpha: 0.32, reach: 0.35)
    static let scrimBottom = (alpha: 0.36, reach: 0.6)

    static func scrim() -> (alphas: [Double], locations: [Double]) {
        let steps = [0, 0.25, 0.5, 0.75, 1.0]
        let ease = { (step: Double) in (1 - step) * (1 - step) }
        let top = steps.map { (alpha: scrimTop.alpha * ease($0), location: scrimTop.reach * $0) }
        let bottom = steps.reversed().map { (alpha: scrimBottom.alpha * ease($0), location: 1 - scrimBottom.reach * $0) }
        let stops = top + bottom
        return (stops.map(\.alpha), stops.map(\.location))
    }

    static func close(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.maxX - inset - circle, y: bounds.maxY - inset - circle, width: circle, height: circle)
    }

    static func back(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + inset, y: bounds.maxY - inset - circle, width: circle, height: circle)
    }

    static func speed(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX - 27, y: bounds.maxY - inset - circle, width: 54, height: circle)
    }

    static func captions(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX + 2, y: bounds.maxY - inset - circle, width: 64, height: circle)
    }

    static let line: CGFloat = 24
    static let lineLift: CGFloat = 28

    static func live(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.maxX - scrubSide - 140, y: bounds.minY + lineLift, width: 140, height: line)
    }

    static func waiting(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + scrubSide, y: bounds.minY + lineLift, width: 100, height: line)
    }

    static func feedback(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX - 70, y: max(bounds.minY + 4, bounds.midY - 76), width: 140, height: 42)
    }

    static func transport(in bounds: CGRect) -> CGRect {
        CGRect(
            x: (bounds.midX - transport.width / 2).rounded(),
            y: (bounds.midY - transport.height / 2).rounded(),
            width: transport.width,
            height: transport.height
        )
    }

    static func scrub(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + scrubSide - 8, y: bounds.minY, width: max(0, bounds.width - 2 * (scrubSide - 8)), height: scrubRoom)
    }

    static func scrubHit(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + scrubSide - 6, y: bounds.minY, width: max(0, bounds.width - 2 * (scrubSide - 6)), height: scrubReach)
    }
}

struct FloatShade: Equatable {
    static let columns = 16
    static let rows = 9
    static let bright = 0.7
    static let glyphShadow: CGFloat = 1
    static let glyphOpacity: Swift.Float = 0.25

    let cells: [Double]

    init(uniform: Double) {
        cells = Array(repeating: uniform, count: Self.columns * Self.rows)
    }

    init?(_ image: CGImage) {
        let columns = Self.columns, rows = Self.rows
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                          bytesPerRow: columns * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return nil }
        cells = (0..<(columns * rows)).map { index in
            Self.luma(red: Double(pixels[index * 4]) / 255, green: Double(pixels[index * 4 + 1]) / 255,
                      blue: Double(pixels[index * 4 + 2]) / 255)
        }
    }

    static func luma(red: Double, green: Double, blue: Double) -> Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    static func luma(of color: NSColor) -> Double? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return luma(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
    }

    func luminance(in unit: CGRect) -> Double {
        let columns = Self.columns, rows = Self.rows
        let box = unit.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, cells.count == columns * rows else { return 0 }
        let left = min(columns - 1, max(0, Int((box.minX * CGFloat(columns)).rounded(.down))))
        let right = min(columns - 1, max(left, Int((box.maxX * CGFloat(columns)).rounded(.up)) - 1))
        let top = min(rows - 1, max(0, Int((box.minY * CGFloat(rows)).rounded(.down))))
        let bottom = min(rows - 1, max(top, Int((box.maxY * CGFloat(rows)).rounded(.up)) - 1))
        var sum = 0.0
        var count = 0
        for row in top...bottom {
            for column in left...right {
                sum += cells[row * columns + column]
                count += 1
            }
        }
        return sum / Double(max(1, count))
    }

    func bright(in unit: CGRect) -> Bool { luminance(in: unit) > Self.bright }
}

class FloatPiece: NSView {
    let chrome: FloatChrome
    let arrival: KitArrival
    let body: NSView
    private var arrived: Bool?

    init(chrome: FloatChrome, arrival: KitArrival, flipped: Bool = true) {
        self.chrome = chrome
        self.arrival = arrival
        body = flipped ? KitFlippedView() : NSView()
        super.init(frame: .zero)
        wantsLayer = true
        body.wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        addSubview(body)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        body.frame = bounds
        arrange()
        let shown = chrome.shown
        if arrived != shown {
            kitArrive(shown, arrival, animated: arrived != nil)
            arrived = shown
        } else if !shown, layer?.animation(forKey: "arrive") == nil {
            kitArrive(false, arrival, animated: false)
        }
    }

    func arrange() {}

    func center(_ view: NSView, in room: NSRect, size: NSSize? = nil) {
        let size = size ?? view.intrinsicContentSize
        view.frame = kitSnap(NSRect(x: room.midX - size.width / 2, y: room.midY - size.height / 2, width: size.width, height: size.height))
    }
}

final class FloatKeyView: KitHoverView {
    var action: () -> Void
    var enabled = true { didSet { if enabled != oldValue { alphaValue = enabled ? 1 : 0.45 } } }
    var shaded = false { didSet { if shaded != oldValue { shade() } } }
    let glass: KitGlassFace?
    let face: NSView
    private let holder: NSView
    private var pressed = false { didSet { if pressed != oldValue { lit() } } }

    init(_ face: NSView, glassed: Bool = true, label: String, help: String? = nil, action: @escaping () -> Void) {
        self.face = face
        if glassed {
            let made = KitGlassFace(face)
            made.style = .regular
            made.effectIsInteractive = true
            glass = made
            holder = made
        } else {
            let made = KitCenteringView()
            made.addSubview(face)
            glass = nil
            holder = made
        }
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        addSubview(holder)
        face.wantsLayer = true
        face.layer?.opacity = 0.92
        kitAccess(label: label, role: .button, help: help)
    }

    convenience init(symbol: String, size: CGFloat, weight: NSFont.Weight, glassed: Bool = true, label: String, help: String? = nil,
                     action: @escaping () -> Void) {
        self.init(KitSymbol(symbol, style: KitSymbol.Style(size: size, weight: weight), tint: .white), glassed: glassed, label: label,
                  help: help, action: action)
        nudge = FloatOptics.nudge(symbol)
    }

    convenience init(text: String, font: NSFont, label: String, help: String? = nil, action: @escaping () -> Void) {
        self.init(KitLabel(text, font: font, color: .white), label: label, help: help, action: action)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var symbol: KitSymbol? { face as? KitSymbol }

    var nudge: CGVector {
        get { glass?.nudge ?? (holder as? KitCenteringView)?.nudge ?? .zero }
        set {
            glass?.nudge = newValue
            (holder as? KitCenteringView)?.nudge = newValue
        }
    }
    var label: KitLabel? { face as? KitLabel }

    override func layout() {
        super.layout()
        holder.frame = bounds
    }

    private func shade() {
        guard let layer = face.layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = FloatShade.glyphShadow
        layer.shadowOpacity = shaded ? FloatShade.glyphOpacity : 0
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, frame.contains(point) else { return nil }
        guard enabled, let glass, glass.effectIsInteractive else { return self }
        return glass.kitCatch
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard enabled else { return }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let fire = pressed && enabled
        pressed = false
        if fire { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        action()
        return true
    }

    override func hoverChanged() { lit() }

    private func lit() {
        face.layer?.kitAnimate("opacity", to: hovering || pressed ? 1 : 0.92, curve: Motion.kitQuick)
    }
}

final class FloatCornerView: FloatPiece {
    let key: FloatKeyView

    init(chrome: FloatChrome, anchor: CGPoint, symbol: String, label: String, action: @escaping () -> Void) {
        key = FloatKeyView(symbol: symbol, size: 12, weight: .bold, label: label, help: label, action: action)
        super.init(chrome: chrome, arrival: .unfold(from: anchor))
        body.addSubview(key)
    }

    override func arrange() {
        key.frame = bounds
    }
}

final class FloatTransportView: FloatPiece {
    let group = KitGlassGroup(spacing: FloatLayout.gap - 6)
    private(set) lazy var rewind = FloatKeyView(symbol: "gobackward.15", size: 16, weight: .semibold, label: "Back 15 Seconds",
                                                help: "Back 15 Seconds") { [weak self] in self?.onRewind() }
    private(set) lazy var toggle = FloatKeyView(symbol: "pause.fill", size: 21, weight: .semibold, label: "Pause",
                                                help: "Pause") { [weak self] in self?.onToggle() }
    private(set) lazy var forward = FloatKeyView(symbol: "goforward.15", size: 16, weight: .semibold, label: "Forward 15 Seconds",
                                                 help: "Forward 15 Seconds") { [weak self] in self?.onForward() }
    private let onRewind: () -> Void
    private let onToggle: () -> Void
    private let onForward: () -> Void
    private var rewinds = 0
    private var forwards = 0
    private var playing: Bool?

    init(chrome: FloatChrome, rewind: @escaping () -> Void, toggle: @escaping () -> Void, forward: @escaping () -> Void) {
        onRewind = rewind
        onToggle = toggle
        onForward = forward
        super.init(chrome: chrome, arrival: .sheet)
        rewinds = chrome.rewinds
        forwards = chrome.forwards
        body.addSubview(group)
        for key in [self.rewind, self.toggle, self.forward] { group.content.addSubview(key) }
    }

    override func arrange() {
        group.frame = bounds
        let y = (bounds.height - FloatLayout.skip) / 2
        rewind.frame = NSRect(x: 0, y: y, width: FloatLayout.skip, height: FloatLayout.skip)
        toggle.frame = NSRect(x: FloatLayout.skip + FloatLayout.gap, y: (bounds.height - FloatLayout.play) / 2,
                              width: FloatLayout.play, height: FloatLayout.play)
        forward.frame = NSRect(x: FloatLayout.skip + FloatLayout.play + FloatLayout.gap * 2, y: y,
                               width: FloatLayout.skip, height: FloatLayout.skip)
        let playing = chrome.playing
        if playing != self.playing {
            let name = playing ? "pause.fill" : "play.fill"
            let words = playing ? "Pause" : "Play"
            toggle.nudge = FloatOptics.nudge(name)
            if self.playing == nil {
                toggle.symbol?.name = name
            } else {
                toggle.symbol?.replace(to: name)
            }
            toggle.kitAccess(label: words, help: words)
            self.playing = playing
        }
        if chrome.rewinds > rewinds, !Motion.reduced {
            rewind.symbol?.addSymbolEffect(.wiggle.counterClockwise, options: .speed(1.6))
        }
        if chrome.forwards > forwards, !Motion.reduced {
            forward.symbol?.addSymbolEffect(.wiggle.clockwise, options: .speed(1.6))
        }
        rewinds = chrome.rewinds
        forwards = chrome.forwards
    }
}

final class FloatScrubView: FloatPiece {
    let seek: (Double, Bool) -> Void
    private let track = CALayer()
    private let fill = CALayer()
    private let knob = CALayer()
    private var ticks: [CALayer] = []
    private let pill = NSGlassEffectView()
    private let words = KitLabel("", font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold), color: .white)
    private var hovering = false { didSet { if hovering != oldValue { needsLayout = true } } }
    private var hoverFraction: Double? { didSet { if hoverFraction != oldValue { needsLayout = true } } }
    private var wasLit: Bool?
    private var tagShown = false
    private var area: NSTrackingArea?

    private static let side: CGFloat = 8

    init(chrome: FloatChrome, seek: @escaping (Double, Bool) -> Void) {
        self.seek = seek
        super.init(chrome: chrome, arrival: .rise(by: 6), flipped: false)
        guard let layer = body.layer else { return }
        track.backgroundColor = NSColor(white: 1, alpha: 0.3).cgColor
        fill.backgroundColor = NSColor.white.cgColor
        knob.backgroundColor = NSColor.white.cgColor
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.35
        knob.shadowRadius = 2
        knob.shadowOffset = CGSize(width: 0, height: -1)
        for part in [track, fill, knob] {
            part.cornerCurve = .continuous
            layer.addSublayer(part)
        }
        pill.style = .regular
        pill.alphaValue = 0
        words.alphaValue = 0
        words.overflow = .tail
        body.addSubview(pill)
        body.addSubview(words)
        kitAccess(label: "Position", value: FloatTime.label(chrome.position))
    }

    private var width: CGFloat { max(1, bounds.width - 2 * Self.side) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let made = NSTrackingArea(rect: NSRect(x: 0, y: bounds.height - FloatLayout.scrubReach, width: bounds.width, height: FloatLayout.scrubReach),
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self)
        addTrackingArea(made)
        area = made
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        hoverAt(event)
    }

    override func mouseMoved(with event: NSEvent) { hoverAt(event) }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        hoverFraction = nil
    }

    private func hoverAt(_ event: NSEvent) {
        let x = body.convert(event.locationInWindow, from: nil).x
        hoverFraction = FloatTime.clamp(Double((x - Self.side) / width))
    }

    private func fraction(_ event: NSEvent) -> Double {
        Double((body.convert(event.locationInWindow, from: nil).x - Self.side) / width)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let inside = body.convert(point, from: superview)
        guard chrome.seekable, inside.y >= 0, inside.y <= FloatLayout.scrubReach, inside.x >= 0, inside.x <= bounds.width else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { seek(fraction(event), false) }
    override func mouseDragged(with event: NSEvent) { seek(fraction(event), false) }
    override func mouseUp(with event: NSEvent) { seek(fraction(event), true) }

    override func arrange() {
        let side = Self.side
        let width = self.width
        let lit = hovering || chrome.scrubbing
        let thick: CGFloat = lit ? 5 : 3
        let through = CGFloat(FloatTime.clamp(chrome.through))
        let line = FloatLayout.scrubLine
        let animate = wasLit != nil && wasLit != lit && !Motion.reduced
        let curve: KitCurve = animate ? .spring(KitSpring(response: 0.24, damping: 0.8)) : .none
        body.alphaValue = chrome.seekable ? 1 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(track, NSRect(x: side, y: line - thick / 2, width: width, height: thick), curve)
        let filled = max(thick, width * through)
        place(fill, NSRect(x: side, y: line - thick / 2, width: filled, height: thick), curve)
        let shown = chrome.chapters.filter { $0.start > chrome.timeline.start && $0.start < chrome.timeline.end }
        while ticks.count < shown.count {
            let tick = CALayer()
            tick.backgroundColor = NSColor(white: 0, alpha: 0.65).cgColor
            body.layer?.insertSublayer(tick, below: knob)
            ticks.append(tick)
        }
        for (index, tick) in ticks.enumerated() {
            tick.isHidden = index >= shown.count
            guard index < shown.count else { continue }
            let x = side + width * CGFloat(chrome.timeline.fraction(shown[index].start))
            place(tick, NSRect(x: x - 1, y: line - (thick + 2) / 2, width: 2, height: thick + 2), curve, round: false)
        }
        knob.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        knob.cornerRadius = 6
        knob.position = CGPoint(x: side + width * through, y: line)
        CATransaction.commit()
        let scale: CGFloat = lit ? 1 : 0.2
        knob.kitAnimate("transform", to: NSValue(caTransform3D: CATransform3DMakeScale(scale, scale, 1)), curve: curve)
        knob.kitAnimate("opacity", to: lit ? 1 : 0, curve: curve)
        wasLit = lit

        let tagged = chrome.scrubbing || (!chrome.chapters.isEmpty && hoverFraction != nil)
        if tagged {
            let fraction = chrome.scrubbing ? Double(through) : hoverFraction ?? Double(through)
            let seconds = chrome.timeline.target(fraction) ?? 0
            let chapter = chrome.chapters.last { seconds >= $0.start && seconds < $0.end }
            words.text = chapter?.name ?? FloatTime.label(seconds)
            let natural = words.intrinsicContentSize
            let wide = min(natural.width + 16, max(0, width - 16))
            let high = natural.height + 8
            pill.frame = kitSnap(NSRect(x: side + width / 2 - wide / 2, y: line + 22 - high / 2, width: wide, height: high))
            pill.cornerRadius = high / 2
            words.frame = kitSnap(NSRect(x: pill.frame.minX + 8, y: pill.frame.minY + 4, width: wide - 16, height: natural.height))
        }
        if tagged != tagShown {
            tagShown = tagged
            for part in [pill, words] { part.layer?.kitAnimate("opacity", to: tagged ? 1 : 0, curve: Motion.kitQuick) }
        }
        setAccessibilityValue(FloatTime.label(chrome.position))
    }

    private func pixel(_ frame: NSRect) -> NSRect {
        let scale = window?.backingScaleFactor ?? 2
        let high = body.bounds.height
        let left = (frame.minX * scale).rounded(.toNearestOrAwayFromZero) / scale
        let right = (frame.maxX * scale).rounded(.toNearestOrAwayFromZero) / scale
        let top = ((high - frame.maxY) * scale).rounded(.toNearestOrAwayFromZero) / scale
        return NSRect(x: left, y: high - top - frame.height, width: right - left, height: frame.height)
    }

    private func place(_ part: CALayer, _ rough: NSRect, _ curve: KitCurve, round: Bool = true) {
        let frame = pixel(rough)
        let bounds = CGRect(origin: .zero, size: frame.size)
        let position = CGPoint(x: frame.midX, y: frame.midY)
        if round { part.cornerRadius = frame.height / 2 }
        if curve.animates {
            part.kitAnimate("bounds", to: NSValue(rect: bounds), curve: curve)
            part.kitAnimate("position", to: NSValue(point: position), curve: curve)
            if round { part.kitAnimate("cornerRadius", to: frame.height / 2, curve: curve) }
        } else {
            part.bounds = bounds
            part.position = position
        }
    }
}
