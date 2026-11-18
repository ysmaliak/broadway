import AppKit
import Combine
import Observation

@MainActor
@Observable
final class FindState {
    var on = false
    var focus = 0
}

@MainActor
final class FindBarView: NSView, NSTextFieldDelegate {
    static let widest: CGFloat = 390
    static let height: CGFloat = 40
    static let key: CGFloat = 26

    struct Shown: Equatable {
        var needle = ""
        var status: String?
        var missed = false
        var matchCase = false
        var wholeWords = false
        var wholeWordsLocked = false

        init() {}

        @MainActor init(_ browser: Browser) {
            needle = browser.needle
            status = browser.findStatus
            missed = browser.missed
            matchCase = browser.matchCase
            wholeWords = browser.wholeWords
            wholeWordsLocked = browser.findResult?.nativeFallback == true && !browser.wholeWords
        }
    }

    weak var browser: Browser?
    var shown = Shown() { didSet { if shown != oldValue { apply(oldValue) } } }
    var availableWidth: CGFloat? {
        didSet {
            guard availableWidth != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    private var watch: AnyCancellable?
    var focusAsk = 0 { didSet { if focusAsk != oldValue { focusField() } } }

    let field = FindField()
    let count = FindCountView()
    private let glass = KitGlass.floating(capsule: true)
    private let inside = KitBox(fill: nil)
    private let keys = KitBox(fill: nil)
    private let edge = KitBox(fill: nil, corners: .capsule)
    private let previous: KitGlassKey
    private let next: KitGlassKey
    private let close: KitGlassKey
    private let options = KitButton(.keycap(.secondary), label: "Search Options")
    private let optionsMark = KitSymbol("ellipsis", style: KitSymbol.Style(size: 10, weight: .semibold), tint: KitColor.ink)

    init(browser: Browser?) {
        self.browser = browser
        previous = KitGlassKey(symbol: "chevron.up", circle: Self.key, symbolSize: 9, weight: .semibold, quiet: true, label: "Previous Match")
        next = KitGlassKey(symbol: "chevron.down", circle: Self.key, symbolSize: 9, weight: .semibold, quiet: true, label: "Next Match")
        close = KitGlassKey(symbol: "xmark", circle: Self.key, symbolSize: 9, weight: .semibold, quiet: true, label: "Close Find on Page")
        super.init(frame: .zero)
        previous.kitAccess(help: "Find the previous match")
        next.kitAccess(help: "Find the next match")
        close.kitAccess(help: "Close the find field and clear its selection")
        options.kitAccess(help: "Search Options")
        options.setAccessibilityHelp("Choose whether to match case or whole words")
        options.content = optionsMark
        previous.action = { [weak self] in self?.browser?.look(forward: false) }
        next.action = { [weak self] in
            self?.browser?.hints.findNextPressed()
            self?.browser?.look(forward: true)
        }
        close.action = { [weak self] in self?.browser?.closeFind() }
        options.action = { [weak self] in self?.popOptions() }

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = Palette.NS.ink
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(string: "Find on page", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.NS.glassFaint,
        ])
        field.delegate = self
        field.setAccessibilityLabel("Find on page")
        field.setAccessibilityHelp("Type text to search this page. Press Return to find the next match.")

        edge.strokeWidth = 1
        edge.wantsLayer = true
        addSubview(glass)
        glass.hold(inside)
        inside.addSubview(field)
        inside.addSubview(count)
        for key in [previous, next, options, close] { keys.addSubview(key) }
        inside.addSubview(keys)
        addSubview(edge)
        apply(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var narrow: Bool { availableWidth.map { $0 < 290 } ?? false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let radius = bounds.height / 2
        guard NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).contains(local) else { return nil }
        let hit = super.hitTest(point)
        let onField = hit.map { $0 === field || $0.isDescendant(of: field) } ?? false
        guard local.x < field.frame.maxX, !onField else { return hit }
        return (field.currentEditor() as? NSView) ?? field
    }

    var fieldWidth: CGFloat {
        guard let availableWidth else { return 150 }
        let room = min(Self.widest, availableWidth)
        let controls: CGFloat = narrow ? 86 : 158
        return max(40, min(160, room - controls - FindCountView.width - 38))
    }

    private var lead: CGFloat { narrow ? 10 : 16 }
    private var trail: CGFloat { narrow ? 6 : 7 }
    private var keysWidth: CGFloat { narrow ? Self.key * 2 + 6 : Self.key * 4 + 6 * 3 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: lead + fieldWidth + 6 + FindCountView.width + 6 + keysWidth + trail, height: Self.height)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        edge.frame = bounds
        inside.frame = glass.bounds
        let middle = bounds.height / 2
        let fieldHeight = ceil(field.fittingSize.height)
        field.frame = kitSnap(NSRect(x: lead - 2, y: middle - fieldHeight / 2, width: fieldWidth + 4, height: fieldHeight))
        let countSize = count.intrinsicContentSize
        count.frame = kitSnap(NSRect(x: lead + fieldWidth + 6, y: middle - countSize.height / 2, width: countSize.width, height: countSize.height))
        let keysX = lead + fieldWidth + 6 + FindCountView.width + 6
        keys.frame = NSRect(x: keysX, y: middle - Self.key / 2, width: keysWidth, height: Self.key)
        previous.isHidden = narrow
        next.isHidden = narrow
        let shownKeys: [NSView] = narrow ? [options, close] : [previous, next, options, close]
        for (index, key) in shownKeys.enumerated() {
            key.frame = NSRect(x: CGFloat(index) * (Self.key + 6), y: 0, width: Self.key, height: Self.key)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusField()
    }

    private func apply(_ old: Shown?) {
        if field.stringValue != shown.needle { field.stringValue = shown.needle }
        if let old, old.needle != shown.needle { browser?.hints.searchChanged() }
        count.status = shown.status
        count.missed = shown.missed
        if old?.missed != shown.missed {
            if old != nil { edge.layer?.kitTransition(Motion.kitQuick) }
            edge.stroke = shown.missed ? NSColor.systemRed.withAlphaComponent(0.35) : nil
        }
    }

    private func focusField() {
        guard let window else { return }
        window.makeFirstResponder(field)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, self.field.currentEditor() == nil else { return }
            window.makeFirstResponder(self.field)
        }
    }

    private func popOptions() {
        guard let browser else { return }
        let match = KitMenuAction("Match Case", key: "") { [weak browser] in browser?.matchCase.toggle() }
        match.state = browser.matchCase ? .on : .off
        match.toolTip = "Match uppercase and lowercase letters exactly"
        let whole = KitMenuAction("Whole Words", key: "") { [weak browser] in browser?.wholeWords.toggle() }
        whole.state = browser.wholeWords ? .on : .off
        whole.isEnabled = !shown.wholeWordsLocked
        whole.toolTip = "Match whole words. Not available on PDFs."
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(match)
        menu.addItem(whole)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: options.bounds.maxY + 4), in: options)
    }

    func controlTextDidChange(_ note: Notification) {
        guard let browser, browser.needle != field.stringValue else { return }
        browser.needle = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        browser?.look(forward: NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
        return true
    }

    static func surface(needle: String, narrow: Bool) -> NSView {
        let browser = Browser(record: WindowRecord())
        browser.needle = needle
        let bar = FindBarView(browser: browser)
        bar.availableWidth = narrow ? 260 : nil
        bar.watch = kitObserve({ [weak browser] in browser.map(Shown.init) }) { [weak bar] in
            if let shown = $0 { bar?.shown = shown }
        }
        let size = bar.intrinsicContentSize
        let stage = KitBox(fill: nil)
        stage.frame = NSRect(x: 0, y: 0, width: size.width + 14, height: size.height + 12)
        bar.frame = NSRect(x: 0, y: 12, width: size.width, height: size.height)
        stage.addSubview(bar)
        stage.setFrameSize(stage.frame.size)
        return KitFixedView(stage, keep: browser)
    }
}

