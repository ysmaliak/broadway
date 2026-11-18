import AppKit

@MainActor
@Observable
final class PageAsk: Identifiable {
    let tab: UUID
    let conversation: Conversation
    let blind: Bool
    let onPage: Bool
    let refusal: String?
    var draft = ""
    var focus = 0
    var fromField = false

    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(tab: Tab, conversation: Conversation, onPage: Bool, refusal: String?) {
        self.tab = tab.id
        self.conversation = conversation
        self.onPage = onPage
        self.refusal = refusal
        blind = tab.neverSent
    }

    var takes: Bool { refusal == nil && conversation.chat.model != nil }
    var answering: Bool { conversation.lastAnswer != nil }
    var agent: Plan? { conversation.chat.model?.plan }

    @discardableResult
    func run(_ text: String? = nil) -> Bool {
        let asked = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard takes, !asked.isEmpty, !conversation.running else { return false }
        if text == nil { draft = "" }
        conversation.send(asked)
        return true
    }

    var placeholder: String {
        if let refusal { return refusal }
        if answering { return "Ask a follow-up…" }
        return onPage ? "Ask about this page…" : "Ask anything…"
    }
}

extension Command {
    static let asking: Set<String> = ["view.ask", "view.chat", "view.chats"]
}

extension Preferences {
    nonisolated static let askKey = "ai.ask"
}

extension PageAsk {
    static var board = NSPasteboard.general

    static func set(_ on: Bool, _ prefs: Preferences, in browsers: [Browser]? = nil) {
        prefs.askAndChat = on
        if !on { (browsers ?? Browsers.all).forEach { $0.closeLine(); $0.chatSwitchedOff() } }
    }
}

extension Tab {
    var asksAgent: Bool { agent || driving }

    var askReadable: Bool {
        guard isWeb, let scheme = pageAddress?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }
}

extension Browser {
    func askChoice(for tab: Tab) -> ModelChoice? {
        guard !tab.asksAgent else { return nil }
        let plans = Plans.shared
        let mac = plans.connected(.thisMac) ? ModelChoice(plan: .thisMac, model: "", effort: nil) : nil
        if tab.neverSent { return mac }
        guard let plan = plans.agent(prefs), plans.connected(plan) else { return nil }
        return plan == .thisMac ? mac : plans.defaultChoice(plan)
    }

    func askRefusal(for tab: Tab) -> String? {
        guard askChoice(for: tab) == nil else { return nil }
        if tab.neverSent { return "Not available in a private window" }
        return prefs.aiPlan == .thisMac ? Plans.macOff : "Install Claude Code or Codex and sign in"
    }

    func askKey() {
        guard prefs.askAndChat, let tab = active else { return }
        if let line = ai.line, line.tab == tab.id {
            if line.answering, !line.conversation.running { line.focus += 1 } else { closeLine() }
            return
        }
        Task { @MainActor in await openLine(tab) }
    }

    func openLine(_ tab: Tab, withPage: Bool = true) async {
        guard prefs.askAndChat, !tab.asksAgent else { return }
        if !Plans.shared.looked { await Plans.shared.refresh() }
        guard active === tab, !tab.asksAgent else { return }
        closeSelection()
        if let line = ai.line, line.tab == tab.id { return }
        ai.line?.conversation.stop()
        let choice = askChoice(for: tab)
        let conversation = Conversation(saved: !tab.neverSent, prefs: prefs)
        conversation.chat.model = choice
        conversation.pageFinder = { [weak self] id in self?.tabs.first { $0.id == id } }
        conversation.seen = { [weak self, weak conversation] in self?.ai.line?.conversation === conversation }
        let onPage = withPage && choice != nil && tab.askReadable
        if onPage { conversation.attachments = [Attachment(label: tab.title.isEmpty ? "This page" : tab.title, kind: .tab(tab.id))] }
        ai.line = PageAsk(tab: tab, conversation: conversation, onPage: onPage, refusal: choice == nil ? askRefusal(for: tab) : nil)
    }

    func closeLine() {
        ai.line?.conversation.stop()
        ai.line = nil
    }

    func lineEscape() -> Bool {
        guard let line = ai.line else { return false }
        if line.conversation.running { line.conversation.stop() } else { closeLine() }
        return true
    }

    func lineKey(_ event: NSEvent, _ flags: NSEvent.ModifierFlags, _ key: String) -> Bool {
        guard let line = ai.line, line.answering, !line.conversation.running else { return false }
        let plain = flags.subtracting([.numericPad, .function])
        if fieldLineKey(line, event, plain, key) { return true }
        if plain == .command, key == "c", !lineHasSelection() {
            copyAnswer(line)
            return true
        }
        if plain == .command, event.keyCode == 36 || event.keyCode == 76 {
            closeLine()
            return true
        }
        if plain == [.command, .shift], key == "v" {
            putAnswerInPage(line)
            return true
        }
        if plain == [.command, .shift], key == "r" {
            askOtherAgent(line)
            return true
        }
        return false
    }

    private func lineHasSelection() -> Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.selectedRange().length > 0
    }

    func copyAnswer(_ line: PageAsk) {
        guard let text = line.conversation.lastAnswer?.text, !text.isEmpty else { return }
        PageAsk.board.clearContents()
        PageAsk.board.setString(text, forType: .string)
        announce("Copied")
    }

    func lineState() -> [String: Any] {
        var out: [String: Any] = ["open": ai.line != nil]
        guard let line = ai.line else { return out }
        let conversation = line.conversation
        out["running"] = conversation.running
        out["sources"] = conversation.attachments.map(\.label)
        out["place"] = conversation.chat.model?.plan.tool ?? ""
        out["blind"] = line.blind
        out["onPage"] = line.onPage
        out["draft"] = line.draft
        out["refusal"] = line.refusal ?? ""
        out["turns"] = conversation.chat.messages.map { message in
            ["role": message.role.rawValue, "text": message.text, "done": message.done, "failed": message.failed ?? "",
             "strays": message.strays, "addressed": message.addressed] as [String: Any]
        }
        return out
    }
}

extension Browser {
    func lineFrames() -> [String: [Double]] {
        guard let root = window?.contentView else { return [:] }
        var out: [String: [Double]] = [:]
        func walk(_ view: NSView) {
            let id = view.accessibilityIdentifier()
            if id.hasPrefix("ask.line"), !view.isHiddenOrHasHiddenAncestor {
                let box = view.convert(view.bounds, to: root)
                let top = root.isFlipped ? box.minY : root.bounds.height - box.maxY
                out[id] = [box.minX, top, box.width, box.height].map { Double($0) }
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return out
    }

    func benchEscape() -> Bool {
        guard let window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                        isARepeat: false, keyCode: 53)
        else { return false }
        return ContentView.keyHooks[ObjectIdentifier(self)]?(event) == nil
    }
}
