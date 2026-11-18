import AppKit

class KitButton: KitHoverView {
    enum Kind: Equatable { case primary, secondary, destructive }

    enum Look: Equatable {
        case plain(press: CGFloat)
        case pill(Kind)
        case keycap(Kind)
    }

    var action: (() -> Void)?
    var look: Look { didSet { if look != oldValue { restyle() } } }
    var isEnabled = true { didSet { if isEnabled != oldValue { alphaValue = isEnabled ? 1 : 0.45; paint() } } }
    var content: NSView? { didSet { place(replacing: oldValue) } }
    var padding: CGFloat = 0 { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    var height: CGFloat? { didSet { invalidateIntrinsicContentSize() } }
    var reach: CGFloat?

    var reaching: CGFloat {
        if let reach { return reach }
        if case .keycap = look { return KitReach.least }
        return 0
    }

    private(set) var pressed = false { didSet { if pressed != oldValue { press() } } }
    private let track = KitBox(fill: nil, corners: .capsule)
    private var glass: NSGlassEffectView?
    var pressGlass: NSGlassEffectView? { didSet { if pressGlass !== oldValue { place(replacing: nil) } } }

    var faceGlass: NSGlassEffectView? { glass ?? pressGlass ?? content as? NSGlassEffectView }

    var glassCatcher: NSView? {
        guard isEnabled, let face = faceGlass, face.effectIsInteractive, !face.isHiddenOrHasHiddenAncestor else { return nil }
        return face.kitCatch
    }

    private var host: NSView { (glass ?? pressGlass)?.kitCatch ?? self }

    init(_ look: Look = .plain(press: 0.94), label: String? = nil, action: (() -> Void)? = nil) {
        self.look = look
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(track)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        if let label { setAccessibilityLabel(label) }
        restyle()
    }

    convenience init(title: String, font: NSFont, look: Look, action: (() -> Void)? = nil) {
        self.init(look, label: title, action: action)
        content = KitLabel(title, font: font)
        place(replacing: nil)
    }

    private func place(replacing old: NSView?) {
        if old !== content { old?.removeFromSuperview() }
        if let content, content.superview !== host { host.addSubview(content) }
        needsLayout = true
        invalidateIntrinsicContentSize()
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else {
            guard KitReach.takes(point, for: self, reach: reaching) else { return nil }
            return glassCatcher ?? self
        }
        if let catcher = glassCatcher { return catcher }
        if let face = faceGlass, hit === face || hit.isDescendant(of: face) { return self }
        return hit
    }

    override var intrinsicContentSize: NSSize {
        let inner = content?.intrinsicContentSize ?? .zero
        return NSSize(width: inner.width + padding * 2, height: height ?? inner.height)
    }

    override func layout() {
        super.layout()
        track.frame = bounds
        glass?.frame = bounds
        glass?.cornerRadius = bounds.height / 2
        glass?.contentView?.frame = glass?.bounds ?? .zero
        if let content {
            let size = content.intrinsicContentSize
            let width = min(bounds.width - padding * 2, size.width < 0 ? bounds.width : size.width)
            let height = size.height < 0 ? bounds.height : min(bounds.height, size.height)
            content.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        }
        if let layer, layer.animation(forKey: "press") == nil { layer.transform = pressTransform(pressed) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = KitReach.rect(bounds, reach: reaching).contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let fire = pressed && isEnabled
        pressed = false
        if fire { action?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action?()
        return true
    }

    override var acceptsFirstResponder: Bool { KitFocus.takes(isEnabled && action != nil) }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let radius: CGFloat = if case .plain = look { min(6, bounds.height / 2) } else { bounds.height / 2 }
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, KitFocus.presses(event) else { return super.keyDown(with: event) }
        action?()
    }

    override func hoverChanged() { paint() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private var amount: CGFloat {
        switch look {
        case .plain(let press): return press
        case .pill: return 0.97
        case .keycap: return 1
        }
    }

    private func pressTransform(_ on: Bool) -> CATransform3D {
        guard on, !Motion.reduced, amount != 1, faceGlass?.effectIsInteractive != true else { return CATransform3DIdentity }
        let mid = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0),
                                                       CATransform3DMakeScale(amount, amount, 1)), mid)
    }

    private func press() {
        layer?.kitAnimate("transform", to: NSValue(caTransform3D: pressTransform(pressed)),
                          curve: pressed ? Motion.kitQuick : Motion.kitSettle, key: "press")
        paint()
    }

