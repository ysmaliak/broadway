import AppKit
import QuartzCore

enum GroupNameReveal {
    static let barHeight: CGFloat = 9
    static let barRadius: CGFloat = 4.5
    static let narrowest: CGFloat = 64
    static let widest: CGFloat = 104
    static let bar = 0.14
    static let shine = 0.26
    static let sweep: CFTimeInterval = 1.4
    static let barFade: CFTimeInterval = 0.12
    static let rise: CGFloat = 4
    static let wipe: CFTimeInterval = 0.28
    static let wipeEdge = 0.2
    static let emojiLag: CFTimeInterval = 0.06
    static let markRest = 0.5
    static let spoken = "Naming group…"

    static func width(for id: UUID, room: CGFloat) -> CGFloat {
        let bytes = id.uuid
        let seed = Int(bytes.0) << 8 | Int(bytes.15)
        let span = Int(widest - narrowest) + 1
        return max(0, min(room, narrowest + CGFloat(seed % span)))
    }

    static func shineOverlay(bar: Double = bar, shine: Double = shine) -> Double {
        guard bar < 1 else { return 0 }
        return max(0, min(1, (shine - bar) / (1 - bar)))
    }
}

final class GroupNameHost: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class GroupNameVeil: NSView {
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsDisplay = true } } }

    private let shine = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = GroupNameReveal.barRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        shine.startPoint = CGPoint(x: 0, y: 0.5)
        shine.endPoint = CGPoint(x: 1, y: 0.5)
        shine.locations = [0, 0.5, 1]
        shine.actions = ["position": NSNull(), "bounds": NSNull(), "colors": NSNull()]
        layer?.addSublayer(shine)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sweep()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        sweep()
    }

    override func viewDidHide() {
        super.viewDidHide()
        still()
    }

    override func updateLayer() {
        let dark = kitDark
        layer?.backgroundColor = KitTone.strong.opacity(GroupNameReveal.bar).resolved(ink, dark: dark).cgColor
        let lit = KitTone.strong.opacity(GroupNameReveal.shineOverlay()).resolved(ink, dark: dark)
        shine.colors = [lit.withAlphaComponent(0).cgColor, lit.cgColor, lit.withAlphaComponent(0).cgColor]
    }

    override func layout() {
        super.layout()
        let width = max(36, bounds.width * 0.6)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shine.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        shine.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        shine.position = CGPoint(x: -width / 2, y: bounds.midY)
        CATransaction.commit()
        sweep()
    }

    func sweep() {
        guard window != nil, !isHidden, bounds.width > 0, !Motion.reduced else {
            shine.removeAnimation(forKey: "sweep")
            shine.isHidden = true
            return
        }
        shine.isHidden = false
        let width = shine.bounds.width
        let from = -width / 2
        let to = bounds.width + width / 2
        if let running = shine.animation(forKey: "sweep") as? CABasicAnimation,
           running.fromValue as? CGFloat == from, running.toValue as? CGFloat == to { return }
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = from
        move.toValue = to
        move.duration = GroupNameReveal.sweep
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        move.isRemovedOnCompletion = false
        shine.add(move, forKey: "sweep")
    }

    func still() {
        shine.removeAnimation(forKey: "sweep")
    }
}
