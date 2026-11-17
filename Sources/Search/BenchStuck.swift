import AppKit

@MainActor
enum BenchStuck {
    static let verbs: Set<String> = ["stuck"]

    static func run(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "stuck only works on a --test run"]); return }
        let action = request["action"] as? String ?? "state"
        switch action {
        case "state":
            answer(["tabs": every().map { row($0.tab, $0.browser) }, "times": times()])
            return
        case "waits":
            if let given = request["times"] as? [Double], given.count == 3 {
                StuckClock.shorten(StuckTimes(question: given[0], agent: given[1], quiet: given[2]))
            } else {
                StuckClock.shorten(nil)
            }
            answer(["times": times()])
            return
        default:
            break
        }
        let wanted = (request["id"] as? String ?? "").lowercased()
        guard !wanted.isEmpty, let (tab, browser) = every().first(where: { $0.tab.id.uuidString.lowercased().hasPrefix(wanted) }) else {
            answer(["error": "no tab \(wanted)"])
            return
        }
        let value = request["value"] as? String ?? ""
        switch action {
        case "said":
            switch value {
            case "stuck": browser.heardStuck(tab)
            case "answering": browser.heardAnswering(tab)
            default: answer(["error": "stuck said ID stuck|answering"]); return
            }
        case "answer":
            guard ["wait", "reload"].contains(value), tab.stuck.card else {
                answer(["error": tab.stuck.card ? "stuck answer ID wait|reload" : "no card on \(wanted)"])
                return
            }
            browser.answerStuck(tab, reload: value == "reload")
        case "do":
            if value == "sleep" {
                browser.sleep(tab) { said in answer(["said": said].merging(row(tab, browser)) { $1 }) }
                return
            }
            guard act(value, on: tab, in: browser, url: request["url"] as? String) else {
                answer(["error": "stuck do ID reload|stop|back|forward|close|sleep|home|go URL"])
                return
            }
        default:
            answer(["error": "stuck state|said|answer|do|waits"])
            return
        }
        answer(row(tab, browser))
    }

    private static func act(_ value: String, on tab: Tab, in browser: Browser, url: String?) -> Bool {
        let front = browser.activeID == tab.id
        switch value {
        case "reload": if front { browser.reload() } else { tab.reload() }
        case "stop": tab.stop()
        case "back": if front { browser.back() } else { tab.back() }
        case "forward": if front { browser.forward() } else { tab.forward() }
        case "close": browser.close(tab)
        case "home": browser.goHome(tab)
        case "go":
            guard let url = url.flatMap(Address.url(from:)) else { return false }
            tab.go(to: url)
        default: return false
        }
        return true
    }

    private static func every() -> [(tab: Tab, browser: Browser)] {
        Browsers.all.flatMap { browser in (browser.tabs + browser.parkedTabs).map { (tab: $0, browser: browser) } }
    }

    private static func times() -> [String: Double] {
        let times = StuckClock.times
        return ["question": times.question, "agent": times.agent, "quiet": times.quiet]
    }

    static func row(_ tab: Tab, _ browser: Browser) -> [String: Any] {
        let now = Date()
        let state = tab.stuck
        var row: [String: Any] = [
            "id": Bench.short(tab), "url": tab.address?.absoluteString ?? "", "committed": tab.committed?.absoluteString ?? "",
            "stuck": state.stuck, "card": state.card, "owed": state.owed, "pid": tab.built?.processID ?? 0,
            "agent": tab.agentWorking, "asleep": tab.asleep, "loading": tab.loading, "onScreen": browser.stuckOnScreen(tab),
            "active": browser.activeID == tab.id, "restarts": state.restarts, "owesAgent": state.owesAgent,
            "open": browser.tabs.contains { $0 === tab } || browser.parkedTabs.contains { $0 === tab },
        ]
        let drawn = Browsers.all.compactMap { $0.window?.contentView }.flatMap { $0.kitSubviews(of: StuckCardView.self) }
        row["cardDrawn"] = drawn.contains { $0.tab === tab && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
        if let since = state.since { row["since"] = now.timeIntervalSince(since) }
        if let due = state.due { row["due"] = due.timeIntervalSince(now) }
        if let quiet = state.quietUntil, quiet > now { row["quiet"] = quiet.timeIntervalSince(now) }
        return row
    }
}
