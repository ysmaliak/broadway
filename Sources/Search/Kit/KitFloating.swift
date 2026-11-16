import AppKit

extension KitGlass {
    static func floating(radius: CGFloat = 0, capsule: Bool = false, interactive: Bool = false) -> KitGlass {
        let glass = KitGlass(radius: radius, tint: Palette.NS.glassTint, interactive: interactive)
        glass.capsule = capsule
        return glass
    }

    func hold(_ view: NSView) {
        contentView = view
    }
}
