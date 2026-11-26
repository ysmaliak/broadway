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

struct AgentGoneTab: Equatable {
    var key: AgentLinkKey?
    var handed: Bool
    var how: AgentLinkEnding
    var kept = false
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
    var person = false
    var number = 1
    var space: UUID?
    var folder: String?
    var placed: AgentPlaceWhy = .front
    var told = false
    var workdir: String?
    var named = false
    var remote = false
    var program: AgentSigner?
    var firstQuestion: UUID?
    var origin: String?

    var live: Bool { ended == nil }

    var held: Bool {
        if case .connection = key { return true }
        return false
    }

    var place: String? {
        guard !named, let workdir else { return nil }
        let last = (workdir as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? nil : last
    }

    var heading: String { place.map { "\(name) · \($0)" } ?? name }

    var title: String { number > 1 ? "\(heading) \(number)" : heading }

    var asker: String { number > 1 ? "\(name) \(number)" : name }

    var needsYouLine: String { place.map { "\(name) in \($0) needs you" } ?? "\(title) needs you" }

    func tag(most: Int = 28) -> String {
        guard title.count > most, let place else { return title }
        let end = number > 1 ? " \(number)" : ""
        let room = max(5, most - name.count - 3 - end.count)
        guard place.count > room else { return title }
        let head = room / 2
        let tail = room - 1 - head
        return "\(name) · \(place.prefix(head))…\(place.suffix(tail))\(end)"
    }

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
    @ObservationIgnored private var gone: [String: AgentGoneTab] = [:]
    @ObservationIgnored private var goneOrder: [String] = []
    @ObservationIgnored private var endedKeys: [AgentLinkKey: AgentLinkEnding] = [:]
    @ObservationIgnored private var signing: Set<UUID> = []
    static let goneLimit = 500
    static let defaultPatience: Double = 100
    static let passLife: TimeInterval = 120
    @ObservationIgnored var idleLimit: TimeInterval = 20 * 60
    @ObservationIgnored var quietLimit: TimeInterval = 2 * 60
    @ObservationIgnored var alive: (Int32, Int64) -> Bool = AgentProcess.alive
    @ObservationIgnored var ending: ((AgentLink) -> Void)?
    @ObservationIgnored var resting: ((UUID) -> Void)?
    @ObservationIgnored var rejoining: ((UUID, [UUID]) -> Void)?
    @ObservationIgnored var asking: (UUID) -> Bool = { _ in false }
    @ObservationIgnored var here: () -> UUID? = { AgentLinks.frontSpace() }
    @ObservationIgnored var spaceNames: () -> [AgentSpaceName]? = { AgentLinks.frontSpaceNames() }
    @ObservationIgnored var places: AgentPlaces = .shared

    var live: [AgentLink] { links.filter(\.live) }

    func link(_ id: UUID) -> AgentLink? {
        links.first { $0.id == id }
    }

    func liveLink(for key: AgentLinkKey) -> AgentLink? {
        links.last { $0.key == key && $0.live }
    }

    @discardableResult
    func join(_ key: AgentLinkKey, name: String?, at now: Date = Date(), wish: AgentWish = AgentWish(), origin: String? = nil) -> AgentLink {
        if let found = liveLink(for: key) {
            heardAt[found.id] = now
            if let named = Self.clean(name), named != found.name { give(found.id, name: named) }
            if found.folder == nil, let folder = wish.folder { update(found.id) { $0.folder = folder } }
            if found.workdir == nil, let workdir = wish.workdir { give(found.id, workdir: workdir) }
            return link(found.id) ?? found
        }
        let id = UUID()
        var made = AgentLink(id: id, name: Self.clean(name) ?? "Agent", key: key, connected: now)
        let before = links.filter { !$0.live && ($0.key == key || origin != nil && $0.origin == origin) }
            .sorted { ($0.endedAt ?? $0.connected) < ($1.endedAt ?? $1.connected) }.map(\.id)
        made.workdir = wish.workdir
        made.named = wish.named
        made.origin = origin
        made.number = number(for: made, besides: id)
        made.folder = wish.folder
        let place = AgentPlaces.choose(wish, spaces: spaceNames(), learned: places.learned(wish.folder), front: here())
        made.space = place.space
        made.placed = place.why
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

    func settle(_ id: UUID, in space: UUID, because why: AgentPlaceWhy, at now: Date = Date()) {
        guard let found = link(id) else { return }
        if why == .asked || why == .moved { places.learn(found.folder, space, at: now) }
        guard found.live, found.space != space || found.placed != why else { return }
        update(id) { link in
            link.space = space
            link.placed = why
            link.told = false
        }
    }

    func give(_ id: UUID, folder: String) {
        guard let found = link(id), found.folder == nil else { return }
        update(id) { $0.folder = folder }
    }

    func give(_ id: UUID, workdir: String) {
        guard var found = link(id), found.workdir == nil else { return }
        found.workdir = workdir
        let number = number(for: found, besides: id)
        update(id) { link in
            link.workdir = workdir
            link.number = number
        }
    }

    func tell(_ id: UUID) -> Bool {
        guard let found = link(id), !found.told else { return false }
        update(id) { $0.told = true }
        return true
    }

    func setPerson(_ id: UUID, _ on: Bool) {
        update(id) { $0.person = on }
    }

    func setRemote(_ id: UUID) {
        guard let found = link(id), !found.remote else { return }
        update(id) { link in
            link.remote = true
            link.program = .elsewhere
        }
    }

    func sign(_ id: UUID, _ program: AgentSigner) {
        guard let found = link(id), !found.remote, found.program != program else { return }
        update(id) { $0.program = program }
    }

    func asked(_ id: UUID?, question: UUID) {
        guard let id, let found = link(id), found.firstQuestion == nil else { return }
        update(id) { $0.firstQuestion = question }
    }

    func reading(_ id: UUID) -> Bool {
        signing.insert(id).inserted
    }

    static func agentExecutable(_ executable: String?) -> Bool {
        let base = ((executable ?? "") as NSString).lastPathComponent.lowercased()
        return ["claude", "codex", "cursor", "opencode", "gemini"].contains { base.hasPrefix($0) }
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

    func rename(_ id: UUID, _ name: String, given: Bool = false) {
        guard let named = Self.clean(name), let found = link(id), found.name != named || given && !found.named else { return }
        give(id, name: named, given: given || found.named)
    }

    private func give(_ id: UUID, name named: String, given: Bool? = nil) {
        guard var found = link(id) else { return }
        found.name = named
        if let given { found.named = given }
        let number = number(for: found, besides: id)
        update(id) { link in
            link.name = named
            link.named = found.named
            link.number = number
        }
    }

    private func number(for made: AgentLink, besides id: UUID) -> Int {
        let taken = Set(links.filter { $0.id != id && $0.heading == made.heading }.map(\.number))
        return (1...).first { !taken.contains($0) } ?? 1
    }

    func setCodex(_ id: UUID, _ thread: CodexThread) {
        guard let found = link(id), found.codex != thread else { return }
        update(id) { $0.codex = thread }
    }

    func setCurrentTab(_ id: UUID, _ tab: String?) {
        tabs[id] = tab
        if tab != nil, let key = link(id)?.key { endedKeys[key] = nil }
    }

    func noteGone(_ tab: String, from link: AgentLink?, handed: Bool) {
        let how = link?.ended ?? .left
        if gone[tab] == nil { goneOrder.append(tab) }
        gone[tab] = AgentGoneTab(key: link?.key, handed: handed, how: how)
        if let key = link?.key { endedKeys[key] = how }
        while goneOrder.count > Self.goneLimit { gone[goneOrder.removeFirst()] = nil }
    }

    func kept(_ tab: String, from id: UUID?) {
        if AgentSocket.shared.currentTab == tab { AgentSocket.shared.currentTab = nil }
        guard let id else { return }
        if tabs[id] == tab { tabs[id] = nil }
        if lastTabs[id] == tab { lastTabs[id] = nil }
        guard let found = link(id), found.live else { return }
        if gone[tab] == nil { goneOrder.append(tab) }
        gone[tab] = AgentGoneTab(key: found.key, handed: true, how: .left, kept: true)
        while goneOrder.count > Self.goneLimit { gone[goneOrder.removeFirst()] = nil }
    }

    func goneTab(_ named: String) -> AgentGoneTab? {
        let wanted = String(named.lowercased().prefix(8))
        guard !wanted.isEmpty else { return nil }
        if let exact = gone[wanted] { return exact }
        return goneOrder.last { $0.hasPrefix(wanted) }.flatMap { gone[$0] }
    }

    func takeEnded(_ key: AgentLinkKey) -> AgentLinkEnding? {
        endedKeys.removeValue(forKey: key)
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
            if !link.person, case .process(let pid, let started) = link.key, !alive(pid, started) {
                end(link.id, .done(nil), at: now)
                gone.append(link.id)
            } else if !link.person, let process = link.process, !alive(process.pid, process.started) {
                end(link.id, .done(nil), at: now)
                gone.append(link.id)
            } else if quiet >= idleLimit, !link.held, quiet >= 2 * idleLimit || inFlight(link.id) == 0 && !busy(link.id) && !asking(link.id) {
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
        gone = [:]
        goneOrder = []
        endedKeys = [:]
        signing = []
    }

    private func drop(_ id: UUID) {
        signing.remove(id)
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
    @TaskLocal static var asked: Double?

    static func wanted(_ request: [String: Any]) -> Double? {
        if request["person"] as? String == "none" { return 0 }
        guard let wait = request["wait"] as? Double ?? (request["wait"] as? Int).map(Double.init), wait > 0 else { return nil }
        return wait
    }

    @MainActor static func seconds(_ task: UUID) -> Double {
        asked ?? AgentLinks.shared.patience(task)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done: CheckedContinuation<AgentAnswer?, Never>?

        init(_ done: CheckedContinuation<AgentAnswer?, Never>) { self.done = done }

        var finished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return done == nil
        }

        @discardableResult
        func resume(_ answer: AgentAnswer?) -> Bool {
            lock.lock()
            let waiting = done
            done = nil
            lock.unlock()
            waiting?.resume(returning: answer)
            return waiting != nil
        }
    }

    @MainActor
    final class Early {
        var hit = false
    }

    @MainActor
    static func race(_ asking: Task<AgentAnswer, Never>, seconds: Double, unseen: Double? = nil, early: Early? = nil) async -> AgentAnswer? {
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
                guard let unseen, unseen < seconds else { return }
                Task { @MainActor in
                    var since: Date?
                    while !once.finished {
                        if AgentLooking.looking() {
                            since = nil
                        } else {
                            let from = since ?? Date()
                            since = from
                            if Date().timeIntervalSince(from) >= unseen {
                                early?.hit = true
                                if !once.resume(nil) { early?.hit = false }
                                return
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
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
