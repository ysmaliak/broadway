import AppKit

final class KitField: KitHoverView, NSTextFieldDelegate {
    let field: NSTextField
    let small: Bool
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            alphaValue = isEnabled ? 1 : 0.45
            field.isEnabled = isEnabled
        }
    }
    var text: String {
        get { field.stringValue }
        set { if field.stringValue != newValue { field.stringValue = newValue } }
    }

    private let ground = KitBox(fill: nil)
    private(set) var editing = false { didSet { if editing != oldValue { paint(animated: true) } } }

    init(placeholder: String, text: String = "", secure: Bool = false, small: Bool = false, label: String? = nil) {
        let made: NSTextField = secure ? KitSecureTextField(string: text) : KitTextField(string: text)
        field = made
        self.small = small
        super.init(frame: .zero)
        (made as? KitTextField)?.onFocus = { [weak self] in self?.editing = true }
        (made as? KitSecureTextField)?.onFocus = { [weak self] in self?.editing = true }
        wantsLayer = true
        ground.corners = .radius(small ? 7 : 9)
        addSubview(ground)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: small ? 12 : 13)
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        if let label { field.setAccessibilityLabel(label) }
        addSubview(field)
        paint(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static func height(small: Bool) -> CGFloat { small ? 24 : 30 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height(small: small))
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let height = ceil(field.intrinsicContentSize.height)
        field.frame = kitSnap(NSRect(x: 8, y: (bounds.height - height) / 2, width: max(0, bounds.width - 16), height: height))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    override func hoverChanged() { paint(animated: true) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint(animated: false)
    }

    func controlTextDidEndEditing(_ obj: Notification) { editing = false }
    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)), let onSubmit else { return false }
        onSubmit()
        return true
    }

    private func paint(animated: Bool) {
        let dark = kitDark
        let lit = (hovering || editing) && isEnabled
        let base = dark ? 0.075 : 0.055
        let wanted = NSColor(white: dark ? 1 : 0, alpha: base + (lit ? 0.03 : 0))
        guard wanted != ground.fill else { return }
        if animated { ground.layer?.kitTransition(Motion.kitQuick) }
        ground.fill = wanted
    }
}

final class KitTextField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onFocus?() }
        return took
    }
}

final class KitSecureTextField: NSSecureTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onFocus?() }
        return took
    }
}
