import Foundation
import Observation

enum AgentLinkKey: Hashable {
    case process(pid: Int32, started: Int64)
    case connection(UUID)
    case named(String)
    case codex(String)
}

enum AgentLinkEnding: Equatable {
    case done(String?)
    case failed(String?)
    case left

    var summary: String? {
        switch self {
        case .done(let said), .failed(let said): return said
        case .left: return nil
        }
    }

    var failed: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum AgentRest: Equatable {
    case finished(String?)
    case quiet
}

struct AgentProcessID: Equatable {
    var pid: Int32
    var started: Int64
}

struct AgentLink: Identifiable, Equatable {
    let id: UUID
    var name: String
    let key: AgentLinkKey
    let connected: Date
    var ended: AgentLinkEnding?
    var endedAt: Date?
    var rest: AgentRest?
    var last: String?
    var process: AgentProcessID?
    var announced = false
    var codex: CodexThread?
    var number = 1

    var live: Bool { ended == nil }

    var title: String { number > 1 ? "\(name) \(number)" : name }

    var accent: Int { AgentLinks.accent(for: name) }

    var seed: UInt64 {
        withUnsafeBytes(of: id.uuid) { $0.load(as: UInt64.self) }
    }
}

@MainActor
@Observable
final class AgentLinks {
    static let shared = AgentLinks()
    nonisolated static let accents = 6
    nonisolated static let summaryLimit = 200

    private(set) var links: [AgentLink] = []
    @ObservationIgnored private var heardAt: [UUID: Date] = [:]
    @ObservationIgnored private var tabs: [UUID: String] = [:]
    @ObservationIgnored private var lastTabs: [UUID: String] = [:]
    @ObservationIgnored private var waits: [UUID: Double] = [:]
    @ObservationIgnored private var passes: [UUID: [String: Date]] = [:]
    @ObservationIgnored private var calls: [UUID: Int] = [:]
    static let defaultPatience: Double = 100
    static let passLife: TimeInterval = 120
    @ObservationIgnored var idleLimit: TimeInterval = 20 * 60
    @ObservationIgnored var quietLimit: TimeInterval = 2 * 60
    @ObservationIgnored var alive: (Int32, Int64) -> Bool = AgentProcess.alive
    @ObservationIgnored var ending: ((AgentLink) -> Void)?
    @ObservationIgnored var resting: ((UUID) -> Void)?
    @ObservationIgnored var rejoining: ((UUID, [UUID]) -> Void)?
    @ObservationIgnored var asking: (UUID) -> Bool = { _ in false }

    var live: [AgentLink] { links.filter(\.live) }

    func link(_ id: UUID) -> AgentLink? {
        links.first { $0.id == id }
    }

    func liveLink(for key: AgentLinkKey) -> AgentLink? {
        links.last { $0.key == key && $0.live }
    }

    @discardableResult
    func join(_ key: AgentLinkKey, name: String?, at now: Date = Date()) -> AgentLink {
        if let found = liveLink(for: key) {
            heardAt[found.id] = now
            if let named = Self.clean(name), named != found.name { give(found.id, name: named) }
            return link(found.id) ?? found
        }
        let id = UUID()
        var made = AgentLink(id: id, name: Self.clean(name) ?? "Agent", key: key, connected: now)
        let before = links.filter { $0.key == key && !$0.live }
            .sorted { ($0.endedAt ?? $0.connected) < ($1.endedAt ?? $1.connected) }.map(\.id)
        made.number = number(for: made.name, besides: id)
        heardAt[id] = now
        links.append(made)
        if !before.isEmpty { rejoining?(id, before) }
        return made
    }

    func heard(_ id: UUID, at now: Date = Date()) {
        heardAt[id] = now
        if link(id)?.rest != nil { update(id) { $0.rest = nil } }
        AgentAwake.refresh()
    }

    func calling(_ id: UUID?, at now: Date = Date()) {
        guard let id, link(id) != nil else { return }
        calls[id, default: 0] += 1
        heard(id, at: now)
    }

    func called(_ id: UUID?, at now: Date = Date()) {
        guard let id, let count = calls[id] else { return }
        calls[id] = count > 1 ? count - 1 : nil
        heardAt[id] = now
    }

