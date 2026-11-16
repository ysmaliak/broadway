import AppKit

enum AppIcon: String, CaseIterable, Identifiable {
    case ink, night, day, volt, citrus

    static let key = "app.icon"
    static let bakedKey = "BroadwayAppIcon"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .night: return "Night"
        case .day: return "Day"
        case .ink: return "Ink"
        case .volt: return "Volt"
        case .citrus: return "Citrus"
        }
    }

    var brand: NSColor {
        switch self {
        case .night: return NSColor(srgbHex: 0xFFC72C)
        case .day, .ink: return KitColor.ink
        case .volt: return NSColor(srgbHex: 0x3B33FF)
        case .citrus: return NSColor(srgbHex: 0xF7C21A)
        }
    }

    static func named(_ raw: String?) -> AppIcon {
        raw.flatMap(AppIcon.init(rawValue:)) ?? .ink
    }
}

@MainActor
enum AppIconShown {
    static let changed = Notification.Name("AppIconShown.changed")

    static var folder: URL? = Bundle.main.resourceURL?.appendingPathComponent("Icons", isDirectory: true) {
        didSet { pictures = [:] }
    }
    static var baked = AppIcon.named(Bundle.main.object(forInfoDictionaryKey: AppIcon.bakedKey) as? String)
    static var shown: NSImage?
    private(set) static var current: AppIcon?
    private static var pictures: [AppIcon: NSImage] = [:]

    static func picture(_ icon: AppIcon) -> NSImage? {
        if let kept = pictures[icon] { return kept }
        guard let file = folder?.appendingPathComponent(icon.rawValue + ".png"), let image = NSImage(contentsOf: file) else { return nil }
        pictures[icon] = image
        return image
    }

    static func apply(_ icon: AppIcon) {
        let image = icon == baked ? (shown == nil ? nil : picture(baked)) : picture(icon)
        current = icon
        shown = image
        NSApplication.shared.applicationIconImage = image
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

extension NSColor {
    convenience init(srgbHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
