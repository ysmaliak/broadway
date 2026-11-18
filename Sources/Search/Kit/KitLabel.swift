import AppKit

final class KitLabel: NSView {
    struct Run: Equatable {
        var text: String
        var font: NSFont
        var color: NSColor? = nil
    }

    enum Overflow: Equatable {
        case tail, middle, head
        case fade(CGFloat)
    }

    var runs: [Run] = [] { didSet { if runs != oldValue { changed() } } }
    var color: NSColor = KitColor.ink { didSet { if color != oldValue { needsDisplay = true } } }
    var opacity: Double = 1 { didSet { if opacity != oldValue { needsDisplay = true } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsDisplay = true } } }
    var alignment: NSTextAlignment = .natural { didSet { if alignment != oldValue { needsDisplay = true } } }
    var overflow: Overflow = .tail { didSet { if overflow != oldValue { changed() } } }
    var lines = 1 { didSet { if lines != oldValue { changed() } } }

    var text: String {
        get { runs.map(\.text).joined() }
        set { runs = [Run(text: newValue, font: runs.first?.font ?? .systemFont(ofSize: NSFont.systemFontSize))] }
    }

    var font: NSFont {
        get { runs.first?.font ?? .systemFont(ofSize: NSFont.systemFontSize) }
        set { runs = runs.isEmpty ? [Run(text: "", font: newValue)] : runs.map { Run(text: $0.text, font: newValue, color: $0.color) } }
    }

    init(_ text: String = "", font: NSFont = .systemFont(ofSize: NSFont.systemFontSize), color: NSColor = KitColor.ink) {
        self.runs = [Run(text: text, font: font)]
        self.color = color
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    override var intrinsicContentSize: NSSize {
        let size = measure(width: .greatestFiniteMagnitude)
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateFade()
    }

    override func draw(_ dirtyRect: NSRect) {
        let string = attributed(dark: kitDark)
        let natural = measure(width: lines == 1 ? .greatestFiniteMagnitude : bounds.width)
        let y = (bounds.height - natural.height) / 2
        let scale = window?.backingScaleFactor ?? 2
        let width = ceil(natural.width * scale) / scale
        let centred = alignment == .center || alignment == .right
        guard lines == 1, centred, width < bounds.width else {
            string.draw(with: textRect(in: bounds.size), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return
        }
        let free = bounds.width - width
        let x = ((alignment == .center ? free / 2 : free) * scale).rounded(.toNearestOrAwayFromZero) / scale
        let left = NSMutableAttributedString(attributedString: string)
        left.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: left.length)) { value, range, _ in
            guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            style.alignment = .left
            left.addAttribute(.paragraphStyle, value: style, range: range)
        }
        left.draw(with: NSRect(x: x, y: y, width: width + 1, height: natural.height), options: [.usesLineFragmentOrigin])
    }

    func textRect(in size: NSSize) -> NSRect {
        let natural = measure(width: lines == 1 ? .greatestFiniteMagnitude : size.width)
        let height = lines == 1 || natural.height <= size.height + 1 ? natural.height : size.height
        return NSRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }

    private var natural: NSSize?

    func measure(width: CGFloat) -> NSSize {
        let unbounded = width == .greatestFiniteMagnitude
        if unbounded, let natural { return natural }
        let size = attributed(dark: false).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                        options: [.usesLineFragmentOrigin]).size
        if unbounded { natural = size }
        return size
    }

    private func changed() {
        natural = nil
        setAccessibilityValue(text)
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    var benchDrawn: NSColor? {
        let string = attributed(dark: kitDark)
        guard string.length > 0 else { return nil }
        return string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    private func attributed(dark: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        switch overflow {
        case .tail: paragraph.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        case .middle: paragraph.lineBreakMode = .byTruncatingMiddle
        case .head: paragraph.lineBreakMode = .byTruncatingHead
        case .fade: paragraph.lineBreakMode = .byClipping
        }
        let out = NSMutableAttributedString()
        let ink = ink.onGlass(kitOnGlass)
        for run in runs {
            let base = run.color ?? color
            let resolved = ink.color(base, KitColor.kind(of: base), opacity: opacity, dark: dark)
            out.append(NSAttributedString(string: run.text, attributes: [.font: run.font, .foregroundColor: resolved, .paragraphStyle: paragraph]))
        }
        return out
    }

    private func updateFade() {
        guard case .fade(let width) = overflow, measure(width: .greatestFiniteMagnitude).width > bounds.width + 0.5 else {
            layer?.mask = nil
            return
        }
        wantsLayer = true
        let mask = (layer?.mask as? CAGradientLayer) ?? CAGradientLayer()
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        let edge = bounds.width > 0 ? Double(max(0, bounds.width - width) / bounds.width) : 0
        mask.locations = [0, NSNumber(value: edge), 1]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        CATransaction.commit()
        layer?.mask = mask
    }
}

extension KitLabel {
    var pixelWidth: CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (measure(width: .greatestFiniteMagnitude).width * scale).rounded(.up) / scale
    }
}

extension NSFont {
    func capCentredTop(in height: CGFloat, baseline: CGFloat) -> CGFloat {
        (height + capHeight) / 2 - baseline
    }
}
