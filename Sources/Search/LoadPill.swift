import AppKit

final class LoadPillView: NSView {
    enum Tone: Equatable {
        case ink, accent
    }

    static func origin(in pane: CGRect, cards: Bool) -> CGPoint {
        CGPoint(x: pane.midX - width / 2,
                y: cards ? -(Metrics.cardGap + height) / 2 : pane.minY + 2)
    }

    static func tone(cards: Bool, onPage: Bool) -> Tone {
        cards || !onPage ? .ink : .accent
    }

    static let width: CGFloat = 128
    static let height: CGFloat = 3
    static let wait: TimeInterval = 0.2

    private let track = CALayer()
    private let fill = CAShapeLayer()
    private var pending: DispatchWorkItem?
    private var tone = Tone.ink
    private var dark = false
    private(set) var shown = false

    var loading = false {
        didSet {
            guard loading != oldValue else { return }
            if loading { arm() } else { settle() }
        }
    }

    var trackOpacity: Swift.Float { track.opacity }

    func paint(_ tone: Tone, dark: Bool) {
        guard tone != self.tone || dark != self.dark else { return }
        self.tone = tone
        self.dark = dark
        recolour()
    }

    private func recolour() {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            let ink = tone == .accent ? NSColor.controlAccentColor : Palette.NS.ink
            track.backgroundColor = ink.withAlphaComponent(tone == .accent ? 0.22 : 0.17).cgColor
            fill.strokeColor = ink.withAlphaComponent(tone == .accent ? 1 : 0.8).cgColor
        }
    }

    private func arm() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.loading else { return }
            self.pending = nil
            self.start()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wait, execute: item)
    }

    private func settle() {
        pending?.cancel()
        pending = nil
        if shown { finish() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.cornerRadius = Self.height / 2
        track.masksToBounds = true
        track.opacity = 0
        fill.fillColor = nil
        fill.lineWidth = Self.height
        fill.lineCap = .round
        fill.strokeEnd = 0
        let still = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "strokeColor": NSNull(),
                     "backgroundColor": NSNull(), "strokeStart": NSNull(), "strokeEnd": NSNull(), "opacity": NSNull()]
        track.actions = still
        fill.actions = still
        track.addSublayer(fill)
        layer?.addSublayer(track)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        fill.frame = track.bounds
        let line = CGMutablePath()
        let cap = min(bounds.height, bounds.width) / 2
        line.move(to: CGPoint(x: cap, y: bounds.midY))
        line.addLine(to: CGPoint(x: bounds.maxX - cap, y: bounds.midY))
        fill.path = line
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolour()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recolour()
        if window != nil, loading, pending == nil { start() }
    }

    private func start() {
        shown = true
        fill.removeAllAnimations()
        track.removeAllAnimations()
        track.opacity = 1
        guard !Motion.calm else {
            fill.strokeStart = 0
            fill.strokeEnd = 1
            return
        }
        fill.strokeStart = 0
        fill.strokeEnd = 0
        let lead = CAKeyframeAnimation(keyPath: "strokeEnd")
        lead.keyTimes = [0, 0.06, 0.154, 0.251, 0.354, 1]
        lead.values = [0, 0.13, 0.5, 0.9, 1, 1]
        let tail = CAKeyframeAnimation(keyPath: "strokeStart")
        tail.keyTimes = [0, 0.354, 0.452, 0.552, 0.655, 1]
        tail.values = [0, 0, 0.33, 0.78, 1, 1]
        for sweep in [lead, tail] {
            sweep.duration = 1
            sweep.repeatCount = .infinity
            sweep.calculationMode = .linear
            fill.add(sweep, forKey: sweep.keyPath)
        }
    }

    private func finish() {
        shown = false
        fill.removeAllAnimations()
        let time: CFTimeInterval = Motion.calm ? 0.15 : 0.25
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.loading else { return }
            self.fill.strokeStart = 0
            self.fill.strokeEnd = 0
        }
        fill.strokeStart = Motion.calm ? 0 : 0.5
        fill.strokeEnd = Motion.calm ? 1 : 0.5
        track.opacity = 0
        for (key, from, target) in [("strokeStart", 0.0, Motion.calm ? 0.0 : 0.5), ("strokeEnd", 1.0, Motion.calm ? 1.0 : 0.5)] {
            let shrink = CABasicAnimation(keyPath: key)
            shrink.fromValue = from
            shrink.toValue = target
            shrink.duration = time
            shrink.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fill.add(shrink, forKey: key)
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = time
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        track.add(fade, forKey: "opacity")
        CATransaction.commit()
    }
}
