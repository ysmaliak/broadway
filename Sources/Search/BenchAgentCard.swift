import AppKit

@MainActor
enum BenchAgentCard {
    static func run(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "agentcard only works on a --test run"]) }
        func sessions() -> [AgentSession] {
            browser.agentSessions(links: AgentLinks.shared.links, front: browser.agentsInFront)
        }
        func found() -> AgentSession? {
            guard let prefix = (request["link"] as? String)?.lowercased(), !prefix.isEmpty else { return nil }
            return sessions().first { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        }
        if request.keys.contains("reduced") {
            if let on = request["reduced"] as? Bool {
                Store.settings.set(on, forKey: "motion.testReduced")
            } else {
                Store.settings.removeObject(forKey: "motion.testReduced")
            }
        }
        switch request["action"] as? String {
        case "open":
            guard let session = found() else { return answer(["error": "agentcard open LINK"]) }
            KitChange.eased { AgentsFolds.shared.toggle(session.id) }
        case "lead":
            guard let session = found() else { return answer(["error": "agentcard lead LINK"]) }
            browser.pressAgent(session)
        case "close":
            guard let session = found() else { return answer(["error": "agentcard close LINK"]) }
            browser.closeAgentTabs(session)
        case "shut":
            AgentsFolds.shared.open = []
        default:
            break
        }
        answer(state(browser, sessions()))
    }

    static func state(_ browser: Browser, _ sessions: [AgentSession]) -> [String: Any] {
        let pending = AgentDesk.shared.pending
        let sections = browser.agentSections(sessions)
        let agents: [[String: Any]] = zip(sessions, sections).map { session, section in
            let lead = section.headed ? browser.agentLead(session, pending: pending) : nil
            let state = session.state(pending: pending)
            return ["id": session.id.uuidString, "title": session.link.title, "headed": section.headed, "open": section.open,
                    "fold": section.rows, "rows": AgentsLayout.rows(section), "count": AgentsLayout.count(section).map { $0 as Any } ?? NSNull(),
                    "lead": lead?.id.uuidString ?? "", "leadTitle": lead.map(Browser.agentTabName) ?? "",
                    "line": AgentsLayout.headline(state, tab: lead.map(Browser.agentTabName), acting: lead?.agentActing),
                    "tabs": session.tabs.map { $0.id.uuidString }]
        }
        var said: [String: Any] = ["agents": agents, "folded": AgentsFolds.shared.folded, "reduced": Motion.reduced,
                                   "active": browser.activeID?.uuidString ?? ""]
        if let card = AgentChrome.bench(browser)["card"] { said["card"] = card }
        if let window = browser.window ?? Links.window, let content = window.contentView {
            func box(_ view: NSView) -> [Double] {
                let frame = view.convert(view.bounds, to: nil)
                return [frame.minX, window.frame.height - frame.maxY, frame.width, frame.height].map(Double.init)
            }
            said["folders"] = content.kitSubviews(of: GroupHeadingView.self).filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }.map { heading in
                ["name": heading.group?.name ?? "", "box": box(heading), "countBox": box(heading.chipFold), "countText": heading.chipFold.text,
                 "countShown": heading.chipFold.showing] as [String: Any]
            }
        }
        return said
    }
}
