import AppKit
import Foundation

extension AgentSocket {
    func link(for request: [String: Any], create: Bool, connection: UUID? = nil, name: String? = nil) -> AgentLink? {
        let links = AgentLinks.shared
        let said = request["agent"] as? [String: Any] ?? [:]
        let named = name ?? said["name"] as? String
        var found: AgentLink?
        let session = (said["session"] as? String).flatMap { $0.isEmpty ? nil : "session:" + $0.lowercased() }
        if said["id"] == nil, let session {
            let guessed = named ?? AgentLinks.displayName(executable: said["executable"] as? String ?? session.components(separatedBy: ":").dropFirst().first ?? "")
            found = links.liveLink(for: .named(session))
            if found == nil, create { found = links.join(.named(session), name: guessed) }
        } else if let connection {
            found = create ? links.join(.connection(connection), name: named) : links.liveLink(for: .connection(connection))
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
        links.heard(found.id)
        if let named, named != found.name { links.rename(found.id, named) }
        AgentLinks.open(found)
        if request["person"] as? String == "none" { links.setPatience(found.id, 0) }
        return links.link(found.id) ?? found
    }
}

extension AgentLinks {
    static func open(_ link: AgentLink) {
        guard !link.task, link.live, TaskLedger.shared.entry(link.id) == nil else { return }
        TaskLedger.shared.open(link.id, origin: .outside, title: link.name)
    }

    static func wire() {
        let links = AgentLinks.shared
        guard links.ending == nil else { return }
        links.ending = { link in
            if !link.task { TaskLedger.shared.close(link.id) }
            AgentBoard.finish(link.id, mood: link.ended?.failed == true ? .failed : .done)
            for found in AgentBoard.allTabs(of: link.id) { AgentPointers.shared.clear(found.tab.id) }
        }
    }

    static func sweepAll(at now: Date = Date()) {
        let links = AgentLinks.shared
        links.sweep(at: now) { id in
            AgentTasks.shared.running[id] != nil || AgentBoard.allTabs(of: id).contains { $0.tab.agentActing != nil }
        }
        CodexDesktop.shared.settle(at: now)
        links.forgetEnded { id in
            !AgentBoard.allTabs(of: id).isEmpty || links.link(id).map { CodexDesktop.holding($0, at: now) } == true
        }
    }

    func row(_ link: AgentLink) -> [String: Any] {
        let tabs = AgentBoard.allTabs(of: link.id).map(\.tab)
        let state = AgentSession(link: link, tabs: tabs).state(pending: AgentDesk.shared.pending)
        var row: [String: Any] = ["id": PersonCommands.short(link.id), "name": link.name, "tabs": tabs.count, "status": state.line,
                                  "state": link.live ? (state.attention ? "needs_you" : "connected") : (link.ended?.failed == true ? "failed" : "done"),
                                  "connected": PersonCommands.stamp(link.connected)]
        if let summary = link.ended?.summary { row["summary"] = summary }
        if let thread = link.codex { row["codex"] = thread.id }
        if link.task { row["task"] = true }
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
        guard !target.task else {
            throw PersonRefusal("refused", "That's a task Broadway runs. Stop it with broadway session stop.")
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
