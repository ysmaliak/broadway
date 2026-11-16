import AppKit

@MainActor
enum BenchGlass {
    static func show(_ bars: [String], _ browser: Browser) {
        let all = Set(bars)
        Shield.shared.offer = all.contains("shield") ? browser.hereHost : nil
        Developer.shared.offer = all.contains("developer") ? LocalServer.key(browser.active?.pageAddress) : nil
        if all.contains("done"), let tab = browser.activeID {
            browser.forms.show(filled: FormApplied(filled: 3), tab: tab)
        } else {
            browser.forms.dismissDone()
        }
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        if all.contains("agent") {
            let question = AgentQuestion(kind: .approval(.send), title: "Send this message?", tab: browser.activeID,
                                         site: browser.hereHost, reason: "You asked me to reply to the thread.")
            Task { _ = await AgentDesk.shared.ask(question) }
        }
    }

    static func dark(_ on: Bool) {
        NSApp.appearance = NSAppearance(named: on ? .darkAqua : .aqua)
    }
}
