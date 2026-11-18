import AppKit

enum ChatActing {
    static let canAct = "A chat can do things on the page for you"

    static func tabNote(_ short: String) -> String {
        "The tab in front of me is tab \(short). Commands without --tab work in it."
    }

    static func agentsOff(_ agent: String) -> String {
        "\(agent) reads the page and answers. To let it do things, turn on Let agents use Broadway in Settings › Agents."
    }

    static let macOnly = "This Mac reads the page and answers. Only Claude Code or Codex can do things on the page."
}

extension Browser {
    func chatActs(_ conversation: Conversation? = nil) -> Bool {
        guard let conversation = conversation ?? ai.chat, conversation.chat.kind == .chat, prefs.agentsAllowed,
              !chatIsPrivate(conversation), let plan = chatAnswerer(conversation).choice?.plan else { return false }
        return plan == .claude || plan == .chatGPT
    }

    func chatActNote(_ conversation: Conversation) -> String {
        if chatActs(conversation) { return ChatActing.canAct }
        let plan = chatAnswerer(conversation).choice?.plan
        if plan == .thisMac { return ChatActing.macOnly }
        return ChatActing.agentsOff(plan?.tool ?? "The agent")
    }

    func stopChat(_ conversation: Conversation? = nil) {
        guard let conversation = conversation ?? ai.chat else { return }
        if conversation.tools != .none { AgentTasks.shared.stop(conversation.chat.id) }
        conversation.stop()
    }

    func chatsOwnTab(_ tab: Tab, of conversation: Conversation? = nil) -> Bool {
        guard tab.agent, let task = tab.agentTask, let id = (conversation ?? ai.chat)?.chat.id else { return false }
        return AgentTasks.shared.root(task) == id
    }

    @discardableResult
    func actTurn(_ text: String, on conversation: Conversation, cutFrom cut: Int? = nil) -> Bool {
        guard let choice = conversation.choice, choice.plan != .thisMac else { return false }
        var chat = conversation.chat
        if let cut, chat.messages.indices.contains(cut) { chat.messages.removeSubrange(cut...) }
        let place = ChatPlaces.shared.place(of: conversation)
        let front = place?.tab.flatMap { id in tabs.first { $0.id == id } }.flatMap { tab in
            tab.canBeRead && (!tab.agent || chatsOwnTab(tab, of: conversation)) ? tab : nil
        }
        let attachments = conversation.attachments.filter { if case .tab = $0.kind { return true } else { return false } }
        let started = AgentTasks.shared.start(prompt: text, choice: choice, prefs: prefs, command: AgentTasks.shared.helperCommand ?? AgentCommand.path,
                                              chat: chat, prepare: { [weak self] made in
            made.attachments = attachments
            made.frontNote = front.map { ChatActing.tabNote(AgentWorkTabs.short($0.id)) }
            made.followsFront = false
            made.pageFinder = { [weak self] id in self?.tabs.first { $0.id == id } }
            made.seen = { [weak self, weak made] in self?.ai.chat === made && self?.chatOpen == true }
            if let place { ChatPlaces.shared.set(place, for: made) }
            TaskLedger.shared.markChat(made.chat.id)
            if let front { AgentLinks.shared.setCurrentTab(made.chat.id, AgentWorkTabs.short(front.id)) }
        }) { event in
            if case .done(let said) = event, !said.isEmpty { ChatColumnView.announce(said) }
        }
        guard let started else { return false }
        ai.chat = started
        return true
    }

    func plainChat(_ conversation: Conversation) -> Conversation {
        guard conversation.tools != .none, !conversation.running, conversation.chat.kind == .chat else { return conversation }
        let made = Conversation(chat: conversation.chat, saved: conversation.saved, prefs: prefs)
        made.pageFinder = { [weak self] id in self?.tabs.first { $0.id == id } }
        made.seen = { [weak self, weak made] in self?.ai.chat === made && self?.chatOpen == true }
        made.happened = { happening in
            guard case .done(let text) = happening, !text.isEmpty else { return }
            ChatColumnView.announce(text)
        }
        made.followsFront = false
        made.attachments = conversation.attachments.filter { if case .tab = $0.kind { return true } else { return false } }
        if let place = ChatPlaces.shared.place(of: conversation) { ChatPlaces.shared.set(place, for: made) }
        ai.chat = made
        return made
    }
}
