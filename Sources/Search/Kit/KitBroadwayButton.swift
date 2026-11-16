import AppKit

class KitBroadwayButton: KitButton {
    let kind: Kind
    let small: Bool
    private let minWidth: CGFloat

    init(_ title: String, kind: Kind = .secondary, small: Bool = false, label: String? = nil, action: (() -> Void)? = nil) {
        self.kind = kind
        self.small = small
        minWidth = small ? 0 : 64
        super.init(.pill(kind), label: label ?? title, action: action)
        content = KitLabel(title, font: Self.font(kind: kind, small: small))
        padding = small ? 9 : 12
        height = small ? 22 : KitPill.height
    }

    init(content view: NSView, kind: Kind = .secondary, small: Bool = false, label: String, action: (() -> Void)? = nil) {
        self.kind = kind
        self.small = small
        minWidth = small ? 0 : 64
        super.init(.pill(kind), label: label, action: action)
        content = view
        padding = small ? 9 : 12
        height = small ? 22 : KitPill.height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func font(kind: Kind, small: Bool) -> NSFont {
        .systemFont(ofSize: small ? 12 : 13, weight: kind == .primary ? .semibold : .regular)
    }

    var title: String {
        get { (content as? KitLabel)?.text ?? "" }
        set {
            guard let label = content as? KitLabel, label.text != newValue else { return }
            label.text = newValue
            setAccessibilityLabel(newValue)
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        guard let label = content as? KitLabel else { return NSSize(width: max(minWidth, size.width), height: size.height) }
        return NSSize(width: max(minWidth, label.pixelWidth + padding * 2), height: size.height)
    }

    override func layout() {
        super.layout()
        guard let label = content as? KitLabel else { return }
        let width = min(bounds.width - padding * 2, label.pixelWidth)
        let height = label.intrinsicContentSize.height
        label.frame = kitSnap(NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height))
    }
}
