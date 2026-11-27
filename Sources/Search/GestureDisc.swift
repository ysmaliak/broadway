import AppKit

@MainActor
final class GestureDisc: NSView {
    enum Edge {
        case left, right, top

        var symbol: String {
            switch self {
            case .left: return "arrow.left"
            case .right: return "arrow.right"
            case .top: return "arrow.clockwise"
            }
        }

        var hub: CGPoint {
            switch self {
            case .left, .right: return CGPoint(x: -0.5, y: 0.5)
            case .top: return .zero
            }
        }

        var ring: CGPoint? {
            self == .top ? CGPoint(x: 0.4923, y: 0.5844) : nil
        }
    }

    nonisolated static let size: CGFloat = 44
    nonisolated static let glyph: CGFloat = 14
    nonisolated static let line: CGFloat = 1.5
    nonisolated static let reach: CGFloat = 98
    nonisolated static let rest: CGFloat = 12
    nonisolated static let least: CGFloat = 0.86
    nonisolated static let pop: CGFloat = 1.08
    nonisolated static let faint: CGFloat = 0.4
    nonisolated static let leap: CGFloat = 10
    nonisolated static let lingers: TimeInterval = 0.35
    nonisolated static let turn: TimeInterval = 0.85

    nonisolated static func gap(_ progress: CGFloat) -> CGFloat {
        reach * (1 - exp(-max(0, progress))) - size
    }

    nonisolated static func scale(_ progress: CGFloat) -> CGFloat {
        least + (1 - least) * min(1, max(0, progress))
    }

    let edge: Edge
    private let face = KitFlippedView()
    private let body = KitFlippedView()
    private let glass = KitGlass(radius: GestureDisc.size / 2, tint: Palette.NS.glassTint)
    private let ring = CAShapeLayer()
    private let arrow: KitSymbol
    private let turner: KitTurnView
    private(set) var gap: CGFloat = -GestureDisc.size
    private(set) var progress: CGFloat = 0
    private var catches = 0
    private var armed = false
    private var gone = false

    init(_ edge: Edge) {
        self.edge = edge
        arrow = KitSymbol(edge.symbol, style: .init(size: GestureDisc.glyph, weight: .semibold), tint: KitColor.ink)
        arrow.whole = edge.ring != nil
        arrow.fine = edge.ring != nil
        turner = KitTurnView(arrow)
        let size = GestureDisc.size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        setAccessibilityElement(false)
        face.wantsLayer = true
        face.frame = bounds
        addSubview(face)
        body.wantsLayer = true
        body.frame = face.bounds
        face.addSubview(body)
        glass.frame = body.bounds
        body.addSubview(glass)
        ring.fillColor = nil
        ring.lineWidth = GestureDisc.line
        ring.lineCap = .round
        ring.strokeEnd = 0
        ring.actions = ["strokeEnd": NSNull(), "strokeColor": NSNull(), "path": NSNull()]
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: (size - GestureDisc.line) / 2,
                    startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
        ring.path = path
        ring.frame = body.bounds
        body.layer?.addSublayer(ring)
        body.addSubview(turner)
        placeGlyph()
        arrow.alphaValue = GestureDisc.faint
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        placeGlyph()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        placeGlyph()
    }

    private func placeGlyph() {
        let size = GestureDisc.size
        let glyph = arrow.intrinsicContentSize
        let spot = kitSnap(NSRect(x: (size - glyph.width) / 2 - hub.x, y: (size - glyph.height) / 2 - hub.y,
                                  width: glyph.width, height: glyph.height))
        if turner.frame != spot { turner.frame = spot }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolour()
    }

