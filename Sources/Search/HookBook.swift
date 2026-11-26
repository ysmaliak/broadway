import CryptoKit
import Foundation
import Observation

enum HookEvent: String, CaseIterable, Sendable {
    case link, download, permission, timer

    var deciding: Bool { self == .link || self == .permission }
    var seconds: Double { deciding ? 1 : 30 }
    var bound: Bool { self == .permission }

    var title: String {
        switch self {
        case .link: "Links"
        case .download: "Downloads"
        case .permission: "Site requests"
        case .timer: "A Timer"
        }
    }
}

struct Hook: Identifiable, Equatable, Sendable {
    static let fewestMinutes = 5
    static let choiceMinutes = [5, 15, 30, 60]

    var id: UUID
    var event: HookEvent
    var path: String
    var on: Bool
    var hash: String?
    var minutes: Int
    var off: String?

    init(id: UUID = UUID(), event: HookEvent, path: String, on: Bool = true, hash: String? = nil, minutes: Int = 15, off: String? = nil) {
        self.id = id
        self.event = event
        self.path = path
        self.on = on
        self.hash = hash
        self.minutes = max(minutes, Hook.fewestMinutes)
        self.off = off
    }

    var program: URL { URL(fileURLWithPath: path) }

    var purpose: String {
        guard event == .timer else { return event.title }
        return Hook.every(minutes)
    }

    static func every(_ minutes: Int) -> String {
        if minutes % 60 == 0 { return minutes == 60 ? "Every hour" : "Every \(minutes / 60) hours" }
        return "Every \(minutes) minutes"
    }

    init?(_ object: [String: Any]) {
        guard let text = object["id"] as? String, let id = UUID(uuidString: text),
              let name = object["event"] as? String, let event = HookEvent(rawValue: name),
              let path = object["program"] as? String, path.hasPrefix("/"),
              let on = object["on"] as? Bool else { return nil }
        let hash = object["hash"] as? String
        if object["hash"] != nil, hash == nil { return nil }
        var minutes = 15
        if event == .timer {
            guard let every = (object["minutes"] as? NSNumber)?.intValue else { return nil }
            minutes = every
        }
        let off = object["off"] as? String
        if object["off"] != nil, off == nil { return nil }
        self.init(id: id, event: event, path: path, on: on, hash: hash, minutes: minutes, off: off)
    }