final class FindField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class FindCountView: NSView {
    static let widest = "999+ of 999+"
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    static let width: CGFloat = ceil((widest as NSString).size(withAttributes: [.font: font]).width) + 2
    static let lineHeight: CGFloat = ceil(KitLabel("0", font: font).intrinsicContentSize.height)

    var status: String? { didSet { if status != oldValue { changed(from: oldValue) } } }
    var missed = false { didSet { if missed != oldValue { paint() } } }

    private let label = KitLabel("", font: FindCountView.font, color: KitColor.muted)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.lineHeight))
        label.alignment = .right
        label.overflow = .tail
        label.wantsLayer = true
        label.kitAccess(id: "Find result status")
        label.isHidden = true
        addSubview(label)
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: Self.lineHeight) }

    override func layout() {
        super.layout()
        label.frame = bounds
    }

    private func changed(from old: String?) {
        if old != nil || status != nil { layer?.kitTransition(Motion.kitQuick) }
        wantsLayer = true
        guard let status else {
            label.isHidden = true
            return
        }
        let natural = (status as NSString).size(withAttributes: [.font: Self.font]).width
        let scale = natural > Self.width ? max(0.7, Self.width / natural) : 1
        label.font = scale < 1 ? .monospacedDigitSystemFont(ofSize: 10 * scale, weight: .medium) : Self.font
        label.text = status
        label.isHidden = false
        label.kitAccess(label: status, help: status)
    }

    private func paint() {
        label.color = missed ? NSColor.systemRed.withAlphaComponent(0.8) : KitColor.muted
    }

    static func surface() -> NSView {
        let stack = KitBox(fill: nil)
        let rows: [(String, Bool)] = [("1 of 3", false), ("12 of 400+", false), ("No matches", true)]
        for (index, row) in rows.enumerated() {
            let view = FindCountView()
            view.status = row.0
            view.missed = row.1
            view.frame = NSRect(x: 4, y: 4 + CGFloat(index) * (lineHeight + 6), width: width, height: lineHeight)
            stack.addSubview(view)
        }
        stack.frame = NSRect(x: 0, y: 0, width: width + 8, height: 8 + CGFloat(rows.count) * lineHeight + CGFloat(rows.count - 1) * 6)
        return KitFixedView(stack)
    }
}