    private func restyle() {
        if case .keycap = look {
            if glass == nil {
                let made = NSGlassEffectView()
                made.effectIsInteractive = true
                addSubview(made, positioned: .below, relativeTo: nil)
                glass = made
                made.kitCatch.addSubview(track)
                if let content { made.kitCatch.addSubview(content) }
            }
        } else if let old = glass {
            glass = nil
            addSubview(track, positioned: .below, relativeTo: nil)
            if let content { addSubview(content) }
            old.removeFromSuperview()
        }
        paint()
        needsLayout = true
    }

    private func paint() {
        let dark = kitDark
        let lit = hovering && isEnabled
        switch look {
        case .plain:
            track.fill = nil
        case .pill(let kind):
            track.gradient = []
            track.stroke = nil
            track.fill = KitPill.fill(kind, dark: dark, lit: lit, pressed: pressed)
            wear(KitPill.ink(kind))
        case .keycap(let kind):
            track.gradient = []
            track.stroke = nil
            track.fill = KitGlass.keyInk(kind, dark: dark, lit: lit, pressed: pressed)
            glass?.tintColor = track.fill == nil ? KitGlass.keyTint(kind, dark: dark) : nil
            let ink: NSColor = switch kind {
            case .primary: dark ? .black : .white
            case .destructive: .white
            case .secondary: KitColor.ink
            }
            wear(ink)
        }
    }

    private func wear(_ ink: NSColor) {
        if let label = content as? KitLabel { label.color = ink }
        if let symbol = content as? KitSymbol { symbol.tint = ink }
    }
}

enum KitPill {
    static let height: CGFloat = 28

    static func fill(_ kind: KitButton.Kind, dark: Bool, lit: Bool = false, pressed: Bool = false) -> NSColor {
        if kind == .primary {
            let shift: CGFloat = pressed ? -0.1 : lit ? 0.05 : 0
            return NSColor(white: dark ? 1 : 0, alpha: (dark ? 0.9 : 0.86) + shift)
        }
        let shift: CGFloat = pressed ? 0.06 : lit ? 0.035 : 0
        return NSColor(white: dark ? 1 : 0, alpha: (dark ? 0.1 : 0.063) + shift)
    }

    static func ink(_ kind: KitButton.Kind) -> NSColor {
        switch kind {
        case .primary: KitColor.ground
        case .secondary: KitColor.ink
        case .destructive: .systemRed
        }
    }
}

enum KitReach {
    static let least: CGFloat = 24

    static func rect(_ bounds: NSRect, reach: CGFloat) -> NSRect {
        bounds.insetBy(dx: -max(0, reach - bounds.width) / 2, dy: -max(0, reach - bounds.height) / 2)
    }

    @MainActor static func takes(_ point: NSPoint, for view: NSView, reach: CGFloat) -> Bool {
        guard reach > 0, !view.isHidden, let above = view.superview else { return false }
        guard rect(view.bounds, reach: reach).contains(view.convert(point, from: above)) else { return false }
        return !above.subviews.contains { other in
            other !== view && !other.isHidden && other.frame.contains(point) && pressable(other.hitTest(point), under: other)
        }
    }

    @MainActor static func pressable(_ hit: NSView?, under top: NSView) -> Bool {
        var at = hit
        while let here = at {
            if here is KitButton || here is NSControl { return true }
            if here.isAccessibilityElement(), here.accessibilityRole() == .button || here.accessibilityRole() == .slider { return true }
            if here === top { return false }
            at = here.superview
        }
        return false
    }

    @MainActor static func field(_ field: NSTextField) -> NSView {
        (field.currentEditor() as? NSView) ?? field
    }
}

final class KitPushButton: NSButton {
    private var handler: (() -> Void)?
    var reach = KitReach.least

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? (KitReach.takes(point, for: self, reach: reach) ? self : nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !bounds.contains(convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        performClick(nil)
    }

    convenience init(_ title: String, prominent: Bool = false, size: NSControl.ControlSize = .regular, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        controlSize = size
        font = .systemFont(ofSize: NSFont.systemFontSize(for: size))
        tintProminence = prominent ? .primary : .automatic
        handler = action
        target = self
        self.action = #selector(fire)
        setButtonType(.momentaryPushIn)
    }

    @objc private func fire() { handler?() }
}
