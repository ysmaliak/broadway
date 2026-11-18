import AppKit

struct KitInk: Equatable {
    enum Kind: Equatable {
        case plain, ink, title, quiet
        case stronger(Double)
    }

    var lift: Double = 0
    var glass = false

    static let flat = KitInk()

    func onGlass(_ on: Bool) -> KitInk {
        guard on != glass else { return self }
        var next = self
        next.glass = on
        return next
    }

    func color(_ base: NSColor, _ kind: Kind = .plain, opacity: Double = 1, dark: Bool) -> NSColor {
        if glass, let strong = KitColor.onGlass(base) {
            let resolved = strong.kitResolved(dark: dark)
            return resolved.withAlphaComponent(resolved.alphaComponent * CGFloat(opacity))
        }
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
    static func onGlass(_ base: NSColor) -> NSColor? {
        if base === muted { return glassMuted }
        if base === faint { return glassFaint }
        return nil
    }

    static let ink = Palette.NS.ink
    static let muted = Palette.NS.muted
    static let faint = Palette.NS.faint
    static let hairline = Palette.NS.hairline
    static let ground = Palette.NS.ground
    static let title = Palette.NS.ink.withAlphaComponent(Paint.title)
    static let glassMuted = Palette.NS.glassMuted
    static let glassFaint = Palette.NS.glassFaint
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

protocol KitOnGlass: NSView {}

extension NSView {
    var kitOnGlass: Bool {
        var view = superview
        while let next = view {
            if next is KitGlassGround || next is KitOnGlass { return true }
            view = next.superview
        }
        return false
    }

    var kitDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