    func inFlight(_ id: UUID) -> Int {
        calls[id] ?? 0
    }

    func did(_ id: UUID?, _ what: String) {
        guard let id, let found = link(id), found.live, found.last != what else { return }
        update(id) { $0.last = what }
    }

    @discardableResult
    func finish(_ id: UUID, summary: String? = nil) -> Bool {
        guard let found = link(id), found.live else { return false }
        let rest = AgentRest.finished(Self.summary(summary))
        if found.rest != rest { update(id) { $0.rest = rest } }
        resting?(id)
        return true
    }

    func watch(_ id: UUID, _ process: AgentProcessID) {
        guard let found = link(id), found.live, found.process == nil else { return }
        update(id) { $0.process = process }
    }

    func lastHeard(_ id: UUID) -> Date? {
        heardAt[id]
    }

    func patience(_ id: UUID) -> Double {
        waits[id] ?? Self.defaultPatience
    }

    func setPatience(_ id: UUID, _ seconds: Double?) {
        waits[id] = seconds.map { max(0, $0) }
    }

    func givePass(_ id: UUID, _ what: String, at now: Date = Date()) {
        passes[id, default: [:]][what] = now
    }

    func takePass(_ id: UUID, _ what: String, at now: Date = Date()) -> Bool {
        guard let given = passes[id]?.removeValue(forKey: what) else { return false }
        return now.timeIntervalSince(given) <= Self.passLife
    }

    func currentTab(_ id: UUID) -> String? {
        tabs[id]
    }

    func lastTab(_ id: UUID) -> String? {
        lastTabs[id]
    }

    func announce(_ id: UUID) {
        guard let found = link(id), !found.announced else { return }
        update(id) { $0.announced = true }
    }

    func rename(_ id: UUID, _ name: String) {
        guard let named = Self.clean(name), link(id)?.name != named else { return }
        give(id, name: named)
    }

    private func give(_ id: UUID, name named: String) {
        let number = number(for: named, besides: id)
        update(id) { link in
            link.name = named
            link.number = number
        }
    }

    private func number(for name: String, besides id: UUID) -> Int {
        let taken = Set(links.filter { $0.id != id && $0.name == name }.map(\.number))
        return (1...).first { !taken.contains($0) } ?? 1
    }

    func setCodex(_ id: UUID, _ thread: CodexThread) {
        guard let found = link(id), found.codex != thread else { return }
        update(id) { $0.codex = thread }
    }

    func setCurrentTab(_ id: UUID, _ tab: String?) {
        tabs[id] = tab
    }

    @discardableResult
    func end(_ id: UUID, _ how: AgentLinkEnding, at now: Date = Date()) -> Bool {
        guard let found = link(id), found.live else { return false }
        let said: AgentLinkEnding
        switch how {
        case .done(let text): said = .done(Self.summary(text))
        case .failed(let text): said = .failed(Self.summary(text))
        case .left: said = .left
        }
        update(id) { link in
            link.ended = said
            link.endedAt = now
        }
        lastTabs[id] = tabs[id]
        tabs[id] = nil
        calls[id] = nil
        if let ended = link(id) { ending?(ended) }
        return true
    }

    func endConnection(_ connection: UUID, at now: Date = Date()) {
        guard let found = liveLink(for: .connection(connection)) else { return }
        end(found.id, .done(nil), at: now)
    }

    func closedShared(_ id: UUID) {
        guard inFlight(id) == 0 else { return }
        finish(id)
    }

    @discardableResult
    func sweep(at now: Date = Date(), busy: (UUID) -> Bool = { _ in false }) -> [UUID] {
        var gone: [UUID] = []
        for link in links where link.live {
            let quiet = now.timeIntervalSince(heardAt[link.id] ?? link.connected)
            if case .process(let pid, let started) = link.key, !alive(pid, started) {
                end(link.id, .done(nil), at: now)
                gone.append(link.id)
            } else if let process = link.process, !alive(process.pid, process.started) {
                end(link.id, .done(nil), at: now)
                gone.append(link.id)
            } else if !busy(link.id), quiet >= idleLimit {
                end(link.id, .left, at: now)
                gone.append(link.id)
            } else if link.rest == nil, inFlight(link.id) == 0, !busy(link.id), !asking(link.id), quiet >= quietLimit {
                update(link.id) { $0.rest = .quiet }
            }
        }
        return gone
    }

