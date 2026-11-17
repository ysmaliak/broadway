import AppKit

@MainActor
enum BenchMemory {
    static let verbs: Set<String> = ["memory"]

    static func run(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "memory only works on a --test run"]); return }
        let watch = MemoryWatch.shared
        switch request["action"] as? String ?? "state" {
        case "state":
            break
        case "ceiling":
            let megabytes = request["megabytes"] as? Double
            watch.lower(to: megabytes.map { UInt64($0 * 1_048_576) })
        case "retry":
            let wanted = (request["id"] as? String ?? "").lowercased()
            guard !wanted.isEmpty, let tab = tabs().first(where: { $0.id.uuidString.lowercased().hasPrefix(wanted) }) else {
                answer(["error": "no tab \(wanted)"])
                return
            }
            let drawn = Browsers.all.compactMap { $0.window?.contentView }.flatMap { $0.kitSubviews(of: TroubleView.self) }
            let shown = drawn.first { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.message == tab.failure }
            if let shown { shown.onRetry() } else { tab.reload() }
            answer(["pressed": shown != nil, "tab": row(tab)])
            return
        default:
            answer(["error": "memory state|ceiling MB|retry ID"])
            return
        }
        answer(state())
    }

    private static func tabs() -> [Tab] {
        MemoryPages.browsers.flatMap { $0.tabs + $0.parkedTabs }
    }

    private static func row(_ tab: Tab) -> [String: Any] {
        [
            "id": Bench.short(tab), "pid": tab.built?.processID ?? 0, "failure": tab.failure ?? "",
            "stopped": tab.memoryStopped, "loading": tab.loading, "committed": tab.committed?.absoluteString ?? "",
            "agent": tab.agent, "stale": tab.stale, "asleep": tab.asleep,
        ]
    }

    private static func state() -> [String: Any] {
        let watch = MemoryWatch.shared
        return [
            "ceiling": Double(watch.ceiling) / 1_048_576,
            "physical": Double(watch.physical) / 1_048_576,
            "readings": watch.readings,
            "renewed": watch.renewed,
            "watched": watch.watched.map { ["pid": Int($0.key), "tabs": $0.value.map { String($0.uuidString.prefix(8)).lowercased() }] },
            "last": watch.lastReadings.map { ["pid": Int($0.pid), "megabytes": Double($0.bytes) / 1_048_576] },
            "waiting": watch.waiting.map { ["pid": Int($0.pid), "megabytes": Double($0.bytes) / 1_048_576] },
            "tabs": tabs().map(row),
        ]
    }
}
