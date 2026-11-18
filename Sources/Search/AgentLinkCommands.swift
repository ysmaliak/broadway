import AppKit
import Foundation

extension AgentSocket {
    func link(for request: [String: Any], create made: Bool, rejoin: Bool = false, connection: UUID? = nil, name: String? = nil) -> AgentLink? {
        let links = AgentLinks.shared
        let create = made || rejoin && links.links.contains { !$0.live && !AgentBoard.allTabs(of: $0.id).isEmpty && $0.key == Self.key(request) }
        let said = request["agent"] as? [String: Any] ?? [:]
        let named = name ?? said["name"] as? String
        var found: AgentLink?
        let session = (said["session"] as? String).flatMap { $0.isEmpty ? nil : "session:" + $0.lowercased() }
        let process = Self.process(said)
        if said["id"] == nil, let session {
            let guessed = named ?? AgentLinks.displayName(executable: said["executable"] as? String ?? session.components(separatedBy: ":").dropFirst().first ?? "")
            found = links.liveLink(for: .named(session))
            if found == nil, create { found = links.join(.named(session), name: guessed) }
            if found == nil, !create, let process {
                found = links.liveLink(for: .process(pid: process.pid, started: process.started)) ?? links.live.last { $0.process == process }
            }
            if let found, let process, found.key == .named(session), AgentLinks.watchable(said["executable"] as? String, session: session) {
                links.watch(found.id, process)
            }
        } else if let connection {
            found = create ? links.join(.connection(connection), name: named) : links.liveLink(for: .connection(connection))
            if let found, let process, AgentLinks.watchable(said["executable"] as? String, session: nil) { links.watch(found.id, process) }
        } else if let id = (said["id"] as? String)?.lowercased(), !id.isEmpty {
            found = links.liveLink(for: .named(id)) ?? links.live.first { $0.id.uuidString.lowercased().hasPrefix(id) }
            if found == nil, create { found = links.join(.named(id), name: named ?? id) }
        } else if let pid = (said["pid"] as? NSNumber)?.int32Value, pid > 1 {
            let started = (said["started"] as? NSNumber)?.int64Value ?? 0
            let key = AgentLinkKey.process(pid: pid, started: started)
            if let live = links.liveLink(for: key) {
                found = live
            } else if create {
                found = links.join(key, name: named ?? AgentLinks.displayName(executable: said["executable"] as? String ?? ""))
            }
        }
        guard let found else { return nil }
        if request["hook"] as? Bool != true { links.heard(found.id) }
        if let named, named != found.name { links.rename(found.id, named) }
        AgentLinks.open(found)
        if request["person"] as? String == "none" { links.setPatience(found.id, 0) }
        return links.link(found.id) ?? found
    }
}

extension AgentSocket {
    static func key(_ request: [String: Any]) -> AgentLinkKey? {
        let said = request["agent"] as? [String: Any] ?? [:]
        if said["id"] == nil, let session = said["session"] as? String, !session.isEmpty { return .named("session:" + session.lowercased()) }
        if let id = (said["id"] as? String)?.lowercased(), !id.isEmpty { return .named(id) }
        guard let process = process(said) else { return nil }
        return .process(pid: process.pid, started: process.started)
    }

    static func process(_ said: [String: Any]) -> AgentProcessID? {
        guard let pid = (said["pid"] as? NSNumber)?.int32Value, pid > 1 else { return nil }
        return AgentProcessID(pid: pid, started: (said["started"] as? NSNumber)?.int64Value ?? 0)
    }
}

extension AgentLinks {
    nonisolated static func agentProgram(_ name: String?) -> Bool {
        let base = ((name ?? "") as NSString).lastPathComponent.lowercased()
        return ["claude", "codex", "cursor", "windsurf"].contains { base.hasPrefix($0) }
    }

    nonisolated static func watchable(_ name: String?, session: String?) -> Bool {
        guard agentProgram(name) else { return false }
        guard let kind = session?.components(separatedBy: ":").dropFirst().first, !kind.isEmpty else { return true }
        return ((name ?? "") as NSString).lastPathComponent.lowercased().hasPrefix(kind)
    }

    static func open(_ link: AgentLink) {
        guard link.live, TaskLedger.shared.entry(link.id) == nil else { return }
        TaskLedger.shared.open(link.id, title: link.name)
    }

    static func wire() {
        let links = AgentLinks.shared
        if links.rejoining == nil { links.rejoining = AgentWorkTabs.takeBack }
        guard links.ending == nil else { return }
        links.ending = { link in
            TaskLedger.shared.close(link.id)
            AgentBoard.finish(link.id, mood: link.ended?.failed == true ? .failed : .done)
            for found in AgentBoard.allTabs(of: link.id) { AgentPointers.shared.clear(found.tab.id) }
        }
        links.asking = { id in
            let mine = Set(AgentBoard.allTabs(of: id).map(\.tab.id))
            return AgentDesk.shared.pending.contains { $0.task == id || $0.tab.map(mine.contains) == true }
                || AgentBoard.allTabs(of: id).contains { $0.tab.agentMood == .waving }
                || AgentDownloadWatch.downloading(mine, since: Date().addingTimeInterval(-links.idleLimit))
        }
        links.resting = { id in
            for found in AgentBoard.allTabs(of: id) where found.tab.agentFinished == nil && found.tab.agentActing == nil {
                if found.tab.agentMood == .reading || found.tab.agentMood == .typing { found.tab.agentMood = .done }
                AgentPointers.shared.clear(found.tab.id)
            }
        }
    }

