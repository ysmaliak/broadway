import AppKit

enum FieldIntent: Equatable {
    case question, task

    private static let asks: Set<String> = ["what", "what's", "whats", "why", "how", "when", "who", "where", "which", "is", "are", "can", "could",
                                            "does", "do", "did", "should", "would", "will", "am", "was", "were"]
    private static let does: Set<String> = ["find", "book", "buy", "compare", "order", "summarize", "summarise", "send", "check", "research", "plan",
                                            "schedule", "reply", "collect", "gather", "make", "fill", "unsubscribe", "cancel", "add", "write",
                                            "draft", "list", "track", "return", "download", "organize", "organise", "clean", "update", "create", "go"]

    static func of(_ text: String) -> FieldIntent? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(separator: " ")
        guard words.count >= 2, trimmed.count <= 500, !trimmed.contains("://") else { return nil }
        let first = words[0].lowercased().trimmingCharacters(in: .punctuationCharacters)
        if trimmed.hasSuffix("?") || asks.contains(first) { return .question }
        if words.count >= 3, does.contains(first) { return .task }
        return nil
    }
}

extension Browser {
    var fieldSearchOnTop: String? {
        get { ai.fieldSearchOnTop }
        set { ai.fieldSearchOnTop = newValue }
    }

    var fieldTasks: Bool {
        guard prefs.agentsAllowed else { return false }
        guard Plans.shared.looked else { return true }
        guard let plan = Plans.shared.agent(prefs) else { return false }
        return plan != .thisMac
    }

    private func fieldAIRow(_ kind: FieldIntent, _ text: String) -> Suggestion {
        let id = kind == .task ? "task:" : launching ? "ask-new:" : "ask:"
        var row = Suggestion(key: kind == .task ? "Start a task" : "Ask", title: text, url: FieldAction.nowhere, kind: .action(id + text))
        row.symbol = kind == .task ? "sparkles" : "questionmark.bubble"
        return row
    }

    func addFieldAIRows() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let intent = FieldIntent.of(text) else { return }
        lookAtPlans()
        let taskRow = fieldTasks ? fieldAIRow(.task, text) : nil
        let askRow = prefs.askAndChat && !(active?.asksAgent ?? false) ? fieldAIRow(.question, text) : nil
        let rows = (intent == .task ? [taskRow, askRow] : [askRow, taskRow]).compactMap { $0 }
        guard !rows.isEmpty else { return }
        if fieldSearchOnTop == typed {
            offers.insert(contentsOf: rows, at: min(1, offers.count))
            return
        }
        var leading = rows
        leading[0].leads = true
        offers.insert(contentsOf: leading, at: 0)
        ending = nil
    }

    func fieldTabKey() -> Bool {
        guard case .action(let id)? = offers.first?.kind, offers.first?.leads == true,
              id.hasPrefix("task:") || id.hasPrefix("ask:") || id.hasPrefix("ask-new:") else { return false }
        fieldSearchOnTop = typed
        picked = nil
        retype()
        return true
    }

    func runFieldAI(_ kind: String, _ text: String) {
        switch kind {
        case "task": startFieldTask(text)
        case "ask": askFromField(text, withPage: true)
        case "ask-new": askFromField(text, withPage: false)
        default: break
        }
    }

    func startFieldTask(_ text: String, command: String? = AgentCommand.path) {
        Task { @MainActor in
            if !Plans.shared.looked { await Plans.shared.refresh() }
            guard prefs.agentsAllowed else { return announce("Turn on Let agents use Broadway in Settings › Agents first") }
            let picked = Plans.shared.agent(prefs)
            guard prefs.aiPlan != .thisMac, picked != .thisMac else {
                return announce("This Mac can't run a task. Pick another agent in Settings › Agents.")
            }
            guard let plan = picked else {
                return announce(Plans.shared.trouble(prefs) ?? TextActions.nothingConnected)
            }
            _ = AgentTasks.shared.start(prompt: text, choice: Plans.shared.defaultChoice(plan), prefs: prefs, command: command) { [weak self] event in
                if case .failed(let said) = event { self?.announce(said) }
            }
        }
    }

    func askFromField(_ text: String, withPage: Bool) {
        guard prefs.askAndChat, let tab = active else { return }
        Task { @MainActor in
            await openLine(tab, withPage: withPage)
            guard let line = ai.line, line.tab == tab.id else { return }
            line.fromField = true
            line.run(text)
        }
    }

    func continueAsTask(_ line: PageAsk) {
        guard let asked = line.conversation.chat.messages.last(where: { $0.role == .user })?.text else { return }
        closeLine()
        startFieldTask(asked)
    }

    func fieldLineKey(_ line: PageAsk, _ event: NSEvent, _ plain: NSEvent.ModifierFlags, _ key: String) -> Bool {
        guard line.fromField else { return false }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if plain.isEmpty, isReturn, line.draft.trimmingCharacters(in: .whitespaces).isEmpty {
            copyAnswer(line)
            return true
        }
        if plain == .command, isReturn {
            continueAsTask(line)
            return true
        }
        if plain == .command, key == "r" {
            line.conversation.askAgain()
            return true
        }
        return false
    }
}
