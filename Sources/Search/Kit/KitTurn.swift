import AppKit

final class KitTurnView: NSView {
    let content: NSView
    private(set) var angle: CGFloat = 0

    init(_ content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(content)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var intrinsicContentSize: NSSize { content.intrinsicContentSize }

    override func layout() {
        super.layout()
        content.frame = bounds
        guard let layer, layer.animation(forKey: "sublayerTransform") == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = matrix(angle)
        CATransaction.commit()
    }

    private var swing: (from: CGFloat, to: CGFloat)?

    func turn(to angle: CGFloat, curve: KitCurve) {
        let was = self.angle
        self.angle = angle
        guard let layer else { return }
        let to = NSValue(caTransform3D: matrix(angle))
        if curve.animates {
            let moving = layer.animation(forKey: "sublayerTransform") != nil
            let shown = moving ? (layer.presentation() ?? layer).sublayerTransform : layer.sublayerTransform
            let now = moving ? atan2(shown.m12, shown.m11) : was
            var velocity = 0.0
            if let swing, let rate = layer.kitRate(forKey: "sublayerTransform"), abs(angle - now) > 0.0001 {
                velocity = rate * Double(swing.to - swing.from) / Double(angle - now)
            }
            swing = (now, angle)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = matrix(angle)
            CATransaction.commit()
            if let made = curve.animation("sublayerTransform", from: NSValue(caTransform3D: matrix(now)), to: to, velocity: velocity) {
                layer.add(made, forKey: "sublayerTransform")
            }
        } else {
            swing = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "sublayerTransform")
            layer.sublayerTransform = matrix(angle)
            CATransaction.commit()
        }
    }

    private func matrix(_ angle: CGFloat) -> CATransform3D {
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        var matrix = CATransform3DMakeTranslation(middle.x, middle.y, 0)
        matrix = CATransform3DRotate(matrix, angle, 0, 0, 1)
        return CATransform3DTranslate(matrix, -middle.x, -middle.y, 0)
    }
}
