import AppKit

struct ReloadFace: Equatable {
    enum Phase: Equatable {
        case idle, starting, loading, stopped
    }

    enum Press: Equatable {
        case reload, stop
    }

    static let grace: Duration = .milliseconds(340)

    private(set) var phase: Phase
    private var loading: Bool
    private var reloads: Int
    private var stops: Int

    init(loading: Bool, reloads: Int = 0, stops: Int = 0) {
        phase = loading ? .loading : .idle
        self.loading = loading
        self.reloads = reloads
        self.stops = stops
    }

    var showsStop: Bool { phase == .loading }
    var symbol: String { showsStop ? "xmark" : "arrow.clockwise" }
    var label: String { showsStop ? "Stop" : "Reload" }
    var help: String { showsStop ? "Stop   esc" : "Reload   ⌘R" }
    var press: Press { showsStop ? .stop : .reload }

    mutating func see(loading now: Bool, reloads: Int, stops: Int) {
        let rose = now && !loading
        let reloaded = reloads != self.reloads
        let stopped = stops != self.stops
        loading = now
        self.reloads = reloads
        self.stops = stops
        if stopped {
            phase = .stopped
        } else if reloaded || rose {
            phase = now ? .starting : .idle
        } else if !now, phase != .stopped {
            phase = .idle
        }
    }

    mutating func waited() {
        if phase == .starting, loading { phase = .loading }
    }
}

final class ReloadDoorView: KitButton {
    var reload: () -> Void = {}
    var stop: () -> Void = {}
    var allowed = true
    var ink: KitInk = .flat { didSet { if ink != oldValue { paintGround() } } }
    var greys: KitGreys = .white { didSet { if greys != oldValue { paintGround() } } }

    private(set) var face: ReloadFace
    private var turns: Int
    private let ground = KitBox(fill: nil, corners: .radius(8))
    private let glyph: ReloadGlyph
    private var waiting: DispatchWorkItem?

    init(size: CGFloat = 15, loading: Bool, reloads: Int, stops: Int) {
        face = ReloadFace(loading: loading, reloads: reloads, stops: stops)
        turns = reloads
        seen = (loading, reloads, stops)
        glyph = ReloadGlyph(size: size, stop: face.showsStop, turns: reloads, lit: false)
        super.init(.plain(press: 0.9))
        addSubview(ground)
        content = glyph
        action = { [weak self] in self?.pressed() }
        glyph.setAccessibilityElement(false)
        label()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 30) }

    override func layout() {
        super.layout()
        ground.frame = bounds
        glyph.frame = bounds
    }

    private var seen: (loading: Bool, reloads: Int, stops: Int)?

    func see(loading: Bool, reloads: Int, stops: Int) {
        if let seen, seen == (loading, reloads, stops) { return }
        seen = (loading, reloads, stops)
        face.see(loading: loading, reloads: reloads, stops: stops)
        turns = reloads
        show()
        waiting?.cancel()
        waiting = nil
        guard face.phase == .starting else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.waiting = nil
            self.face.waited()
            self.show()
        }
        waiting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34, execute: work)
    }

    func adopt(loading: Bool, reloads: Int, stops: Int) {
        waiting?.cancel()
        waiting = nil
        seen = (loading, reloads, stops)
        face = ReloadFace(loading: loading, reloads: reloads, stops: stops)
        turns = reloads
        glyph.adopt(stop: face.showsStop, turns: reloads)
        label()
    }

    private func pressed() {
        guard allowed else { return }
        switch face.press {
        case .stop: stop()
        case .reload: reload()
        }
    }

    private func show() {
        glyph.show(stop: face.showsStop, turns: turns, lit: hovering)
        label()
    }

    private func label() {
        setAccessibilityLabel(face.label)
        toolTip = face.help
    }

    override func hoverChanged() {
        super.hoverChanged()
        show()
        ground.layer?.kitTransition(Motion.kitQuick)
        paintGround()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintGround()
    }

    private func paintGround() {
        ground.fill = hovering ? greys.hover(ink, dark: kitDark) : nil
    }
}

final class ReloadGlyph: NSView {
    private let size: CGFloat
    private let arrow = CALayer()
    private let cross = CALayer()
    private let arrowMask = CALayer()
    private let crossMask = CALayer()
    private var stop: Bool
    private var turns: Int
    private var lit: Bool
    private var pivot = CGPoint(x: 0.5, y: 0.5)
    private var drawnScale: CGFloat = 0

    init(size: CGFloat, stop: Bool, turns: Int, lit: Bool) {
        self.size = size
        self.stop = stop
        self.turns = turns
        self.lit = lit
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        for (shape, mask) in [(arrow, arrowMask), (cross, crossMask)] {
            shape.mask = mask
            layer?.addSublayer(shape)
        }
        arrow.opacity = stop ? 0 : 1
        cross.opacity = stop ? 1 : 0
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        draw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        draw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint(animated: false)
    }