    func forget(_ id: UUID) {
        links.removeAll { $0.id == id }
        drop(id)
    }

    func forgetEnded(keeping held: (UUID) -> Bool) {
        let gone = links.filter { !$0.live && !held($0.id) }.map(\.id)
        guard !gone.isEmpty else { return }
        links.removeAll { gone.contains($0.id) }
        gone.forEach(drop)
    }

    func reset() {
        links = []
        heardAt = [:]
        tabs = [:]
        lastTabs = [:]
        waits = [:]
        passes = [:]
        calls = [:]
    }

    private func drop(_ id: UUID) {
        heardAt[id] = nil
        lastTabs[id] = nil
        waits[id] = nil
        passes[id] = nil
        calls[id] = nil
        tabs[id] = nil
    }

    private func update(_ id: UUID, _ change: (inout AgentLink) -> Void) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        change(&links[index])
        AgentAwake.refresh()
    }

    nonisolated static func clean(_ name: String?) -> String? {
        guard let name else { return nil }
        let line = name.components(separatedBy: .newlines).joined(separator: " ")
            .filter { !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return String(line.prefix(40))
    }

    nonisolated static func summary(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > summaryLimit ? String(line.prefix(summaryLimit - 1)) + "…" : line
    }

    nonisolated static func accent(for name: String) -> Int {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        let known: [String: Int] = ["claude code": 4, "claude": 4, "codex": 1, "cursor": 2, "windsurf": 0, "zed": 3, "terminal": 5]
        if let hit = known[key] { return hit }
        if key.hasPrefix("claude") { return 4 }
        if key.hasPrefix("codex") { return 1 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        let open = [0, 2, 3, 5]
        return open[Int(hash % UInt64(open.count))]
    }

    static func displayName(executable: String) -> String {
        let base = (executable as NSString).lastPathComponent.lowercased()
        let known: [(String, String)] = [("claude", "Claude Code"), ("codex", "Codex"), ("cursor", "Cursor"),
                                         ("windsurf", "Windsurf"), ("zed", "Zed"), ("code", "VS Code"),
                                         ("terminal", "Terminal"), ("iterm2", "iTerm"), ("ghostty", "Ghostty"),
                                         ("rex", "Rex"), ("python3", "Python"), ("python", "Python"), ("node", "Node")]
        if let hit = known.first(where: { base == $0.0 || base.hasPrefix($0.0 + " ") || base.hasPrefix($0.0 + "-") }) {
            return hit.1
        }
        let trimmed = (executable as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "Agent" }
        return first.uppercased() + trimmed.dropFirst()
    }

    static func mcpName(_ client: String?) -> String? {
        guard let client = clean(client) else { return nil }
        let known: [String: String] = ["claude-code": "Claude Code", "claude-ai": "Claude", "codex": "Codex",
                                       "codex-mcp-client": "Codex", "cursor": "Cursor", "cursor-vscode": "Cursor",
                                       "windsurf": "Windsurf", "zed": "Zed"]
        if let hit = known[client.lowercased()] { return hit }
        return displayName(executable: client)
    }
}

enum AgentPatience {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done: CheckedContinuation<AgentAnswer?, Never>?

        init(_ done: CheckedContinuation<AgentAnswer?, Never>) { self.done = done }

        func resume(_ answer: AgentAnswer?) {
            lock.lock()
            let waiting = done
            done = nil
            lock.unlock()
            waiting?.resume(returning: answer)
        }
    }

    @MainActor
    static func race(_ asking: Task<AgentAnswer, Never>, seconds: Double) async -> AgentAnswer? {
        let box = OnceBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<AgentAnswer?, Never>) in
                let once = Once(done)
                box.set(once)
                Task { @MainActor in once.resume(await asking.value) }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(seconds))
                    once.resume(nil)
                }
            }
        } onCancel: {
            box.resume()
        }
    }

    private final class OnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var once: Once?
        private var cancelled = false

        func set(_ once: Once) {
            lock.lock()
            self.once = once
            let early = cancelled
            lock.unlock()
            if early { once.resume(nil) }
        }

        func resume() {
            lock.lock()
            cancelled = true
            let found = once
            lock.unlock()
            found?.resume(nil)
        }
    }
}

