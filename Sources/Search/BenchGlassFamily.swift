import AppKit

@MainActor
enum BenchGlassFamily {
    static let names = ["page-ask", "site-file", "announcement", "agent-ask-outside", "offer-bar", "link-preview", "chat-down"]
    private static var holds: [AnyObject] = []

    static func make(_ name: String, _ request: [String: Any], browser: Browser?) -> NSView? {
        guard let browser else { return nil }
        switch name {
        case "page-ask":
            return ask(browser, state: request["state"] as? String ?? "answered")
        case "site-file":
            let insecure = request["kind"] as? String == "insecure"
            let card = FileCard(kind: insecure ? .insecure : .site, site: "files.example.test", host: "files.example.test",
                                name: "quarterly-report.pdf", file: UUID(), more: request["more"] as? Bool ?? false)
            let view = SiteFileQuestionView(browser: browser, card: card)
            return BenchFloating.sized(view, view.fit((request["width"] as? Double).map { CGFloat($0) }))
        case "announcement":
            let note = CapsuleNote(request["text"] as? String ?? "Tab closed", size: 12, trailing: request["trailing"] as? String ?? "")
            return BenchFloating.sized(note, note.intrinsicContentSize)
        case "agent-ask-outside":
            var question = AgentQuestion(kind: .choice(["Use the work account", "Use the personal account", "Stop here"]),
                                         title: "Which account should this order go on?")
            question.asker = "Claude Code"
            AgentDesk.shared.benchAsk(question)
            let card = AgentCardView(browser: browser, desk: .shared)
            return BenchFloating.sized(card, NSSize(width: 460, height: card.intrinsicContentSize.height))
        case "chat-down":
            return down(browser)
        case "link-preview":
            let size = NSSize(width: 320, height: 148)
            return BenchFloating.sized(LinkPreviewCard(preview: IntegrationPreviewSurface.github, size: size), size)
        case "offer-bar":
            let bar = OfferBarView(request["text"] as? String ?? "Open links from Mail in this space?",
                                   choices: [.init("Not Now") {}, .init("Open Here", .primary) {}])
            return BenchFloating.sized(bar, bar.intrinsicContentSize)
        default:
            return nil
        }
    }

    private static func down(_ browser: Browser) -> NSView? {
        let line = "The page lists four made-up ponds and the reeds that grow beside each one. It gives the depth of every pond and says which of them freeze in winter."
        var chat = Chat()
        chat.model = ModelChoice(plan: .thisMac, model: "", effort: nil)
        chat.messages = [ChatMessage(role: .user, text: "What is this page about?"),
                         ChatMessage(role: .assistant, text: Array(repeating: line, count: 8).joined(separator: "\n\n"))]
        let conversation = Conversation(chat: chat, saved: false, prefs: browser.prefs)
        browser.ai.chat = conversation
        holds.append(conversation)
        let thread = ChatThreadView(browser: browser)
        let size = NSSize(width: 340, height: 260)
        thread.frame = NSRect(origin: .zero, size: size)
        thread.layoutSubtreeIfNeeded()
        thread.refresh()
        thread.layoutSubtreeIfNeeded()
        thread.scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        thread.scroll.reflectScrolledClipView(thread.scroll.contentView)
        return BenchFloating.sized(thread, size)
    }

    private static func ask(_ browser: Browser, state: String) -> NSView? {
        guard let tab = browser.active else { return nil }
        var chat = Chat()
        chat.model = ModelChoice(plan: .thisMac, model: "", effort: nil)
        var refusal: String?
        switch state {
        case "empty":
            break
        case "refused":
            refusal = "Pick an agent in Settings to ask about a page"
        case "working":
            chat.messages = [ChatMessage(role: .user, text: "What is this page about?"), ChatMessage(role: .assistant, text: "", done: false)]
        case "failed":
            var answer = ChatMessage(role: .assistant, text: "")
            answer.failed = "The agent stopped answering"
            answer.stopped = true
            chat.messages = [ChatMessage(role: .user, text: "What is this page about?"), answer]
        default:
            var answer = ChatMessage(role: .assistant, text: "The page lists four made-up ponds and the reeds that grow beside each one. It gives the depth of every pond and says which of them freeze in winter.")
            answer.addressed = true
            answer.strays = ["a fifth pond"]
            chat.messages = [ChatMessage(role: .user, text: "What is this page about?"), answer]
        }
        let conversation = Conversation(chat: chat, saved: false, prefs: browser.prefs)
        if state != "empty", state != "refused" {
            conversation.attachments = [Attachment(label: "pond-notes.txt", kind: .text("Four ponds")), Attachment(label: "A tab about reeds", kind: .text("Reeds"))]
        }
        let line = PageAsk(tab: tab, conversation: conversation, onPage: true, refusal: refusal)
        holds.append(line)
        let view = PageAskView(browser: browser, line: line)
        let width: CGFloat = 560
        return BenchFloating.sized(view, NSSize(width: width, height: view.height(for: width)))
    }
}
