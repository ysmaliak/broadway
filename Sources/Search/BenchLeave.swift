import AppKit

@MainActor
enum BenchLeave {
    static let verbs: Set<String> = ["leave"]

    static func run(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "leave only works on a --test run"]); return }
        let action = request["action"] as? String ?? "state"
        switch action {
        case "state":
            answer(state())
            return
        case "hold":
            LeaveHold.hold(request["value"] as? String != "off")
            answer(state())
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
        switch (action, value) {
        case ("answer", "stay"), ("answer", "leave"):
            guard tab.leaveQuestion != nil else { answer(["error": "no question on \(wanted)"]); return }
            browser.answerLeave(tab, leave: value == "leave")
        case ("do", "reload"):
            if browser.activeID == tab.id { browser.reload() } else { tab.reload() }
        case ("do", "close"):
            if browser.activeID == tab.id { browser.closeFront() } else { browser.closeTab(tab) }
        case ("do", "window"):
            browser.window?.performClose(nil)
        default:
            answer(["error": "leave state|hold on|off|answer ID stay|leave|do ID reload|close|window"])
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { answer(state()) }
    }

    private static func every() -> [(tab: Tab, browser: Browser)] {
        Browsers.all.flatMap { browser in (browser.tabs + browser.parkedTabs).map { (tab: $0, browser: browser) } }
    }

    private static func state() -> [String: Any] {
        let cards = Browsers.all.compactMap { $0.window?.contentView }.flatMap { $0.kitSubviews(of: StuckCardView.self) }
        return [
            "held": LeaveHold.held,
            "windows": Browsers.all.count,
            "shown": Browsers.all.filter { $0.window?.isVisible == true }.count,
            "tabs": every().map { tab, browser in
                [
                    "id": Bench.short(tab), "url": tab.address?.absoluteString ?? "", "pid": tab.built?.processID ?? 0,
                    "asked": tab.leaveQuestion != nil, "closing": tab.leaveClosing?.open == true,
                    "active": browser.activeID == tab.id, "loading": tab.loading, "asleep": tab.asleep,
                    "card": cards.contains { $0.tab === tab && $0.words.title == LeaveWords.title && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor },
                ] as [String: Any]
            },
        ]
    }
}
