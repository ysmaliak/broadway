import AppKit

struct KitInk: Equatable {
    enum Kind: Equatable {
        case plain, ink, title, quiet
        case stronger(Double)
    }

    var lift: Double = 0

    static let flat = KitInk()

    func color(_ base: NSColor, _ kind: Kind = .plain, opacity: Double = 1, dark: Bool) -> NSColor {
        let resolved = base.kitResolved(dark: dark)
        let alpha = Double(resolved.alphaComponent)
        guard lift > 0, kind != .plain else { return resolved.withAlphaComponent(CGFloat(alpha * opacity)) }
        let level = CGFloat(Swift.Float(Paint.ink(light: dark, lift: lift)))
        func ink(_ value: Double) -> NSColor {
            NSColor(srgbRed: level, green: level, blue: level, alpha: CGFloat(Swift.Float(min(1, value))) * CGFloat(opacity))
        }
        switch kind {
        case .plain: return resolved
        case .ink: return ink(alpha)
        case .title: return ink(Paint.titleAlpha(lift))
        case .quiet: return ink(alpha + (Paint.liftedQuiet - alpha) * lift)
        case .stronger(let gain):
            return resolved.withAlphaComponent(CGFloat(Swift.Float(min(1, alpha * (1 + gain * lift)))) * CGFloat(opacity))
        }
    }
}

enum KitColor {
    static let ink = Palette.NS.ink
    static let muted = Palette.NS.muted
    static let faint = Palette.NS.faint
    static let hairline = Palette.NS.hairline
    static let ground = Palette.NS.ground
    static let title = Palette.NS.ink.withAlphaComponent(Paint.title)
    static let dim: CGFloat = 0.16

    static func kind(of base: NSColor) -> KitInk.Kind {
        if base === ink || base === Palette.NS.inkStrong { return .ink }
        if base === title { return .title }
        if base === muted { return .quiet }
        if base === faint || base === hairline { return .stronger(0.6) }
        return .plain
    }
}

extension NSColor {
    func kitResolved(dark: Bool) -> NSColor {
        var out = self
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            out = self.usingColorSpace(.sRGB) ?? self
        }
        return out
    }
}

extension NSView {
    var kitDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
