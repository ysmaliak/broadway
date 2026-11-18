import AppKit
import Combine

final class ChatColumnView: NSView {
    let browser: Browser
    let head: ChatHeadView
    let thread: ChatThreadView
    let composer: ChatComposerView
    private(set) var list: ChatListView?
    private let rule = KitBox(fill: KitColor.hairline)
    private var watch: AnyCancellable?
    private var focusWatch: AnyCancellable?

    static let headHeight: CGFloat = SidePanelContentView.lineHeight
    static let pageHeight: CGFloat = 26

    init(browser: Browser) {
        self.browser = browser
        head = ChatHeadView(browser: browser)
        thread = ChatThreadView(browser: browser)
        composer = ChatComposerView(browser: browser)
        super.init(frame: .zero)
        for view in [thread, head, rule, composer] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Chat")
        watch = kitTrack { [weak self] in self?.refresh() }
        focusWatch = kitObserve(initial: false, distinct: true, { [weak browser] in browser?.ai.chatFocus ?? 0 }) { [weak self] _ in
            self?.composer.focus()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static func announce(_ text: String) {
        let said = ChatText.plain(text)
        let short = said.count > 400 ? String(said.prefix(399)) + "…" : said
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Answer: \(short)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func refresh() {
        let listing = browser.ai.chatListing
        head.refresh()
        if listing {
            let made = list ?? {
                let made = ChatListView(browser: browser)
                addSubview(made)
                list = made
                return made
            }()
            made.isHidden = false
            made.refresh()
        } else {
            list?.isHidden = true
        }
        thread.isHidden = listing
        composer.isHidden = listing
        if !listing {
            thread.refresh()
            composer.refresh()
        }
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.composer.focus() } }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let top = head.height
        head.frame = NSRect(x: 0, y: 0, width: width, height: top)
        rule.frame = NSRect(x: 0, y: top, width: width, height: 1)
        let below = top + 1
        if let list, !list.isHidden {
            list.frame = NSRect(x: 0, y: below, width: width, height: max(0, bounds.height - below))
            return
        }
        let foot = composer.height(for: width)
        composer.frame = NSRect(x: 0, y: bounds.height - foot, width: width, height: foot)
        thread.frame = NSRect(x: 0, y: below, width: width, height: max(0, bounds.height - below - foot))
    }
}

final class ChatHeadView: NSView {
    let browser: Browser
    private let agent: KitButton
    private let agentName = KitLabel("", font: .systemFont(ofSize: 13, weight: .semibold))
    private let agentChevron = KitSymbol("chevron.down", style: KitSymbol.Style(size: 9, weight: .semibold), tint: KitColor.muted)
    private let fresh: KitDoor
    private let chats: KitDoor
    private let listTitle = KitLabel("Chats", font: .systemFont(ofSize: 13, weight: .semibold))
    private let close: KitDoor
    private let page: KitButton
    private let pageMark = KitSymbol("doc.text", style: KitSymbol.Style(size: 10, weight: .medium), tint: KitColor.faint)
    private let pageName = KitLabel("", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private var agents: [Plan] = []
    private var showsPage = false

    init(browser: Browser) {
        self.browser = browser
        agent = KitButton(.plain(press: 0.97), label: "Agent")
        fresh = KitDoor(icon: "square.and.pencil", help: "New Chat") { [weak browser] in browser?.newChat() }
        chats = KitDoor(icon: "list.bullet", help: "Chats") { [weak browser] in
            guard let browser else { return }
            browser.ai.chatListing.toggle()
        }
        close = KitDoor(icon: "xmark", help: "Hide Chat") { [weak browser] in browser?.hideChat() }
        page = KitButton(.plain(press: 0.98), label: "Page")
        super.init(frame: .zero)
        agent.action = { [weak self] in self?.pickAgent() }
        page.action = { [weak browser] in browser?.goToChatPage() }
        agentName.setAccessibilityElement(false)
        pageName.setAccessibilityElement(false)
        agent.addSubview(agentName)
        agent.addSubview(agentChevron)
        page.addSubview(pageMark)
        page.addSubview(pageName)
        for view in [agent, listTitle, fresh, chats, close, page] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var height: CGFloat { ChatColumnView.headHeight + (showsPage ? ChatColumnView.pageHeight : 0) }

    func refresh() {
        let listing = browser.ai.chatListing
        let conversation = browser.ai.chat
        let answerer = browser.chatAnswerer(conversation)
        agents = browser.chatAgents(conversation)
        let task = conversation?.chat.kind == .task
        agentName.text = task ? (conversation?.chat.title ?? "Task") : answerer.choice?.plan.tool ?? "No agent"
        agentChevron.isHidden = agents.count < 2 || task
        agent.isEnabled = !agentChevron.isHidden
        agent.setAccessibilityLabel(agentName.text)
        agent.setAccessibilityHelp(agentChevron.isHidden ? nil : "Pick the agent for this chat")
        agent.isHidden = listing
        listTitle.isHidden = !listing
        chats.on = listing
        fresh.isHidden = !browser.prefs.askAndChat
        chats.isHidden = !browser.prefs.askAndChat
        let place = browser.chatPlace(conversation)
        let shown = !listing && !task && conversation != nil
        var words = ""
        if shown, let place {
            if place.agentTab {
                words = "An agent's tab gives no page"
            } else if !place.title.isEmpty {
                words = place.title
            } else if place.kept, place.tab == nil {
                words = "Not about a page"
            }
        }
        pageName.text = words
        let showing = !words.isEmpty
        page.isEnabled = place?.tab != nil && !(place?.agentTab ?? false)
        page.setAccessibilityLabel(page.isEnabled ? "Go to the page: \(words)" : words)
        if showing != showsPage {
            showsPage = showing
            superview?.needsLayout = true
        }
        page.isHidden = !showing
        needsLayout = true
    }

    private func pickAgent() {
        let current = browser.chatAnswerer().choice?.plan
        let items: [KitMenuItem] = agents.map { plan in
            .action(plan.tool, on: plan == current, id: "chat.agent.\(plan.rawValue)") { [weak browser] in browser?.pickChatAgent(plan) }
        }
        KitMenu.popUp(KitMenu.make([.header("For This Chat")] + items), from: agent.bounds, of: agent)
    }

    override func layout() {
        super.layout()
        let line = ChatColumnView.headHeight
        let side: CGFloat = 26
        var right = bounds.width - 10
        for door in [close, chats, fresh] where !door.isHidden {
            door.frame = NSRect(x: right - side, y: (line - side) / 2, width: side, height: side)
            right -= side + 4
        }
        let room = max(0, right - 14 - 6)
        let name = agentName.measure(width: max(0, room - 16))
        let nameWidth = min(ceil(name.width), max(0, room - 16))
        let buttonWidth = nameWidth + (agentChevron.isHidden ? 0 : 14) + 12
        agent.frame = kitSnap(NSRect(x: 8, y: (line - 26) / 2, width: buttonWidth, height: 26))
        agentName.frame = kitSnap(NSRect(x: 6, y: (26 - name.height) / 2, width: nameWidth, height: ceil(name.height)))
        agentChevron.frame = NSRect(x: 6 + nameWidth + 4, y: 8, width: 10, height: 10)
        let list = listTitle.measure(width: room)
        listTitle.frame = kitSnap(NSRect(x: 14, y: (line - list.height) / 2, width: min(room, ceil(list.width)), height: ceil(list.height)))
        if showsPage {
            page.frame = NSRect(x: 8, y: line - 6, width: max(0, bounds.width - 16), height: ChatColumnView.pageHeight)
            pageMark.frame = NSRect(x: 6, y: (ChatColumnView.pageHeight - 12) / 2, width: 12, height: 12)
            let size = pageName.measure(width: max(0, page.frame.width - 30))
            pageName.frame = kitSnap(NSRect(x: 24, y: (ChatColumnView.pageHeight - size.height) / 2,
                                            width: max(0, page.frame.width - 30), height: ceil(size.height)))
        }
    }
}

final class ChatThreadDocument: NSView {
    weak var thread: ChatThreadView?
    override var isFlipped: Bool { true }

    func changed() { thread?.relayout() }
}

final class ChatThreadView: NSView {
    let browser: Browser
    let scroll = NSScrollView()
    let document = ChatThreadDocument()
    private var rows: [ChatRow] = []
    private let empty = KitLabel("", font: .systemFont(ofSize: 13, weight: .semibold), color: KitColor.ink)
    private let emptyNote = KitLabel("", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private let down: KitGlassKey
    private(set) var following = true
    private var placing = false
    private var shownChat: ObjectIdentifier?
    private var announced: Set<UUID> = []

    init(browser: Browser) {
        self.browser = browser
        down = KitGlassKey(symbol: "arrow.down", circle: 28, symbolSize: 11, weight: .semibold, label: "Go to the Newest")
        super.init(frame: .zero)
        down.action = { [weak self] in self?.goDown() }
        document.thread = self
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        emptyNote.lines = 4
        empty.lines = 2
        for label in [empty, emptyNote] { label.alignment = .center }
        for view in [scroll, empty, emptyNote, down] as [NSView] { addSubview(view) }
        down.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var width: CGFloat { max(40, bounds.width - ChatLook.pad * 2) }

    func refresh() {
        guard let conversation = browser.ai.chat else {
            for row in rows { row.removeFromSuperview() }
            rows = []
            showEmpty(nil)
            return
        }
        if shownChat != ObjectIdentifier(conversation) {
            shownChat = ObjectIdentifier(conversation)
            following = true
        }
        let messages = conversation.chat.messages
        let status = conversation.status
        _ = conversation.running
        var made: [ChatRow] = []
        let lastAnswer = messages.last { $0.role == .assistant }?.id
        for message in messages {
            let key = message.id.uuidString
            if message.role == .user {
                let row = rows.first { $0.key == key } as? ChatUserTurn ?? ChatUserTurn(key: key, text: message.text)
                row.set(message.text)
                made.append(row)
            } else {
                let row = rows.first { $0.key == key } as? ChatAnswerTurn ?? ChatAnswerTurn(key: key, browser: browser)
                row.set(message, status: message.done ? nil : status, last: message.id == lastAnswer && !conversation.running)
                made.append(row)
            }
        }
        for (index, waiting) in conversation.queued.enumerated() {
            let key = "queued-\(index)-\(waiting.hashValue)"
            made.append(rows.first { $0.key == key } ?? ChatUserTurn(key: key, text: waiting, waiting: true))
        }
        for row in rows where !made.contains(where: { $0 === row }) { row.removeFromSuperview() }
        for row in made where row.superview !== document { document.addSubview(row) }
        rows = made
        showEmpty(messages.isEmpty ? conversation : nil)
        relayout()
    }

    private func showEmpty(_ conversation: Conversation?) {
        let showing = conversation != nil || browser.ai.chat == nil
        empty.isHidden = !showing
        emptyNote.isHidden = !showing
        guard showing, let conversation else { return }
        let answerer = browser.chatAnswerer(conversation)
        let place = browser.chatPlace(conversation)
        let agent = answerer.choice?.plan.tool ?? ""
        if let refused = answerer.refusal, conversation.chat.kind == .chat {
            empty.text = "No agent can answer here"
            emptyNote.text = refused
        } else if browser.chatIsPrivate(conversation) {
            empty.text = "Ask anything"
            emptyNote.text = "In a private window only \(agent) on this Mac answers. Nothing of the page is read."
        } else if place?.agentTab == true {
            empty.text = "Ask anything"
            emptyNote.text = "This is an agent's tab, so the chat goes on without a page"
        } else if let id = place?.tab, let tab = browser.tabs.first(where: { $0.id == id }), tab.canBeRead {
            empty.text = "Ask about this page"
            emptyNote.text = browser.chatActNote(conversation)
        } else {
            empty.text = "Ask anything"
            emptyNote.text = "This tab has no page to read"
        }
        needsLayout = true
    }

    func relayout() {
        let wasDown = following
        var y = ChatLook.pad
        let inner = width
        for row in rows {
            let height = row.height(for: inner)
            row.frame = NSRect(x: ChatLook.pad, y: y, width: inner, height: height)
            y += height + ChatLook.turnGap
        }
        let total = max(y - ChatLook.turnGap + ChatLook.pad, scroll.contentSize.height)
        placing = true
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: rows.isEmpty ? scroll.contentSize.height : total)
        for row in rows { row.needsLayout = true }
        if wasDown { scrollToEnd() }
        placing = false
        updateDown()
    }

    private func scrollToEnd() {
        let end = max(0, document.frame.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func scrolled() {
        guard !placing else { return }
        let end = max(0, document.frame.height - scroll.contentSize.height)
        following = scroll.contentView.bounds.minY >= end - 24
        updateDown()
    }

    private func updateDown() {
        let hidden = following || document.frame.height <= scroll.contentSize.height + 1
        if down.isHidden != hidden { down.isHidden = hidden }
    }

    func goDown() {
        following = true
        scrollToEnd()
        updateDown()
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let room = max(40, bounds.width - 48)
        let top = empty.measure(width: room)
        let note = emptyNote.measure(width: room)
        let block = ceil(top.height) + 6 + ceil(note.height)
        let y = max(16, (bounds.height - block) / 2 - 20)
        empty.frame = kitSnap(NSRect(x: 24, y: y, width: room, height: ceil(top.height)))
        emptyNote.frame = kitSnap(NSRect(x: 24, y: y + ceil(top.height) + 6, width: room, height: ceil(note.height)))
        down.frame = NSRect(x: (bounds.width - 28) / 2, y: bounds.height - 28 - 10, width: 28, height: 28)
        if document.frame.width != scroll.contentSize.width { relayout() }
    }
}

final class ChatComposerText: NSTextView {
    weak var browser: Browser?
    var changed: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { browser?.ai.chatFocused = true }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        if gave { browser?.ai.chatFocused = false }
        return gave
    }

    override func didChangeText() {
        super.didChangeText()
        browser?.ai.chatDraft = string
        changed?()
    }
}

final class ChatComposerView: NSView {
    let browser: Browser
    private let well = KitBox(fill: Palette.NS.wash, corners: .radius(12))
    let scroll = NSScrollView()
    let text = ChatComposerText()
    private let placeholder = KitLabel("", font: .systemFont(ofSize: ChatText.size), color: KitColor.faint)
    private let steer = CommandHintView("↩", "Steer")
    private let queue = CommandHintView("⌘↩", "Queue")
    private let stop = CommandHintView("esc", "Stop")
    private var running = false

    static let lines = 6
    static let pad: CGFloat = 10

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        text.browser = browser
        text.isRichText = false
        text.allowsUndo = true
        text.font = .systemFont(ofSize: ChatText.size)
        text.textColor = KitColor.ink
        text.insertionPointColor = KitColor.ink
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.setAccessibilityLabel("Message")
        text.changed = { [weak self] in self?.typed() }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = text
        placeholder.setAccessibilityElement(false)
        for hint in [steer, queue, stop] { hint.setAccessibilityElement(false) }
        for view in [well, scroll, placeholder, steer, queue, stop] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var lineHeight: CGFloat { ceil((text.font ?? ChatText.body).boundingRectForFont.height) - 1 }

    private func textHeight(_ width: CGFloat) -> CGFloat {
        guard let layout = text.layoutManager, let container = text.textContainer else { return lineHeight }
        if container.size.width != width { container.size = NSSize(width: max(1, width), height: .greatestFiniteMagnitude) }
        layout.ensureLayout(for: container)
        let used = ceil(layout.usedRect(for: container).height)
        return min(max(lineHeight, used), lineHeight * CGFloat(Self.lines))
    }

    private var hints: Bool { running }

    func height(for width: CGFloat) -> CGFloat {
        let inner = width - Self.pad * 2 - 24
        return Self.pad + 10 + textHeight(inner) + (hints ? 6 + 16 : 0) + 10 + Self.pad
    }

    func refresh() {
        let conversation = browser.ai.chat
        running = conversation?.running ?? false
        let answerer = browser.chatAnswerer(conversation)
        let refused = answerer.refusal
        text.isEditable = refused == nil
        if text.string != browser.ai.chatDraft { text.string = browser.ai.chatDraft }
        if let refused {
            placeholder.text = refused
            placeholder.lines = 3
        } else if running {
            placeholder.text = "Steer the answer"
            placeholder.lines = 1
        } else if conversation?.chat.messages.isEmpty == false {
            placeholder.text = "Ask a follow-up"
            placeholder.lines = 1
        } else {
            let place = browser.chatPlace(conversation)
            let readable = place?.tab.flatMap { id in browser.tabs.first { $0.id == id } }?.canBeRead == true
            placeholder.text = readable && !(place?.agentTab ?? false) && !(conversation.map(browser.chatIsPrivate) ?? false)
                ? "Ask about this page" : "Ask anything"
            placeholder.lines = 1
        }
        text.setAccessibilityPlaceholderValue(placeholder.text)
        placeholder.isHidden = !text.string.isEmpty && refused == nil
        for hint in [steer, queue, stop] { hint.isHidden = !hints }
        superview?.needsLayout = true
        needsLayout = true
    }

    private func typed() {
        placeholder.isHidden = !text.string.isEmpty
        superview?.needsLayout = true
        needsLayout = true
    }

    func focus() {
        guard let window, !isHidden, text.isEditable else { return }
        window.makeFirstResponder(text)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        well.frame = NSRect(x: Self.pad, y: Self.pad, width: width - Self.pad * 2, height: bounds.height - Self.pad * 2)
        let inner = width - Self.pad * 2 - 24
        let height = textHeight(inner)
        scroll.frame = NSRect(x: Self.pad + 12, y: Self.pad + 10, width: inner, height: height)
        text.frame.size.width = inner
        text.minSize = NSSize(width: inner, height: height)
        text.maxSize = NSSize(width: inner, height: .greatestFiniteMagnitude)
        let size = placeholder.measure(width: inner)
        placeholder.frame = kitSnap(NSRect(x: Self.pad + 12, y: Self.pad + 10, width: inner, height: ceil(size.height)))
        if hints {
            var right = Self.pad + 12 + inner
            let y = Self.pad + 10 + height + 6
            for hint in [stop, queue, steer] {
                let w = ceil(hint.intrinsicContentSize.width)
                right -= w
                hint.frame = kitSnap(NSRect(x: right, y: y, width: w, height: 16))
                right -= 10
            }
        }
    }
}
