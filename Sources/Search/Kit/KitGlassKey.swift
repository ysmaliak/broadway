import AppKit

final class KitGlassKey: KitButton {
    let kind: Kind
    let size: BroadwaySize
    let circle: CGFloat?
    let quiet: Bool
    let tall: CGFloat?

    init(title: String, kind: Kind = .secondary, size: BroadwaySize = .small, quiet: Bool = false, tall: CGFloat? = nil,
         action: (() -> Void)? = nil) {
        self.kind = kind
        self.size = size
        self.circle = nil
        self.quiet = quiet
        self.tall = tall
        super.init(.keycap(kind), label: title, action: action)
        content = KitLabel(title, font: Self.font(kind, size))
        padding = size.padding
        refreshInk()
    }

    init(symbol: String, circle: CGFloat, symbolSize: CGFloat = 11, weight: NSFont.Weight = .medium, kind: Kind = .secondary,
         quiet: Bool = false, label: String? = nil, action: (() -> Void)? = nil) {
        self.kind = kind
        self.size = .small
        self.circle = circle
        self.quiet = quiet
        self.tall = nil
        super.init(.keycap(kind), label: label, action: action)
        content = KitSymbol(symbol, style: KitSymbol.Style(size: symbolSize, weight: weight))
        refreshInk()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func font(_ kind: Kind, _ size: BroadwaySize) -> NSFont {
        .systemFont(ofSize: size.font, weight: kind == .primary ? .semibold : .regular)
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

    var symbol: String {
        get { (content as? KitSymbol)?.name ?? "" }
        set { (content as? KitSymbol)?.name = newValue }
    }

    override var intrinsicContentSize: NSSize {
        if let circle { return NSSize(width: circle, height: circle) }
        let inner = content?.intrinsicContentSize ?? .zero
        let width = inner.width + size.padding * 2
        return NSSize(width: size == .regular ? max(64, width) : width, height: tall ?? size.height)
    }

    override func hoverChanged() {
        super.hoverChanged()
        refreshInk()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        refreshInk()
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        refreshInk()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        refreshInk()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshInk()
    }

    private func refreshInk() {
        let lit = (hovering || pressed) && isEnabled
        let opacity = quiet && !lit ? 0.86 : 1
        let ink: NSColor = switch kind {
        case .primary: kitDark ? .black : .white
        case .destructive: .white
        case .secondary: KitColor.ink
        }
        if let label = content as? KitLabel {
            label.color = ink
            label.opacity = opacity
        } else if let symbol = content as? KitSymbol {
            symbol.tint = ink
            symbol.opacity = opacity
        }
    }
}

enum BroadwaySize {
    case regular, small

    var height: CGFloat { self == .regular ? 28 : 22 }
    var font: CGFloat { self == .regular ? 13 : 12 }
    var padding: CGFloat { self == .regular ? 12 : 9 }
}
