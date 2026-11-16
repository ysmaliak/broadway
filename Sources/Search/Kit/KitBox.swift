import AppKit
import QuartzCore

class KitBox: NSView {
    enum Corners: Equatable {
        case square
        case radius(CGFloat)
        case capsule
    }

    var fill: NSColor? { didSet { if fill != oldValue { needsDisplay = true } } }
    var stroke: NSColor? { didSet { if stroke != oldValue { needsDisplay = true } } }
    var strokeWidth: CGFloat? { didSet { if strokeWidth != oldValue { needsDisplay = true } } }
    var gradient: [NSColor] = [] { didSet { if gradient != oldValue { needsDisplay = true } } }
    var gradientAxis: (start: CGPoint, end: CGPoint) = (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)) { didSet { needsDisplay = true } }
    var corners: Corners = .square { didSet { if corners != oldValue { needsLayout = true } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsDisplay = true } } }
    var passesClicks = true

    private var gradientLayer: CAGradientLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    convenience init(fill: NSColor?, stroke: NSColor? = nil, corners: Corners = .square) {
        self.init(frame: .zero)
        self.fill = fill
        self.stroke = stroke
        self.corners = corners
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return passesClicks && hit === self ? nil : hit
    }

    var radius: CGFloat {
        switch corners {
        case .square: return 0
        case .radius(let value): return min(value, min(bounds.width, bounds.height) / 2)
        case .capsule: return min(bounds.width, bounds.height) / 2
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        gradientLayer?.frame = bounds
        gradientLayer?.cornerRadius = radius
        gradientLayer?.cornerCurve = .continuous
        gradientLayer?.kitAxis(from: gradientAxis.start, to: gradientAxis.end, in: bounds.size)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    var hairline: CGFloat { 1 / max(1, window?.backingScaleFactor ?? 2) }

    var resolvedStrokeWidth: CGFloat { stroke == nil ? 0 : strokeWidth ?? hairline }

    override func updateLayer() {
        guard let layer else { return }
        let dark = kitDark
        func resolve(_ color: NSColor) -> CGColor { ink.color(color, KitColor.kind(of: color), dark: dark).cgColor }
        layer.backgroundColor = fill.map(resolve)
        layer.borderColor = stroke.map(resolve)
        layer.borderWidth = resolvedStrokeWidth
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        if gradient.isEmpty {
            gradientLayer?.removeFromSuperlayer()
            gradientLayer = nil
        } else {
            let made = gradientLayer ?? CAGradientLayer()
            if gradientLayer == nil {
                layer.insertSublayer(made, at: 0)
                gradientLayer = made
            }
            made.colors = gradient.map(resolve)
            made.frame = layer.bounds
            made.kitAxis(from: gradientAxis.start, to: gradientAxis.end, in: layer.bounds.size)
            made.cornerRadius = radius
            made.cornerCurve = .continuous
        }
    }
}

enum KitPath {
    static func capsule(_ rect: CGRect) -> CGPath {
        let radius = min(rect.width, rect.height) / 2
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    static func shape(_ path: CGPath, fill: NSColor?, stroke: NSColor? = nil, lineWidth: CGFloat = 1) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.path = path
        shape.fillColor = fill?.cgColor
        shape.strokeColor = stroke?.cgColor
        shape.lineWidth = lineWidth
        return shape
    }
}
