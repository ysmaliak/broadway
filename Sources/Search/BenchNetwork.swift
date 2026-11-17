import Foundation

@MainActor
enum BenchNetwork {
    static let verbs: Set<String> = ["network"]

    static func run(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "network only works on a --test run"]) }
        switch request["action"] as? String ?? "state" {
        case "away": NetworkPath.shared.said(false)
        case "back": NetworkPath.shared.said(true)
        case "state": break
        default: return answer(["error": "network takes away, back or state"])
        }
        answer(state())
    }

    static func state() -> [String: Any] {
        let path = NetworkPath.shared
        let tabs = Tab.live.allObjects
        return [
            "available": path.available.map { $0 as Any } ?? NSNull(),
            "returns": path.returns,
            "waiting": tabs.filter(\.waitingForNetwork).map(Bench.short),
            "owed": tabs.filter(\.retry.network.owed).map(Bench.short),
        ]
    }
}
