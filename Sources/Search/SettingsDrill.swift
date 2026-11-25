import AppKit

enum SettingsMetrics {
    static var margin: CGFloat = 16
    static var top: CGFloat = 20
    static var bottom: CGFloat = 0
    static var foot: CGFloat = 20
    static var radius: CGFloat = 14
    static var inset: CGFloat = 10
    static var rowPad: CGFloat = 13
    static var rowIcons = false
    static var icon: CGFloat = 22
    static var tile: CGFloat = 30
    static var hero: CGFloat = 56
    static var gap: CGFloat = 11
    static var sectionGap: CGFloat = 16
    static var headingGap: CGFloat = 10
    static var headingInset: CGFloat = 10
    static var footerGap: CGFloat = 10
    static var footerAfter: CGFloat = 30
    static var controlGap: CGFloat = 12
    static func tone(light: UInt32, dark: UInt32) -> NSColor {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(white: CGFloat(hex & 255) / 255, alpha: 1)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }

    static var ground = tone(light: 0xFFFFFF, dark: 0x1F1F1F)
    static var fill = tone(light: 0xF8F8F8, dark: 0x252525)
    static var stroke: NSColor = .clear

    static func cg(_ color: NSColor, dark: Bool) -> CGColor {
        var out = color.cgColor
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { out = color.cgColor }
        return out
    }
    static var separator = tone(light: 0xEBEBEB, dark: 0x2F2F2F)
    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let detailFont = NSFont.systemFont(ofSize: 12)
    static let detailDigitsFont = NSFont.monospacedDigitSystemFont(ofSize: detailFont.pointSize, weight: .regular)
    static let headingFont = NSFont.systemFont(ofSize: 13, weight: .medium)
}

final class SettingsText: NSTextField {
    convenience init(_ text: String, font: NSFont, color: NSColor = .labelColor, wraps: Bool = false) {
        if wraps {
            self.init(wrappingLabelWithString: text)
        } else {
            self.init(labelWithString: text)
            lineBreakMode = .byTruncatingTail
        }
        self.font = font
        textColor = color
        translatesAutoresizingMaskIntoConstraints = false
        isSelectable = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = alignmentRect(forFrame: NSRect(origin: .zero, size: newSize)).width
        guard cell?.wraps == true, abs(preferredMaxLayoutWidth - width) > 0.25 else { return }
        preferredMaxLayoutWidth = width
        invalidateIntrinsicContentSize()
    }
}

final class SettingsBlock: NSView {
    var after: NSLayoutConstraint?
}

class SettingsPageStack: NSView {
    private let stack = NSStackView()
    private var lead: NSLayoutConstraint?

    var top: CGFloat = SettingsMetrics.top {
        didSet { lead?.constant = top }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let lead = stack.topAnchor.constraint(equalTo: topAnchor, constant: top)
        self.lead = lead
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            lead,
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -SettingsMetrics.bottom),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = SettingsMetrics.cg(SettingsMetrics.ground, dark: kitDark)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    var blocks: [NSView] { stack.arrangedSubviews }

    func hug() {
        stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SettingsMetrics.bottom).isActive = true
    }

    func clear() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    private var lastBlock: SettingsBlock? {
        stack.arrangedSubviews.last { !$0.isHidden } as? SettingsBlock
    }

    var last: NSView? {
        guard let content = lastBlock?.subviews.first else { return nil }
        return (content as? SettingsPageStack)?.last ?? content
    }

    func end(with air: CGFloat) {
        guard let block = lastBlock else { return }
        (block.subviews.first as? SettingsPageStack)?.end(with: 0)
        block.after?.constant = -air
    }

    func add(_ view: NSView, inset: CGFloat = SettingsMetrics.margin, top: CGFloat = 0, after: CGFloat = 0) {
        let holder = SettingsBlock()
        holder.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(view)
        let foot = view.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -after)
        holder.after = foot
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: holder.topAnchor, constant: top),
            foot,
        ])
        stack.addArrangedSubview(holder)
        holder.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func frame(of id: String) -> NSRect? {
        guard let row = kitSubviews(of: SettingsRowView.self).first(where: { $0.rowID == id }) else { return nil }
        return row.convert(row.bounds, to: self)
    }
}

