import AppKit
import Combine

protocol KitHeightForWidth: NSView {
    func height(for width: CGFloat) -> CGFloat
}

enum KitForm {
    static let inset: CGFloat = 10
    static let fallbackWidth: CGFloat = 590
    static let tile: CGFloat = 22
    static let tileGap: CGFloat = 11
    static let labelGap: CGFloat = 8
    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let detailFont = NSFont.systemFont(ofSize: 11)
    static let tiledDetailFont = NSFont.systemFont(ofSize: 12)
    static let separator = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x3D / 255, green: 0x3D / 255, blue: 0x3D / 255, alpha: 1)
            : NSColor(srgbRed: 0xEF / 255, green: 0xEF / 255, blue: 0xEF / 255, alpha: 1)
    }

    static let ground = pair(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let card = pair(light: 0xF7F7F7, dark: 0x252525)
    static let rule = pair(light: 0xEBEBEB, dark: 0x2F2F2F)
    static let radius: CGFloat = 10

    static func wash(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light)
        }
    }

    static func pair(light: UInt32, dark: UInt32) -> NSColor {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light)
        }
    }

    @MainActor
    static func symbol(_ name: String) -> KitSymbol {
        KitSymbol(name, style: KitSymbol.Style(size: tile * 0.7, weight: IconLook.weight), tint: .secondaryLabelColor)
    }

    static func button(_ title: String, action: @escaping () -> Void) -> KitFormButton {
        KitFormButton(title, action: action)
    }

    static func note(_ text: String) -> KitLabel {
        KitLabel(text, font: titleFont, color: .secondaryLabelColor)
    }

    static func toggle(_ label: String, isOn: Bool, set: @escaping (Bool) -> Void) -> KitSwitch {
        let made = KitSwitch(isOn: isOn, small: true, label: label, system: true)
        made.onChange = set
        return made
    }
}

final class KitFormButton: KitButton {
    var title: String {
        get { (content as? KitLabel)?.text ?? "" }
        set {
            (content as? KitLabel)?.text = newValue
            setAccessibilityLabel(newValue)
            invalidateIntrinsicContentSize()
        }
    }

    init(_ title: String, action: @escaping () -> Void) {
        super.init(.pill(.secondary), label: title, action: action)
        let label = KitLabel(title, font: KitForm.titleFont)
        label.setAccessibilityElement(false)
        content = label
        padding = 12
        height = 28
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var exactWidth: CGFloat {
        let text = (content as? KitLabel)?.measure(width: .greatestFiniteMagnitude).width ?? 0
        return max(64, ceil(text) + padding * 2)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: exactWidth, height: 28) }

    override func layout() {
        super.layout()
        guard let label = content as? KitLabel else { return }
        let size = label.intrinsicContentSize
        let text = label.measure(width: .greatestFiniteMagnitude).width
        let inner = ceil(text) + padding * 2
        let x = ((bounds.width - inner) / 2).rounded(.toNearestOrAwayFromZero) + padding + ceil(text) - text
        label.frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(.toNearestOrAwayFromZero), width: size.width, height: size.height)
    }
}

final class KitFormLine: KitFlippedView, KitFits {
    let id: String
    var title: String { didSet { if title != oldValue { titleText.text = title; changed() } } }
    var detail: String? { didSet { if detail != oldValue { detailText.text = detail ?? ""; detailText.isHidden = detail == nil; changed() } } }
    var controls: [NSView] = [] { didSet { if controls.map(ObjectIdentifier.init) != oldValue.map(ObjectIdentifier.init) { swapControls(oldValue) } } }
    var controlSpacing: CGFloat = 8 { didSet { if controlSpacing != oldValue { changed() } } }
    var side: CGFloat = 0 { didSet { if side != oldValue { changed() } } }
    var top: CGFloat = 0 { didSet { if top != oldValue { changed() } } }
    var bottom: CGFloat = 0 { didSet { if bottom != oldValue { changed() } } }
    var labelGap: CGFloat = KitForm.labelGap { didSet { if labelGap != oldValue { changed() } } }
    var firstLine: CGFloat? { didSet { if firstLine != oldValue { changed() } } }

    private let titleText: KitParagraph
    private let detailText: KitParagraph
    private let tile: NSView?
    private let centred: Bool

    var detailLabel: KitParagraph { detailText }

    init(id: String, title: String, detail: String? = nil, tile: NSView? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.tile = tile
        centred = false
        titleText = KitParagraph(title, font: KitForm.titleFont, color: .labelColor)
        detailText = KitParagraph(detail ?? "", font: tile == nil ? KitForm.detailFont : KitForm.tiledDetailFont, color: .secondaryLabelColor)
        super.init(frame: .zero)
        build()
    }

