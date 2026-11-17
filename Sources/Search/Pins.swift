import Foundation

struct PinDef: Codable, Equatable {
    var id: UUID
    var letter: String
    /// The page it was pinned at (see Browser.goHome).
    var home: String
    var title: String
    var name: String?
    var icon: TabIcon? = nil
    var split: PinSplit? = nil

    var lasting: Bool { URL(string: home).map { !InternalPage.retired($0) } ?? true }
}

extension PinDef {
    private enum Keys: String, CodingKey { case id, letter, home, title, name, icon, split }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        letter = try c.decode(String.self, forKey: .letter)
        home = try c.decode(String.self, forKey: .home)
        title = try c.decode(String.self, forKey: .title)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        icon = try c.decodeIfPresent(TabIcon.self, forKey: .icon)
        split = try? c.decodeIfPresent(PinSplit.self, forKey: .split)
    }
}

@MainActor
enum Pins {
    /// Pins by space, in their order.
    private(set) static var bySpace: [UUID: [PinDef]] = [:]
    private static var sharedPins: [PinDef] = []
    private static var loaded = false

    /// A space's pins changed in one window; the others follow.
    static let changed = Notification.Name("SearchPinsChanged")

    /// Where pins.json keeps the shared pins, beside the spaces' ids.
    nonisolated static let sharedKey = "shared"

    private static var file: URL { Store.file("pins.json") }

    static func defs(_ space: UUID) -> [PinDef] {
        load()
        return bySpace[space] ?? []
    }

    static func shared() -> [PinDef] {
        load()
        return sharedPins
    }

    /// Read once. Before there is a pins.json, the pins are the oldest
    /// window's, from its session files — every space's.
    static func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: file), let saved = decode(data) {
            bySpace = saved.bySpace.compactMapValues { defs in
                let kept = PinSplit.whole(defs.filter(\.lasting))
                return kept.isEmpty ? nil : kept
            }
            sharedPins = PinSplit.whole(saved.shared.filter(\.lasting))
            if bySpace != saved.bySpace || sharedPins != saved.shared { save() }
            return
        }
        for space in Spaces.read() {
            let defs = Session.read(space: space.id).tabs.compactMap { entry -> PinDef? in
                guard let letter = entry.pin else { return nil }
                return PinDef(id: entry.pinID ?? UUID(), letter: letter, home: entry.home ?? entry.url,
                              title: entry.title, name: entry.name, icon: entry.icon)
            }
            if !defs.isEmpty { bySpace[space.id] = defs }
        }
        save()
    }

    /// A window's pins for a space, as they now are: kept, written, and
    /// passed to the other windows when they differ from what was there.
    static func set(_ space: UUID, _ defs: [PinDef], from browser: Browser) {
        load()
        guard (bySpace[space] ?? []) != defs else { return }
        bySpace[space] = defs.isEmpty ? nil : defs
        save()
        NotificationCenter.default.post(name: changed, object: browser, userInfo: ["space": space])
    }

    /// The shared pins as they now are, passed to the other windows, which
    /// take them into every space they hold. True when they changed.
    @discardableResult
    static func setShared(_ defs: [PinDef], from browser: Browser) -> Bool {
        load()
        guard sharedPins != defs else { return false }
        sharedPins = defs
        save()
        NotificationCenter.default.post(name: changed, object: browser, userInfo: ["shared": true])
        return true
    }

    /// A space deleted: its pins go with it.
    static func forget(_ space: UUID) {
        guard bySpace.removeValue(forKey: space) != nil else { return }
        save()
    }

    static func unload() {
        precondition(Store.unitTests)
        bySpace = [:]
        sharedPins = []
        loaded = false
    }

    private static func save() {
        let bySpace = bySpace, shared = sharedPins
        Disk.write(file) { encode(bySpace: bySpace, shared: shared) }
    }

    // MARK: - the two lists, worked out

    /// A space's own pin, shown by every space from now on: at the end of
    /// the shared ones.
    nonisolated static func share(_ id: UUID, own: [PinDef], shared: [PinDef]) -> (own: [PinDef], shared: [PinDef]) {
        guard let pin = own.first(where: { $0.id == id }) else { return (own, shared) }
        return (own.filter { $0.id != id }, shared + [pin])
    }

    /// A shared pin kept by one space only: first among its own.
    nonisolated static func unshare(_ id: UUID, own: [PinDef], shared: [PinDef]) -> (own: [PinDef], shared: [PinDef]) {
        guard let pin = shared.first(where: { $0.id == id }) else { return (own, shared) }
        return ([pin] + own, shared.filter { $0.id != id })
    }

    /// A row's pins, as the row has them, into the space's own and the
    /// shared ones, each in the row's order.
    nonisolated static func split(_ defs: [PinDef], shared ids: Set<UUID>) -> (own: [PinDef], shared: [PinDef]) {
        (defs.filter { !ids.contains($0.id) }, defs.filter { ids.contains($0.id) })
    }

    /// What a space's row holds: the shared pins, then its own, while the
    /// shared ones show; its own alone otherwise.
    nonisolated static func row(own: [PinDef], shared: [PinDef], showing: Bool) -> [PinDef] {
        guard showing else { return own }
        let sharedIDs = Set(shared.map(\.id))
        return shared + own.filter { !sharedIDs.contains($0.id) }
    }

    /// What a row's shared pins say the shared list now is: nothing while
    /// they don't show, and nothing from a row that holds none — a row not
    /// yet given them, the switch just turned on, must not wipe them.
    /// Taking the last one out goes through unpin and keepHere, which set
    /// the list themselves.
    nonisolated static func sharedToWrite(_ rowShared: [PinDef], showing: Bool) -> [PinDef]? {
        showing && !rowShared.isEmpty ? rowShared : nil
    }

    nonisolated static func decode(_ data: Data) -> (bySpace: [UUID: [PinDef]], shared: [PinDef])? {
        guard let saved = try? JSONDecoder().decode([String: [PinDef]].self, from: data) else { return nil }
        var bySpace: [UUID: [PinDef]] = [:]
        for (key, defs) in saved {
            if let space = UUID(uuidString: key) { bySpace[space] = defs }
        }
        return (bySpace, saved[sharedKey] ?? [])
    }

    /// No shared pins, no "shared" key: the file stays what it was for
    /// anyone who never turns them on.
    nonisolated static func encode(bySpace: [UUID: [PinDef]], shared: [PinDef]) -> Data? {
        var out: [String: [PinDef]] = [:]
        for (space, defs) in bySpace { out[space.uuidString] = defs }
        if !shared.isEmpty { out[sharedKey] = shared }
        return try? JSONEncoder().encode(out)
    }
}
