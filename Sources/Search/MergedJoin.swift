import AppKit
import QuartzCore

enum MergedForm: String {
    case full, quiet, still
}

@MainActor
enum MergedCrowd {
    static let gap: CFTimeInterval = 0.35
    private static var last: CFTimeInterval = -.infinity

    static func first(now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        defer { last = now }
        return now - last > gap
    }

    static func forget() { last = -.infinity }
}

final class MergedCanvas: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
enum MergedMotion {
    static let key = "merged"
    static let still: [String: CAAction] = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(),
                                            "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "strokeEnd": NSNull(),
                                            "transform": NSNull()]

    static func play(_ layer: CALayer, _ keyPath: String, from: Any, to: Any, lasts: CFTimeInterval, after wait: CFTimeInterval = 0) {
        let move = CABasicAnimation(keyPath: keyPath)
        move.fromValue = from
        move.toValue = to
        move.duration = lasts
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(move, to: layer, keyPath, after: wait)
    }

    static func spring(_ layer: CALayer, _ keyPath: String, from: Any, to: Any, _ spring: KitSpring, after wait: CFTimeInterval = 0) {
        add(spring.animation(keyPath, from: from, to: to), to: layer, keyPath, after: wait)
    }

    static func add(_ move: CAAnimation, to layer: CALayer, _ name: String, after wait: CFTimeInterval = 0) {
        if wait > 0 {
            move.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + wait
            move.fillMode = .backwards
        }
        layer.add(move, forKey: key + "." + name)
    }

    static func stop(_ layer: CALayer?) {
        guard let layer else { return }
        for name in layer.animationKeys() ?? [] where name.hasPrefix(key + ".") { layer.removeAnimation(forKey: name) }
    }
}

@MainActor
final class MergedJoin {
    static let pop = KitSpring(response: 0.26, damping: 0.62)
    static let waits: CFTimeInterval = 0.34

    private let canvas = MergedCanvas()
    private let upper = CAShapeLayer()
    private let lower = CAShapeLayer()
    private let stem = CAShapeLayer()
    private let node = CAShapeLayer()
    private weak var mark: NSView?

    var layers: [CALayer] { canvas.superview == nil ? [] : [upper, lower, stem, node] }

    static func branch(up: Bool, in box: CGRect) -> CGPath {
        let s = box.width / 16
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * s, y: box.minY + y * s) }
        let y: CGFloat = up ? 3.4 : 12.6
        let path = CGMutablePath()
        path.move(to: p(1.9, y))
        path.addCurve(to: p(8.2, 8), control1: p(5.6, y), control2: p(4.9, 8))
        return path
    }

    static func stem(in box: CGRect) -> CGPath {
        let s = box.width / 16
        let path = CGMutablePath()
        path.move(to: CGPoint(x: box.minX + 8.2 * s, y: box.minY + 8 * s))
        path.addLine(to: CGPoint(x: box.minX + 10.6 * s, y: box.minY + 8 * s))
        return path
    }

    static func node(in box: CGRect) -> CGRect {
        let s = box.width / 16
        return CGRect(x: box.minX + 10.2 * s, y: box.minY + 5.5 * s, width: 5 * s, height: 5 * s)
    }

    func wear(on mark: NSView, in content: NSView, tint: NSColor, scale: CGFloat, form: MergedForm) {
        content.addSubview(canvas, positioned: .above, relativeTo: mark)
        self.mark = mark
        for shape in [upper, lower, stem, node] {
            shape.actions = MergedMotion.still
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.contentsScale = scale
            canvas.layer?.addSublayer(shape)
        }
        fit(tint: tint)
        mark.alphaValue = 0
        switch form {
        case .full:
            if let fading = mark.layer { MergedMotion.play(fading, "opacity", from: 1, to: 0, lasts: 0.12) }
            for shape in [upper, lower] { MergedMotion.play(shape, "strokeEnd", from: 0, to: 1, lasts: 0.24, after: 0.06) }
            MergedMotion.play(stem, "strokeEnd", from: 0, to: 1, lasts: 0.1, after: 0.27)
            MergedMotion.play(node, "opacity", from: 0, to: 0, lasts: Self.waits)
            MergedMotion.spring(node, "transform.scale", from: 0, to: 1, Self.pop, after: Self.waits)
        case .quiet:
            if let fading = mark.layer { MergedMotion.play(fading, "opacity", from: 1, to: 0, lasts: 0.2) }
            if let layer = canvas.layer { MergedMotion.play(layer, "opacity", from: 0, to: 1, lasts: 0.22) }
        case .still:
            break
        }
    }

    func fit(tint: NSColor) {
        guard let mark else { return }
        canvas.frame = mark.frame
        if mark.alphaValue != 0 { mark.alphaValue = 0 }
        let box = canvas.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let colour = tint.cgColor
        for shape in [upper, lower, stem] {
            shape.frame = box
            shape.fillColor = nil
            shape.strokeColor = colour
            shape.lineWidth = 1.7
        }
        upper.path = Self.branch(up: true, in: box)
        lower.path = Self.branch(up: false, in: box)
        stem.path = Self.stem(in: box)
        let spot = Self.node(in: box)
        node.bounds = CGRect(origin: .zero, size: spot.size)
        node.position = CGPoint(x: spot.midX, y: spot.midY)
        node.path = CGPath(ellipseIn: node.bounds.insetBy(dx: 0.4, dy: 0.4), transform: nil)
        node.fillColor = colour
        node.strokeColor = nil
        CATransaction.commit()
    }

    func end() {
        for layer in [upper, lower, stem, node, canvas.layer, mark?.layer] { MergedMotion.stop(layer) }
        for shape in [upper, lower, stem, node] { shape.removeFromSuperlayer() }
        canvas.removeFromSuperview()
        mark?.alphaValue = 1
        mark = nil
    }
}
