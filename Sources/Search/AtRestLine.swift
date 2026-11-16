import AppKit

final class AtRestLabel: NSView {
    var rest: AtRest? { didSet { if rest != oldValue { changed() } } }
    var size: CGFloat = 13 { didSet { if size != oldValue { changed() } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsDisplay = true } } }
    var inkColor: NSColor = KitColor.ink { didSet { if inkColor != oldValue { needsDisplay = true } } }
    var dimColor: NSColor = KitColor.muted { didSet { if dimColor != oldValue { needsDisplay = true } } }

    init(rest: AtRest?, size: CGFloat) {
        self.rest = rest
        self.size = size
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(rest?.text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    var natural: CGFloat {
        segments(dark: false).reduce(0) { $0 + ceil($1.text.size().width) }
    }

    static func natural(_ rest: AtRest, size: CGFloat) -> CGFloat {
        AtRestLabel(rest: rest, size: size).natural
    }

    override var intrinsicContentSize: NSSize {
        let height = segments(dark: false).map { $0.text.size().height }.max() ?? ceil(NSFont.systemFont(ofSize: size).boundingRectForFont.height)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func changed() {
        setAccessibilityLabel(rest?.text)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private struct Segment {
        enum Give { case fixed, head, middle }
        let text: NSAttributedString
        let give: Give
    }

    private func pixel(_ width: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return ceil(width * scale) / scale
    }

    private func segments(dark: Bool) -> [Segment] {
        guard let rest else { return [] }
        let plain = NSFont.systemFont(ofSize: size)
        let strong = rest.kind == .file || rest.kind == .other ? plain : NSFont.systemFont(ofSize: size, weight: .medium)
        let dim = ink.color(dimColor, KitColor.kind(of: dimColor), dark: dark)
        let full = ink.color(inkColor, KitColor.kind(of: inkColor), dark: dark)
        func run(_ text: String, _ font: NSFont, _ color: NSColor, _ mode: NSLineBreakMode) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = mode
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        }
        var out: [Segment] = []
        if rest.kind == .notSecure {
            out.append(Segment(text: run("Not secure", plain, dim, .byClipping), give: .fixed))
            out.append(Segment(text: run("  ", plain, dim, .byClipping), give: .fixed))
        }
        if !rest.lead.isEmpty { out.append(Segment(text: run(rest.lead, plain, dim, .byTruncatingHead), give: .head)) }
        out.append(Segment(text: run(rest.name, strong, full, .byTruncatingMiddle), give: .middle))
        if !rest.tail.isEmpty { out.append(Segment(text: run(rest.tail, plain, dim, .byClipping), give: .fixed)) }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        let parts = segments(dark: kitDark)
        let natural = parts.map { pixel($0.text.size().width) }
        let fixed = zip(parts, natural).filter { $0.0.give == .fixed }.reduce(0) { $0 + $1.1 }
        let room = max(0, bounds.width - fixed)
        var drawn = parts.map(\.text)
        var lines: [Int: CTLine] = [:]
        var widths = natural
        let lead = parts.firstIndex { $0.give == .head }
        if let name = parts.firstIndex(where: { $0.give == .middle }) {
            let least = lead.map { pixel(KitTruncate.width(NSAttributedString(string: "…", attributes: parts[$0].text.attributes(at: 0, effectiveRange: nil)))) } ?? 0
            let offered = min(natural[name], max(0, room - least))
            if offered < natural[name] {
                let cut = KitTruncate.cut(parts[name].text, to: offered, mode: .middle)
                drawn[name] = cut.text
                widths[name] = pixel(cut.width)
                lines[name] = KitTruncate.line(parts[name].text, to: offered, mode: .middle)
            }
            if let lead {
                let left = max(0, room - widths[name])
                if left < natural[lead] {
                    let cut = KitTruncate.cut(parts[lead].text, to: left, mode: .start)
                    drawn[lead] = cut.text
                    widths[lead] = pixel(cut.width)
                    lines[lead] = KitTruncate.line(parts[lead].text, to: left, mode: .start)
                }
            }
        }
        var x: CGFloat = 0
        let scale = window?.backingScaleFactor ?? 2
        for (index, (text, width)) in zip(drawn, widths).enumerated() where width > 0 {
            let height = text.size().height
            let y = ((bounds.height - height) / 2 * scale).rounded(.toNearestOrAwayFromZero) / scale
            if let line = lines[index], let context = NSGraphicsContext.current?.cgContext {
                KitTruncate.draw(line, at: CGPoint(x: x, y: y), flipped: isFlipped, in: context)
            } else {
                text.draw(with: NSRect(x: x, y: y, width: width + 1, height: height), options: [.usesLineFragmentOrigin])
            }
            x += width
        }
    }
}

extension AtRest {
    @MainActor static func surface(lift: Double) -> NSView {
        let addresses = ["https://gist.github.com/octocat/abc", "http://localhost:3000/", "http://example.com/plain",
                         "https://a.very.long.subdomain.chain.example.co.uk/path"]
        let rests = addresses.compactMap { URL(string: $0).flatMap(AtRest.of) }
        return AtRestSurface(rests: rests, lift: lift)
    }
}

@MainActor
final class AtRestSurface: KitFlippedView {
    private var rows: [(view: NSView, width: CGFloat?)] = []

    init(rests: [AtRest], lift: Double) {
        super.init(frame: .zero)
        let ink = KitInk(lift: lift)
        for rest in rests {
            let label = AtRestLabel(rest: rest, size: 13)
            label.ink = ink
            rows.append((label, AtRestLabel.natural(rest, size: 13)))
        }
        let narrow = AtRestLabel(rest: rests[3], size: 13)
        narrow.ink = ink
        rows.append((narrow, min(150, AtRestLabel.natural(rests[3], size: 13))))
        let long = KitLabel("A tab title that is long enough to fade at its end", font: .systemFont(ofSize: 13), color: KitColor.ink)
        long.overflow = .fade(28)
        long.ink = ink
        rows.append((long, nil))
        let resting = AtRestLabel(rest: rests[0], size: 13)
        resting.ink = ink
        rows.append((resting, AtRestLabel.natural(rests[0], size: 13)))
        for row in rows { addSubview(row.view) }
        frame.size = fittingSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let width: CGFloat = 220

    private func height(_ view: NSView) -> CGFloat {
        if let label = view as? KitLabel { return ceil(label.measure(width: .greatestFiniteMagnitude).height) }
        return view.intrinsicContentSize.height
    }

    override var intrinsicContentSize: NSSize {
        let inner = rows.reduce(0) { $0 + height($1.view) } + CGFloat(max(0, rows.count - 1)) * 6
        return NSSize(width: Self.width + 8, height: inner + 8)
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func layout() {
        super.layout()
        var y: CGFloat = 4
        for row in rows {
            let h = height(row.view)
            row.view.frame = kitSnap(CGRect(x: 4, y: y, width: min(row.width ?? Self.width, Self.width), height: h))
            y += h + 6
        }
    }
}
