import Foundation

@MainActor
enum AgentEndTabs {
    struct Kept: Equatable {
        var id: String
        var why: String
    }

    struct Outcome: Equatable {
        var closed: [String] = []
        var handed: [String] = []
        var kept: [Kept] = []

        var object: [String: Any] {
            ["closed": closed, "handed": handed, "kept": kept.map { ["id": $0.id, "why": $0.why] }]
        }
    }

    private static var chain: Task<Void, Never>?
    private static var ends: [UUID: Task<Outcome, Never>] = [:]

    static var limit: TimeInterval { AgentLinks.shared.idleLimit }

    static var minutes: Int { max(1, Int((limit / 60).rounded())) }

    @discardableResult
    static func begin(_ link: UUID, at now: Date = Date()) -> Task<Outcome, Never> {
        let task = queue { await pass(only: link, at: now) }
        ends[link] = task
        Task { @MainActor in
            _ = await task.value
            if ends[link] == task { ends[link] = nil }
        }
        return task
    }

    static func ending(_ link: UUID) -> Task<Outcome, Never>? {
        ends[link]
    }

    @discardableResult
    static func settle(at now: Date = Date()) async -> Outcome {
        await queue { await pass(only: nil, at: now) }.value
    }

    private static func queue(_ work: @escaping @MainActor () async -> Outcome) -> Task<Outcome, Never> {
        let before = chain
        let task = Task { @MainActor in
            await before?.value
            return await work()
        }
        chain = Task { @MainActor in _ = await task.value }
        return task
    }

    static func ended(_ tab: Tab) -> Bool {
        guard tab.agent, let task = tab.agentTask, let link = AgentLinks.shared.link(task) else { return false }
        return !link.live
    }

    static func candidates(only: UUID?) -> [(tab: Tab, browser: Browser)] {
        var seen = Set<Tab.ID>()
        return AgentBoard.browsers.flatMap { browser in
            (browser.tabs + browser.parkedAgentTabs).filter { ended($0) && (only == nil || $0.agentTask == only) }.map { ($0, browser) }
        }.filter { seen.insert($0.tab.id).inserted }
    }

    static func looking(_ tab: Tab, in browser: Browser) -> Bool {
        browser.visibleTabIDs.contains(tab.id) && browser.tabs.contains { $0 === tab }
    }

    private static func there(_ tab: Tab) -> Bool {
        ended(tab) && AgentBoard.browsers.contains { browser in (browser.tabs + browser.parkedAgentTabs).contains { $0 === tab } }
    }

    private static func pass(only: UUID?, at now: Date) async -> Outcome {
        let links = AgentLinks.shared
        var outcome = Outcome()
        let found = candidates(only: only)
        guard !found.isEmpty else { return outcome }
        let going = Set(found.map(\.tab.id))
        let others = AgentBoard.browsers.flatMap { $0.tabs + $0.parkedAgentTabs }.filter { !going.contains($0.id) }
        for (tab, browser) in found where there(tab) {
            let link = tab.agentTask.flatMap(links.link)
            let id = AgentWorkTabs.short(tab.id)
            if tab.agentFinished == nil {
                tab.agentFinished = now
                tab.agentActing = nil
                tab.agentMood = .done
            }
            let waited = now.timeIntervalSince(link?.endedAt ?? tab.agentFinished ?? now)
            if looking(tab, in: browser) || link?.person == true && tab.agentSeen {
                hand(tab, browser, link)
                outcome.handed.append(id)
                continue
            }
            let why = await AgentWorkTabs.busy(tab, among: others)
            guard there(tab) else { continue }
            if looking(tab, in: browser) || why != nil && waited >= limit {
                hand(tab, browser, link)
                outcome.handed.append(id)
            } else if let why {
                outcome.kept.append(Kept(id: id, why: why))
            } else {
                browser.closeAgentTab(tab)
                links.noteGone(id, from: link, handed: false)
                outcome.closed.append(id)
            }
        }
        return outcome
    }

    static func keepTitle(_ tabs: [(tab: Tab, browser: Browser)]) -> String {
        var names: [String] = []
        for found in tabs where found.browser.prefs.usesSpaces {
            let space = found.tab.space ?? found.browser.spaceOf(found.tab)
            if let name = found.browser.spaces.first(where: { $0.id == space })?.name, !names.contains(name) { names.append(name) }
        }
        let what = tabs.count == 1 ? "Keep this agent's tab as yours" : "Keep this agent's \(tabs.count) tabs as yours"
        guard let last = names.last else { return what + "?" }
        let spaces = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
        return what + ", in " + spaces + "?"
    }

    static func hand(_ tab: Tab, _ browser: Browser, _ link: AgentLink?) {
        let id = AgentWorkTabs.short(tab.id)
        browser.keepAgentTab(tab)
        AgentLinks.shared.noteGone(id, from: link, handed: true)
    }

    static func lines(_ outcome: Outcome) -> [String] {
        var lines: [String] = []
        if !outcome.closed.isEmpty {
            lines.append("Closed \(outcome.closed.count) tab\(outcome.closed.count == 1 ? "" : "s"): " + outcome.closed.joined(separator: ", "))
        }
        if !outcome.handed.isEmpty {
            let count = outcome.handed.count
            lines.append("\(count) tab\(count == 1 ? " is" : "s are") the person's now: " + outcome.handed.joined(separator: ", "))
        }
        for kept in outcome.kept {
            lines.append("Kept \(kept.id) open: \(kept.why). It closes once that is over, or becomes the person's after \(minutes) minutes.")
        }
        return lines
    }

    static func refusal(_ gone: AgentGoneTab, tab: String, handed: Bool) -> AgentSocket.TabRefusal {
        guard gone.kept else { return refusal(gone.how, tab: tab, handed: handed) }
        return AgentSocket.TabRefusal(code: ToolCode.notYours.rawValue, message: "Tab \(tab) is the person's now", hint: ToolCode.notYours.hint)
    }

    static func refusal(_ how: AgentLinkEnding, tab: String?, handed: Bool) -> AgentSocket.TabRefusal {
        let why = how == .left ? "Your Broadway session ended after \(minutes) minutes without a command" : "Your Broadway session ended"
        let what = handed ? ", and tab \(tab ?? "") is the person's now" : ", and its tabs closed"
        return AgentSocket.TabRefusal(code: ToolCode.sessionEnded.rawValue, message: why + what, hint: ToolCode.sessionEnded.hint)
    }
}
