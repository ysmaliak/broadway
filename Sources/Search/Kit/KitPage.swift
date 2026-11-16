import AppKit

class KitFlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class KitParagraph: NSView {
    var text: String { didSet { if text != oldValue { changed() } } }
    var font: NSFont { didSet { if font != oldValue { changed() } } }
    var color: NSColor { didSet { if color != oldValue { needsDisplay = true } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsDisplay = true } } }
    var alignment: NSTextAlignment { didSet { if alignment != oldValue { changed() } } }
    var maxWidth: CGFloat = .greatestFiniteMagnitude { didSet { if maxWidth != oldValue { changed() } } }
    var lineSpacing: CGFloat = 0 { didSet { if lineSpacing != oldValue { changed() } } }

    private var measuredAt: CGFloat = -1

    init(_ text: String, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize), color: NSColor = KitColor.ink,
         alignment: NSTextAlignment = .natural, maxWidth: CGFloat = .greatestFiniteMagnitude) {
        self.text = text
        self.font = font
        self.color = color
        self.alignment = alignment
        self.maxWidth = maxWidth
        super.init(frame: .zero)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    var naturalWidth: CGFloat { min(maxWidth, ceil(measure(width: .greatestFiniteMagnitude).width)) }

    override var intrinsicContentSize: NSSize {
        let natural = naturalWidth
        let width = bounds.width > 0 && bounds.width < natural ? bounds.width : natural
        return NSSize(width: natural, height: ceil(measure(width: width).height))
    }

    func height(for width: CGFloat) -> CGFloat {
        ceil(measure(width: min(width, naturalWidth)).height)
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - measuredAt) > 0.5 {
            measuredAt = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    var smoothing = true { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        if smoothing, let context = NSGraphicsContext.current?.cgContext {
            context.setAllowsFontSmoothing(true)
            context.setShouldSmoothFonts(true)
        }
        attributed(dark: kitDark).draw(with: bounds, options: [.usesLineFragmentOrigin])
    }

    func balancedWidth(within limit: CGFloat) -> CGFloat {
        guard ceil(measure(width: .greatestFiniteMagnitude).width) > limit else { return limit }
        let tall = ceil(measure(width: limit).height)
        var low: CGFloat = 1
        var high = limit
        while high - low > 1 {
            let middle = ((low + high) / 2).rounded()
            if ceil(measure(width: middle).height) > tall { low = middle } else { high = middle }
        }
        return high
    }

    func measure(width: CGFloat) -> NSSize {
        attributed(dark: false).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin]).size
    }

    private func changed() {
        setAccessibilityValue(text)
        measuredAt = -1
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    private func attributed(dark: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = lineSpacing
        let resolved = ink.color(color, KitColor.kind(of: color), dark: dark)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: resolved, .paragraphStyle: paragraph])
    }
}

final class KitEmptyView: NSView {
    static let lineWidth: CGFloat = 340
    private(set) var line: KitParagraph?

    init(_ text: String, line: String? = nil, symbol: String = "tray") {
        super.init(frame: .zero)
        let tile = NSView()
        let glyph = KitSymbol(symbol, style: .init(size: 34, weight: .regular), tint: KitColor.muted)
        tile.addSubview(glyph)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 64), tile.heightAnchor.constraint(equalToConstant: 44),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor), glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        let title = KitParagraph(text, font: .systemFont(ofSize: 17, weight: .semibold), color: KitColor.ink, alignment: .center)
        var views: [NSView] = [tile, title]
        if let line {
            let words = KitParagraph(line, font: .systemFont(ofSize: 13), color: KitColor.muted, alignment: .center, maxWidth: Self.lineWidth)
            words.maxWidth = words.balancedWidth(within: Self.lineWidth)
            self.line = words
            views.append(words)
        }
        let stack = NSStackView.kit(.vertical, spacing: 10, alignment: .centerX, views)
        stack.setCustomSpacing(14, after: tile)
        stack.setHuggingPriority(NSLayoutConstraint.Priority(240), for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 24),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([text, line].compactMap { $0 }.joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
}

extension NSView {
    func kitPin(_ child: NSView, insets: NSEdgeInsets = NSEdgeInsetsZero) {
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            child.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            child.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }

    static func kitFixed(_ view: NSView, width: CGFloat, height: CGFloat) -> NSView {
        let holder = KitFlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        holder.widthAnchor.constraint(equalToConstant: width).isActive = true
        holder.heightAnchor.constraint(equalToConstant: height).isActive = true
        holder.kitPin(view)
        return holder
    }

    func kitSize(width: CGFloat? = nil, height: CGFloat? = nil) {
        translatesAutoresizingMaskIntoConstraints = false
        if let width { widthAnchor.constraint(equalToConstant: width).isActive = true }
        if let height { heightAnchor.constraint(equalToConstant: height).isActive = true }
    }
}
