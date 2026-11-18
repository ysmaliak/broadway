import AppKit

struct ChatPlace: Equatable {
    var tab: Tab.ID?
    var title: String
    var url: URL?
    var shut = false
    var agentTab = false
    var kept = false
    var macByItself = false
}

enum ChatAnswerer: Equatable {
    case agent(ModelChoice)
    case refused(String)

    static let noAgent = "Install Claude Code or Codex and sign in"
    static let notPrivate = "Not available in a private window"
    static let macOff = "This Mac can't answer now. Pick another agent in Settings › Agents."
    static let taskDone = "This task has finished"

    var choice: ModelChoice? {
        if case .agent(let choice) = self { return choice }
        return nil
    }

    var refusal: String? {
        if case .refused(let said) = self { return said }
        return nil
    }
}

@MainActor
final class ChatPlaces {
    static let shared = ChatPlaces()

    private let kept = NSMapTable<Conversation, Box>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    final class Box {
        var place: ChatPlace
        init(_ place: ChatPlace) { self.place = place }
    }

    private var behind: [UUID: Conversation] = [:]

    func place(of conversation: Conversation) -> ChatPlace? { kept.object(forKey: conversation)?.place }

    func leave(_ conversation: Conversation?) {
        behind = behind.filter { $0.value.running }
        guard let conversation, conversation.running else { return }
        behind[conversation.chat.id] = conversation
    }

    func takeBack(_ id: UUID) -> Conversation? { behind.removeValue(forKey: id) }

    func stopAll() {
        for conversation in behind.values { conversation.stop() }
    }

    func behind(_ id: UUID) -> Conversation? { behind[id] }

    func set(_ place: ChatPlace, for conversation: Conversation) {
        if let box = kept.object(forKey: conversation) { box.place = place } else { kept.setObject(Box(place), forKey: conversation) }
    }
}

extension Browser {
    var chatOpen: Bool { ai.chatShown && sidePanelShown && sidePanel == .chat }

    var chatAllowed: Bool { prefs.askAndChat && !isPopup }

    func toggleChat() {
        guard chatAllowed else { return }
        if chatOpen { hideChat() } else if let tab = active { showChat(tab) }
    }

    func showChat(_ tab: Tab) {
        guard chatAllowed else { return }
        presentChat()
    }

    private func presentChat() {
        ChatStore.shared.load()
        Task { @MainActor in if !Plans.shared.looked { await Plans.shared.refresh() } }
        closeSelection()
        if sidePanel != .chat { closeSidePanel() }
        if ai.chat == nil, prefs.askAndChat { ai.chat = newChatConversation() }
        ai.chatListing = false
        ai.chatShown = true
        sidePanel = .chat
        sidePanelShown = true
        ai.chatFocus += 1
    }

    func hideChat() {
        ai.chatShown = false
        ai.chatFocused = false
        if !prefs.askAndChat {
            ai.chat = nil
            ai.chatDraft = ""
            ai.chatListing = false
        }
        if sidePanel == .chat {
            sidePanel = nil
            sidePanelShown = false
        }
        active?.web.window?.makeFirstResponder(active?.web)
    }

    func chatSwitchedOff() {
        ChatPlaces.shared.stopAll()
        ai.chatListing = false
        if let shown = ai.chat, shown.chat.kind != .chat { return }
        stopChat()
        if chatOpen { hideChat() } else { ai.chatShown = false }
        ai.chat = nil
        ai.chatDraft = ""
    }

    func showChats() {
        guard chatAllowed, let tab = active else { return }
        showChat(tab)
        ai.chatListing = true
    }

    func newChat() {
        guard prefs.askAndChat else { return }
        ChatPlaces.shared.leave(ai.chat)
        ai.chat = newChatConversation()
        ai.chatDraft = ""
        ai.chatEditing = nil
        ai.chatListing = false
        ai.chatFocus += 1
    }

    func newChatConversation() -> Conversation {
        let conversation = Conversation(saved: !isPrivate, prefs: prefs)
        watch(conversation)
        return conversation
    }

    private func watch(_ conversation: Conversation) {
        conversation.pageFinder = { [weak self] id in self?.tabs.first { $0.id == id } }
        conversation.seen = { [weak self, weak conversation] in self?.ai.chat === conversation && self?.chatOpen == true }
        conversation.happened = { [weak conversation] happening in
            guard case .done(let text) = happening, !text.isEmpty, conversation != nil else { return }
            ChatColumnView.announce(text)
        }
    }

    func open(chat: Chat) {
        ChatStore.shared.update(chat.id) {
            $0.unread = false
            $0.opened = Date()
        }
        if let live = ai.chat, live.chat.id == chat.id {
            ai.chatListing = false
            return
        }
        ChatPlaces.shared.leave(ai.chat)
        if let live = ChatPlaces.shared.takeBack(chat.id) {
            ai.chat = live
            ai.chatDraft = ""
            ai.chatListing = false
            ai.chatFocus += 1
            return
        }
        let stored = ChatStore.shared.chats.first { $0.id == chat.id } ?? chat
        let conversation = Conversation(chat: stored, saved: !isPrivate, prefs: prefs)
        watch(conversation)
        conversation.followsFront = false
        ChatPlaces.shared.set(ChatPlace(tab: nil, title: "", kept: true), for: conversation)
        ai.chat = conversation
        ai.chatDraft = ""
        ai.chatListing = false
        ai.chatFocus += 1
    }