    private func recolour() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.strokeColor = Palette.NS.ink.cgColor
        }
    }

    var shown: (top: CGFloat, opacity: CGFloat, ring: CGFloat) {
        guard let layer else { return (gap, 0, 0) }
        let face = self.face.layer.map { ($0.presentation() ?? $0).opacity } ?? 1
        let whole = (layer.presentation() ?? layer).opacity
        return (along((layer.presentation() ?? layer).frame), CGFloat(face * whole), (ring.presentation() ?? ring).strokeEnd)
    }

    private func along(_ frame: CGRect) -> CGFloat {
        guard let host = superview else { return gap }
        switch edge {
        case .left: return frame.minX
        case .right: return host.bounds.width - frame.maxX
        case .top: return host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
        }
    }

    func settle(in host: NSView) {
        switch edge {
        case .left: autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
        case .right: autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
        case .top: autoresizingMask = [.minXMargin, .maxXMargin, host.isFlipped ? .maxYMargin : .minYMargin]
        }
        recolour()
        let reduced = Motion.reduced
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.layer?.opacity = reduced ? 0 : 1
        layer?.sublayerTransform = scaled(reduced ? 1 : GestureDisc.least)
        CATransaction.commit()
        place(gap: reduced ? GestureDisc.rest : -GestureDisc.size)
    }

    private func spot(gap: CGFloat) -> NSRect {
        let size = GestureDisc.size
        guard let host = superview else { return NSRect(x: 0, y: 0, width: size, height: size) }
        let scale = window?.backingScaleFactor ?? 2
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        switch edge {
        case .left:
            return NSRect(x: gap, y: snap((host.bounds.height - size) / 2), width: size, height: size)
        case .right:
            return NSRect(x: host.bounds.width - size - gap, y: snap((host.bounds.height - size) / 2), width: size, height: size)
        case .top:
            return NSRect(x: snap((host.bounds.width - size) / 2), y: host.isFlipped ? gap : host.bounds.height - gap - size, width: size, height: size)
        }
    }

    private func place(gap: CGFloat, curve: KitCurve = .none) {
        self.gap = gap
        guard let layer else {
            frame = spot(gap: gap)
            return
        }
        let from = (layer.presentation() ?? layer).position
        frame = spot(gap: gap)
        if let move = curve.animation("position", from: NSValue(point: from), to: NSValue(point: layer.position)) {
            dropCatches()
            layer.add(move, forKey: "position")
        } else {
            layer.removeAnimation(forKey: "position")
        }
    }

    private func follow(gap target: CGFloat) {
        guard let layer else { return place(gap: target) }
        let from = layer.position
        place(gap: target)
        let offset = CGPoint(x: from.x - layer.position.x, y: from.y - layer.position.y)
        guard hypot(offset.x, offset.y) > GestureDisc.leap,
              let catchUp = Motion.kitGlide.animation("position", from: NSValue(point: offset), to: NSValue(point: .zero)) as? CAPropertyAnimation
        else { return }
        catchUp.isAdditive = true
        catches += 1
        layer.add(catchUp, forKey: "catch.\(catches)")
    }

    private func dropCatches() {
        guard let layer else { return }
        for key in layer.animationKeys() ?? [] where key.hasPrefix("catch.") { layer.removeAnimation(forKey: key) }
    }

    private func setFace(scale: CGFloat, curve: KitCurve = .none) {
        layer?.kitAnimate("sublayerTransform", to: NSValue(caTransform3D: scaled(scale)), curve: curve)
    }

    func follow(_ progress: CGFloat, armed: Bool) {
        guard !gone else { return }
        let whole = min(1, max(0, progress))
        self.progress = progress
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = whole
        CATransaction.commit()
        arrow.alphaValue = GestureDisc.faint + (1 - GestureDisc.faint) * whole
        let popped = armed && !self.armed
        self.armed = armed
        if Motion.reduced {
            face.layer?.opacity = Swift.Float(whole)
            return
        }
        follow(gap: GestureDisc.gap(progress))
        setFace(scale: GestureDisc.scale(progress))
        if popped { pop() }
    }

    private func pop() {
        guard !Motion.reduced, let layer = face.layer else { return }
        let pop = CAKeyframeAnimation(keyPath: "sublayerTransform")
        pop.values = [1, GestureDisc.pop, 1].map { NSValue(caTransform3D: scaled($0)) }
        pop.keyTimes = [0, 0.35, 1]
        pop.duration = 0.26
        pop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        layer.add(pop, forKey: "pop")
    }

    func back() {
        guard !gone else { return }
        gone = true
        let curve = Motion.kitSettle
        guard curve.animates, let layer else {
            removeFromSuperview()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        place(gap: -GestureDisc.size - 2, curve: curve)
        setFace(scale: GestureDisc.least, curve: curve)
        layer.kitAnimate("opacity", to: 0, curve: .easeOut(0.2))
        CATransaction.commit()
    }

    func commit() {
        guard !gone else { return }
        if !armed { pop() }
        armed = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = 1
        CATransaction.commit()
        arrow.alphaValue = 1
        if Motion.reduced {
            face.layer?.opacity = 1
            return
        }
        place(gap: GestureDisc.rest, curve: Motion.kitSettle)
        setFace(scale: 1, curve: Motion.kitSettle)
    }

    var hub: CGPoint {
        guard let ring = edge.ring else { return edge.hub }
        let box = arrow.intrinsicContentSize
        return CGPoint(x: (ring.x - 0.5) * box.width, y: (ring.y - 0.5) * box.height)
    }

    var pivot: CGPoint {
        CGPoint(x: turner.frame.midX + hub.x, y: turner.frame.midY + hub.y)
    }

    func turned(_ angle: CGFloat) -> CATransform3D {
        let middle = CGPoint(x: turner.bounds.midX + hub.x, y: turner.bounds.midY + hub.y)
        var matrix = CATransform3DMakeTranslation(middle.x, middle.y, 0)
        matrix = CATransform3DRotate(matrix, angle, 0, 0, 1)
        return CATransform3DTranslate(matrix, -middle.x, -middle.y, 0)
    }

    func spin() {
        guard !gone, !Motion.reduced, let layer = turner.layer else { return }
        let turn = CAKeyframeAnimation(keyPath: "sublayerTransform")
        turn.values = (0...32).map { NSValue(caTransform3D: turned(CGFloat($0) * .pi / 16)) }
        turn.calculationMode = .linear
        turn.duration = GestureDisc.turn
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        layer.add(turn, forKey: "turn")
    }

    func leave() {
        guard !gone else { return }
        gone = true
        let curve = Motion.kitSlide
        guard curve.animates, let layer else {
            removeFromSuperview()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        setFace(scale: GestureDisc.least, curve: curve)
        layer.kitAnimate("opacity", to: 0, curve: curve)
        CATransaction.commit()
    }

    private func scaled(_ scale: CGFloat) -> CATransform3D {
        let half = GestureDisc.size / 2
        var transform = CATransform3DMakeTranslation(half, half, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -half, -half, 0)
    }
}
