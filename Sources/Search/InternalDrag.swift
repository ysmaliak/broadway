import AppKit
import UniformTypeIdentifiers

enum InternalDrag {
    static let folder = UTType(exportedAs: "com.ysmaliak.broadway.drag.folder")
    static let bookmark = UTType(exportedAs: "com.ysmaliak.broadway.drag.bookmark")
    static let all = [folder, bookmark]
    static let oldPrefixes = ["search-group:"]

    static func provider(_ type: UTType, _ id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { done in
            done(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    static func carries(_ provider: NSItemProvider, _ type: UTType) -> Bool {
        provider.hasItemConformingToTypeIdentifier(type.identifier)
    }

    static func isInternal(_ provider: NSItemProvider) -> Bool {
        all.contains { carries(provider, $0) }
    }

    static func isInternal(_ text: String) -> Bool {
        oldPrefixes.contains { text.hasPrefix($0) }
    }

    static func load(_ provider: NSItemProvider, _ type: UTType, _ done: @escaping @MainActor (UUID) -> Void) {
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(id) } }
        }
    }
}

enum FolderDrop {
    struct Place: Equatable {
        var pinned: Bool
        var before: Browser.ListItem?
    }

    static func place(y: CGFloat, rowsTop: CGFloat, raised: [(id: UUID, rect: CGRect)],
                      items: [(item: Browser.ListItem, rect: CGRect)], moving: UUID?) -> Place {
        let boundary = raised.map(\.rect.maxY).max() ?? rowsTop
        if y < boundary + 4 {
            let next = raised.filter { $0.id != moving }.sorted { $0.rect.minY < $1.rect.minY }.first { y < $0.rect.midY }
            return Place(pinned: true, before: next.map { .folder($0.id) })
        }
        let next = items.filter { $0.item != moving.map { .folder($0) } }.sorted { $0.rect.minY < $1.rect.minY }.first { y < $0.rect.midY }
        return Place(pinned: false, before: next?.item)
    }

    static func line(for place: Place, raised: [(id: UUID, rect: CGRect)],
                     items: [(item: Browser.ListItem, rect: CGRect)], gap: CGFloat) -> CGFloat? {
        if place.pinned {
            if case .folder(let id)? = place.before, let rect = raised.first(where: { $0.id == id })?.rect {
                return above(rect, among: raised.map(\.rect), gap: gap)
            }
            return raised.map(\.rect.maxY).max().map { $0 + gap / 2 }
        }
        if let before = place.before, let rect = items.first(where: { $0.item == before })?.rect {
            return above(rect, among: items.map(\.rect), gap: gap)
        }
        return items.map(\.rect.maxY).max().map { $0 + gap / 2 }
    }

    private static func above(_ rect: CGRect, among rects: [CGRect], gap: CGFloat) -> CGFloat {
        guard let end = rects.map(\.maxY).filter({ $0 <= rect.minY + 0.5 }).max() else { return rect.minY - gap / 2 }
        return (end + rect.minY) / 2
    }
}

extension Browser {
    func dropOnColumn(_ providers: [NSItemProvider], folderPlace: @escaping @MainActor (UUID) -> FolderDrop.Place) -> Bool {
        if let provider = providers.first(where: { InternalDrag.carries($0, InternalDrag.folder) }) {
            InternalDrag.load(provider, InternalDrag.folder) { [weak self] id in
                guard let self, self.tabGroups.contains(where: { $0.id == id }) else { return }
                let place = folderPlace(id)
                self.placeFolder(id, pinned: place.pinned, before: place.before)
            }
            return true
        }
        return take(providers)
    }
}
