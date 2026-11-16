import AppKit

final class KitSwitch: KitHoverView {
    let small: Bool
    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            native?.state = isOn ? .on : .off
            place(animated: !quiet)
            paint(animated: !quiet)
            say()
        }
    }
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            native?.isEnabled = isEnabled
            paint(animated: false)
        }
    }
    var onChange: ((Bool) -> Void)?
    let native: NSSwitch?

    private let track = CALayer()
    private let thumb = CALayer()
    private var quiet = false
    private var holding = false { didSet { if holding != oldValue { place(animated: true) } } }
    private var focused = false { didSet { if focused != oldValue { paint(animated: true) } } }

    init(isOn: Bool = false, small: Bool = false, label: String? = nil, system: Bool = false) {
        self.isOn = isOn
        self.small = small
        native = system ? NSSwitch() : nil
        super.init(frame: NSRect(origin: .zero, size: Self.size(small: small)))
        wantsLayer = true
        if let native {
            native.controlSize = small ? .small : .regular
            native.state = isOn ? .on : .off
            native.target = self
            native.action = #selector(nativeFlipped)
            native.sizeToFit()
            setFrameSize(native.frame.size)
            addSubview(native)
            native.refusesFirstResponder = true
            native.setAccessibilityElement(false)
            track.isHidden = true
            thumb.isHidden = true
        }
        track.cornerCurve = .continuous
        thumb.cornerCurve = .continuous
        thumb.shadowOpacity = 0.25
        thumb.shadowRadius = 1
        thumb.shadowOffset = CGSize(width: 0, height: 0.5)
        thumb.borderWidth = 0.5
        layer?.addSublayer(track)
        layer?.addSublayer(thumb)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        if let label { setAccessibilityLabel(label) }
        say()
        place(animated: false)
        paint(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var shownTrack: CGColor? { track.backgroundColor }

    func set(_ on: Bool, animated: Bool) {
        quiet = !animated
        isOn = on
        quiet = false
    }

    static func colors(on: Bool, dark: Bool, lit: Bool) -> (track: NSColor, knob: NSColor) {
        let lift: CGFloat = lit ? 0.04 : 0
        if on {
            return dark ? (NSColor(white: 1, alpha: 0.88 + lift), NSColor(white: 0.12, alpha: 1))
                : (NSColor(white: 0, alpha: 0.86 + lift), NSColor.white)
        }
        return dark ? (NSColor(white: 1, alpha: 0.16 + lift), NSColor(white: 0.85, alpha: 1))
            : (NSColor(white: 0, alpha: 0.12 + lift), NSColor.white)
    }

    static func size(small: Bool) -> NSSize { small ? NSSize(width: 28, height: 16) : NSSize(width: 34, height: 20) }

    @objc private func nativeFlipped() {
        guard let native else { return }
        let on = native.state == .on
        guard on != isOn else { return }
        isOn = on
        onChange?(isOn)
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { native?.intrinsicContentSize ?? Self.size(small: small) }
    override var acceptsFirstResponder: Bool { KitFocus.takes(isEnabled) }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        focused = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        focused = false
        return true
    }

    override func layout() {
        super.layout()
        if let native {
            let size = native.intrinsicContentSize
            native.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        }
        place(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint(animated: false)
    }

    override func hoverChanged() { paint(animated: true) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, native == nil else { return }
        holding = true
    }

    override func mouseUp(with event: NSEvent) {
        guard holding else { return }
        holding = false
        flip()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, event.charactersIgnoringModifiers == " " else { return super.keyDown(with: event) }
        flip()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        flip()
        return true
    }

    private func flip() {
        guard isEnabled else { return }
        isOn.toggle()
        onChange?(isOn)
    }

    private func say() {
        setAccessibilityValue(isOn ? "on" : "off")
    }

    private func place(animated: Bool) {
        let size = Self.size(small: small)
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let side = size.height - 4
        let wide = side + (holding && !Motion.reduced ? 4 : 0)
        let x = isOn ? rect.maxX - 2 - wide : rect.minX + 2
        let frame = CGRect(x: x, y: rect.minY + 2, width: wide, height: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = rect
        track.cornerRadius = size.height / 2
        thumb.cornerRadius = side / 2
        thumb.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerWidth: side / 2, cornerHeight: side / 2, transform: nil)
        CATransaction.commit()
        let curve = animated ? (holding ? Motion.kitQuick : Motion.kitSettle) : .none
        thumb.kitAnimate("bounds", to: NSValue(rect: CGRect(origin: .zero, size: frame.size)), curve: curve, key: "size")
        thumb.kitAnimate("position", to: NSValue(point: CGPoint(x: frame.midX, y: frame.midY)), curve: curve, key: "move")
    }

    private func paint(animated: Bool) {
        let dark = kitDark
        let lit = (hovering || focused) && isEnabled
        let (fill, knob) = Self.colors(on: isOn, dark: dark, lit: lit)
        let curve = animated ? Motion.kitQuick : .none
        track.kitAnimate("backgroundColor", to: fill.cgColor, curve: curve, key: "fill")
        thumb.kitAnimate("backgroundColor", to: knob.cgColor, curve: animated ? Motion.kitSettle : .none, key: "knob")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.opacity = isEnabled ? 1 : 0.45
        thumb.opacity = isEnabled ? 1 : 0.45
        thumb.borderColor = NSColor(white: 0, alpha: dark ? 0.2 : 0.1).cgColor
        thumb.shadowColor = NSColor.black.cgColor
        CATransaction.commit()
    }
}
