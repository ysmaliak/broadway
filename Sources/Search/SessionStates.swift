import Foundation

@MainActor
enum SessionStates {
    struct Kept: Codable, Equatable {
        var url: String
        var state: Data
    }

    private static var known: [UUID: [String: Kept]] = [:]
    private static var written: [UUID: [ObjectIdentifier: Set<String>]] = [:]

    private static func file(_ space: UUID) -> URL {
        Store.file(space == Space.firstID ? "session-states.plist" : "session-states-\(space.uuidString).plist")
    }

    static func read(space: UUID, naming row: Session.Shape? = nil) -> [String: Kept] {
        if let kept = known[space] { return kept }
        let stored = (try? Data(contentsOf: file(space)))
            .flatMap { try? PropertyListDecoder().decode([String: Kept].self, from: $0) } ?? [:]
        var named = Set(row?.tabs.compactMap(\.state) ?? [])
        named.formUnion(Session.read(space: space).tabs.compactMap(\.state))
        for record in Browsers.read() { named.formUnion(record.rows[space.uuidString]?.tabs.compactMap(\.state) ?? []) }
        named.formUnion(liveKeys())
        let kept = stored.filter { named.contains($0.key) }
        known[space] = kept
        if kept.count != stored.count { save(space, kept, now: false) }
        return kept
    }

    static func state(for entry: Session.Entry, in kept: [String: Kept]) -> Data? {
        guard let key = entry.state, let found = kept[key], found.url == entry.url else { return nil }
        return found.state
    }

    static func keep(_ tabs: [Tab], space: UUID, from browser: Browser, now: Bool) {
        var kept = read(space: space)
        let old = kept
        let owner = ObjectIdentifier(browser)
        let before = written[space]?[owner] ?? []
        let row = Set(tabs.map(\.stateKey))
        for key in before.subtracting(row).subtracting(liveKeys()) { kept[key] = nil }
        for tab in tabs {
            if let state = tab.keptState {
                kept[tab.stateKey] = Kept(url: state.url.absoluteString, state: state.state)
            } else if tab.asleep {
                kept[tab.stateKey] = nil
            }
        }
        written[space, default: [:]][owner] = before.union(row).filter { kept[$0] != nil }
        guard kept != old else { return }
        known[space] = kept
        save(space, kept, now: now)
    }

    static func erase(space: UUID) {
        known[space] = nil
        written[space] = nil
        Disk.remove(file(space))
    }

    static func unload() {
        precondition(Store.unitTests)
        known = [:]
        written = [:]
    }

    private static func liveKeys() -> Set<String> {
        Set(Browsers.all.flatMap { ($0.tabs + $0.parkedTabs).map(\.stateKey) })
    }

    private static func save(_ space: UUID, _ kept: [String: Kept], now: Bool) {
        Disk.write(file(space), now: now) {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return try? encoder.encode(kept)
        }
    }
}