enum AgentProcess {
    static func alive(_ pid: Int32, _ started: Int64) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let found = startTime(pid) else { return false }
        return started == 0 || found == started
    }

    static func startTime(_ pid: Int32) -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let time = info.kp_proc.p_un.__p_starttime
        return Int64(time.tv_sec) * 1_000_000 + Int64(time.tv_usec)
    }
}

enum AgentLinkState: Equatable {
    case idle
    case working(String)
    case needsYou(String)
    case driving
    case finished(String?)
    case quiet(String?)
    case done(String?)
    case failed(String?)

    var line: String {
        switch self {
        case .idle: return "Thinking"
        case .working(let doing): return doing
        case .needsYou(let question): return question.isEmpty ? "Needs you" : "Needs you: \(question)"
        case .driving: return "You're driving"
        case .finished(let said): return said ?? "Finished"
        case .quiet(let last): return last.map { "Idle after \(Self.lowered($0))" } ?? "Idle"
        case .done(let summary): return summary ?? "Done"
        case .failed(let summary): return summary ?? "Couldn't finish"
        }
    }

    var attention: Bool {
        if case .needsYou = self { return true }
        return false
    }

    var working: Bool {
        if case .working = self { return true }
        return false
    }

    var resting: Bool {
        switch self {
        case .finished, .quiet: return true
        default: return false
        }
    }

    var animated: Bool {
        switch self {
        case .working, .needsYou: return true
        default: return false
        }
    }

    struct TabFacts: Equatable {
        var acting: String?
        var mood: AgentMood?
        var driving = false
        var host: String?
        var question: String?
        var asking = false
    }

    static func of(_ tabs: [TabFacts], ended: AgentLinkEnding?, rest: AgentRest? = nil, last: String? = nil) -> AgentLinkState {
        if let asked = tabs.first(where: { $0.asking || $0.question != nil || $0.mood == .waving }) {
            return .needsYou(asked.question ?? "")
        }
        if tabs.contains(where: \.driving) { return .driving }
        if let ended {
            return ended.failed ? .failed(ended.summary) : .done(ended.summary)
        }
        if case .finished(let said) = rest { return .finished(said ?? last.map { "Finished after \(lowered($0))" }) }
        if let busy = tabs.first(where: { $0.acting != nil }), let acting = busy.acting {
            return .working(phrase(acting, host: busy.host))
        }
        if rest == .quiet { return .quiet(last) }
        return .idle
    }

    static func lowered(_ doing: String) -> String {
        guard let first = doing.first else { return doing }
        return first.lowercased() + doing.dropFirst()
    }

    static func codex(_ thread: CodexThread, ended: AgentLinkEnding?) -> AgentLinkState {
        if let ended {
            let said = ended.summary ?? (thread.finished ? thread.said : nil)
            return ended.failed ? .failed(said) : .done(said)
        }
        if thread.working { return .working(thread.doing ?? "Working") }
        if thread.finished { return .done(thread.said) }
        return .quiet(nil)
    }

    static func phrase(_ acting: String, host: String?) -> String {
        guard let host = host.flatMap({ $0.isEmpty ? nil : PageIndex.bare($0.lowercased()) }) else { return acting }
        switch acting {
        case "Reading", "Opening", "Scrolling": return "\(acting) \(host)"
        case "Looking": return "Looking at \(host)"
        case "Clicking", "Typing", "Pressing a key", "Signing in", "Filling": return "\(acting) on \(host)"
        default: return acting
        }
    }

    var mood: AgentCharacter.Mood {
        switch self {
        case .idle: return .idle
        case .working(let doing):
            return doing.hasPrefix("Typing") || doing.hasPrefix("Pressing") || doing.hasPrefix("Filling") ? .typing : .reading
        case .needsYou: return .waving
        case .driving: return .driving
        case .finished, .done: return .done
        case .quiet: return .ended
        case .failed: return .failed
        }
    }
}
