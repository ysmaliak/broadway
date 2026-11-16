import AppKit

extension KitButton {
    static func pill(_ title: String, kind: Kind = .secondary, font: NSFont, height: CGFloat, padding: CGFloat,
                     action: (() -> Void)? = nil) -> KitButton {
        let button = KitButton(.pill(kind), label: title, action: action)
        let label = KitLabel(title, font: font, color: kind == .destructive ? .systemRed : KitColor.ink)
        label.setAccessibilityElement(false)
        button.content = label
        button.height = height
        button.padding = padding
        return button
    }
}
