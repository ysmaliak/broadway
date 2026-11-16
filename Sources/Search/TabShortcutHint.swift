import AppKit

final class ShortcutNumberView: NSView {
    static let side: CGFloat = 15

    var number: Int { didSet { if number != oldValue { refresh() } } }
    var ink: KitInk = .flat { didSet { label.ink = ink } }

    private let label = KitLabel()

    init(number: Int) {
        self.number = number
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.color = KitColor.ink
        label.opacity = 0.65
        label.alignment = .center
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        label.frame = bounds
    }

    private func refresh() {
        label.text = String(number)
        setAccessibilityLabel("Command \(number)")
    }
}
