import Foundation

@MainActor
enum AgentPopupNews {
    static var told: [UUID: Set<UUID>] = [:]

    static func take(_ tab: Tab) -> String? {
        let known = told[tab.id] ?? []
        let fresh = tab.blockedPopups.filter { !known.contains($0.id) }
        told[tab.id] = known.union(tab.blockedPopups.map(\.id))
        guard !fresh.isEmpty else { return nil }
        return line(fresh.map(\.url))
    }

    static func line(_ urls: [URL?]) -> String {
        let shown = urls.compactMap { $0 }.map { AgentChange.short(AgentSecrets.shown($0)) }
        let place = shown.isEmpty ? "" : ": " + shown.prefix(3).joined(separator: ", ")
        return urls.count == 1 ? "The page tried to open a window and Broadway blocked it\(place)"
            : "The page tried to open \(urls.count) windows and Broadway blocked them\(place)"
    }
}
