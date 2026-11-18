import Foundation

extension Bench {
    func knowing(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        func state() -> [String: Any] {
            [
                "skills": SkillStore.shared.all.count,
                "now": NowBoard.rows(for: browser, at: Date()).map { ["title": $0.title, "detail": $0.detail, "id": $0.id] },
                "replies": ReplyWatches.shared.watches.map { ["title": $0.title, "lines": $0.lines.count, "replied": $0.replied != nil, "unreadable": $0.unreadable] as [String: Any] },
            ]
        }
        let after = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { answer(state()) } }
        switch request["action"] as? String {
        case "desk":
            let pending = AgentDesk.shared.pending
            switch request["text"] as? String {
            case "yes": pending.first.map { AgentDesk.shared.take($0.id, .yes) }
            case "no": pending.first.map { AgentDesk.shared.take($0.id, .no) }
            case let text? where text.hasPrefix("pick "):
                if let first = pending.first, let number = Int(text.dropFirst(5)) { AgentDesk.shared.take(first.id, .picked(number - 1)) }
            default: break
            }
            answer(["pending": pending.map(AgentDesk.benchRow)])
        case "visit":
            if let url = (request["text"] as? String).flatMap(URL.init(string:)) {
                let named = (request["space"] as? String).flatMap { name in browser.spaces.first { $0.name == name }?.id }
                let space = request["space"] as? String == "none" ? nil : named ?? browser.spaceID
                for _ in 0..<max(1, request["times"] as? Int ?? 1) { browser.history.record(url, title: "Visited", space: space) }
            }
            answer(state())
        case "watch":
            browser.watchForReply()
            after()
        case "check":
            Task { @MainActor in
                await ReplyWatches.shared.check()
                answer(state())
            }
        default:
            answer(state())
        }
    }
}
