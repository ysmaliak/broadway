import Foundation

enum AgentHandoff {
    static let reasonLimit = 60
    static let seconds = (standard: 300.0, most: 900.0)

    static let spec = ToolSpec(
        name: "handoff",
        description: "Hand your tab to the person for something only they can do, such as a captcha or a one-time code, and wait until they give it back. Answers with what changed while they had it.",
        properties: ["tab": ["type": "string"],
                     "reason": ["type": "string", "description": "What the person should do, 60 characters at most"],
                     "seconds": ["type": "number", "description": "How long to wait, 300 by default and 900 at most"],
                     "optional": ["type": "boolean", "description": "Let the person skip it"]],
        required: ["tab", "reason"])

    enum Ending: Equatable {
        case done
        case skipped
        case unanswered
    }

    static func ending(_ answer: AgentAnswer?, optional: Bool) -> Ending {
        switch answer {
        case .picked(1) where optional: .skipped
        case .picked, .yes, .no, .always, .never: .done
        case .dropped, nil: .unanswered
        }
    }

    static func wait(_ arguments: [String: Any]) -> Double {
        let asked = arguments["seconds"] as? Double ?? (arguments["seconds"] as? Int).map(Double.init) ?? seconds.standard
        return min(max(asked, 1), seconds.most)
    }

    static func reason(_ arguments: [String: Any]) -> String {
        AgentQuestion.clean(arguments["reason"] as? String ?? "", limit: reasonLimit)
    }
}

extension BrowserToolbox {
    func handoff(_ arguments: [String: Any], task: UUID?) async -> ToolOutcome {
        let reason = AgentHandoff.reason(arguments)
        guard !reason.isEmpty else { return .failure("handoff needs a reason the person can read", code: .usage) }
        guard let found = find(arguments) else { return .failure("No such tab. Call tabs for the list.", code: .noTab) }
        let tab = found.tab
        guard tab.page == nil else { return .failure("Broadway internal pages are person-only", code: .personPage) }
        guard let task else { return .failure("Only an agent session can hand a tab to the person", code: .needsTask) }
        if TaskLedger.shared.entry(task)?.origin.unattended == true {
            return .failure("This task runs without the person, so nobody can take the tab", code: .refused)
        }
        let site = AgentSites.site(of: tab.pageAddress)
        if let refused = await gate(.tab, tab: tab, site: site, task: task) { return refused }
        let optional = arguments["optional"] as? Bool ?? false
        let seconds = AgentHandoff.wait(arguments)
        let before = AgentSecrets.shown(tab.pageAddress)
        let started = Date()
        var question = AgentQuestion(kind: .choice(optional ? ["Done", "Skip"] : ["Done"]), title: reason)
        question.task = task
        question.tab = tab.id
        question.site = site
        question.quoteLabel = "Handed to you"
        let mood = tab.agentMood
        tab.agentMood = .waving
        let asking = Task { @MainActor in await AgentDesk.shared.ask(question) }
        var ending = AgentHandoff.ending(await AgentPatience.race(asking, seconds: seconds), optional: optional)
        AgentDesk.shared.take(question.id, .dropped)
        if ending == .unanswered, tab.driving {
            let left = max(0, seconds - Date().timeIntervalSince(started))
            if await AgentDriving.settled(tab, patience: .milliseconds(Int(left * 1000))) { ending = .done }
        }
        if tab.agentMood == .waving { tab.agentMood = mood == .waving ? .reading : mood }
        guard ending != .unanswered else {
            return .failure("The person didn't give the tab back within \(Int(seconds)) s", code: .needsYou,
                            hint: "Tell the person, then run the same command again")
        }
        tab.handedBack = false
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let now = AgentSecrets.shown(tab.pageAddress)
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        let change = AgentChange(
            tab: id, did: "handoff",
            said: ending == .skipped ? "The person skipped it, in \(id)" : "The person gave the tab back after \(AgentChange.seconds(ms)) s, in \(id)",
            ms: ms, page: .init(url: now, title: tab.title, navigated: now != before),
            kept: ending == .skipped ? ["skipped": true] : [:])
        return ToolOutcome(text: ToolReply.notice + change.lines().joined(separator: "\n"), data: change.object())
    }
}
