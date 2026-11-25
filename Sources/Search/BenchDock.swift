import AppKit

@MainActor
enum BenchDock {
    static let verbs: Set<String> = ["dock"]

    static func run(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "dock only works on a --test run"]) }
        let bar = DockBar.shared
        switch request["action"] as? String ?? "state" {
        case "tile":
            bar.drivesTile = true
            AgentBadge.drivesTile = true
        case "leave":
            bar.drivesTile = false
            AgentBadge.drivesTile = false
        case "state": break
        default: return answer(["error": "dock takes state, tile or leave"])
        }
        answer([
            "shown": bar.shown != nil,
            "percent": bar.shown.map { $0 as Any } ?? NSNull(),
            "drivesTile": bar.drivesTile,
            "tileSet": bar.tileSet,
            "running": Shared.fetches.dockLoads.count,
            "badge": AgentBadge.shown ?? "",
            "badgeLabel": NSApp.dockTile.badgeLabel ?? "",
        ])
    }
}
