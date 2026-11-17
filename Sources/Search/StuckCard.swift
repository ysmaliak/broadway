import AppKit

@MainActor
final class StuckCardView: NSView {
    let tab: Tab
    private weak var browser: Browser?
    private let dim = KitBox(fill: Palette.NS.ground.withAlphaComponent(0.62))
    private let card = StuckCardPlate()
    private let glass = KitGlass(radius: 14, tint: Palette.NS.glassTint)
    private let heading = KitLabel(StuckWords.title, font: .systemFont(ofSize: 13, weight: .semibold), color: KitColor.ink)
    private let words = KitLabel(StuckWords.text, font: .systemFont(ofSize: 13), color: KitColor.ink)
    private let wait = StuckCardView.choice(StuckWords.wait, strong: false)
    private let reload = StuckCardView.choice(StuckWords.reload, strong: true)

    init(tab: Tab, browser: Browser) {
        self.tab = tab
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        dim.passesClicks = false
        heading.overflow = .middle
        words.lines = 0
        addSubview(dim)
        addSubview(card)
        card.addSubview(glass)
        card.addSubview(heading)
        card.addSubview(words)
        card.addSubview(wait)
        card.addSubview(reload)
        wait.action = { [weak self] in self?.answer(reload: false) }
        reload.action = { [weak self] in self?.answer(reload: true) }
        card.touched = { [weak browser] in browser?.focusPane(tab) }
        setEnabled(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + StuckCardView.settle) { [weak self] in self?.setEnabled(true) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(StuckWords.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static let settle: TimeInterval = 0.5

    var ready: Bool { reload.isEnabled && wait.isEnabled }

    override func mouseDown(with event: NSEvent) {
        browser?.focusPane(tab)
    }

    private func setEnabled(_ on: Bool) {
        wait.isEnabled = on
        reload.isEnabled = on
    }

    private func answer(reload: Bool) {
        browser?.focusPane(tab)
        browser?.answerStuck(tab, reload: reload)
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
        let wordsHeight = ceil(words.measure(width: inner).height)
        words.frame = NSRect(x: 14, y: y, width: inner, height: wordsHeight)
        y += wordsHeight + 12
        let reloadWidth = Self.buttonWidth(reload)
        reload.frame = NSRect(x: 14 + inner - reloadWidth, y: y, width: reloadWidth, height: 28)
        let waitWidth = Self.buttonWidth(wait)
        wait.frame = NSRect(x: reload.frame.minX - 8 - waitWidth, y: y, width: waitWidth, height: 28)
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
