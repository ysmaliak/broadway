import AppKit
import Observation

struct AgentPointer: Equatable {
    enum Kind: String { case click, type, press, scroll, hover }

    var target: CGRect
    var kind: Kind
    var at: Date
    var name: String
    var accent: Int

    var spot: CGPoint {
        switch kind {
        case .type: return CGPoint(x: target.minX + min(18, target.width / 2), y: target.midY)
        default: return CGPoint(x: target.midX, y: target.midY)
        }
    }

    static let lingers: TimeInterval = 2

    static func rect(_ said: Any?) -> CGRect? {
        guard let box = said as? [String: Any] else { return nil }
        let number = { (key: String) -> CGFloat? in (box[key] as? NSNumber).map { CGFloat(truncating: $0) } }
        guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height"),
              width.isFinite, height.isFinite, x.isFinite, y.isFinite, width >= 0, height >= 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
@Observable
final class AgentPointers {
    static let shared = AgentPointers()

    private(set) var shown: [Tab.ID: AgentPointer] = [:]

    func point(_ tab: Tab.ID, _ pointer: AgentPointer) {
        shown[tab] = pointer
        let at = pointer.at
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentPointer.lingers + 0.05) { [weak self] in
            guard let self, self.shown[tab]?.at == at else { return }
            self.shown[tab] = nil
        }
    }

    func clear(_ tab: Tab.ID) {
        shown[tab] = nil
    }
}

final class AgentPointerView: KitFlippedView {
    var tab: Tab.ID? { didSet { if tab != oldValue { needsLayout = true } } }
    var driving = false { didSet { if driving != oldValue { needsLayout = true } } }

    private let box = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let arrow = AgentArrowView()
    private var shownAt: Date?
    private var placed: CGRect?
    private var up = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        box.fillColor = nil
        box.lineWidth = 2
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.opacity = 0
        layer?.opacity = 0
        layer?.addSublayer(box)
        layer?.addSublayer(ring)
        arrow.isHidden = true
        addSubview(arrow)
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let pointer = tab.flatMap { AgentPointers.shared.shown[$0] }
        guard let pointer, !driving else {
            if up {
                up = false
                layer?.kitAnimate("opacity", to: 0, curve: Motion.kitQuick)
            }
            shownAt = nil
            placed = nil
            return
        }
        let arriving = !up
        if arriving {
            up = true
            arrow.isHidden = false
            layer?.kitAnimate("opacity", to: 1, curve: .none)
        }
        let colour = AgentCharacter.accentColor(pointer.accent).cgColor
        let spot = CGPoint(x: min(max(pointer.spot.x, 0), bounds.width), y: min(max(pointer.spot.y, 0), bounds.height))
        let moves = !arriving && placed != pointer.target && !Motion.calm
        let curve: KitCurve = moves ? .spring(KitSpring(response: 0.28, damping: 0.9)) : .none
        placed = pointer.target
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.strokeColor = colour
        ring.strokeColor = colour
        box.isHidden = pointer.kind != .type
        ring.isHidden = pointer.kind != .click
        let boxSize = CGSize(width: max(8, pointer.target.width + 6), height: max(8, pointer.target.height + 6))
        box.path = KitPath.continuous(CGRect(origin: .zero, size: boxSize), radius: 5)
        box.bounds = CGRect(origin: .zero, size: boxSize)
        CATransaction.commit()
        box.kitAnimate("position", to: NSValue(point: CGPoint(x: pointer.target.midX, y: pointer.target.midY)), curve: curve)
        arrow.colour = AgentCharacter.accentColor(pointer.accent)
        arrow.name = pointer.name
        arrow.typing = pointer.kind == .type
        let before = arrow.frame.origin
        arrow.frame = NSRect(origin: spot, size: AgentArrowView.size)
        if case .spring(let spring) = curve, let layer = arrow.layer {
            let from = CATransform3DMakeTranslation(before.x - spot.x, before.y - spot.y, 0)
            layer.add(spring.animation("transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: CATransform3DIdentity)),
                      forKey: "move")
        }
        if pointer.kind == .click {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.position = spot
            CATransaction.commit()
            if pointer.at != shownAt { pulse() }
        }
        shownAt = pointer.at
    }

