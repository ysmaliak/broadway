import AppKit
import Combine

final class HiddenPanelView: KitHoverView {
    static let width: CGFloat = 380
    static let listCap: CGFloat = 320
    private static let pad: CGFloat = 14
    private static let close: CGFloat = 24
    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let bodyFont = NSFont.systemFont(ofSize: 13)
    private static let callout = NSFont.systemFont(ofSize: 12)

    let browser: Browser
    private let glass = KitGlass(radius: 16, tint: Palette.NS.glassTint)
    private let title = KitLabel("", font: HiddenPanelView.titleFont)
    private let closeButton = KitButton(.keycap(.secondary), label: "Done")
    private let nothing = KitLabel("Nothing is hidden here", font: HiddenPanelView.bodyFont, color: .secondaryLabelColor)
    private let lead = KitLabel("Hidden on this site. Point at a line to see it.", font: HiddenPanelView.callout, color: .secondaryLabelColor)
    private let scroll = NSScrollView()
    private let list = HiddenListView()
    private let rule = NSBox()
    private let hide = KitButton(title: "Hide Something…", font: .systemFont(ofSize: 13, weight: .semibold), look: .pill(.primary))
    private let restoreAll = KitButton(title: "Restore All", font: .systemFont(ofSize: 13), look: .pill(.secondary))
    private var watch: AnyCancellable?

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        addSubview(glass)
        closeButton.content = KitSymbol("xmark", style: KitSymbol.Style(size: 10, weight: .semibold))
        closeButton.toolTip = "Done   esc"
        closeButton.action = { [weak browser] in browser?.reviewing = false }
        hide.action = { [weak browser] in browser?.toggleHiding() }
        restoreAll.action = { [weak browser] in browser?.restoreAll() }
        for button in [hide, restoreAll] {
            button.height = BroadwaySize.regular.height
            button.padding = BroadwaySize.regular.padding
        }
        rule.boxType = .separator
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        for view in [title, closeButton, nothing, lead, scroll, rule, hide, restoreAll] as [NSView] { addSubview(view) }
        list.panel = self
        watch = kitObserve({ [weak browser] in (browser?.hereHost, browser?.hereVeils) }) { [weak self] _ in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static func listHeight(_ veils: [Veil]) -> CGFloat {
        min(listCap, veils.reduce(0) { $0 + HiddenRowView.height(of: $1) } + CGFloat(max(0, veils.count - 1)))
    }

    static func height(for browser: Browser) -> CGFloat {
        let veils = browser.hereVeils
        let head = 14 + lineHeight(titleFont) + 12
        let body = veils.isEmpty ? lineHeight(bodyFont) : lineHeight(callout) + 6 + listHeight(veils)
        return head + body + 14 + 1 + 14 + BroadwaySize.regular.height + 14
    }

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    private func refresh() {
        let veils = browser.hereVeils
        title.text = browser.hereHost ?? "This page"
        nothing.isHidden = !veils.isEmpty
        lead.isHidden = veils.isEmpty
        scroll.isHidden = veils.isEmpty
        restoreAll.isHidden = veils.isEmpty
        list.veils = veils
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: Self.height(for: browser)) }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let pad = Self.pad
        let width = bounds.width - 2 * pad
        let titleHeight = Self.lineHeight(Self.titleFont)
        let headTop: CGFloat = 14
        let side = Self.close
        closeButton.frame = NSRect(x: bounds.width - pad - side, y: headTop + (titleHeight - side) / 2, width: side, height: side)
        title.frame = kitSnap(NSRect(x: pad, y: headTop, width: closeButton.frame.minX - 10 - pad, height: titleHeight))
        var y = headTop + titleHeight + 12
        if browser.hereVeils.isEmpty {
            let height = Self.lineHeight(Self.bodyFont)
            nothing.frame = kitSnap(NSRect(x: pad, y: y, width: width, height: height))
            y += height
        } else {
            let height = Self.lineHeight(Self.callout)
            lead.frame = kitSnap(NSRect(x: pad, y: y, width: width, height: height))
            y += height + 6
            let listHeight = Self.listHeight(browser.hereVeils)
            scroll.frame = NSRect(x: pad, y: y, width: width, height: listHeight)
            list.frame = NSRect(x: 0, y: 0, width: width, height: list.contentHeight)
            y += listHeight
        }
        y += 14
        rule.frame = NSRect(x: 0, y: y, width: bounds.width, height: 1)
        y += 1 + 14
        let tall = BroadwaySize.regular.height
        let hideWidth = max(64, hide.intrinsicContentSize.width)
        hide.frame = NSRect(x: pad, y: y, width: hideWidth, height: tall)
        let restoreWidth = max(64, restoreAll.intrinsicContentSize.width)
        restoreAll.frame = NSRect(x: hide.frame.maxX + 8, y: y, width: restoreWidth, height: tall)
    }

    override func hoverChanged() {
        if !hovering { browser.stopPeeking() }
    }

    override func cancelOperation(_ sender: Any?) {
        browser.reviewing = false
    }

    fileprivate func peek(_ veil: Veil) { browser.peek(veil) }
    fileprivate func restore(_ veil: Veil) { browser.restore(veil) }
}