    func written(over raw: [String: Any]) -> [String: Any] {
        var object = raw
        object["id"] = id.uuidString
        object["event"] = event.rawValue
        object["program"] = path
        object["on"] = on
        object["hash"] = hash
        object["minutes"] = event == .timer ? minutes : nil
        object["off"] = off
        return object
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct HookEntry {
    var hook: Hook?
    var raw: [String: Any]

    init(raw: [String: Any]) {
        self.raw = raw
        hook = Hook(raw)
    }

    init(_ hook: Hook) {
        self.hook = hook
        raw = hook.written(over: [:])
    }

    var written: [String: Any] { hook?.written(over: raw) ?? raw }
}

struct HookResult: Equatable {
    var at: Date
    var problem: String?
    var said = ""
}

@MainActor
@Observable
final class HookBook {
    static let shared = HookBook(file: Store.file("hooks.json"))
    static let fileVersion = 1
    static let missesAllowed = 3
    static let switchedOff = "Switched off after three time-outs or crashes in a row"
    static let couldntStart = "Switched off because it couldn't start"
    static let changedWords = "Changed since you approved it"

    private(set) var entries: [HookEntry] = []
    private(set) var results: [UUID: HookResult] = [:]
    private(set) var changed: Set<UUID> = []
    private(set) var revision = 0
    @ObservationIgnored private(set) var misses: [UUID: Int] = [:]
    @ObservationIgnored let file: URL

    init(file: URL) {
        self.file = file
        guard let data = try? Data(contentsOf: file) else { return }
        guard let entries = HookBook.read(data) else {
            Store.quarantine(file)
            return
        }
        self.entries = entries
        look()
    }

    static func read(_ data: Data) -> [HookEntry]? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = top["hooks"] as? [Any] else { return nil }
        var found: [HookEntry] = []
        for item in list {
            guard let object = item as? [String: Any] else { return nil }
            found.append(HookEntry(raw: object))
        }
        return found
    }

    static func data(_ entries: [HookEntry]) -> Data? {
        let top: [String: Any] = ["version": fileVersion, "hooks": entries.map(\.written)]
        guard JSONSerialization.isValidJSONObject(top) else { return nil }
        return try? JSONSerialization.data(withJSONObject: top, options: [.prettyPrinted, .sortedKeys])
    }

    var hooks: [Hook] { entries.compactMap(\.hook) }

    func hook(_ id: UUID) -> Hook? { hooks.first { $0.id == id } }

    func ready(for event: HookEvent) -> [Hook] {
        hooks.filter { $0.event == event && $0.on && $0.off == nil }
    }

    private func save() {
        revision += 1
        guard let data = HookBook.data(entries) else { return }
        Disk.write(file) { data }
    }

    private func change(_ id: UUID, _ edit: (inout Hook) -> Void) {
        guard let at = entries.firstIndex(where: { $0.hook?.id == id }), var hook = entries[at].hook else { return }
        edit(&hook)
        guard hook != entries[at].hook else { return }
        entries[at].hook = hook
        save()
    }

    @discardableResult
    func add(_ event: HookEvent, program: URL, minutes: Int = 15) -> Hook? {
        guard let data = try? Data(contentsOf: program) else { return nil }
        let hook = Hook(event: event, path: program.path, hash: event.bound ? Hook.hash(of: data) : nil, minutes: minutes)
        entries.append(HookEntry(hook))
        save()
        return hook
    }

    func turn(_ id: UUID, on: Bool) {
        if on { misses[id] = 0 }
        change(id) {
            $0.on = on
            if on { $0.off = nil }
        }
    }

    func approve(_ id: UUID) {
        guard let hook = hook(id), hook.event.bound, let data = try? Data(contentsOf: hook.program) else { return }
        let hash = Hook.hash(of: data)
        changed.remove(id)
        results[id] = nil
        change(id) { $0.hash = hash }
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.hook?.id == id }
        results[id] = nil
        misses[id] = nil
        changed.remove(id)
        save()
    }

    func note(_ id: UUID, _ result: HookResult, missed: Bool, started: Bool = true) {
        results[id] = result
        guard hook(id) != nil else { return }
        if missed {
            let count = (misses[id] ?? 0) + 1
            misses[id] = count
            if count >= HookBook.missesAllowed {
                misses[id] = 0
                change(id) {
                    $0.on = false
                    $0.off = started ? HookBook.switchedOff : HookBook.couldntStart
                }
            }
        } else {
            misses[id] = 0
        }
    }

    func mark(_ id: UUID, changed now: Bool) {
        guard changed.contains(id) != now else { return }
        if now { changed.insert(id) } else { changed.remove(id) }
        revision += 1
    }

    func look() {
        let bound = hooks.filter(\.event.bound).map { ($0.id, $0.path, $0.hash) }
        guard !bound.isEmpty else { return }
        Task.detached(priority: .utility) {
            var found: Set<UUID> = []
            for (id, path, hash) in bound {
                let data = try? Data(contentsOf: URL(fileURLWithPath: path))
                if data.map(Hook.hash(of:)) != hash || hash == nil { found.insert(id) }
            }
            await MainActor.run { [found] in
                for (id, _, _) in bound { self.mark(id, changed: found.contains(id)) }
            }
        }
    }

    func line(_ hook: Hook, now: Date = Date()) -> String {
        if let off = hook.off { return off }
        if hook.event.bound, changed.contains(hook.id) { return HookBook.changedWords }
        guard let result = results[hook.id] else { return "Hasn't run yet" }
        if let problem = result.problem { return problem }
        return "Ran " + HookBook.ago(result.at, now: now)
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        let days = hours / 24
        return days == 1 ? "yesterday" : "\(days) days ago"
    }
}
