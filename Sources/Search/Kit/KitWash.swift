import AppKit

struct KitWash: Equatable {
    let light: CGFloat
    let dark: CGFloat

    func alpha(dark isDark: Bool) -> CGFloat { isDark ? dark : light }

    func color(dark isDark: Bool, plus: CGFloat = 0) -> NSColor {
        NSColor(white: isDark ? 1 : 0, alpha: alpha(dark: isDark) + plus)
    }

    func color(plus: CGFloat = 0) -> NSColor {
        KitForm.wash(light: light + plus, dark: dark + plus)
    }

    static let control = KitWash(light: 0.063, dark: 0.1)
    static let controlInk = KitWash(light: 0.86, dark: 0.9)
    static let controlOff = KitWash(light: 0.12, dark: 0.16)
    static let track = KitWash(light: 0.055, dark: 0.075)
    static let plate = KitWash(light: 0.08, dark: 0.14)
}
