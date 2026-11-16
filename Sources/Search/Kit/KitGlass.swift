import AppKit

final class KitGlass: NSGlassEffectView {
    var capsule = false { didSet { needsLayout = true } }

    init(radius: CGFloat = 0, tint: NSColor? = nil, style: NSGlassEffectView.Style = .regular, interactive: Bool = false) {
        super.init(frame: .zero)
        cornerRadius = radius
        tintColor = tint
        self.style = style
        effectIsInteractive = interactive
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if capsule { cornerRadius = min(bounds.width, bounds.height) / 2 }
    }

    static func keyTint(_ kind: KitButton.Kind, dark: Bool) -> NSColor {
        switch kind {
        case .primary: return dark ? NSColor(white: 1, alpha: 0.86) : NSColor(white: 0, alpha: 0.78)
        case .secondary: return dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.05)
        case .destructive: return NSColor.systemRed.withAlphaComponent(0.85)
        }
    }

    static func keyInk(_ kind: KitButton.Kind, dark: Bool, lit: Bool = false, pressed: Bool = false) -> NSColor? {
        switch kind {
        case .primary: return KitPill.fill(.primary, dark: dark, lit: lit, pressed: pressed)
        case .secondary: return nil
        case .destructive: return NSColor.systemRed.withAlphaComponent(pressed ? 0.72 : lit ? 0.95 : 0.85)
        }
    }

    static func trackTint(dark: Bool) -> NSColor {
        NSColor(white: 0, alpha: dark ? 0.18 : 0.06)
    }

    static func thumbTint(dark: Bool) -> NSColor {
        NSColor(white: 1, alpha: dark ? 0.26 : 0.8)
    }
}
