import AppKit
import Foundation

@MainActor
enum PersonKnowledge {
    private static func skill(_ call: PersonCall) throws -> Skill {
        let name = try call.need("name")
        guard let found = SkillStore.shared.skill(named: name) else { throw PersonRefusal.missing("skill", name) }
        return found
    }

    private static func looked() async {
        if !Plans.shared.looked { await Plans.shared.refresh() }
    }

    static let verbs: [PersonVerb] = [
        PersonVerb("skills", "list", .look) { call in
            var arguments: [String: Any] = [:]
            if let url = call.string("url") { arguments["url"] = url }
            let told = try await PersonCommands.tool(call, "skills", arguments)
            let url = call.string("url").flatMap(URL.init(string:))
            let found = url.map { SkillStore.shared.skills(for: $0) } ?? SkillStore.shared.all
            var data: [String: Any] = ["skills": found.map { ["name": $0.name, "yours": !$0.builtIn, "about": $0.summary, "sites": $0.sites] as [String: Any] }]
            if let note = told["note"] { data["note"] = note }
            return data
        },
        PersonVerb("skills", "show", .look) { call in
            let found = try skill(call)
            return ["name": found.name, "sites": found.sites, "yours": !found.builtIn, "text": found.text]
        },
        PersonVerb("skills", "new", .arrange) { call in
            switch SkillStore.shared.save(try call.need("text")) {
            case .saved: return ["message": "Kept"]
            case .unreadable: throw PersonRefusal.usage("That isn't a skill", hint: "A skill starts with a line like # Name, then a line like sites: example.com")
            case .failed: throw PersonRefusal("failed", "It couldn't be saved")
            }
        },
        PersonVerb("skills", "duplicate", .arrange) { call in
            guard let made = SkillStore.shared.duplicate(try skill(call)) else { throw PersonRefusal("failed", "It couldn't be copied") }
            return ["name": made.name, "message": "Copied"]
        },
        PersonVerb("skills", "delete", .erase, first: { call in
            guard !(try skill(call)).builtIn else { throw PersonRefusal("refused", "A built-in skill can't be deleted") }
        }) { call in
            let found = try skill(call)
            SkillStore.shared.delete(found)
            return ["message": "Deleted"]
        },
        PersonVerb("replies", "list", .look) { _ in
            ["website": true, "watches": ReplyWatches.shared.watches.map {
                ["id": PersonCommands.short($0.id), "state": $0.replied != nil ? "replied" : $0.unreadable ? "unreadable" : "waiting", "title": $0.title, "url": AgentSecrets.shown($0.url)]
            }]
        },
        PersonVerb("replies", "stop", .arrange) { call in
            let found = try PersonCommands.pick(ReplyWatches.shared.watches, id: \.id, named: try call.need("id"), what: "watch")
            ReplyWatches.shared.stop(found.id)
            return ["id": PersonCommands.short(found.id), "message": "Stopped"]
        },
        PersonVerb("now", "list", .look) { call in
            ["website": true, "rows": NowBoard.rows(for: call.browser, at: Date()).map { ["id": $0.id, "title": $0.title, "detail": $0.detail] }]
        },
        PersonVerb("now", "done", .arrange) { call in
            let id = try call.need("id")
            guard NowBoard.rows(for: call.browser, at: Date()).contains(where: { $0.id == id }) else { throw PersonRefusal.missing("row", id) }
            NowMemory.shared.done(id)
            return ["id": id, "message": "Done"]
        },
        PersonVerb("plans", "list", .look) { _ in
            await looked()
            return ["plans": Plan.cloud.map { plan in
                let status = Plans.shared.statuses[plan]
                return ["plan": plan.name, "state": status?.connected == true ? "connected" : status?.installed == true ? "not signed in" : "not installed", "account": status?.account ?? ""]
            }]
        },
        PersonVerb("plans", "usage", .look) { _ in
            await looked()
            return ["usage": Plan.cloud.compactMap { plan -> [String: Any]? in
                guard let limit = Plans.shared.limits[plan] else { return nil }
                return ["plan": plan.name, "window": limit.window, "used": limit.used.map { "\(Int($0 * 100))%" } ?? "", "resets": PersonCommands.stamp(limit.resets), "out": limit.out]
            }]
        },
        PersonVerb("plans", "models", .look) { _ in
            await looked()
            return ["models": Plan.cloud.flatMap { plan in
                Plans.shared.models(plan).map { ["plan": plan.name, "id": $0.id, "name": $0.name, "efforts": $0.efforts.map(\.name).joined(separator: ", ")] }
            }]
        },
        PersonVerb("agents", "status", .look) { call in
            let prefs = call.browser.prefs
            var status: [String: Any] = ["switch": prefs.agentsAllowed, "mode": prefs.agentMode.rawValue, "sites": AgentSites.shared.rules.keys.sorted().map { ["site": $0, "rule": AgentSites.shared.rules[$0]?.rawValue ?? ""] }]
            if let link = call.link { status["session"] = AgentLinks.shared.row(link) }
            return status
        },
        PersonVerb("approvals", "list", .look) { call in
            ["website": true, "approvals": AgentDesk.shared.pending.map {
                ["title": $0.title, "site": $0.site ?? "", "task": $0.task.map { call.browser.taskName($0) } ?? "", "quote": $0.quote]
            }]
        },
        PersonVerb("helpers", "list", .look) { call in
            let wanted = call.string("session")?.lowercased()
            let rows = AgentTasks.shared.helpers.flatMap { parent, helpers -> [[String: Any]] in
                guard wanted == nil || parent.uuidString.lowercased().hasPrefix(wanted ?? "") else { return [] }
                return helpers.map { ["session": PersonCommands.short(parent), "id": PersonCommands.short($0.id), "state": $0.state.rawValue, "answer": $0.answer] }
            }
            return ["website": true, "helpers": rows]
        },
    ]
}
