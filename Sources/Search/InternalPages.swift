import AppKit

struct InternalPage: Equatable {
    enum Kind: String, CaseIterable {
        case settings, history, downloads, files, bookmarks, passwords
        case importing = "import"
    }

    var kind: Kind
    var detail: String?

    init(_ kind: Kind, _ detail: String? = nil) {
        self.kind = kind
        self.detail = detail?.isEmpty == true ? nil : detail
    }

    static let scheme = "broadway"

    init?(url: URL) {
        guard url.scheme?.lowercased() == InternalPage.scheme,
              let host = url.host()?.lowercased(), let kind = Kind(rawValue: host)
        else { return nil }
        let rest = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.init(kind, rest)
    }

    static func retired(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == scheme else { return false }
        return InternalPage(url: url).map { $0.kind == .downloads } ?? true
    }

    var url: URL {
        var text = "\(InternalPage.scheme)://\(kind.rawValue)"
        if let detail, let path = detail.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            text += "/" + path
        }
        return URL(string: text) ?? URL(string: "\(InternalPage.scheme)://\(kind.rawValue)")!
    }

    var title: String {
        switch kind {
        case .settings: return "Settings"
        case .history: return "History"
        case .downloads: return "Downloads"
        case .files: return "Files"
        case .bookmarks: return "Bookmarks"
        case .passwords: return "Passwords"
        case .importing: return "Bring Things Over"
        }
    }

    var symbol: String {
        switch kind {
        case .settings: return "gearshape"
        case .history: return "clock"
        case .downloads: return "arrow.down.circle"
        case .files: return "doc.on.doc"
        case .bookmarks: return "book"
        case .passwords: return "key"
        case .importing: return "square.and.arrow.down"
        }
    }

    static let glyphSide: CGFloat = 14
    static let glyphSize: CGFloat = 13
    @MainActor private static var glyphs: [Kind: NSImage] = [:]

    @MainActor var glyph: NSImage? {
        if let held = Self.glyphs[kind] { return held }
        guard let drawn = KitGlyph.made(symbol, KitSymbol.Style(size: Self.glyphSize, weight: IconLook.weight)) else { return nil }
        let side = Self.glyphSide
        let ink = KitGlyph.ink(of: drawn)
        let scale = min(1, side / max(ink.width, ink.height, 0.01))
        let left = ((side - ink.width * scale) / 2 * 2).rounded() / 2
        let bottom = ((side - ink.height * scale) / 2 * 2).rounded() / 2
        let frame = NSRect(x: left - ink.minX * scale, y: bottom - ink.minY * scale,
                           width: drawn.size.width * scale, height: drawn.size.height * scale)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            drawn.draw(in: frame)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = title
        Self.glyphs[kind] = image
        return image
    }
}
