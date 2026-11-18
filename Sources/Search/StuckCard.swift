import AppKit

struct TabCardWords {
    let title: String
    let text: String
    let other: String
    let main: String
    let keys: Bool

    static let stuck = TabCardWords(title: StuckWords.title, text: StuckWords.text, other: StuckWords.wait, main: StuckWords.reload, keys: false)
    static let leave = TabCardWords(title: LeaveWords.title, text: LeaveWords.text, other: LeaveWords.leave, main: LeaveWords.stay, keys: true)
}

@MainActor
final class StuckCardView: NSView {
    let tab: Tab
    let words: TabCardWords
    private weak var browser: Browser?
    private let answered: (Bool) -> Void
    private let dim = KitBox(fill: Palette.NS.ground.withAlphaComponent(0.62))
    private let card = StuckCardPlate()
    private let glass = KitGlass.floating(radius: 14)
    private let heading: KitLabel
    private let text: KitLabel
    private let other: KitButton
    private let main: KitButton

    convenience init(tab: Tab, browser: Browser) {
        self.init(tab: tab, browser: browser, words: .stuck) { [weak browser] main in browser?.answerStuck(tab, reload: main) }
    }

    init(tab: Tab, browser: Browser, words: TabCardWords, answered: @escaping (Bool) -> Void) {
        self.tab = tab
        self.words = words
        self.browser = browser
        self.answered = answered
        heading = KitLabel(words.title, font: .systemFont(ofSize: 13, weight: .semibold), color: KitColor.ink)
        text = KitLabel(words.text, font: .systemFont(ofSize: 13), color: KitColor.ink)
        other = StuckCardView.choice(words.other, strong: false)
        main = StuckCardView.choice(words.main, strong: true)
        super.init(frame: .zero)
        wantsLayer = true
        dim.passesClicks = false
        heading.overflow = .middle
        text.lines = 0
        addSubview(dim)
        addSubview(card)
        card.addSubview(glass)
        card.addSubview(heading)
        card.addSubview(text)
        card.addSubview(other)
        card.addSubview(main)
        other.action = { [weak self] in self?.answer(main: false) }
        main.action = { [weak self] in self?.answer(main: true) }
        card.touched = { [weak browser] in browser?.focusPane(tab) }
        setEnabled(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + StuckCardView.settle) { [weak self] in self?.setEnabled(true) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(words.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static let settle: TimeInterval = 0.5

    var ready: Bool { main.isEnabled && other.isEnabled }

    override var acceptsFirstResponder: Bool { words.keys }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard words.keys, let window else { return }
        window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard words.keys, [36, 53, 76].contains(event.keyCode) else { return super.keyDown(with: event) }
        if ready { answer(main: true) }
    }

    override func cancelOperation(_ sender: Any?) {
        guard words.keys else { return }
        if ready { answer(main: true) }
    }

    override func mouseDown(with event: NSEvent) {
        browser?.focusPane(tab)
    }

    private func setEnabled(_ on: Bool) {
        other.isEnabled = on
        main.isEnabled = on
    }

    private func answer(main: Bool) {
        browser?.focusPane(tab)
        answered(main)
    }

    private static func choice(_ title: String, strong: Bool) -> KitButton {
        let button = KitButton(title: title, font: .systemFont(ofSize: 13, weight: strong ? .semibold : .regular),
                               look: .keycap(strong ? .primary : .secondary))
        button.padding = 12
        button.height = 28
        button.kitAccess(label: title, role: .button)
        return button
    }

    private static func buttonWidth(_ button: KitButton) -> CGFloat {
        max(64, ceil(button.intrinsicContentSize.width))
    }

    override func layout() {
        super.layout()
        dim.frame = bounds
        let cardWidth = min(380, max(0, bounds.width - 32))
        let inner = max(0, cardWidth - 28)
        var y: CGFloat = 14
        let headingHeight = heading.intrinsicContentSize.height
        heading.frame = NSRect(x: 14, y: y, width: inner, height: headingHeight)
        y += headingHeight + 10
        let wordsHeight = ceil(text.measure(width: inner).height)
        text.frame = NSRect(x: 14, y: y, width: inner, height: wordsHeight)
        y += wordsHeight + 12
        let mainWidth = Self.buttonWidth(main)
        main.frame = NSRect(x: 14 + inner - mainWidth, y: y, width: mainWidth, height: 28)
        let otherWidth = Self.buttonWidth(other)
        other.frame = NSRect(x: main.frame.minX - 8 - otherWidth, y: y, width: otherWidth, height: 28)
        y += 28 + 14
        card.frame = kitSnap(NSRect(x: (bounds.width - cardWidth) / 2, y: 56, width: cardWidth, height: y))
        glass.frame = card.bounds
    }
}

private final class StuckCardPlate: NSView {
    var touched: (() -> Void)?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        touched?()
    }
}
