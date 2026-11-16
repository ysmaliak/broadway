import Foundation
import Observation

struct Favorite: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var address: String?
    var action: String?
    var symbol: String?
}

@MainActor
@Observable
final class Favorites {
    static let shared = Favorites(file: Store.file("favorites.json"))

    private(set) var list: [Favorite] = []

    private let file: URL

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let read = try? JSONDecoder().decode([Favorite].self, from: data) {
            list = read
        }
    }

    private func save() {
        let snapshot = list
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }

    func contains(_ id: String) -> Bool { list.contains { $0.id == id } }

    func toggle(_ favorite: Favorite) {
        if contains(favorite.id) {
            list.removeAll { $0.id == favorite.id }
        } else {
            list.append(favorite)
        }
        save()
    }

    func remove(_ id: String) {
        guard contains(id) else { return }
        list.removeAll { $0.id == id }
        save()
    }

    @discardableResult
    func move(_ id: String, by step: Int) -> Bool {
        guard let here = list.firstIndex(where: { $0.id == id }) else { return false }
        let there = here + step
        guard list.indices.contains(there) else { return false }
        list.swapAt(here, there)
        save()
        return true
    }

    static func make(from offer: Suggestion) -> Favorite? {
        if case .action(let id) = offer.kind {
            guard !id.hasPrefix("now:"), !id.hasPrefix("page:") else { return nil }
            return Favorite(id: id, title: offer.key, detail: offer.title, address: nil, action: id,
                            symbol: offer.symbol.isEmpty ? nil : offer.symbol)
        }
        if case .command = offer.kind { return nil }
        let url = PageHit.plain(offer.url)
        guard url != FieldAction.nowhere else { return nil }
        return Favorite(id: History.identity(for: url), title: offer.primary, detail: Address.editable(url),
                        address: url.absoluteString, action: nil, symbol: nil)
    }
}

extension Browser {
    func favoriteRows() -> [Suggestion] {
        Favorites.shared.list.compactMap(favoriteRow)
    }

    private func favoriteRow(_ favorite: Favorite) -> Suggestion? {
        if let action = favorite.action {
            var row: Suggestion
            if action.hasPrefix("quick:"), let quick = QuickActions.shared.action(String(action.dropFirst("quick:".count)), history: history) {
                guard let made = quickRow(quick) else { return nil }
                row = made
            } else if action.hasPrefix("command:"), let command = Command.named(String(action.dropFirst("command:".count))) {
                guard FieldCommands.available(command, in: self) else { return nil }
                row = FieldCommands.row(command)
            } else if action.hasPrefix("quick:") {
                return nil
            } else {
                row = Suggestion(key: favorite.title, title: favorite.detail, url: FieldAction.nowhere, kind: .action(action))
                row.symbol = favorite.symbol ?? "star"
            }
            return row
        }
        guard let address = favorite.address, let url = URL(string: address) else { return nil }
        let open = tabs.first { tab in
            !tab.shy && tab.address.map { History.identity(for: $0) } == favorite.id
        }
        if let open, open.id != activeID {
            return Suggestion(key: favorite.title, title: Address.pretty(url), url: url, kind: .open, tab: open.id)
        }
        return Suggestion(key: favorite.detail, title: favorite.title, url: url, kind: .known)
    }

    func toggleFavorite() {
        guard let row = pickedOffer, let favorite = Favorites.make(from: row) else { return }
        let adding = !Favorites.shared.contains(favorite.id)
        Favorites.shared.toggle(favorite)
        announce(adding ? "Added to Favorites" : "Removed from Favorites")
        if typed.isEmpty {
            let id = favorite.id
            retype()
            if let index = offers.firstIndex(where: { Favorites.make(from: $0)?.id == id }) { picked = index }
        }
    }

    func moveFavorite(by step: Int) {
        guard let row = pickedOffer, let id = Favorites.make(from: row)?.id, Favorites.shared.move(id, by: step) else { return }
        retype()
        if let section = fieldSections.first(where: { $0.title == "Favorites" }),
           let place = Favorites.shared.list.firstIndex(where: { $0.id == id }) {
            picked = section.range.lowerBound + place
        }
    }

    func handleFavoriteKey(_ combo: KeyCombo) -> Bool {
        let store = ShortcutStore.shared
        if combo == store.key(for: "field.favorite") {
            toggleFavorite()
            return true
        }
        guard typed.isEmpty else { return false }
        if combo == store.key(for: "field.favoriteUp") {
            moveFavorite(by: -1)
            return true
        }
        if combo == store.key(for: "field.favoriteDown") {
            moveFavorite(by: 1)
            return true
        }
        return false
    }

    func addFavoriteItems(_ offer: Suggestion, into items: inout [FieldMenuItem]) {
        guard let favorite = Favorites.make(from: offer) else { return }
        let store = ShortcutStore.shared
        let held = Favorites.shared.contains(favorite.id)
        items.append(FieldMenuItem(id: "favorite", title: held ? "Remove from Favorites" : "Add to Favorites",
                                   symbol: held ? "star.slash" : "star",
                                   keys: store.key(for: "field.favorite")?.display ?? "") { [weak self] in
            self?.toggleFavorite()
        })
        guard held, typed.isEmpty, Favorites.shared.list.count > 1 else { return }
        items.append(FieldMenuItem(id: "favoriteUp", title: "Move Up", symbol: "arrow.up",
                                   keys: store.key(for: "field.favoriteUp")?.display ?? "") { [weak self] in
            self?.moveFavorite(by: -1)
        })
        items.append(FieldMenuItem(id: "favoriteDown", title: "Move Down", symbol: "arrow.down",
                                   keys: store.key(for: "field.favoriteDown")?.display ?? "") { [weak self] in
            self?.moveFavorite(by: 1)
        })
    }
}
