import AppKit
import Combine
import CoreServices
import Foundation

struct CodexThread: Equatable {
    var id: String
    var folder: String?
    var title: String?
    var working = false
    var doing: String?
    var said: String?
    var finished = false
    var started: Date?

    var name: String {
        let place = title ?? folder.map { ($0 as NSString).lastPathComponent }
        guard let place, !place.isEmpty else { return "Codex" }
        return "Codex · \(place)"
    }

    var address: URL? {
        guard let id = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "codex://threads/\(id)")
    }
}

enum CodexRollout {
    struct Head: Equatable {
        var id: String
        var folder: String?
        var desktop: Bool
    }

    struct Turn: Equatable {
        var working = false
        var doing: String?
        var said: String?
        var finished = false
        var started: Date?
    }

    static func head(_ line: Data) -> Head? {
        guard let row = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              row["type"] as? String == "session_meta",
              let meta = row["payload"] as? [String: Any],
              let id = (meta["id"] as? String) ?? (meta["session_id"] as? String), !id.isEmpty else { return nil }
        let origin = (meta["originator"] as? String ?? "").lowercased()
        let own = meta["source"] is String || meta["source"] == nil
        let folder = (meta["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Head(id: id, folder: folder, desktop: origin.contains("desktop") && own)
    }

    static func turn(_ tail: Data, whole: Bool) -> Turn {
        var lines = tail.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !whole, !lines.isEmpty { lines.removeFirst() }
        var turn = Turn()
        var inside = false
        for line in lines.reversed() {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let payload = row["payload"] as? [String: Any], let kind = payload["type"] as? String else { continue }
            if row["type"] as? String == "event_msg" {
                switch kind {
                case "task_complete":
                    turn.finished = true
                    turn.said = AgentLinks.summary(payload["last_agent_message"] as? String)
                    turn.started = stamp(payload["started_at"])
                    turn.doing = nil
                    return turn
                case "turn_aborted", "task_aborted":
                    turn.doing = nil
                    return turn
                case "task_started":
                    turn.working = true
                    turn.started = stamp(payload["started_at"])
                    return turn
                case "item_completed":
                    inside = true
                    if turn.doing == nil, let item = payload["item"] as? [String: Any] { turn.doing = doing(item) }
                default:
                    continue
                }
            }
        }
        turn.working = inside
        return turn
    }

    static func doing(_ item: [String: Any]) -> String? {
        switch item["type"] as? String {
        case "CommandExecution":
            if let parsed = (item["parsed_cmd"] as? [[String: Any]])?.last {
                switch parsed["type"] as? String {
                case "read": return named("Reading", parsed["name"] as? String ?? parsed["path"] as? String)
                case "search": return "Searching the code"
                case "list_files": return "Looking through files"
                default: break
                }
            }
            let command = (item["command"] as? [String])?.last ?? item["command"] as? String ?? ""
            let last = command.components(separatedBy: "&&").last?.trimmingCharacters(in: .whitespaces) ?? ""
            let words = last.split(separator: " ").prefix(3).joined(separator: " ")
            return words.isEmpty ? "Running a command" : AgentLinks.summary("Running \(words)")
        case "FileChange":
            let first = (item["changes"] as? [String: Any])?.keys.sorted().first
            return named("Editing", first)
        case "Extension":
            switch item["kind"] as? String {
            case "web.search":
                let action = item["action"] as? [String: Any]
                if let page = (action?["url"] as? String).flatMap(URL.init(string:))?.host() {
                    return "Reading \(PageIndex.bare(page.lowercased()))"
                }
                return "Searching the web"
            case "clock.sleep": return "Waiting"
            default: return nil
            }
        case "McpToolCall":
            let server = item["server"] as? String ?? item["server_name"] as? String
            return server.map { "Using \($0)" } ?? "Using a tool"
        case "ImageView":
            return named("Looking at", item["path"] as? String)
        case "AgentMessage":
            let text = (item["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ")
            return AgentLinks.summary(text)
        case "Reasoning":
            return "Thinking"
        case "ContextCompaction":
            return "Tidying its notes"
        case "UserMessage":
            return "Reading your message"
        default:
            return nil
        }
    }

    static func title(_ index: Data, id: String) -> String? {
        let needle = Data("\"\(id)\"".utf8)
        for line in index.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: needle) != nil {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  row["id"] as? String == id else { continue }
            if let name = AgentLinks.clean(row["thread_name"] as? String) { return name }
        }
        return nil
    }

    static func firstLine(of url: URL, limit: Int = 4 << 20) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var line = Data()
        while line.count < limit {
            guard let chunk = try? handle.read(upToCount: 64 << 10), !chunk.isEmpty else { break }
            if let end = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                line.append(chunk[chunk.startIndex..<end])
                return line
            }
            line.append(chunk)
        }
        return line.isEmpty ? nil : line
    }

    static func tail(of url: URL, bytes: Int) -> (data: Data, whole: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let from = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: from)
        guard let data = try? handle.readToEnd() else { return nil }
        return (data, from == 0)
    }

    private static func named(_ verb: String, _ path: String?) -> String {
        guard let path, !path.isEmpty else { return verb == "Looking at" ? "Looking at an image" : verb }
        let bare = path.hasPrefix("file://") ? URL(string: path)?.path ?? path : path
        return AgentLinks.summary("\(verb) \((bare as NSString).lastPathComponent)") ?? verb
    }

    private static func stamp(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        if let text = value as? String, let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
        return nil
    }
}

@MainActor
final class CodexDesktop {
    static let shared = CodexDesktop()
    nonisolated static let bundle = "com.openai.codex"
    static let hold: TimeInterval = 120
    static let stale: TimeInterval = 10 * 60
    static let days = 7

