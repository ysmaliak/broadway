import AppKit

final class KitMiddleLine: NSView {
    let text: String
    let font: NSFont
    let color: NSColor
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsDisplay = true } } }

    init(_ text: String, font: NSFont, color: NSColor = KitColor.ink) {
        self.text = text
        self.font = font
        self.color = color
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    override var intrinsicContentSize: NSSize {
        let size = NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).size
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = kitDark
        let resolved = ink == .flat ? color.kitResolved(dark: dark) : ink.color(color, KitColor.kind(of: color), dark: dark)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: resolved]
        let string = NSAttributedString(string: text, attributes: attributes)
        let whole = CTLineCreateWithAttributedString(string)
        var line = whole
        if CTLineGetTypographicBounds(whole, nil, nil, nil) > Double(bounds.width) {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            line = CTLineCreateTruncatedLine(whole, Double(bounds.width), .middle, token) ?? whole
        }
        let height = string.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin]).height
        let baseline = (bounds.height - height) / 2 + NSLayoutManager().defaultBaselineOffset(for: font)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