    static func sweepAll(at now: Date = Date()) {
        let links = AgentLinks.shared
        links.sweep(at: now) { id in
            AgentBoard.allTabs(of: id).contains { $0.tab.agentActing != nil }
        }
        CodexDesktop.shared.settle(at: now)
        links.forgetEnded { id in
            !AgentBoard.allTabs(of: id).isEmpty || links.link(id).map { CodexDesktop.holding($0, at: now) } == true
        }
    }

    static func word(_ state: AgentLinkState) -> String {
        switch state {
        case .needsYou: return "needs_you"
        case .finished: return "finished"
        case .quiet: return "idle"
        default: return "connected"
        }
    }

    func row(_ link: AgentLink) -> [String: Any] {
        let tabs = AgentBoard.allTabs(of: link.id).map(\.tab)
        let state = AgentSession(link: link, tabs: tabs).state(pending: AgentDesk.shared.pending)
        var row: [String: Any] = ["id": PersonCommands.short(link.id), "name": link.name, "tabs": tabs.count, "status": state.line,
                                  "state": link.live ? Self.word(state) : (link.ended?.failed == true ? "failed" : "done"),
                                  "connected": PersonCommands.stamp(link.connected)]
        if let summary = link.ended?.summary { row["summary"] = summary }
        if let thread = link.codex { row["codex"] = thread.id }
        return row
    }
}

@MainActor
enum PersonAgents {
    static let verbs: [PersonVerb] = [
        PersonVerb("agents", "connect", .tool) { call in
            guard let link = call.link else {
                throw PersonRefusal("no_agent", "Broadway couldn't tell which agent this is", hint: "Set BROADWAY_AGENT to a name for this session, or run broadway from the agent")
            }
            AgentLinks.shared.announce(link.id)
            return ["connected": AgentLinks.shared.row(link)]
        },
        PersonVerb("agents", "list", .tool) { _ in
            let links = AgentLinks.shared
            return ["agents": links.links.map(links.row)]
        },
        PersonVerb("agents", "done", .tool) { call in
            try await end(call, mine: true)
        },
        PersonVerb("agents", "idle", .tool) { call in
            guard let link = call.link else {
                throw PersonRefusal("no_agent", "This agent has no session in Broadway")
            }
            let links = AgentLinks.shared
            links.finish(link.id, summary: call.string("summary"))
            return ["agent": links.link(link.id).map(links.row) ?? [:], "message": "Your card reads finished until your next command"]
        },
        PersonVerb("agents", "disconnect", .tool, softer: { call in
            guard let named = call.string("id") else { return nil }
            return call.link.map { PersonCommands.short($0.id).hasPrefix(named.lowercased()) } == true ? nil : .arrange
        }) { call in
            try await end(call, mine: call.string("id") == nil)
        },
    ]

    private static func end(_ call: PersonCall, mine: Bool) async throws -> [String: Any] {
        let links = AgentLinks.shared
        let target: AgentLink
        if mine {
            guard let link = call.link else { throw PersonRefusal("no_agent", "This agent has no session to end") }
            target = link
        } else {
            target = try PersonCommands.pick(links.live, id: \.id, named: call.need("id"), what: "agent session")
        }
        if call.flag("close"), call.flag("keep") { throw PersonRefusal.usage("--close and --keep pull opposite ways, so pick one") }
        let summary = call.string("summary")
        let here = links.currentTab(target.id)
        links.end(target.id, call.flag("failed") ? .failed(summary) : .done(summary))
        var data: [String: Any] = ["ended": links.link(target.id).map(links.row) ?? [:]]
        var lines: [String] = []
        if call.flag("close") {
            let found = AgentWorkTabs.tabs(of: target.id, in: call.box)
            let unseen = found.filter { AgentWorkTabs.unseen($0.tab, in: $0.browser) }
            let every = call.box.browsers.flatMap { $0.tabs + $0.parkedAgentTabs }
            let said = await AgentWorkTabs.tidy(unseen, everyTab: every)
            data["closed"] = said.closed
            data["tidy"] = said.object
            if !said.closed.isEmpty { lines.append("Closed \(said.closed.count) tab\(said.closed.count == 1 ? "" : "s") the person never looked at: " + said.closed.joined(separator: ", ")) }
            lines += said.lines
        }
        let left = AgentWorkTabs.tabs(of: target.id, in: call.box)
        data["tabs"] = left.map { AgentWorkTabs.row($0.tab, current: here) }
        data["left"] = left.count
        let ids = left.map { AgentWorkTabs.short($0.tab.id) }.joined(separator: ", ")
        lines.insert(left.isEmpty ? "Ended. 0 tabs of yours are left open." : "Ended. \(left.count) tab\(left.count == 1 ? "" : "s") of yours left open for the person: \(ids).", at: 0)
        data["message"] = lines.joined(separator: "\n")
        return data
    }
}
