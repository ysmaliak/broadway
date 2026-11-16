import AppKit

@MainActor
final class ApplePairingCardView: NSView {
    static let pad: CGFloat = 10
    static let gap: CGFloat = 8
    static let tile: CGFloat = 22

    static func width(_ spot: CGRect) -> CGFloat { max(240, min(360, spot.width)) }

    let browser: Browser
    var apple: ApplePasswords { didSet { if apple !== oldValue { needsLayout = true } } }
    var pairing: Browser.ApplePairing {
        didSet { if Self.width(pairing.spot) != Self.width(oldValue.spot) { invalidateIntrinsicContentSize(); needsLayout = true } }
    }

    private let glass = KitGlass(radius: 10, tint: Palette.NS.glassTint)
    private let tile = NSView()
    private let icon = KitSymbol("key.icloud", style: .init(size: 15, weight: IconLook.weight), tint: ApplePairingCardView.primary)
    private let content = KitFlippedView()
    static let primary = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black }
    static let secondary = NSColor(name: nil) {
        $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.302) : NSColor(white: 0, alpha: 0.4)
    }
    static let hint = NSColor(name: nil) {
        $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.487) : NSColor(white: 0, alpha: 0.5)
    }
    private let title = KitLabel("", font: .systemFont(ofSize: 13), color: ApplePairingCardView.primary)
    private let detail = KitLabel("", font: .systemFont(ofSize: 11), color: ApplePairingCardView.secondary)
    let code = KitField(placeholder: "000000", small: true, label: "Code")
    private let retry = PageKey("Try Again", kind: .primary)
    private let cancel = PageKey("Cancel", kind: .secondary)
    private var shown: ApplePasswords.State?
    private var keys: Any?

    init(browser: Browser, apple: ApplePasswords, pairing: Browser.ApplePairing) {
        self.browser = browser
        self.apple = apple
        self.pairing = pairing
        super.init(frame: .zero)
        title.lines = 0
        detail.lines = 2
        code.field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        code.field.textColor = Self.primary
        code.field.placeholderAttributedString = NSAttributedString(string: "000000", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular), .foregroundColor: Self.hint,
        ])
        for view in [title, detail, code.field] as [NSView] { view.wantsLayer = true }
        code.onChange = { [weak self] typed in self?.typed(typed) }
        code.onSubmit = { [weak self] in self?.send() }
        code.identifier = NSUserInterfaceItemIdentifier("pairing.code")
        retry.action = { [weak self] in
            guard let apple = self?.apple else { return }
            Task { await apple.connect() }
        }
        cancel.action = { [weak self] in self?.browser.endApplePairing(paired: false) }
        retry.identifier = NSUserInterfaceItemIdentifier("pairing.retry")
        cancel.identifier = NSUserInterfaceItemIdentifier("pairing.cancel")
        tile.addSubview(icon)
        addSubview(glass)
        glass.contentView = content
        for view in [tile, title, detail, code, retry, cancel] as [NSView] { content.addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Connect Apple Passwords")
        identifier = NSUserInterfaceItemIdentifier("pairing.card")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        blend()
    }

    private func blend() {
        let filter = kitDark ? "plusL" : "plusD"
        for view in [detail, code.field] as [NSView] where view.layer?.compositingFilter as? String != filter {
            view.layer?.compositingFilter = filter
        }
        let strong: String? = kitDark ? nil : "plusD"
        if title.layer?.compositingFilter as? String != strong { title.layer?.compositingFilter = strong }
    }

    private var words: (title: String, detail: String) {
        switch apple.state {
        case .idle: return (apple.trouble ?? "Not connected", "Apple Passwords")
        case .starting: return ("Connecting to Apple Passwords…", "Your Mac shows a six-digit code in a moment")
        case .code: return ("Enter the code your Mac shows", "Six digits, from the Passwords window. Once per launch of Broadway.")
        case .checking: return ("Checking…", "Six digits, from the Passwords window. Once per launch of Broadway.")
        case .paired: return ("Connected", "Apple Passwords")
        }
    }

    private var typing: Bool { apple.state == .code || apple.state == .checking }
    private var retries: Bool { apple.state == .idle && apple.signing.mayStart }

    private func textWidth(_ width: CGFloat) -> CGFloat { width - Self.pad * 2 - Self.tile - Self.gap * 2 }

    private func titleHeight(_ width: CGFloat) -> CGFloat { ceil(title.measure(width: textWidth(width)).height) }

    private func wordsHeight(_ width: CGFloat) -> CGFloat {
        let line = ceil(detail.measure(width: .greatestFiniteMagnitude).height)
        return titleHeight(width) + 1 + min(ceil(detail.measure(width: textWidth(width)).height), line * 2)
    }

    private var controlsHeight: CGFloat { typing ? KitField.height(small: true) : 22 }

    override var intrinsicContentSize: NSSize {
        let width = Self.width(pairing.spot)
        apply()
        let top = max(Self.tile, wordsHeight(width))
        return NSSize(width: width, height: Self.pad + top + Self.gap + controlsHeight + Self.pad)
    }

    private func apply() {
        let said = words
        if title.text != said.title { title.text = said.title }
        if detail.text != said.detail { detail.text = said.detail }
    }

    override func layout() {
        super.layout()
        let state = apple.state
        apply()
        blend()
        if state != shown {
            let first = shown == nil
            shown = state
            code.text = ""
            if state == .code { focusCode(later: first) }
            invalidateIntrinsicContentSize()
        }
        let width = bounds.width
        glass.frame = bounds
        content.frame = glass.bounds
        let words = wordsHeight(width)
        let top = max(Self.tile, words)
        tile.frame = kitSnap(NSRect(x: Self.pad, y: Self.pad + (top - Self.tile) / 2 + 0.5, width: Self.tile, height: Self.tile))
        icon.frame = tile.bounds
        let x = Self.pad + Self.tile + Self.gap
        let titleHeight = titleHeight(width)
        let y = Self.pad + (top - words) / 2
        title.frame = kitSnap(NSRect(x: x, y: y, width: textWidth(width), height: titleHeight))
        detail.frame = kitSnap(NSRect(x: x, y: y + titleHeight + 1, width: textWidth(width), height: words - titleHeight - 1))
        let row = Self.pad + top + Self.gap
        let height = controlsHeight
        code.isHidden = !typing
        code.isEnabled = state != .checking
        retry.isHidden = typing || !retries
        code.frame = kitSnap(NSRect(x: Self.pad, y: row + (height - KitField.height(small: true)) / 2, width: 84, height: KitField.height(small: true)))
        let retrySize = retry.intrinsicContentSize
        retry.frame = kitSnap(NSRect(x: Self.pad, y: row + (height - 22) / 2, width: retrySize.width, height: 22))
        let cancelSize = cancel.intrinsicContentSize
        cancel.frame = kitSnap(NSRect(x: width - Self.pad - cancelSize.width, y: row + (height - 22) / 2, width: cancelSize.width, height: 22))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        guard window != nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === window, holdsKeys else { return event }
            browser.endApplePairing(paired: false)
            return nil
        }
        if apple.state == .code { focusCode(later: true) }
    }

    private var holdsKeys: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let editor = responder as? NSTextView, editor.isFieldEditor, (editor.delegate as? NSView)?.isDescendant(of: self) == true { return true }
        return (responder as? NSView)?.isDescendant(of: self) == true
    }

    override func cancelOperation(_ sender: Any?) {
        browser.endApplePairing(paired: false)
    }

    private func focusCode(later: Bool) {
        let focus = { [weak self] in
            guard let self, let window, !code.isHidden else { return }
            window.makeFirstResponder(code.field)
        }
        if later { DispatchQueue.main.async(execute: focus) } else { focus() }
    }

    private func typed(_ text: String) {
        let digits = String(text.filter(\.isNumber).prefix(6))
        if digits != text { code.text = digits }
        if digits.count == 6 { send() }
    }

    private func send() {
        let typed = code.text
        guard typed.count == 6, apple.state == .code else { return }
        code.text = ""
        let apple = apple
        Task { await apple.enter(typed) }
    }
}

final class PageKey: KitButton {
    init(_ title: String, kind: Kind) {
        super.init(.keycap(kind), label: title)
        let ink = kind == .primary ? NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white } : KitColor.ink
        content = KitLabel(title, font: .systemFont(ofSize: 12, weight: kind == .primary ? .semibold : .regular), color: ink)
        padding = 9
        height = 22
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        guard let label = content as? KitLabel else { return super.intrinsicContentSize }
        return NSSize(width: label.pixelWidth + padding * 2, height: height ?? 22)
    }

    override func layout() {
        super.layout()
        guard let label = content as? KitLabel else { return }
        let width = min(bounds.width - padding * 2, label.pixelWidth)
        let height = label.intrinsicContentSize.height
        label.frame = kitSnap(NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height))
    }
}