final class HiddenListView: NSView {
    weak var panel: HiddenPanelView?
    var veils: [Veil] = [] { didSet { if veils != oldValue { rebuild() } } }
    private var rows: [HiddenRowView] = []
    private var rules: [NSBox] = []

    override var isFlipped: Bool { true }

    var contentHeight: CGFloat {
        veils.reduce(0) { $0 + HiddenRowView.height(of: $1) } + CGFloat(max(0, veils.count - 1))
    }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rules.forEach { $0.removeFromSuperview() }
        rows = veils.map { veil in
            let row = HiddenRowView(veil: veil)
            row.peek = { [weak self] in self?.panel?.peek(veil) }
            row.restore = { [weak self] in self?.panel?.restore(veil) }
            addSubview(row)
            return row
        }
        rules = veils.dropLast().map { _ in
            let rule = NSBox()
            rule.boxType = .separator
            addSubview(rule)
            return rule
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let height = HiddenRowView.height(of: row.veil)
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
            if rules.indices.contains(index) {
                rules[index].frame = NSRect(x: 0, y: y, width: bounds.width, height: 1)
                y += 1
            }
        }
    }
}

final class HiddenRowView: KitHoverView {
    let veil: Veil
    var peek: (() -> Void)?
    var restore: (() -> Void)?
    private static let labelFont = NSFont.systemFont(ofSize: 13)
    private static let noteFont = NSFont.systemFont(ofSize: 12)
    private let label = KitLabel("", font: HiddenRowView.labelFont, color: .labelColor)
    private let note = KitLabel("", font: HiddenRowView.noteFont, color: .secondaryLabelColor)
    private let button = NSButton(title: "Restore", target: nil, action: nil)

    static func height(of veil: Veil) -> CGFloat {
        let line = HiddenPanelView.lineHeight(labelFont)
        let extra = (veil.note?.isEmpty == false) ? 2 + HiddenPanelView.lineHeight(noteFont) : 0
        return 8 + line + extra + 8
    }

    init(veil: Veil) {
        self.veil = veil
        super.init(frame: .zero)
        label.text = veil.label
        note.text = veil.note ?? ""
        note.isHidden = veil.note?.isEmpty ?? true
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.contentTintColor = .controlAccentColor
        button.target = self
        button.action = #selector(restoreTapped)
        button.alphaValue = 0
        for view in [label, note, button] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func restoreTapped() { restore?() }

    override func layout() {
        super.layout()
        let size = button.intrinsicContentSize
        button.frame = NSRect(x: bounds.width - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let room = max(0, button.frame.minX - 10)
        let line = HiddenPanelView.lineHeight(Self.labelFont)
        label.frame = kitSnap(NSRect(x: 0, y: 8, width: room, height: line))
        note.frame = kitSnap(NSRect(x: 0, y: 8 + line + 2, width: room, height: HiddenPanelView.lineHeight(Self.noteFont)))
    }

    override func hoverChanged() {
        button.alphaValue = hovering ? 1 : 0
        if hovering { peek?() }
    }
}
