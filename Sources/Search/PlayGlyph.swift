import AppKit

final class PlayGlyph: NSImageView {
    static let sidebar = KitSymbol.Style(size: 11, weight: .bold)
    static let float = KitSymbol.Style(size: 21, weight: .semibold)

    let style: KitSymbol.Style
    var tint: NSColor? { didSet { if tint != oldValue { paint() } } }
    private(set) var name = ""
    private(set) var replaced = 0
    private(set) var morphed = false
    private(set) var morph: CAShapeLayer?
    private var leaving: CAShapeLayer?
    private var flight: (from: PlayShape, to: PlayShape, start: CFTimeInterval)?
    private var turn = 0

    init(style: KitSymbol.Style, tint: NSColor? = nil) {
        self.style = style
        self.tint = tint
        super.init(frame: .zero)
        imageScaling = .scaleNone
        imageAlignment = .alignCenter
        contentTintColor = tint
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    var drawn: NSRect {
        guard let size = image?.size else { return .zero }
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    func show(_ name: String, animated: Bool) {
        guard let next = KitGlyph.image(name, style) else { return }
        let was = self.name
        self.name = name
        guard animated, kitReplaces, let to = placed(name), let from = midway ?? placed(was) else {
            land()
            morphed = false
            image = next
            return
        }
        replaced += 1
        morphed = true
        image = next
        fly(from, to)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            land()
            leave()
        }
    }

    override func layout() {
        super.layout()
        guard window != nil, !bounds.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.flight == nil else { return }
            _ = self.placed("play.fill")
            _ = self.placed("pause.fill")
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func placed(_ name: String) -> PlayShape? {
        PlayMorph.shape(name, style, in: bounds.size, scale: window?.backingScaleFactor ?? 2)
    }

    private var midway: PlayShape? {
        guard let flight else { return nil }
        return PlayMorph.at(flight.from, flight.to, CACurrentMediaTime() - flight.start)
    }

    private func fly(_ from: PlayShape, _ to: PlayShape) {
        guard let host = layer else { return land() }
        let shape = morph ?? CAShapeLayer()
        turn += 1
        let turn = turn
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leave()
        if morph == nil {
            host.addSublayer(shape)
            morph = shape
        }
        shape.frame = host.bounds
        shape.contentsScale = window?.backingScaleFactor ?? 2
        shape.lineJoin = .round
        shape.lineCap = .round
        paint()
        let height = shape.contentsAreFlipped() ? shape.bounds.height : nil
        func drawn(_ shape: PlayShape) -> CGPath { (height.map { shape.flipped(in: $0) } ?? shape).path }
        let steps = Int((PlayMorph.duration * PlayMorph.rate).rounded())
        let shapes = (0...steps).map { $0 == steps ? to : PlayMorph.at(from, to, Double($0) / PlayMorph.rate) }
        let times = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        let paths = CAKeyframeAnimation(keyPath: "path")
        paths.values = shapes.map(drawn)
        paths.keyTimes = times
        let widths = CAKeyframeAnimation(keyPath: "lineWidth")
        widths.values = shapes.map { $0.round * 2 }
        widths.keyTimes = times
        let both = CAAnimationGroup()
        both.animations = [paths, widths]
        both.duration = PlayMorph.duration
        shape.path = drawn(to)
        shape.lineWidth = to.round * 2
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.turn == turn else { return }
            self.land(fading: true)
        }
        shape.add(both, forKey: PlayMorph.key)
        CATransaction.commit()
        flight = (from, to, CACurrentMediaTime())
    }

    private func land(fading: Bool = false) {
        flight = nil
        guard let morph else { return }
        self.morph = nil
        turn += 1
        paint()
        displayIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard fading else {
            morph.removeFromSuperlayer()
            return CATransaction.commit()
        }
        leave()
        leaving = morph
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = PlayMorph.fade
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        morph.opacity = 0
        CATransaction.setCompletionBlock { [weak self, weak morph] in
            guard let self, let morph, self.leaving === morph else { return }
            self.leave()
        }
        morph.add(fade, forKey: PlayMorph.fadeKey)
        CATransaction.commit()
    }

    private func leave() {
        guard let leaving else { return }
        self.leaving = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leaving.removeFromSuperlayer()
        CATransaction.commit()
    }

    private func paint() {
        guard let morph else {
            contentTintColor = tint
            return
        }
        contentTintColor = .clear
        var ink: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { ink = (tint ?? .labelColor).cgColor }
        morph.fillColor = ink
        morph.strokeColor = ink
    }
}
