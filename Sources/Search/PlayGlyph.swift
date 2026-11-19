import AppKit
import Symbols

final class PlayGlyph: NSImageView {
    static let sidebar = KitSymbol.Style(size: 11, weight: .bold)
    static let float = KitSymbol.Style(size: 21, weight: .semibold)

    let style: KitSymbol.Style
    var tint: NSColor? { didSet { if tint != oldValue { contentTintColor = tint } } }
    private(set) var name = ""
    private(set) var replaced = 0
    private(set) var played: ReplaceSymbolEffect?

    init(style: KitSymbol.Style, tint: NSColor? = nil) {
        self.style = style
        self.tint = tint
        super.init(frame: .zero)
        imageScaling = .scaleNone
        imageAlignment = .alignCenter
        contentTintColor = tint
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    var drawn: NSRect {
        guard let size = image?.size else { return .zero }
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    func show(_ name: String, animated: Bool) {
        guard let next = KitGlyph.image(name, style) else { return }
        self.name = name
        if animated, kitReplaces {
            replaced += 1
            played = kitReplace(with: next)
        } else {
            image = next
        }
    }
}