    func showTask(_ task: UUID) {
        guard prefs.agentsAllowed, !isPopup else { return }
        let kind = AgentTasks.shared.running[task]?.chat.kind ?? ChatStore.shared.chats.first { $0.id == task }?.kind
        if kind == .chat, !prefs.askAndChat { return }
        if let running = AgentTasks.shared.running[task] {
            presentChat()
            running.followsFront = false
            ai.chat = running
            ai.chatListing = false
        } else if let chat = ChatStore.shared.chats.first(where: { $0.id == task }) {
            presentChat()
            open(chat: chat)
        }
    }

    func chatPlace(_ conversation: Conversation? = nil) -> ChatPlace? {
        guard let conversation = conversation ?? ai.chat else { return nil }
        if conversation.followsFront, conversation.chat.kind == .chat {
            guard let tab = active else { return ChatPlace(tab: nil, title: "", shut: isPrivate) }
            return place(for: tab)
        }
        return ChatPlaces.shared.place(of: conversation)
    }

    func place(for tab: Tab) -> ChatPlace {
        ChatPlace(tab: tab.id, title: tab.title.isEmpty ? (tab.pageAddress?.host() ?? "") : tab.title, url: tab.pageAddress,
                  shut: isPrivate || tab.neverSent, agentTab: tab.agent && !chatsOwnTab(tab))
    }

    func chatIsPrivate(_ conversation: Conversation) -> Bool {
        isPrivate || !conversation.saved || chatPlace(conversation)?.shut == true
    }

    func chatAnswerer(_ conversation: Conversation? = nil) -> ChatAnswerer {
        guard let conversation = conversation ?? ai.chat else { return .refused(ChatAnswerer.noAgent) }
        if conversation.chat.kind != .chat {
            guard prefs.agentsAllowed, AgentSessions.shared.live[conversation.chat.id] != nil, let choice = conversation.choice else {
                return .refused(ChatAnswerer.taskDone)
            }
            return .agent(choice)
        }
        let plans = Plans.shared
        let mac = ModelChoice(plan: .thisMac, model: "", effort: nil)
        let macHere = plans.connected(.thisMac)
        if chatIsPrivate(conversation) { return macHere ? .agent(mac) : .refused(ChatAnswerer.notPrivate) }
        let setting = plans.agent(prefs)
        if prefs.aiPlan == .thisMac || setting == .thisMac { return macHere ? .agent(mac) : .refused(ChatAnswerer.macOff) }
        let byItself = ChatPlaces.shared.place(of: conversation)?.macByItself == true
        if let picked = conversation.chat.model, !(byItself && picked.plan == .thisMac), plans.connected(picked.plan) { return .agent(picked) }
        if let setting, plans.connected(setting) { return .agent(plans.defaultChoice(setting)) }
        return macHere ? .agent(mac) : .refused(ChatAnswerer.noAgent)
    }

    func chatAgents(_ conversation: Conversation? = nil) -> [Plan] {
        guard let conversation = conversation ?? ai.chat, conversation.chat.kind == .chat else { return [] }
        let plans = Plans.shared
        if chatIsPrivate(conversation) || prefs.aiPlan == .thisMac || plans.agent(prefs) == .thisMac { return plans.connected(.thisMac) ? [.thisMac] : [] }
        return Plan.allCases.filter { plans.connected($0) }
    }

    func pickChatAgent(_ plan: Plan) {
        guard let conversation = ai.chat, chatAgents(conversation).contains(plan) else { return }
        if var place = ChatPlaces.shared.place(of: conversation) {
            place.macByItself = false
            ChatPlaces.shared.set(place, for: conversation)
        }
        conversation.use(Plans.shared.defaultChoice(plan))
    }

    private func settle(_ conversation: Conversation) -> Conversation {
        guard conversation.chat.messages.isEmpty, conversation.followsFront else { return conversation }
        var place = active.map(place(for:)) ?? ChatPlace(tab: nil, title: "", shut: isPrivate)
        place.kept = true
        var settled = conversation
        if conversation.saved == place.shut {
            settled = Conversation(chat: conversation.chat, saved: !place.shut, prefs: prefs)
            watch(settled)
            ai.chat = settled
        }
        settled.followsFront = false
        if let id = place.tab, let tab = tabs.first(where: { $0.id == id }), tab.canBeRead, !place.agentTab {
            settled.attachments = [Attachment(label: tab.title.isEmpty ? "This page" : tab.title, kind: .tab(tab.id))]
        } else {
            settled.attachments = []
        }
        ChatPlaces.shared.set(place, for: settled)
        return settled
    }

