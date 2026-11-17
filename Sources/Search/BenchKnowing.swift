import Foundation

extension Bench {
    func knowing(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let drafts = browser.drafts
        func state() -> [String: Any] {
            var out: [String: Any] = [
                "memory": MemoryStore.shared.notes.count, "skills": SkillStore.shared.all.count,
                "routinesOn": Routines.shared.on, "watchOn": Eye.shared.on, "looking": Eye.shared.looking,
                "routines": Routines.shared.routines.map {
                    ["id": String($0.id.uuidString.prefix(8)).lowercased(), "schedule": $0.schedule, "ran": $0.lastRun != nil,
                     "result": $0.result?.line ?? "", "chatKind": $0.result?.chat.flatMap { id in ChatStore.shared.chats.first { $0.id == id }?.kind.rawValue } ?? ""]
                },
                "now": NowBoard.rows(for: browser, at: Date()).map { ["title": $0.title, "detail": $0.detail, "id": $0.id] },
                "replies": ReplyWatches.shared.watches.map { ["title": $0.title, "lines": $0.lines.count, "replied": $0.replied != nil, "unreadable": $0.unreadable] as [String: Any] },
                "drafting": drafts.working != nil,
            ]
            if let preview = drafts.preview {
                out["preview"] = preview.answers.map { ["box": $0.field.title, "text": $0.text] }
                out["warned"] = preview.warned
            }
            if let eye = Eye.shared.trouble { out["trouble"] = eye }
            return out
        }
        let after = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { answer(state()) } }
        switch request["action"] as? String {
        case "remember":
            let source = MemorySource(by: "you", title: "bench", day: MemoryStore.dayName(Date()), pages: [])
            MemoryStore.shared.remember(request["text"] as? String ?? "", subject: .you, name: nil, source: source)
            answer(state())
        case "routines":
            Routines.shared.on = request["on"] as? Bool ?? true
            answer(state())
        case "routine":
            let added = Routines.shared.add(schedule: request["schedule"] as? String ?? "", prompt: request["text"] as? String ?? "")
            guard case .added(let routine) = added else { answer(["error": "not a routine"]); return }
            Routines.shared.runNow(routine.id)
            after()
        case "eye":
            Eye.shared.on = request["on"] as? Bool ?? true
            answer(state())
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
        case "look":
            Eye.shared.look(.morning)
            after()
        case "watch":
            browser.watchForReply()
            after()
        case "check":
            Task { @MainActor in
                await ReplyWatches.shared.check()
                answer(state())
            }
        case "draftreply":
            Plans.shared.standIn(FakeProvider(plan: .claude, script: [.emit(.text(request["text"] as? String ?? "")), .emit(.finished(ProviderUsage()))]), for: .claude)
            Task { @MainActor in
                await Plans.shared.refresh()
                answer(state())
            }
        case "draft":
            drafts.begin()
            after()
        case "fill":
            drafts.confirm()
            after()
        default:
            answer(state())
        }
    }
}
