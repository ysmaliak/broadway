import AppKit
import QuartzCore

final class PinMorphView: NSView {
    static let rowMark: CGFloat = SideLook.rowMark
    static let rowLead: CGFloat = SideLook.rowLead

    private let clip = NSView()
    private let base = KitPlate()
    private let wash = KitPlate()
    private let face = PinFaceView()
    private let title = KitLabel()
    private let mark = RowMarkView()
    private var held: NSView?
    private var tally: SideCountView?
    private var ink: KitInk?
    private var form: CGFloat = 0
    private var rowWidth: CGFloat = 0
    private var slab: Bool?
    var washed = true
    var solid: NSColor? {
        didSet {
            base.fill = solid.map { KitTone(base: $0) }
            base.isHidden = solid == nil
        }
    }
    var rowRadius = Metrics.sideRadius
    var count = 0 {
        didSet {
            guard count != oldValue else { return }
            let chip = tally ?? SideCountView()
            if tally == nil {
                addSubview(chip)
                tally = chip
            }
            chip.count = count
            if let ink { chip.dress(ink) }
            chip.fold(count > 1, curve: .none)
            placeTally(in: bounds)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerCurve = .continuous
        addSubview(clip)
        for view in [base, wash, face, title, mark] as [NSView] { clip.addSubview(view) }
        base.isHidden = true
        wash.strokeWidth = 1
        title.lines = 1
        title.overflow = .tail
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(tab: Tab, live: Bool, landing: Bool, titleSize: CGFloat, ground: RowGround) {
        let icon = tab.icon
        let tint = PinTint.of(icon).seeded((tab.home ?? tab.address)?.absoluteString ?? tab.pin ?? "")
        let dark = ground.dark
        let glyph = tint.dress(dark: dark) == .ink
        face.tint = tint
        face.state = landing ? .resting : live ? .live : .hovered
        slab = live && !washed ? dark : nil
        if live, !washed {
            SelectedLook.dress(wash, greys: ground.greys, ink: ground.ink, lifts: false)
        } else {
            wash.fill = ground.greys.wash
            wash.stroke = ground.greys.edge
            wash.hairline = !washed
            wash.rim = nil
            wash.ramp = nil
        }
        wash.ink = ground.ink
        wash.isHidden = !washed && !live
        title.text = tab.label
        title.font = .systemFont(ofSize: titleSize)
        let tone: KitTone = live || washed ? .ink : .title
        title.color = tone.base
        title.opacity = tone.opacity
        title.ink = ground.ink
        mark.icon = icon
        mark.letter = tab.pin ?? tab.monogram
        mark.letterSize = 12
        mark.tiled = false
        mark.glyph = glyph
        mark.ink = ground.ink
        ink = ground.ink
        tally?.dress(ground.ink)
    }

    private func placeTally(in box: NSRect) {
        guard let tally else { return }
        let width = tally.width
        tally.frame = NSRect(x: box.width - width - Self.tallyInset, y: Self.tallyInset, width: width, height: SideCountView.height)
    }

    static let tallyInset: CGFloat = 4

    var tallyFrame: NSRect? { tally.flatMap { $0.showing ? $0.frame : nil } }

    func carry(_ view: NSView) {
        held?.removeFromSuperview()
        held = view
        for part in [face, title, mark] as [NSView] { part.isHidden = true }
        slab = nil
        wash.isHidden = true
        clip.addSubview(view)
        view.frame = clip.bounds
    }

    private struct Seen {
        var frames: [ObjectIdentifier: (CGPoint, CGSize)] = [:]
        var alphas: [ObjectIdentifier: Swift.Float] = [:]
        var radius: CGFloat = 0
    }

    private var parts: [NSView] { [self, clip, base, wash, face, title, mark] + [tally].compactMap { $0 } }

    private func seen() -> Seen {
        var seen = Seen()
        for view in parts {
            guard let layer = view.layer else { continue }
            let shown = layer.presentation() ?? layer
            seen.frames[ObjectIdentifier(view)] = (shown.position, shown.bounds.size)
            seen.alphas[ObjectIdentifier(view)] = shown.opacity
        }
        seen.radius = (clip.layer?.presentation() ?? clip.layer)?.cornerRadius ?? 0
        return seen
    }

    func apply(frame: NSRect, form: CGFloat, lift: CGFloat, curve: KitCurve) {
        let before = curve.animates ? seen() : nil
        let old = self.form
        self.form = form
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = frame
        let box = NSRect(origin: .zero, size: frame.size)
        clip.frame = box
        let radius = PinShape.mix(rowRadius, PinPlaces.radius, form)
        clip.layer?.cornerRadius = radius
        base.frame = box
        base.radius = radius
        held?.frame = box
        base.alphaValue = 1 - form
        wash.frame = box
        wash.radius = radius
        face.frame = box
        face.radius = radius
        wash.alphaValue = 1 - form
        face.alphaValue = form
        let lead = Self.rowLead
        let size = PinShape.mix(Self.rowMark, PinPlaces.mark, form)
        let markX = PinShape.mix(lead + Self.rowMark / 2, box.width / 2, form)
        mark.size = size
        mark.frame = NSRect(x: markX - size / 2, y: box.height / 2 - size / 2, width: size, height: size)
        if form == 0 { rowWidth = box.width }
        let x = lead + Self.rowMark + SideLook.markGap + PinShape.mix(0, -12, form)
        let wide = max(box.width, rowWidth)
        let room = tally.map { $0.showing ? $0.width + Self.tallyInset : 0 } ?? 0
        title.frame = NSRect(x: x, y: (box.height - 16) / 2, width: max(0, wide - lead - Self.rowMark - SideLook.markGap - 10 - room), height: 16)
        placeTally(in: box)
        let words = max(0, 1 - form * 2.2)
        title.alphaValue = words
        let rest = SelectedLook.shadow
        let resting = slab.map { Swift.Float(1 - form) * ($0 ? rest.dark : rest.light) } ?? 0
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Swift.Float(0.28 * lift) + resting * Swift.Float(1 - lift)
        layer?.shadowRadius = 12 * lift + rest.radius * (1 - lift)
        layer?.shadowOffset = CGSize(width: 0, height: -5 * lift - rest.y * (1 - lift))
        let shape = KitPath.continuous(box, radius: radius)
        if let layer, curve.animates, let was = layer.presentation()?.shadowPath ?? layer.shadowPath, was != shape,
           let animation = curve.animation("shadowPath", from: was, to: shape) {
            animation.fillMode = .backwards
            layer.add(animation, forKey: "morph.shadowPath")
        }
        layer?.shadowPath = shape
        CATransaction.commit()
        guard let before else { return }
        for view in parts {
            guard let layer = view.layer, let was = before.frames[ObjectIdentifier(view)] else { continue }
            let dx = was.0.x - layer.position.x, dy = was.0.y - layer.position.y
            if abs(dx) > 0.01 || abs(dy) > 0.01, let animation = curve.animation("position", from: NSValue(point: NSPoint(x: dx, y: dy)),
                                                                                 to: NSValue(point: .zero)) {
                (animation as? CAPropertyAnimation)?.isAdditive = true
                animation.fillMode = .backwards
                layer.add(animation, forKey: "morph.position.\(CACurrentMediaTime())")
            }
            let dw = was.1.width - layer.bounds.width, dh = was.1.height - layer.bounds.height
            if abs(dw) > 0.01 || abs(dh) > 0.01, let animation = curve.animation("bounds.size", from: NSValue(size: NSSize(width: dw, height: dh)),
                                                                                to: NSValue(size: .zero)) {
                (animation as? CAPropertyAnimation)?.isAdditive = true
                animation.fillMode = .backwards
                layer.add(animation, forKey: "morph.size.\(CACurrentMediaTime())")
            }
            if let alpha = before.alphas[ObjectIdentifier(view)], abs(alpha - layer.opacity) > 0.001, view !== title,
               let animation = curve.animation("opacity", from: alpha, to: layer.opacity) {
                animation.fillMode = .backwards
                layer.add(animation, forKey: "morph.opacity")
            }
        }
        if let layer = clip.layer, abs(before.radius - layer.cornerRadius) > 0.01,
           let animation = curve.animation("cornerRadius", from: before.radius, to: layer.cornerRadius) {
            animation.fillMode = .backwards
            layer.add(animation, forKey: "morph.radius")
        }
        if old != form, let duration = curve.animation("opacity", from: 0, to: 1)?.duration {
            for view in [title] {
                guard let layer = view.layer else { continue }
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                let toTile = form > old
                fade.values = toTile ? [layer.presentation()?.opacity ?? 1, 0, 0] : [0, 0, layer.opacity]
                fade.keyTimes = toTile ? [0, 0.45, 1] : [0, 0.55, 1]
                fade.duration = duration
                fade.fillMode = .backwards
                layer.add(fade, forKey: "morph.words")
            }
        }
        for view in [wash, face] { view.needsLayout = true }
    }
}

extension SidePageView {
    static var morphChange: KitCurve {
        Motion.reduced ? .none : Motion.light ? .easeOut(0.14 * PinMorph.slow) : .spring(KitSpring(response: 0.22 * PinMorph.slow, damping: 0.9))
    }

    static var morphLanding: KitCurve {
        Motion.reduced ? .none : Motion.light ? .easeOut(0.16 * PinMorph.slow) : .spring(KitSpring(response: 0.26 * PinMorph.slow, damping: 0.86))
    }

    static var morphFlight: KitCurve {
        Motion.reduced ? .none : Motion.light ? .easeOut(0.16) : .spring(.settle)
    }
}