    init(_ title: String, detail: String? = nil, callout: Bool = false, leading: NSView? = nil, controls: [NSView] = []) {
        id = title
        self.title = title
        self.detail = detail
        tile = leading
        centred = true
        titleText = KitParagraph(title, font: KitForm.titleFont, color: .labelColor)
        detailText = KitParagraph(detail ?? "", font: callout ? KitForm.tiledDetailFont : KitForm.detailFont, color: .secondaryLabelColor)
        super.init(frame: .zero)
        labelGap = 16
        build()
        self.controls = controls
        swapControls([])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        detailText.isHidden = detail == nil
        if let tile { addSubview(tile) }
        addSubview(titleText)
        addSubview(detailText)
    }

    var onChange: (() -> Void)?

    func setText(_ title: String, detail: String?) {
        self.title = title
        if let detail { self.detail = detail }
    }

    private func changed() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        onChange?()
    }

    private func swapControls(_ old: [NSView]) {
        for view in old where !controls.contains(where: { $0 === view }) && view.superview === self { view.removeFromSuperview() }
        for view in controls where view.superview !== self {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        changed()
    }

    private func size(of view: NSView) -> NSSize {
        if !centred, let label = view as? KitLabel {
            return NSSize(width: label.measure(width: .greatestFiniteMagnitude).width, height: label.intrinsicContentSize.height)
        }
        let size = view.intrinsicContentSize
        if size.width >= 0 && size.height >= 0 { return size }
        let fitted = view.fittingSize
        return NSSize(width: size.width < 0 ? fitted.width : size.width, height: size.height < 0 ? fitted.height : size.height)
    }

    private var controlSizes: [NSSize] { controls.filter { !$0.isHidden }.map(size(of:)) }

    private var controlsWidth: CGFloat {
        let sizes = controlSizes
        guard !sizes.isEmpty else { return 0 }
        return sizes.reduce(0) { $0 + $1.width } + controlSpacing * CGFloat(sizes.count - 1)
    }

    private func labelWidth(_ width: CGFloat) -> CGFloat {
        let content = width - side * 2
        let free = controlsWidth > 0 ? content - controlsWidth - labelGap : content
        return max(0, free - (tile == nil ? 0 : KitForm.tile + KitForm.tileGap))
    }

    private func labelHeight(_ width: CGFloat) -> CGFloat {
        let label = labelWidth(width)
        let top = titleText.height(for: label)
        guard detail != nil else { return top }
        return top + 2 + detailText.height(for: label)
    }

    func height(for width: CGFloat) -> CGFloat {
        if centred {
            let controls = max(0, (controlSizes.map(\.height).max() ?? 0) - (firstLine == nil ? 0 : 2))
            return max(labelHeight(width), controls, tile == nil ? 0 : KitForm.tile)
        }
        let label = max(labelHeight(width), tile == nil ? 0 : KitForm.tile)
        let control = controlSizes.map(\.height).max() ?? 0
        return top + bottom + max(label, control)
    }

    func kitHeight(width: CGFloat) -> CGFloat { height(for: width) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(for: bounds.width > 0 ? bounds.width : 480))
    }

    override func layout() {
        super.layout()
        if centred {
            layoutCentred()
            return
        }
        let width = bounds.width
        let labelWidth = labelWidth(width)
        let labelHeight = labelHeight(width)
        var x = side
        if let tile {
            let y = (top + (max(labelHeight, KitForm.tile) - KitForm.tile) / 2).rounded(.toNearestOrAwayFromZero)
            tile.frame = NSRect(x: x, y: y, width: KitForm.tile, height: KitForm.tile)
            x += KitForm.tile + KitForm.tileGap
        }
        let labelTop = top + max(0, (KitForm.tile - labelHeight) / 2).rounded(.toNearestOrAwayFromZero) * (tile == nil ? 0 : 1)
        let titleHeight = titleText.height(for: labelWidth)
        titleText.frame = NSRect(x: x, y: labelTop, width: labelWidth, height: titleHeight)
        if detail != nil {
            detailText.frame = NSRect(x: x, y: labelTop + titleHeight + 2, width: labelWidth, height: detailText.height(for: labelWidth))
        }
        let shown = controls.filter { !$0.isHidden }
        let sizes = shown.map(size(of:))
        let group = sizes.map(\.height).max() ?? 0
        var right = width - side
        for (view, size) in zip(shown, sizes).reversed() {
            let w = size.width
            view.frame = NSRect(x: right - w, y: top + ((group - size.height) / 2).rounded(.toNearestOrAwayFromZero), width: w, height: size.height)
            right -= w + controlSpacing
        }
    }

    private func layoutCentred() {
        let height = bounds.height
        let room = labelWidth(bounds.width)
        let titleHeight = titleText.height(for: room)
        let detailHeight = detail == nil ? 0 : detailText.height(for: room)
        let text = titleHeight + (detail == nil ? 0 : 2 + detailHeight)
        var x: CGFloat = 0
        if let tile {
            tile.frame = kitSnap(NSRect(x: 0, y: (height - KitForm.tile) / 2, width: KitForm.tile, height: KitForm.tile))
            x = KitForm.tile + KitForm.tileGap
        }
        var y = firstLine == nil ? (height - text) / 2 : 0
        titleText.frame = kitSnap(NSRect(x: x, y: y, width: min(room, titleText.naturalWidth), height: titleHeight))
        y += titleHeight + 2
        if detail != nil {
            detailText.frame = kitSnap(NSRect(x: x, y: y, width: min(room, detailText.naturalWidth), height: detailHeight))
        }
        var right = bounds.width
        let shown = controls.filter { !$0.isHidden }
        for (view, size) in zip(shown, shown.map(size(of:))).reversed() {
            right -= size.width
            let top = firstLine.map { (titleHeight - size.height) / 2 + $0 } ?? (height - size.height) / 2
            view.frame = kitSnap(NSRect(x: right, y: top, width: size.width, height: size.height))
            right -= controlSpacing
        }
    }
}

