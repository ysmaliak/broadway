import AppKit

enum WelcomeShadow {
    static func apply(_ layer: CALayer?, colour: NSColor = .black, opacity: Swift.Float, radius: CGFloat, y: CGFloat, path: CGPath? = nil) {
        guard let layer else { return }
        layer.shadowColor = colour.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = radius
        layer.shadowOffset = CGSize(width: 0, height: y)
        layer.shadowPath = path
    }

    static func apply(_ view: NSView, colour: NSColor = .black, opacity: CGFloat, radius: CGFloat, y: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowColor = colour.withAlphaComponent(opacity)
        shadow.shadowBlurRadius = radius
        shadow.shadowOffset = NSSize(width: 0, height: view.isFlipped ? y : -y)
        view.wantsLayer = true
        view.shadow = shadow
    }
}

enum WelcomeFonts {
    static func serif(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .heavy).fontDescriptor
        let traits: [NSFontDescriptor.TraitKey: Any] = [.weight: NSFont.Weight.heavy.rawValue,
                                                       .symbolic: NSFontDescriptor.SymbolicTraits.italic.rawValue]
        let serif = (base.withDesign(.serif) ?? base).addingAttributes([.traits: traits])
        return NSFont(descriptor: serif, size: size) ?? .systemFont(ofSize: size, weight: .heavy)
    }
}

struct SeededDots {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}
