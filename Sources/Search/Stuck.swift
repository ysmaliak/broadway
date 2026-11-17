import AppKit
import WebKit

@MainActor
enum StuckClock {
    private static var shortened: StuckTimes?

    static var times: StuckTimes { Store.testing ? shortened ?? .standard : .standard }

    static func shorten(_ times: StuckTimes?) {
        guard Store.testing else { return }
        shortened = times
    }
}

@MainActor
final class StuckEnd {
    weak var view: WKWebView?
    var heard = false

    init(view: WKWebView) {
        self.view = view
    }
}

enum StuckWords {
    static let title = "This page stopped answering"
    static let text = "Reload starts it again. Anything typed into it may be lost."
    static let reload = "Reload"
    static let wait = "Wait"
    static let agent = "The page stopped answering, so Broadway loaded its address again. Look at the page before you repeat anything."
}

extension WKWebView {
    var processID: Int {
        let key = NSSelectorFromString("_webProcessIdentifier")
        guard responds(to: key) else { return 0 }
        return (value(forKey: "_webProcessIdentifier") as? NSNumber)?.intValue ?? 0
    }
}

extension Tab {
    var isStuck: Bool { stuck.stuck }

    var agentWorking: Bool { agent && !driving && agentFinished == nil }

    func reach(_ ask: StuckAsk) -> Bool {
        let redoing = stuckRedoing
        stuckRedoing = false
        let plan = StuckRules.plan(.ask(ask), stuck: isStuck, remembers: built != nil && !agent && !redoing)
        return follow(plan)
    }

    func reachToEnd() {
        guard isStuck, let built else { return }
        _ = endProcess(of: built)
    }

    func cameForward() {
        _ = StuckRules.cameForward(&stuck, agent: agentWorking)
    }

    func takeStuckFailure() -> ToolOutcome? {
        guard StuckRules.takeAgentFailure(&stuck) else { return nil }
        return .failure(StuckWords.agent, code: .pageReloaded, retrySafe: false)
    }

    @discardableResult
    func follow(_ plan: StuckPlan) -> Bool {
        switch plan {
        case .asIs:
            return false
        case .remember(let ask):
            StuckRules.remember(ask, in: &stuck, at: Date())
            return false
        case .endAndSleep:
            restAfterEnd()
            return true
        case .endAndClose:
            reachToEnd()
            return false
        case .endThen(let ask):
            restart { [weak self] in self?.redo(ask) }
            return true
        }
    }

    func restart(then next: @escaping () -> Void) {
        guard let built else {
            stuck.letGo()
            next()
            return
        }
        if endProcess(of: built) {
            next()
            return
        }
        sleep(picture: nil)
        next()
    }

    func endedOnPurpose(_ webView: WKWebView) -> Bool {
        guard let end = stuckEnd, end.view === webView else {
            if built === webView { stuck.letGo() }
            return false
        }
        end.heard = true
        stuckEnd = nil
        return true
    }

    func openAgain(_ url: URL?) {
        if asleep {
            _ = wake()
        } else if let url {
            web.open(url)
        }
    }

    private func restAfterEnd() {
        guard built != nil, address != nil else {
            reachToEnd()
            return
        }
        sleep(picture: nil)
    }

    private func redo(_ ask: StuckAsk) {
        stuckRedoing = true
        defer { stuckRedoing = false }
        switch ask {
        case .reload(let fromOrigin):
            if asleep { _ = wake() } else { reload(fromOrigin: fromOrigin) }
        case .stop:
            restAfterEnd()
        case .back:
            if asleep { _ = wake() } else { back() }
        case .forward:
            if asleep { _ = wake() } else { forward() }
        case .address(let url):
            go(to: url)
        }
    }

    private func endProcess(of web: WKWebView) -> Bool {
        stuck.letGo()
        let before = web.processID
        let end = StuckEnd(view: web)
        stuckEnd = end
        let reset = NSSelectorFromString("_killWebContentProcessAndResetState")
        let plain = NSSelectorFromString("_killWebContentProcess")
        if web.responds(to: reset) {
            web.perform(reset)
        } else if web.responds(to: plain) {
            web.perform(plain)
        }
        let gone = end.heard || web.processID != before || before == 0
        if gone, !end.heard {
            DispatchQueue.main.asyncAfter(deadline: .now() + StuckTimes.endHolds) { [weak self] in
                guard let self, stuckEnd === end else { return }
                stuckEnd = nil
            }
        } else if !gone {
            stuckEnd = nil
        }
        return gone
    }
}

extension Browser {
    @objc(_webViewWebProcessDidBecomeUnresponsive:)
    func webViewProcessStoppedAnswering(_ webView: WKWebView) {
        guard let tab = anyTab(for: webView) else { return }
        heardStuck(tab)
    }

    @objc(_webViewWebProcessDidBecomeResponsive:)
    func webViewProcessAnswersAgain(_ webView: WKWebView) {
        guard let tab = anyTab(for: webView) else { return }
        heardAnswering(tab)
    }

    func heardStuck(_ tab: Tab) {
        guard tab.built != nil, tab.page == nil else { return }
        let agent = tab.agentWorking
        switch StuckRules.heard(&tab.stuck, at: Date(), agent: agent, times: StuckClock.times) {
        case .redo(let ask):
            tab.follow(StuckRules.redo(ask))
        case .askAt(let due):
            later(due) { [weak self, weak tab] in
                guard let self, let tab else { return }
                stuckDue(tab)
            }
        case .endAgentAt(let due):
            later(due) { [weak self, weak tab] in
                guard let self, let tab else { return }
                stuckAgentDue(tab)
            }
        case .nothing:
            break
        }
    }

    func heardAnswering(_ tab: Tab) {
        StuckRules.answered(&tab.stuck)
    }

    func stuckOnScreen(_ tab: Tab) -> Bool {
        !shut && visibleTabIDs.contains(tab.id)
    }

    func stuckDue(_ tab: Tab) {
        _ = StuckRules.due(&tab.stuck, at: Date(), onScreen: stuckOnScreen(tab), agent: tab.agentWorking)
    }

    func stuckAgentDue(_ tab: Tab) {
        guard StuckRules.agentDue(tab.stuck, at: Date(), agent: tab.agentWorking) else { return }
        let url = tab.committed ?? tab.address
        tab.restart { [weak tab] in
            guard let tab else { return }
            tab.openAgain(url)
        }
        StuckRules.restartedForAgent(&tab.stuck)
    }

    func answerStuck(_ tab: Tab, reload: Bool) {
        guard reload else {
            StuckRules.wait(&tab.stuck, at: Date(), times: StuckClock.times)
            return
        }
        let url = tab.address ?? tab.committed
        tab.restart { [weak tab] in tab?.openAgain(url) }
    }

    private func later(_ due: Date, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due.timeIntervalSinceNow)) {
            MainActor.assumeIsolated { work() }
        }
    }
}