final class KitFormRows: KitFlippedView, KitHeightForWidth {
    private(set) var lines: [KitFormLine] = []
    private var rules: [KitBox] = []
    private var measuredAt: CGFloat = -1
    var separators = true { didSet { needsLayout = true } }
    var inset: CGFloat = 0 { didSet { if inset != oldValue { place() } } }

    private func place() {
        for (index, line) in lines.enumerated() {
            line.side = inset
            line.top = index == 0 ? inset : KitForm.inset
            line.bottom = index == lines.count - 1 ? inset : KitForm.inset
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func set(_ new: [KitFormLine]) {
        guard new.map(ObjectIdentifier.init) != lines.map(ObjectIdentifier.init) else { return }
        for line in lines where !new.contains(where: { $0 === line }) { line.removeFromSuperview() }
        for line in new where line.superview !== self { addSubview(line) }
        lines = new
        while rules.count < max(0, lines.count - 1) {
            let rule = KitBox(fill: KitForm.separator)
            addSubview(rule)
            rules.append(rule)
        }
        while rules.count > max(0, lines.count - 1) { rules.removeLast().removeFromSuperview() }
        place()
    }

    func height(for width: CGFloat) -> CGFloat {
        lines.reduce(0) { $0 + $1.height(for: width) } + CGFloat(max(0, lines.count - 1))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(for: bounds.width > 0 ? bounds.width : KitForm.fallbackWidth))
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - measuredAt) > 0.5 {
            measuredAt = bounds.width
            invalidateIntrinsicContentSize()
        }
        var y: CGFloat = 0
        for (index, line) in lines.enumerated() {
            let height = line.height(for: bounds.width)
            line.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
            if index < rules.count {
                rules[index].isHidden = !separators
                rules[index].frame = NSRect(x: inset, y: y, width: bounds.width - inset * 2, height: 1)
                y += 1
            }
        }
    }
}

