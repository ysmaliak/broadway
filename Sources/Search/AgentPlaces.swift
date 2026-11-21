import Foundation

enum AgentPlaceWhy: Equatable {
    case asked
    case setting
    case learned
    case moved
    case named(String)
    case front
}

struct AgentPlace: Equatable {
    var space: UUID?
    var why: AgentPlaceWhy
}

struct AgentWish: Equatable {
    var folder: String?
    var space: String?

    init(folder: String? = nil, space: String? = nil) {
        self.folder = folder.flatMap { $0.isEmpty ? nil : $0 }
        self.space = space.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
    }

    init(_ said: [String: Any]) {
        self.init(folder: said["folder"] as? String ?? said["cwd"] as? String, space: said["space"] as? String)
    }
}

struct AgentSpaceName: Equatable {
    var id: UUID
    var name: String
}

@MainActor
final class AgentPlaces {
    static let shared = AgentPlaces(store: Store.settings)
    static let key = "agents.folderSpaces"
    static let most = 200

    private let store: UserDefaults?
    private var memory: [String: [String: Any]] = [:]

    init(store: UserDefaults?) {
        self.store = store
    }

    private var all: [String: [String: Any]] {
        get { store.map { $0.dictionary(forKey: Self.key) as? [String: [String: Any]] ?? [:] } ?? memory }
        set {
            if let store { store.set(newValue, forKey: Self.key) } else { memory = newValue }
        }
    }

    func learned(_ folder: String?) -> UUID? {
        guard let folder, let id = all[folder]?["space"] as? String else { return nil }
        return UUID(uuidString: id)
    }

    func learn(_ folder: String?, _ space: UUID, at now: Date = Date()) {
        guard let folder, !folder.isEmpty else { return }
        var kept = all
        kept[folder] = ["space": space.uuidString, "at": now.timeIntervalSinceReferenceDate]
        if kept.count > Self.most {
            let oldest = kept.sorted { ($0.value["at"] as? Double ?? 0) < ($1.value["at"] as? Double ?? 0) }
            for (key, _) in oldest.prefix(kept.count - Self.most) { kept[key] = nil }
        }
        all = kept
    }

    func forget(_ folder: String) {
        var kept = all
        kept[folder] = nil
        all = kept
    }

    nonisolated static func choose(_ wish: AgentWish, spaces: [AgentSpaceName]?, learned: UUID?, front: UUID?,
                                   home: String = NSHomeDirectory()) -> AgentPlace {
        guard let spaces, spaces.count > 1 else { return AgentPlace(space: front, why: .front) }
        if let asked = wish.space, let found = spaces.first(where: { $0.name.lowercased() == asked.lowercased() }) {
            return AgentPlace(space: found.id, why: .setting)
        }
        if let learned, spaces.contains(where: { $0.id == learned }) {
            return AgentPlace(space: learned, why: .learned)
        }
        if let folder = wish.folder, let found = named(folder, spaces: spaces, home: home) {
            return AgentPlace(space: found.id, why: .named(found.shown))
        }
        return AgentPlace(space: front, why: .front)
    }

    nonisolated static func named(_ folder: String, spaces: [AgentSpaceName], home: String) -> (id: UUID, shown: String)? {
        let parts = below(folder, home: home)
        var found: [UUID: String] = [:]
        for space in spaces {
            let wanted = words(space.name)
            guard !wanted.isEmpty, let at = parts.list.firstIndex(where: { words($0) == wanted }) else { continue }
            found[space.id] = parts.lead + parts.list[...at].joined(separator: "/")
        }
        guard found.count == 1, let only = found.first else { return nil }
        return (only.key, only.value)
    }

    nonisolated static func below(_ folder: String, home: String) -> (lead: String, list: [String]) {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        if !base.isEmpty, folder.hasPrefix(base + "/") {
            return ("~/", folder.dropFirst(base.count + 1).split(separator: "/").map(String.init))
        }
        return ("/", folder.split(separator: "/").map(String.init))
    }

    nonisolated static func words(_ text: String) -> [String] {
        text.lowercased().split { $0.isWhitespace || $0 == "-" || $0 == "_" }.map(String.init)
    }

    nonisolated static func find(_ named: String, in spaces: [AgentSpaceName]) -> [AgentSpaceName] {
        let lower = named.trimmingCharacters(in: .whitespaces).lowercased()
        let exact = spaces.filter { $0.name.lowercased() == lower }
        if !exact.isEmpty { return exact }
        return spaces.filter { $0.name.lowercased().hasPrefix(lower) }
    }

    nonisolated static func line(_ placed: Any?, how: String = "open with space") -> String? {
        guard let placed = placed as? [String: Any], placed["first"] as? Bool == true,
              let name = placed["name"] as? String, let why = placed["why"] as? String else { return nil }
        if why == reason(.asked, onScreen: true) {
            return placed["kept"] as? Bool == true ? "In \(name), as asked. This folder's tabs go there from now on" : "In \(name), as asked"
        }
        return "In \(name), \(why). For another space, and for this folder from then on: \(how)"
    }

    nonisolated static func reason(_ why: AgentPlaceWhy, onScreen: Bool) -> String {
        switch why {
        case .asked: return "as asked"
        case .setting: return "from BROADWAY_SPACE"
        case .learned: return "where this folder's sessions go"
        case .moved: return "where the person moved your tab"
        case .named(let shown): return "matching \(shown)"
        case .front: return onScreen ? "the space on screen" : "the space on screen when you connected"
        }
    }
}
