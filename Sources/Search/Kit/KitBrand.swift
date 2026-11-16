import AppKit

enum KitBrand {
    static let blue = NSColor(srgbRed: 0x31 / 255, green: 0x39 / 255, blue: 0xFB / 255, alpha: 1)
    static let red = NSColor(srgbRed: 0xFB / 255, green: 0x3A / 255, blue: 0x4D / 255, alpha: 1)
    static let cream = NSColor(srgbRed: 0xFF / 255, green: 0xFC / 255, blue: 0xEC / 255, alpha: 1)
    static let night = NSColor(srgbRed: 0x00 / 255, green: 0x03 / 255, blue: 0x54 / 255, alpha: 1)
    static let pink = NSColor(srgbRed: 0xFF / 255, green: 0x89 / 255, blue: 0xB3 / 255, alpha: 1)
    static let lilac = NSColor(srgbRed: 0xF0 / 255, green: 0xB4 / 255, blue: 0xFF / 255, alpha: 1)
    static let sky = NSColor(srgbRed: 0x8C / 255, green: 0xAC / 255, blue: 0xFF / 255, alpha: 1)

    static let confetti: [NSColor] = [blue, red, pink, lilac, sky, cream]
}