    @discardableResult
    func pinChatAnswerer(_ conversation: Conversation) -> ModelChoice? {
        guard let choice = chatAnswerer(conversation).choice else { return nil }
        var place = ChatPlaces.shared.place(of: conversation) ?? ChatPlace(tab: nil, title: "", kept: true)
        if choice.plan == .thisMac {
            if conversation.chat.model?.plan != .thisMac { place.macByItself = true }
            conversation.chat.model = choice
        } else {
            if place.macByItself, conversation.chat.model?.plan == .thisMac { conversation.chat.model = nil }
            place.macByItself = false
            if conversation.choice != choice { conversation.chat.model = choice }
        }
        ChatPlaces.shared.set(place, for: conversation)
        return conversation.choice == choice ? choice : nil
    }

    func sendChat(queue: Bool = false) {
        guard let chat = ai.chat else { return }
        let text = ai.chatDraft
        if chat.chat.kind != .chat {
            guard chatAnswerer(chat).choice != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            ai.chatDraft = ""
            AgentSessions.shared.answer(chat.chat.id, text)
            return
        }
        guard prefs.askAndChat, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard Plans.shared.looked else {
            Task { @MainActor in
                await Plans.shared.refresh()
                if Plans.shared.looked { self.sendChat(queue: queue) }
            }
            return
        }
        guard chatAnswerer(chat).choice != nil else { return }
        var conversation = settle(chat)
        guard pinChatAnswerer(conversation) != nil else { return }
        if !conversation.running {
            if chatActs(conversation) {
                let cut = ai.chatEditing.flatMap { id in conversation.chat.messages.firstIndex { $0.id == id && $0.role == .user } }
                guard actTurn(text, on: conversation, cutFrom: cut) else { return }
                ai.chatDraft = ""
                ai.chatEditing = nil
                return
            }
            conversation = plainChat(conversation)
        }
        ai.chatDraft = ""
        if let editing = ai.chatEditing {
            ai.chatEditing = nil
            conversation.rewrite(editing, as: text)
        } else if conversation.running, !queue {
            conversation.steer(text)
        } else {
            conversation.send(text)
        }
    }

    func retryChat() {
        guard let conversation = ai.chat, !conversation.running, conversation.chat.kind == .chat else { return }
        guard pinChatAnswerer(conversation) != nil else { return }
        if chatActs(conversation), let last = conversation.chat.messages.lastIndex(where: { $0.role == .user }) {
            actTurn(conversation.chat.messages[last].text, on: conversation, cutFrom: last)
            return
        }
        plainChat(conversation).askAgain()
    }

    func finishChat(keepOpen: Bool) {
        stopChat()
        if !keepOpen, let chat = ai.chat?.chat, chat.kind == .task { closeTaskTabs(chat.id) }
        ai.chat = nil
        ai.chatDraft = ""
        if keepOpen { newChat() } else { hideChat() }
    }

    func goToChatPage() {
        guard let id = chatPlace()?.tab, let tab = tabs.first(where: { $0.id == id }) else { return }
        select(tab)
    }

    func chatKey(_ event: NSEvent, _ flags: NSEvent.ModifierFlags, _ key: String) -> Bool {
        guard chatOpen, ai.chatFocused, !ai.chatListing else { return false }
        let plain = flags.subtracting([.numericPad, .function, .capsLock])
        if event.keyCode == 53, plain.isEmpty {
            if ai.chatEditing != nil {
                ai.chatEditing = nil
                ai.chatDraft = ""
                return true
            }
            if ai.chat?.running == true {
                stopChat()
                return true
            }
            return false
        }
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }
        let empty = ai.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if plain.isEmpty {
            if !empty { sendChat() }
            return true
        }
        if plain == .command, !empty {
            sendChat(queue: true)
            return true
        }
        return false
    }

    func chatState() -> [String: Any] {
        var out: [String: Any] = ["chat": chatOpen, "listing": ai.chatListing]
        guard let conversation = ai.chat else { return out }
        let answerer = chatAnswerer(conversation)
        let place = chatPlace(conversation)
        out["running"] = conversation.running
        out["queued"] = conversation.queued
        out["sources"] = conversation.attachments.map(\.label)
        out["place"] = answerer.choice?.label ?? ""
        out["agent"] = answerer.choice?.plan.tool ?? ""
        out["refused"] = answerer.refusal ?? ""
        out["page"] = place?.title ?? ""
        out["pageKept"] = place?.kept ?? false
        out["private"] = chatIsPrivate(conversation)
        out["saved"] = conversation.saved
        out["kind"] = conversation.chat.kind.rawValue
        out["acts"] = chatActs(conversation)
        out["tools"] = conversation.tools != .none
        out["title"] = conversation.chat.title
        out["draft"] = ai.chatDraft
        out["turns"] = conversation.chat.messages.map { message in
            ["role": message.role.rawValue, "text": message.text, "done": message.done, "failed": message.failed ?? "",
             "trouble": message.failed == nil ? "" : ChatTrouble(message).kind.rawValue,
             "strays": message.strays, "addressed": message.addressed, "steps": message.steps.count,
             "agent": message.model?.plan.tool ?? ""] as [String: Any]
        }
        return out
    }
}
