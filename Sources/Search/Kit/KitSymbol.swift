import AppKit
import QuartzCore
import Symbols

enum KitSwap {
    static let leave = "swap.leave"
    static let arrive = "swap.arrive"
    static let out: CFTimeInterval = 0.07
    static let fade: CFTimeInterval = 0.09
    static let cross: CFTimeInterval = 0.12
    static let crossKey = "swap.cross"
    static let small: CGFloat = 0.6
    static let spring = KitSpring(response: 0.26, damping: 0.62)
}

final class KitSymbol: NSImageView {
    struct Style: Equatable {
        var size: CGFloat = 13
        var weight: NSFont.Weight = IconLook.weight
        var scale: NSImage.SymbolScale = .medium
        var fill = false
        var palette: [NSColor] = []
        var hierarchical = false
    }

    var name: String { didSet { if name != oldValue { refresh() } } }
    var style: Style { didSet { if style != oldValue { refresh() } } }
    var tint: NSColor = KitColor.ink { didSet { if tint != oldValue { refresh() } } }
    var opacity: Double = 1 { didSet { if opacity != oldValue { refresh() } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { refresh() } } }

    init(_ name: String, style: Style = Style(), tint: NSColor = KitColor.ink, label: String? = nil) {
        self.name = name
        self.style = style
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        imageScaling = .scaleNone
        refresh()
        if let label { setAccessibilityLabel(label) } else { setAccessibilityElement(false) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override var image: NSImage? { didSet { if image !== oldValue { settle() } } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        settle()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        settle()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        settle()
    }

    func centreInk(in rect: NSRect) {
        inked = rect
        settle()
    }

    private var inked: NSRect?

    private func settle() {
        guard let rect = inked, let image else { return }
        if style.palette.isEmpty, image !== Self.image(name, style) { return }
        let scale = kitScale
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.toNearestOrAwayFromZero) / scale }
        let size = image.size
        let whole = NSRect(origin: .zero, size: size)
        var next = NSRect(x: snap(rect.midX - size.width / 2), y: snap(rect.midY - size.height / 2), width: size.width, height: size.height)
        if frame != next { frame = next }
        guard window != nil else { return }
        let ink = KitGlyph.drawnInk(name, style, in: self, backing: scale) ?? whole
        let down = superview?.isFlipped ?? true
        next.origin = NSPoint(x: snap(rect.midX - ink.midX), y: snap(rect.midY - (down ? ink.midY : size.height - ink.midY)))
        if frame != next { frame = next }
    }

    func swap(to name: String, curve: KitCurve = Motion.kitQuick) {
        guard name != self.name, let next = Self.image(name, style) else { return }
        swapping = true
        self.name = name
        swapping = false
        turn += 1
        guard curve.animates, window != nil, let layer else {
            layer?.removeAnimation(forKey: KitSwap.leave)
            layer?.removeAnimation(forKey: KitSwap.arrive)
            image = next
            return
        }
        let mine = turn
        let small = NSValue(caTransform3D: about(KitSwap.small))
        let whole = NSValue(caTransform3D: CATransform3DIdentity)
        let shown = layer.presentation() ?? layer
        let leave = CAAnimationGroup()
        leave.animations = [
            KitCurve.easeOut(KitSwap.out).animation("transform", from: shown.value(forKeyPath: "transform"), to: small),
            KitCurve.easeOut(KitSwap.out).animation("opacity", from: shown.opacity, to: 0),
        ].compactMap { $0 }
        leave.duration = KitSwap.out
        leave.fillMode = .forwards
        leave.isRemovedOnCompletion = false
        layer.removeAnimation(forKey: KitSwap.arrive)
        layer.add(leave, forKey: KitSwap.leave)
        DispatchQueue.main.asyncAfter(deadline: .now() + KitSwap.out) { [weak self] in
            guard let self, turn == mine else { return }
            image = Self.image(self.name, style) ?? next
            guard let layer = self.layer else { return }
            let arrive = CAAnimationGroup()
            let spring = KitSwap.spring.animation("transform", from: NSValue(caTransform3D: about(KitSwap.small)), to: whole)
            arrive.animations = [spring, KitCurve.easeOut(KitSwap.fade).animation("opacity", from: 0, to: 1)].compactMap { $0 }
            arrive.duration = spring.duration
            layer.add(arrive, forKey: KitSwap.arrive)
            layer.removeAnimation(forKey: KitSwap.leave)
        }
    }

    private func about(_ scale: CGFloat) -> CATransform3D {
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        var matrix = CATransform3DMakeTranslation(middle.x, middle.y, 0)
        matrix = CATransform3DScale(matrix, scale, scale, 1)
        return CATransform3DTranslate(matrix, -middle.x, -middle.y, 0)
    }

    private var swapping = false
    private var turn = 0
    private var replacing = false
    private(set) var replaced = 0

    func replace(to name: String) {
        guard name != self.name else { return }
        guard kitReplaces, let next = Self.image(name, style) else {
            self.name = name
            return
        }
        replacing = true
        self.name = name
        replacing = false
        replaced += 1
        kitReplace(with: next)
    }

    static func image(_ name: String, _ style: Style) -> NSImage? {
        KitGlyph.image(name, style)
    }

    private func refresh() {
        if !swapping, !replacing {
            let next = Self.image(name, style)
            if next !== image { image = next }
        }
        let tinted = style.palette.isEmpty ? ink.color(tint, KitColor.kind(of: tint), opacity: opacity, dark: kitDark) : nil
        if tinted != contentTintColor { contentTintColor = tinted }
    }
}
