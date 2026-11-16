import Foundation

enum AIGroupTrace {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recording = false
    nonisolated(unsafe) private static var events: [[String: Any]] = []

    static func begin() {
        lock.withLock {
            recording = true
            events = []
        }
    }

    static func end() -> [[String: Any]] {
        lock.withLock {
            recording = false
            defer { events = [] }
            return events
        }
    }

    static func note(_ kind: String, _ fields: @autoclosure () -> [String: Any]) {
        lock.withLock {
            guard recording else { return }
            var event = fields()
            event["kind"] = kind
            events.append(event)
        }
    }

    static func said(_ pick: AIGroupPick, in ask: AIGroupAsk) -> String {
        switch pick {
        case .none: return "none"
        case .group(let id): return "group: " + (ask.groups.first { $0.id == id }?.name ?? "?")
        case .tab(let id): return "tab: " + ((ask.loose + ask.fresh).first { $0.id == id }?.title ?? "?")
        }
    }
}