    override func layout() {
        super.layout()
        place()
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func draw() {
        guard scale != drawnScale else { return }
        drawnScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let (image, bounds) = Self.render("arrow.clockwise", size: size, scale: scale) {
            arrowMask.contents = image
            arrowMask.contentsScale = scale
            arrowMask.frame = CGRect(origin: .zero, size: bounds)
            arrow.bounds = CGRect(origin: .zero, size: bounds)
            pivot = Self.ring(image) ?? CGPoint(x: 0.5, y: 0.5)
        }
        if let (image, bounds) = Self.render("xmark", size: size, scale: scale) {
            crossMask.contents = image
            crossMask.contentsScale = scale
            crossMask.frame = CGRect(origin: .zero, size: bounds)
            cross.bounds = CGRect(origin: .zero, size: bounds)
        }
        place()
        tint(animated: false)
        CATransaction.commit()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        let round = { (value: CGFloat) in (value * self.scale).rounded() / self.scale }
        let a = arrow.bounds.size
        arrow.anchorPoint = pivot
        arrow.position = CGPoint(x: round(middle.x - a.width / 2) + pivot.x * a.width,
                                 y: round(middle.y - a.height / 2) + pivot.y * a.height)
        let c = cross.bounds.size
        cross.position = CGPoint(x: round(middle.x - c.width / 2) + c.width / 2,
                                 y: round(middle.y - c.height / 2) + c.height / 2)
        CATransaction.commit()
    }

    private func tint(animated: Bool) {
        var color: CGColor = NSColor.gray.cgColor
        let ink = lit ? Palette.NS.ink : Palette.NS.muted
        effectiveAppearance.performAsCurrentDrawingAppearance { color = ink.cgColor }
        CATransaction.begin()
        if animated && !Motion.reduced {
            CATransaction.setAnimationDuration(0.12)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        arrow.backgroundColor = color
        cross.backgroundColor = color
        CATransaction.commit()
    }

    func show(stop: Bool, turns: Int, lit: Bool) {
        if lit != self.lit {
            self.lit = lit
            tint(animated: true)
        }
        if turns != self.turns {
            let more = turns > self.turns
            self.turns = turns
            if more && !Motion.calm && window != nil { turn() }
        }
        if stop != self.stop {
            self.stop = stop
            swap()
        }
    }

    func adopt(stop: Bool, turns: Int) {
        self.turns = turns
        guard stop != self.stop else { return }
        self.stop = stop
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [arrow, cross] { shape.removeAnimation(forKey: "show") }
        arrow.opacity = stop ? 0 : 1
        cross.opacity = stop ? 1 : 0
        CATransaction.commit()
    }

    private func turn() {
        let spin = CASpringAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * CGFloat.pi
        spin.isAdditive = true
        spin.mass = 1
        spin.stiffness = 220
        spin.damping = 24
        spin.duration = spin.settlingDuration
        arrow.add(spin, forKey: "turn \(turns)")
    }

    private func swap() {
        let incoming = stop ? cross : arrow
        let outgoing = stop ? arrow : cross
        let shown = outgoing.presentation()?.opacity ?? 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incoming.opacity = 1
        outgoing.opacity = 0
        CATransaction.commit()
        guard window != nil else { return }
        let calm = Motion.calm
        let now = CACurrentMediaTime()
        let away = calm ? 0.14 : 0.08
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = shown
        fadeOut.toValue = 0
        fadeOut.duration = away
        fadeOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
        outgoing.add(fadeOut, forKey: "show")
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.beginTime = calm ? 0 : now + 0.05
        fadeIn.duration = calm ? 0.14 : 0.1
        fadeIn.fillMode = .backwards
        fadeIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        incoming.add(fadeIn, forKey: "show")
        guard !calm else { return }
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 0.5
        shrink.duration = away
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        outgoing.add(shrink, forKey: "grow")
        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.5
        grow.toValue = 1
        grow.mass = 1
        grow.stiffness = 600
        grow.damping = 30
        grow.beginTime = now + 0.05
        grow.duration = grow.settlingDuration
        grow.fillMode = .backwards
        incoming.add(grow, forKey: "grow")
    }

    static func render(_ name: String, size: CGFloat, scale: CGFloat) -> (CGImage, CGSize)? {
        guard let symbol = KitGlyph.image(name, .init(size: size, weight: IconLook.control)) else { return nil }
        let points = symbol.size
        let width = Int((points.width * scale).rounded(.up)), height = Int((points.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        symbol.draw(in: CGRect(origin: .zero, size: points))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return (image, CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
    }

    static func ring(_ image: CGImage) -> CGPoint? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let alpha = data.bindMemory(to: UInt8.self, capacity: width * height)
        var low = height, high = -1
        for row in 0..<height {
            for column in 0..<width where alpha[row * width + column] > 128 {
                low = min(low, row)
                high = max(high, row)
            }
        }
        guard high > low else { return nil }
        let half = (low + high) / 2
        var left = width, right = -1, bottom = -1
        for row in half...high {
            for column in 0..<width where alpha[row * width + column] > 128 {
                left = min(left, column)
                right = max(right, column)
                bottom = max(bottom, row)
            }
        }
        guard right > left else { return nil }
        let radius = CGFloat(right - left + 1) / 2
        let x = CGFloat(left) + radius
        let y = CGFloat(bottom + 1) - radius
        return CGPoint(x: x / CGFloat(width), y: 1 - y / CGFloat(height))
    }
}

extension ReloadFace {
    @MainActor static func surface(stop: Bool, lift: Double, frame: Bool) -> NSView {
        let row = KitFlippedView()
        let doors = [ReloadDoorView(loading: false, reloads: 0, stops: 0), ReloadDoorView(size: 13, loading: false, reloads: 0, stops: 0)]
        for (index, door) in doors.enumerated() {
            door.ink = KitInk(lift: lift)
            door.greys = frame ? .frame : .white
            door.frame = NSRect(x: 4 + CGFloat(index) * 38, y: 4, width: 30, height: 30)
            row.addSubview(door)
        }
        return BenchFloating.sized(row, NSSize(width: 76, height: 38))
    }
}