    var home: URL? = CodexDesktop.defaultHome
    var links = AgentLinks.shared
    var allowed: () -> Bool = { Shared.prefs.agentsAllowed }
    var running: () -> Bool = CodexDesktop.defaultRunning
    var opener: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private(set) var watching = false
    private var heads: [String: CodexRollout.Head] = [:]
    private var others: Set<String> = []
    private var hidden: [String: Date] = [:]
    private var stream: FSEventStreamRef?
    private var bag: Set<AnyCancellable> = []

    nonisolated static var defaultHome: URL? {
        let env = ProcessInfo.processInfo.environment
        if let asked = env["BROADWAY_CODEX_HOME"], !asked.isEmpty { return URL(fileURLWithPath: asked) }
        if Store.testing { return nil }
        if let asked = env["CODEX_HOME"], !asked.isEmpty { return URL(fileURLWithPath: asked) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    nonisolated static func defaultRunning() -> Bool {
        if Store.testing, let said = ProcessInfo.processInfo.environment["BROADWAY_CODEX_RUNNING"] { return said == "1" }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    func wake() {
        guard bag.isEmpty else { return }
        kitObserve({ Shared.prefs.agentsOn }) { [weak self] _ in self?.update() }
            .store(in: &bag)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.publisher(for: name)
                .filter { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == CodexDesktop.bundle }
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.update() }
                .store(in: &bag)
        }
        update()
    }

    func update(at now: Date = Date()) {
        let agents = allowed()
        let want = agents && home != nil && running()
        if want && !watching {
            watching = true
            listen()
            scan(at: now)
        } else if !want && watching {
            watching = false
            quiet()
        }
        if !want { leave(forget: !agents, at: now) }
    }

    func scan(at now: Date = Date()) {
        guard let sessions = home?.appendingPathComponent("sessions") else { return }
        let calendar = Calendar.current
        let manager = FileManager.default
        for back in 0..<Self.days {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where Self.rollout(name) {
                consider(folder.appendingPathComponent(name), at: now)
            }
        }
    }

    func changed(_ paths: [String], at now: Date = Date()) {
        guard watching else { return }
        for path in Set(paths) where Self.rollout((path as NSString).lastPathComponent) {
            consider(URL(fileURLWithPath: path), at: now)
        }
    }

    func consider(_ url: URL, at now: Date = Date()) {
        let path = url.path
        guard watching, !others.contains(path) else { return }
        guard let written = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return }
        let existing = heads[path].flatMap { links.liveLink(for: .codex($0.id)) }
        guard existing != nil || now.timeIntervalSince(written) < links.idleLimit else { return }
        let head: CodexRollout.Head
        if let known = heads[path] {
            head = known
        } else {
            guard let line = CodexRollout.firstLine(of: url), let read = CodexRollout.head(line) else { return }
            guard read.desktop else {
                others.insert(path)
                return
            }
            heads[path] = read
            head = read
        }
        guard let tail = CodexRollout.tail(of: url, bytes: 256 << 10) else { return }
        var turn = CodexRollout.turn(tail.data, whole: tail.whole)
        if turn.working, now.timeIntervalSince(written) >= Self.stale { turn.working = false }
        if let hid = hidden[head.id] {
            guard let started = turn.started, started > hid else { return }
            hidden[head.id] = nil
        }
        var thread = links.liveLink(for: .codex(head.id))?.codex ?? CodexThread(id: head.id, folder: head.folder)
        thread.working = turn.working
        thread.doing = turn.doing
        thread.said = turn.said
        thread.finished = turn.finished
        thread.started = turn.started
        if thread.title == nil || turn.finished { thread.title = title(head.id) ?? thread.title }
        let link = links.join(.codex(head.id), name: thread.name, at: written)
        links.announce(link.id)
        links.setCodex(link.id, thread)
    }

    func settle(at now: Date = Date()) {
        for link in links.live {
            guard var thread = link.codex, thread.working, let heard = links.lastHeard(link.id),
                  now.timeIntervalSince(heard) >= Self.stale else { continue }
            thread.working = false
            links.setCodex(link.id, thread)
        }
    }

    func reveal(_ link: AgentLink) {
        guard let address = link.codex?.address else { return }
        opener(address)
    }

    func hide(_ link: AgentLink, at now: Date = Date()) {
        guard let thread = link.codex else { return }
        hidden[thread.id] = now
        links.forget(link.id)
    }

    static func holding(_ link: AgentLink, at now: Date = Date()) -> Bool {
        guard link.codex != nil, let ended = link.endedAt else { return false }
        return now.timeIntervalSince(ended) < hold
    }

    func reset() {
        quiet()
        watching = false
        heads = [:]
        others = []
        hidden = [:]
    }

    private func title(_ id: String) -> String? {
        guard let index = home?.appendingPathComponent("session_index.jsonl"),
              let tail = CodexRollout.tail(of: index, bytes: 128 << 10) else { return nil }
        return CodexRollout.title(tail.data, id: id)
    }

    private func leave(forget: Bool, at now: Date) {
        for link in links.links where link.codex != nil {
            if forget {
                links.forget(link.id)
            } else if link.live {
                links.end(link.id, .done(link.codex?.finished == true ? link.codex?.said : nil), at: now)
            }
        }
    }

    private nonisolated static func rollout(_ name: String) -> Bool {
        name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    private func listen() {
        guard stream == nil, let sessions = home?.appendingPathComponent("sessions") else { return }
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, _, count, paths, _, _ in
            let found = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            let list = Array(found.prefix(count))
            MainActor.assumeIsolated { CodexDesktop.shared.changed(list) }
        }
        guard let made = FSEventStreamCreate(nil, callback, &context, [sessions.path] as CFArray,
                                             FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(made, .main)
        FSEventStreamStart(made)
        stream = made
    }

    private func quiet() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