    private func pulse() {
        let small = CGPath(ellipseIn: CGRect(x: -5, y: -5, width: 10, height: 10), transform: nil)
        let large = CGPath(ellipseIn: CGRect(x: -17, y: -17, width: 34, height: 34), transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.path = Motion.calm ? small : large
        ring.opacity = Motion.calm ? 0.6 : 0
        CATransaction.commit()
        guard !Motion.calm else { return }
        let grow = CABasicAnimation(keyPath: "path")
        grow.fromValue = small
        grow.toValue = large
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.6
        fade.toValue = 0
        let both = CAAnimationGroup()
        both.animations = [grow, fade]
        both.duration = 0.45
        both.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(both, forKey: "pulse")
    }
}

final class AgentArrowView: KitFlippedView {
    static let size = NSSize(width: 68, height: 28)

    var colour: NSColor = .systemBlue { didSet { if colour != oldValue { needsLayout = true } } }
    var name = "" { didSet { if name != oldValue { needsLayout = true } } }
    var typing = false { didSet { if typing != oldValue { needsLayout = true } } }

    private let arrow = CAShapeLayer()
    private let pill = KitBox(fill: nil, corners: .capsule)
    private let words = KitLabel("", font: .systemFont(ofSize: 10, weight: .semibold), color: .white)
    private let keys = KitSymbol("keyboard", style: KitSymbol.Style(size: 8, weight: .semibold), tint: .white)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: 1)
        arrow.lineWidth = 1.2
        arrow.lineJoin = .round
        arrow.strokeColor = NSColor.white.cgColor
        let path = CGMutablePath()
        let size = CGSize(width: 14, height: 18)
        path.move(to: CGPoint(x: 1, y: 1))
        path.addLine(to: CGPoint(x: 1, y: size.height - 3))
        path.addLine(to: CGPoint(x: size.width * 0.38, y: size.height * 0.68))
        path.addLine(to: CGPoint(x: size.width - 1, y: size.height * 0.62))
        path.closeSubpath()
        arrow.path = path
        arrow.frame = CGRect(origin: .zero, size: size)
        layer?.addSublayer(arrow)
        addSubview(pill)
        pill.addSubview(words)
        pill.addSubview(keys)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrow.fillColor = colour.cgColor
        CATransaction.commit()
        pill.fill = colour
        words.text = name
        let text = words.intrinsicContentSize
        let key = typing ? keys.intrinsicContentSize : .zero
        keys.isHidden = !typing
        let inner = NSSize(width: text.width + (typing ? 4 + key.width : 0), height: max(text.height, key.height))
        let size = NSSize(width: inner.width + 12, height: inner.height + 4)
        pill.frame = kitSnap(NSRect(x: 16, y: 12, width: size.width, height: size.height))
        words.frame = kitSnap(NSRect(x: 6, y: (size.height - text.height) / 2, width: text.width, height: text.height))
        keys.frame = kitSnap(NSRect(x: 6 + text.width + 4, y: (size.height - key.height) / 2, width: key.width, height: key.height))
    }
}

extension AgentPointers {
    static func surface(kind: AgentPointer.Kind) -> NSView {
        let tab = Tab(bench: true)
        shared.shown[tab.id] = AgentPointer(target: CGRect(x: 60, y: 50, width: 160, height: 28), kind: kind,
                                            at: Date.distantFuture, name: "Claude", accent: 2)
        let view = AgentPointerView()
        view.tab = tab.id
        return BenchFloating.sized(view, NSSize(width: 320, height: 140))
    }
}