final class SettingsHeading: NSView {
    init(_ title: String) {
        super.init(frame: .zero)
        let label = SettingsText(title, font: SettingsMetrics.headingFont)
        label.setAccessibilityRole(.staticText)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.headingInset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SettingsMetrics.headingGap),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
        setAccessibilitySubrole(.init(rawValue: "AXHeading"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class SettingsCard: NSView {
    private let stack = NSStackView()
    private var lines: [NSView] = []
    private var names: [ObjectIdentifier: String] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    var rows: [NSView] { stack.arrangedSubviews.filter { view in !lines.contains { $0.superview === view } } }
    var isEmpty: Bool { stack.arrangedSubviews.isEmpty }

    override func updateLayer() {
        let dark = kitDark
        layer?.cornerRadius = SettingsMetrics.radius
        layer?.backgroundColor = SettingsMetrics.cg(SettingsMetrics.fill, dark: dark)
        layer?.borderWidth = 1 / max(window?.backingScaleFactor ?? 2, 1)
        layer?.borderColor = SettingsMetrics.cg(SettingsMetrics.stroke, dark: dark)
        for line in lines { line.layer?.backgroundColor = SettingsMetrics.cg(SettingsMetrics.separator, dark: dark) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func add(_ row: NSView, name: String? = nil) {
        if !stack.arrangedSubviews.isEmpty {
            let line = NSView()
            line.wantsLayer = true
            line.translatesAutoresizingMaskIntoConstraints = false
            lines.append(line)
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(line)
            let lead = (stack.arrangedSubviews.last as? SettingsSeparated)?.separatorLead ?? SettingsMetrics.inset
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: lead),
                line.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -SettingsMetrics.inset),
                line.topAnchor.constraint(equalTo: holder.topAnchor),
                line.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                line.heightAnchor.constraint(equalToConstant: 1),
            ])
            stack.addArrangedSubview(holder)
            holder.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            needsDisplay = true
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let name { names[ObjectIdentifier(row)] = name }
    }

    func name(of row: NSView) -> String? {
        names[ObjectIdentifier(row)] ?? (row as? SettingsRowView)?.rowID ?? (row as? SettingsFormRow)?.name
            ?? (row is SettingsNothing ? SettingsStageMap.note : nil)
    }

    func row(at point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let spot = stack.convert(point, from: self)
        return rows.first { $0.frame.contains(spot) }
    }

    func row(holding view: NSView) -> NSView? {
        rows.first { view === $0 || view.isDescendant(of: $0) }
    }
}

class SettingsRowView: NSView, SettingsSeparated, AccessActing {
    let rowID: String
    let icon: KitSymbol?
    private let tile: SettingsTile?
    let title: SettingsText
    let detail: SettingsText
    private(set) var control: NSView?
    private var info: NSButton?
    private let wide: Bool
    private let highlight = KitBox(fill: nil)
    private lazy var toggles: [KitSwitch] = control.map { ($0 as? KitSwitch).map { [$0] } ?? $0.kitSubviews(of: KitSwitch.self) } ?? []
    private var fitted: [ObjectIdentifier: NSSize] = [:]
    var tint: NSColor = .secondaryLabelColor { didSet { if tile == nil { icon?.tint = tint } } }
    var press: (() -> Void)?
    var acting: Bool { press != nil }

    var separatorLead: CGFloat { SettingsMetrics.inset }

    private let pad: CGFloat
    private let centered: Bool

    init(id: String, symbol: String?, title: String, detail: String = "", more: String? = nil,
         wide: Bool = false, control: NSView? = nil, pad: CGFloat = SettingsMetrics.rowPad,
         centered: Bool = false, tiled: Bool = false) {
        rowID = id
        self.wide = wide
        self.pad = pad
        self.centered = centered
        if tiled, let symbol {
            icon = KitSymbol(symbol, style: KitSymbol.Style(size: SettingsMetrics.tile * 0.5, weight: IconLook.weight), tint: .labelColor)
            tile = SettingsTile()
        } else {
            icon = SettingsMetrics.rowIcons ? symbol.map {
                KitSymbol($0, style: KitSymbol.Style(size: SettingsMetrics.icon * 0.7, weight: IconLook.weight), tint: .secondaryLabelColor)
            } : nil
            tile = nil
        }
        self.title = SettingsText(title, font: SettingsMetrics.titleFont)
        self.detail = SettingsText(detail, font: SettingsMetrics.detailFont, color: .secondaryLabelColor, wraps: true)
        self.control = control
        super.init(frame: .zero)
        build(more: more)
        identifier = NSUserInterfaceItemIdentifier("settings.row." + id)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var lit = false {
        didSet { highlight.fill = lit ? NSColor.labelColor.withAlphaComponent(0.1) : nil }
    }

    func say(_ text: String) {
        guard detail.stringValue != text else { return }
        detail.stringValue = text
        detail.isHidden = text.isEmpty
    }

    func rename(_ text: String) {
        guard title.stringValue != text else { return }
        title.stringValue = text
    }

    private func build(more: String?) {
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let words = NSStackView()
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        words.setHuggingPriority(.defaultHigh, for: .vertical)
        words.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSStackView()
        heading.orientation = .horizontal
        heading.spacing = 5
        heading.addArrangedSubview(title)
        if let more {
            let button = NSButton()
            button.image = KitGlyph.image("info.circle", .init(size: 11, weight: IconLook.weight), label: "More about \(title.stringValue)")
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = more
            button.focusRingType = .none
            button.setAccessibilityLabel("More about \(title.stringValue)")
            let tell = SettingsMore(more)
            button.kitOnChange { tell.show(from: $0) }
            objc_setAssociatedObject(button, &SettingsMore.key, tell, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            heading.addArrangedSubview(button)
            info = button
        }
        words.addArrangedSubview(heading)
        words.addArrangedSubview(detail)
        detail.isHidden = detail.stringValue.isEmpty
        addSubview(words)
        var constraints: [NSLayoutConstraint] = []
        var lead = leadingAnchor
        var leadGap = SettingsMetrics.inset
        let band = NSLayoutGuide()
        addLayoutGuide(band)
        let hug = band.heightAnchor.constraint(equalTo: words.heightAnchor)
        hug.priority = .defaultLow
        constraints += [
            band.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            band.leadingAnchor.constraint(equalTo: leadingAnchor),
            band.trailingAnchor.constraint(equalTo: trailingAnchor),
            band.heightAnchor.constraint(greaterThanOrEqualTo: words.heightAnchor),
            hug,
        ]
        if let icon {
            let side = tile == nil ? SettingsMetrics.icon : SettingsMetrics.tile
            if let tile {
                tile.translatesAutoresizingMaskIntoConstraints = false
                addSubview(tile)
            }
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            constraints += [
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.inset),
                icon.widthAnchor.constraint(equalToConstant: side),
                icon.heightAnchor.constraint(equalToConstant: side),
                icon.centerYAnchor.constraint(equalTo: words.centerYAnchor),
            ]
            if let tile {
                constraints += [
                    tile.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
                    tile.trailingAnchor.constraint(equalTo: icon.trailingAnchor),
                    tile.topAnchor.constraint(equalTo: icon.topAnchor),
                    tile.bottomAnchor.constraint(equalTo: icon.bottomAnchor),
                ]
            }
            if !wide { constraints.append(band.heightAnchor.constraint(greaterThanOrEqualToConstant: side)) }
            lead = icon.trailingAnchor
            leadGap = SettingsMetrics.gap
        }
        constraints += [
            words.leadingAnchor.constraint(equalTo: lead, constant: leadGap),
            detail.widthAnchor.constraint(equalTo: words.widthAnchor),
        ]
        if wide {
            constraints.append(words.topAnchor.constraint(equalTo: band.topAnchor))
        } else {
            constraints += [
                words.centerYAnchor.constraint(equalTo: band.centerYAnchor),
                band.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            ]
        }
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
            if wide {
                constraints += [
                    words.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsMetrics.inset),
                    control.leadingAnchor.constraint(equalTo: words.leadingAnchor),
                    control.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SettingsMetrics.inset),
                    control.topAnchor.constraint(equalTo: words.bottomAnchor, constant: 10),
                    control.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
                ]
            } else {
                control.setContentHuggingPriority(.required, for: .horizontal)
                control.setContentCompressionResistancePriority(.required, for: .horizontal)
                words.setHuggingPriority(NSLayoutConstraint.Priority(200), for: .horizontal)
                detail.setContentHuggingPriority(NSLayoutConstraint.Priority(200), for: .horizontal)
                let edge = control.leadingAnchor
                let fill = words.trailingAnchor.constraint(equalTo: edge, constant: -SettingsMetrics.controlGap)
                fill.priority = NSLayoutConstraint.Priority(230)
                let spare = control is SettingsPopUp ? SettingsPopUp.spare : 0
                constraints += [
                    words.trailingAnchor.constraint(lessThanOrEqualTo: edge, constant: -SettingsMetrics.controlGap),
                    control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: spare - SettingsMetrics.inset),
                    fill,
                ]
                if centered {
                    constraints.append(control.centerYAnchor.constraint(equalTo: band.centerYAnchor))
                } else if let popUp = control as? SettingsPopUp {
                    constraints += [
                        popUp.button.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
                        band.bottomAnchor.constraint(greaterThanOrEqualTo: control.bottomAnchor),
                    ]
                } else {
                    constraints += [
                        control.centerYAnchor.constraint(equalTo: band.centerYAnchor),
                        band.topAnchor.constraint(lessThanOrEqualTo: control.topAnchor),
                        band.bottomAnchor.constraint(greaterThanOrEqualTo: control.bottomAnchor),
                    ]
                }
            }
        } else {
            let fill = words.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsMetrics.inset)
            fill.priority = NSLayoutConstraint.Priority(700)
            constraints += [words.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SettingsMetrics.inset), fill]
            if wide { constraints.append(words.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad)) }
        }
        NSLayoutConstraint.activate(constraints)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { press != nil }

    override func layout() {
        super.layout()
        for toggle in toggles {
            guard let drawn = toggle.native?.intrinsicContentSize, drawn != fitted[ObjectIdentifier(toggle)] else { continue }
            fitted[ObjectIdentifier(toggle)] = drawn
            toggle.invalidateIntrinsicContentSize()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard press != nil, let hit else { return hit }
        if hit is NSControl, !(hit is NSTextField) { return hit }
        return self
    }

    override func mouseUp(with event: NSEvent) {
        guard let press, event.clickCount == 1 else { return super.mouseUp(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { press() }
    }

    override func mouseDown(with event: NSEvent) {
        if press == nil { super.mouseDown(with: event) }
    }

    func dim(_ off: Bool) {
        alphaValue = off ? 0.5 : 1
        for control in kitSubviews(of: NSControl.self) where control !== info {
            control.isEnabled = !off
        }
        for toggle in kitSubviews(of: KitSwitch.self) { toggle.isEnabled = !off }
        for button in kitSubviews(of: KitButton.self) { button.isEnabled = !off }
        for choice in kitSubviews(of: KitChoice.self) {
            choice.isEnabled = !off
            choice.alphaValue = 1
        }
        for pictures in kitSubviews(of: SettingsPictureChoice.self) {
            pictures.isEnabled = !off
            pictures.alphaValue = 1
        }
    }
}

@MainActor
final class SettingsMore: NSObject {
    static var key: UInt8 = 0
    private let text: String
    private var popup: KitPopup?

    init(_ text: String) {
        self.text = text
        super.init()
    }

    func show(from view: NSView) {
        if let popup {
            popup.close()
            return
        }
        let note = Self.note(text)
        popup = KitPopup.show(note, size: note.frame.size, from: view.bounds, of: view, edge: .below) { [weak self] in
            self?.popup = nil
        }
    }

    static func note(_ text: String) -> NSView {
        let width: CGFloat = 280
        let pad: CGFloat = 8
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = width
        let height = ceil(label.fittingSize.height)
        let note = KitFlippedView(frame: NSRect(x: 0, y: 0, width: width + pad * 2, height: height + pad * 2))
        label.frame = NSRect(x: pad, y: pad, width: width, height: height)
        note.addSubview(label)
        return note
    }
}

final class SettingsDrillMark: NSStackView {
    let value = SettingsText("", font: SettingsMetrics.titleFont, color: .secondaryLabelColor)
    private let capsule = SettingsCount()

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        let chevron = KitSymbol("chevron.right", style: KitSymbol.Style(size: 12, weight: .semibold), tint: .secondaryLabelColor)
        addArrangedSubview(value)
        addArrangedSubview(capsule)
        addArrangedSubview(chevron)
        show(count: nil, value: nil)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(count: Int?, value text: String?) {
        value.stringValue = text ?? ""
        value.isHidden = text == nil
        capsule.count = count
        capsule.isHidden = count == nil
    }
}

final class SettingsCount: NSView {
    private let label = SettingsText("", font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor)
    var count: Int? { didSet { label.stringValue = count.map(String.init) ?? "" } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 26),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.quaternaryLabelColor.kitResolved(dark: kitDark).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class SettingsTile: NSView {
    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class SettingsDrillRow: SettingsRowView {
    let mark = SettingsDrillMark()
    private var resting = ""

    func tell(_ value: String?) {
        say(value ?? resting)
    }

    init(id: String, symbol: String, title: String, line: String? = nil, tiled: Bool = true, open: @escaping () -> Void) {
        super.init(id: id, symbol: symbol, title: title, detail: line ?? "", control: mark, pad: SettingsMetrics.rowPad - (tiled ? 2 : 0),
                   centered: true, tiled: tiled)
        resting = line ?? ""
        press = open
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp("Opens its page")
    }

    override func accessibilityPerformPress() -> Bool {
        press?()
        return press != nil
    }
}

final class SettingsDangerRow: SettingsRowView {
    init(id: String, symbol: String, title: String, detail: String, act: @escaping () -> Void) {
        super.init(id: id, symbol: symbol, title: title, detail: detail, pad: SettingsMetrics.rowPad - 4)
        tint = .systemRed
        self.title.textColor = .systemRed
        press = act
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    override func accessibilityPerformPress() -> Bool {
        press?()
        return press != nil
    }
}

final class SettingsNothing: NSView {
    init(_ text: String) {
        super.init(frame: .zero)
        let label = SettingsText(text, font: SettingsMetrics.titleFont, color: .secondaryLabelColor, wraps: true)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.inset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsMetrics.inset),
            label.topAnchor.constraint(equalTo: topAnchor, constant: SettingsMetrics.rowPad),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SettingsMetrics.rowPad),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class SettingsPopUp: NSView {
    static let spare: CGFloat = 3.5
    let button: NSPopUpButton
    private let circle = KitBox(fill: nil, corners: .capsule)
    private let chevron = KitSymbol("chevron.up.chevron.down", style: KitSymbol.Style(size: 10, weight: .semibold), tint: .labelColor)

    init(_ button: NSPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)) {
        self.button = button
        super.init(frame: .zero)
        button.isBordered = false
        button.focusRingType = .none
        button.font = .systemFont(ofSize: 13)
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        for view in [button, circle, chevron] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            circle.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 9),
            circle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.spare),
            circle.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            circle.widthAnchor.constraint(equalToConstant: 20),
            circle.heightAnchor.constraint(equalToConstant: 20),
            chevron.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            circle.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            button.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        circle.fill = kitDark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.064)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? button : nil
    }

    override func accessibilityChildren() -> [Any]? { [button] }
}

final class SettingsPill: KitBroadwayButton {
    init(_ title: String, kind: Kind = .secondary, action: (() -> Void)? = nil) {
        super.init(title, kind: kind, action: action)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}


protocol SettingsSeparated: NSView {
    var separatorLead: CGFloat { get }
}

@MainActor
class SettingsFormStack: SettingsPageStack {
    private var card: SettingsCard?

    func section(_ title: String? = nil, footer: String? = nil, footerSize: CGFloat = 12, _ rows: () -> Void) {
        close()
        let made = SettingsCard()
        if let title { add(SettingsHeading(title)) }
        card = made
        rows()
        close(footer: footer, footerSize: footerSize)
    }

    func close(footer: String? = nil, footerSize: CGFloat = 12) {
        guard let made = card else { return }
        card = nil
        guard !made.isEmpty else { return }
        if let footer {
            add(made, after: SettingsMetrics.footerGap)
            add(SettingsFooter(footer, size: footerSize), inset: SettingsMetrics.margin, after: SettingsMetrics.footerAfter)
        } else {
            add(made, after: SettingsMetrics.sectionGap)
        }
    }

    func put(_ row: NSView, name: String? = nil) {
        if let card { card.add(row, name: name) } else { add(row, after: SettingsMetrics.sectionGap) }
    }

    func hosted(_ view: NSView) {
        close()
        (view as? SettingsPageStack)?.hug()
        (view as? SettingsPageStack)?.top = 0
        add(view, inset: 0)
    }

    @discardableResult
    func fitted(_ view: NSView, lead: CGFloat = SettingsMetrics.inset, name: String? = nil) -> SettingsFormRow {
        let row = view as? SettingsFormRow ?? SettingsFormRow(view, lead: lead)
        if let name { row.name = name }
        put(row)
        return row
    }
}

final class SettingsFormRow: NSView, SettingsSeparated {
    let content: NSView
    var separatorLead: CGFloat
    var name: String?
    private var measuredAt: CGFloat = -1

    init(_ content: NSView, lead: CGFloat = SettingsMetrics.inset, pad: CGFloat = SettingsMetrics.rowPad) {
        self.content = content
        separatorLead = lead
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsMetrics.inset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ])
        (content as? KitFormSection)?.refresh()
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = content.bounds.width
        if abs(width - measuredAt) > 0.5 {
            measuredAt = width
            content.invalidateIntrinsicContentSize()
        }
    }
}

final class SettingsFooter: NSView {
    let words: KitParagraph
    private var measuredAt: CGFloat = -1

    init(_ text: String, size: CGFloat = 12) {
        words = KitParagraph(text, font: .systemFont(ofSize: size), color: .secondaryLabelColor)
        super.init(frame: .zero)
        addSubview(words)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        words.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func room(_ width: CGFloat) -> CGFloat { max(0, width - SettingsMetrics.headingInset * 2) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: words.height(for: room(bounds.width > 0 ? bounds.width : 610)))
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - measuredAt) > 0.5 {
            measuredAt = bounds.width
            invalidateIntrinsicContentSize()
        }
        let room = room(bounds.width)
        words.frame = kitSnap(NSRect(x: SettingsMetrics.headingInset, y: 0, width: min(room, words.naturalWidth), height: words.height(for: room)))
    }
}