final class KitFormCard: NSView, KitFits {
    var rows: [NSView] = [] {
        didSet {
            for view in oldValue where !rows.contains(where: { $0 === view }) { view.removeFromSuperview() }
            for view in rows where view.superview !== self { addSubview(view) }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    var rowPadding = NSEdgeInsets(top: 10, left: KitForm.inset, bottom: 10, right: KitForm.inset)

    private let ground = KitBox(fill: KitForm.card, corners: .radius(KitForm.radius))
    private var lines: [KitBox] = []

    init(rows: [NSView] = []) {
        super.init(frame: .zero)
        addSubview(ground)
        self.rows = rows
        for view in rows where view.superview !== self { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: kitHeight(width: bounds.width > 0 ? bounds.width : 400))
    }

    private func height(of row: NSView, width: CGFloat) -> CGFloat {
        if let fits = row as? KitFits { return fits.kitHeight(width: width) }
        let size = row.intrinsicContentSize
        return size.height < 0 ? row.fittingSize.height : size.height
    }

    func kitHeight(width: CGFloat) -> CGFloat {
        let inner = width - rowPadding.left - rowPadding.right
        let shown = rows.filter { !$0.isHidden }
        return shown.map { height(of: $0, width: inner) + rowPadding.top + rowPadding.bottom }.reduce(0, +) + CGFloat(max(0, shown.count - 1))
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let inner = bounds.width - rowPadding.left - rowPadding.right
        let shown = rows.filter { !$0.isHidden }
        while lines.count < max(0, shown.count - 1) {
            let line = KitBox(fill: KitForm.rule)
            addSubview(line)
            lines.append(line)
        }
        var y: CGFloat = 0
        for (index, row) in shown.enumerated() {
            if index > 0 {
                lines[index - 1].isHidden = false
                lines[index - 1].frame = NSRect(x: KitForm.inset, y: y, width: bounds.width - KitForm.inset * 2,
                                                height: 1 / (window?.backingScaleFactor ?? 1))
                y += 1
            }
            let height = height(of: row, width: inner)
            row.frame = NSRect(x: rowPadding.left, y: y + rowPadding.top, width: inner, height: height)
            y += height + rowPadding.top + rowPadding.bottom
        }
        for line in lines.dropFirst(max(0, shown.count - 1)) { line.isHidden = true }
    }
}

final class KitTrackField: KitHoverView, NSTextFieldDelegate {
    let field: NSTextField
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var width: CGFloat { didSet { invalidateIntrinsicContentSize() } }
    var isEnabled = true {
        didSet {
            field.isEnabled = isEnabled
            alphaValue = isEnabled ? 1 : 0.45
        }
    }
    var text: String {
        get { field.stringValue }
        set { if field.stringValue != newValue { field.stringValue = newValue } }
    }

    private let track = KitBox(fill: nil, corners: .radius(9))
    private var focused = false { didSet { if focused != oldValue { paint() } } }

    init(placeholder: String, secure: Bool = false, width: CGFloat, alignment: NSTextAlignment = .right, label: String? = nil) {
        field = secure ? NSSecureTextField(string: "") : NSTextField(string: "")
        self.width = width
        super.init(frame: .zero)
        addSubview(track)
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.isBezeled = false
        field.focusRingType = .none
        field.font = KitForm.titleFont
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        if let label { field.setAccessibilityLabel(label) }
        addSubview(field)
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: width, height: 30) }

    override func layout() {
        super.layout()
        track.frame = bounds
        let height = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: 8, y: ((bounds.height - height) / 2).rounded(.toNearestOrAwayFromZero), width: bounds.width - 16, height: height)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    override func hoverChanged() { paint() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        let lit = (hovering || focused) && isEnabled
        track.fill = KitWash.track.color(plus: lit ? 0.03 : 0)
        track.layer?.kitTransition(Motion.kitQuick)
    }

    func controlTextDidBeginEditing(_ obj: Notification) { focused = true }
    func controlTextDidEndEditing(_ obj: Notification) { focused = false }
    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        onSubmit?()
        return true
    }
}

class KitFormSection: KitFlippedView, KitHeightForWidth {
    let rows = KitFormRows()
    var bag: Set<AnyCancellable> = []
    private var made: [String: KitFormLine] = [:]
    private var refreshing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(rows)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func line(_ id: String, _ title: String, _ detail: String? = nil, symbol: String? = nil, spacing: CGFloat = 8,
              _ controls: [NSView] = []) -> KitFormLine {
        let line = made[id] ?? KitFormLine(id: id, title: title, detail: detail, tile: symbol.map(KitForm.symbol))
        made[id] = line
        line.title = title
        line.detail = detail
        line.controlSpacing = spacing
        line.controls = controls
        return line
    }

    func spec() -> [KitFormLine] { [] }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let width = bounds.width > 0 ? bounds.width : KitForm.fallbackWidth
        let before = rows.lines.isEmpty ? -1 : rows.height(for: width)
        rows.set(spec())
        if rows.height(for: width) != before { invalidateIntrinsicContentSize() }
    }

    func height(for width: CGFloat) -> CGFloat {
        refresh()
        return rows.height(for: width)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: rows.height(for: bounds.width > 0 ? bounds.width : KitForm.fallbackWidth))
    }

    override func layout() {
        refresh()
        super.layout()
        rows.frame = bounds
    }
}

@MainActor
func kitSettle(_ change: () -> Void) {
    change()
}
