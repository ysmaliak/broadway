import AppKit

@MainActor
enum KitSymbolCache {
    private struct Key: Hashable {
        let name: String
        let size: CGFloat
        let weight: CGFloat
        let scale: Int
        let fill: Bool
        let hierarchical: Bool
    }

    private static var images: [Key: NSImage] = [:]
    private static var missing: Set<Key> = []

    static func image(_ name: String, _ style: KitSymbol.Style, make: () -> NSImage?) -> NSImage? {
        guard style.palette.isEmpty else { return make() }
        let key = Key(name: name, size: style.size, weight: style.weight.rawValue, scale: style.scale.rawValue,
                      fill: style.fill, hierarchical: style.hierarchical)
        if let image = images[key] { return image }
        if missing.contains(key) { return nil }
        if images.count > 600 { images.removeAll() }
        guard let made = make() else {
            missing.insert(key)
            return nil
        }
        images[key] = made
        return made
    }
}
