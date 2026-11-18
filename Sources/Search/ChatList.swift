import AppKit
import Combine

extension Browser {
    static func listed(_ chats: [Chat]) -> [Chat] {
        chats.filter { $0.kind == .chat && !$0.messages.isEmpty }
            .sorted { left, right in
                if left.pinned != right.pinned { return left.pinned }
                return left.updated > right.updated
            }
    }

    var chatList: [Chat] { Browser.listed(ChatStore.shared.chats) }

    private var everyWindow: [Browser] {
        var seen = Set<ObjectIdentifier>()
        return (Browsers.all + [self]).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func live(_ id: UUID, _ change: (Conversation) -> Void) {
        for browser in everyWindow {
            if let conversation = browser.ai.chat, conversation.chat.id == id { change(conversation) }
        }
        if let behind = ChatPlaces.shared.behind(id) { change(behind) }
    }

    func renameChat(_ id: UUID, to name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        ChatStore.shared.update(id) { $0.title = title }
        live(id) { $0.chat.title = title }
    }

    func pinChat(_ id: UUID) {
        guard let pinned = ChatStore.shared.chats.first(where: { $0.id == id })?.pinned else { return }
        ChatStore.shared.update(id) { $0.pinned = !pinned }
        live(id) { $0.chat.pinned = !pinned }
    }

    func deleteChat(_ id: UUID) {
        guard let kept = ChatStore.shared.chats.first(where: { $0.id == id }) else { return }
        var gone = kept
        live(id) { conversation in
            stopChat(conversation)
            gone = conversation.chat
        }
        _ = ChatPlaces.shared.takeBack(id)
        ChatStore.shared.delete(id)
        for browser in everyWindow where browser.ai.chat?.chat.id == id {
            let listing = browser.ai.chatListing
            browser.ai.chat = nil
            browser.newChat()
            browser.ai.chatListing = listing
        }
        let restored = gone
        announce("Chat deleted", undo: {
            var back = restored
            back.messages.removeAll { !$0.done }
            ChatStore.shared.restore(back)
        })
    }
}

enum ChatWhen {
    static func said(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if let week = calendar.date(byAdding: .day, value: -6, to: now), date > calendar.startOfDay(for: week) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

final class ChatListRow: KitButton, NSTextFieldDelegate {
    let chat: Chat
    weak var browser: Browser?
    private let ground = KitBox(fill: nil, corners: .radius(SideLook.rowRadius - 3))
    private let title = KitLabel("", font: .systemFont(ofSize: 13), color: KitColor.ink)
    private let when = KitLabel("", font: ChatLook.small, color: KitColor.faint)
    private let pin = KitSymbol("pin.fill", style: KitSymbol.Style(size: 9, weight: .medium), tint: KitColor.faint)
    private var field: NSTextField?

    static let height: CGFloat = 32

    init(chat: Chat, browser: Browser) {
        self.chat = chat
        self.browser = browser
        super.init(.plain(press: 0.98), label: chat.title)
        title.text = chat.title
        when.text = ChatWhen.said(chat.updated)
        pin.isHidden = !chat.pinned
        for view in [ground, title, when, pin] as [NSView] { addSubview(view) }
        for view in [title, when] { view.setAccessibilityElement(false) }
        setAccessibilityLabel(chat.title)
        setAccessibilityValue((chat.pinned ? "Pinned, " : "") + when.text)
        action = { [weak browser] in browser?.open(chat: chat) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hoverChanged() {
        super.hoverChanged()
        ground.fill = hovering ? Palette.NS.hover : nil
    }

    var renaming: Bool { field != nil }

    func rename() {
        guard field == nil else { return }
        let made = NSTextField(string: chat.title)
        made.font = .systemFont(ofSize: 13)
        made.isBordered = false
        made.focusRingType = .none
        made.drawsBackground = false
        made.delegate = self
        made.setAccessibilityLabel("Chat name")
        addSubview(made)
        field = made
        title.isHidden = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(made)
        made.currentEditor()?.selectAll(nil)
    }

    private func endRename(keep: Bool) {
        guard let made = field else { return }
        field = nil
        let name = made.stringValue
        made.removeFromSuperview()
        title.isHidden = false
        if keep { browser?.renameChat(chat.id, to: name) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            endRename(keep: true)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endRename(keep: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endRename(keep: true)
    }

    override func menu(for event: NSEvent) -> NSMenu? { menu() }

    func menu() -> NSMenu {
        let id = chat.id
        let pinned = chat.pinned
        return KitMenu.make([
            .action("Rename…", id: "chat.rename") { [weak self] in self?.rename() },
            .action(pinned ? "Unpin" : "Pin", id: "chat.pin") { [weak browser] in browser?.pinChat(id) },
            .separator,
            .action("Delete", id: "chat.delete") { [weak browser] in browser?.deleteChat(id) },
        ])
    }

    override func accessibilityPerformShowMenu() -> Bool {
        KitMenu.popUp(menu(), from: bounds, of: self)
        return true
    }

    override func mouseUp(with event: NSEvent) {
        if field != nil { return }
        super.mouseUp(with: event)
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let size = when.measure(width: 120)
        let whenWidth = ceil(size.width)
        when.frame = kitSnap(NSRect(x: bounds.width - 10 - whenWidth, y: (bounds.height - size.height) / 2, width: whenWidth, height: ceil(size.height)))
        var right = bounds.width - 10 - whenWidth - 8
        if !pin.isHidden {
            pin.frame = NSRect(x: right - 10, y: (bounds.height - 10) / 2, width: 10, height: 10)
            right -= 18
        }
        let name = title.measure(width: max(0, right - 10))
        title.frame = kitSnap(NSRect(x: 10, y: (bounds.height - name.height) / 2, width: max(0, right - 10), height: ceil(name.height)))
        field?.frame = NSRect(x: 8, y: (bounds.height - 20) / 2, width: max(0, right - 8), height: 20)
    }
}

final class ChatListView: NSView {
    let browser: Browser
    private let scroll = NSScrollView()
    private let document = ChatThreadDocument()
    private let empty = KitLabel("No chats yet", font: .systemFont(ofSize: 13), color: KitColor.muted)
    private(set) var rows: [ChatListRow] = []
    private var shown: [Chat] = []

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        empty.alignment = .center
        addSubview(scroll)
        addSubview(empty)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Chats")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func refresh() {
        let chats = browser.chatList
        empty.isHidden = !chats.isEmpty
        guard chats != shown, !rows.contains(where: \.renaming) else { return }
        shown = chats
        for row in rows { row.removeFromSuperview() }
        rows = chats.map { ChatListRow(chat: $0, browser: browser) }
        for row in rows { document.addSubview(row) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = scroll.contentSize.width
        var y: CGFloat = 8
        for row in rows {
            row.frame = NSRect(x: 6, y: y, width: max(0, width - 12), height: ChatListRow.height)
            y += ChatListRow.height + 2
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, y + 8))
        let size = empty.measure(width: max(0, bounds.width - 32))
        empty.frame = kitSnap(NSRect(x: 16, y: max(24, bounds.height / 2 - 40), width: max(0, bounds.width - 32), height: ceil(size.height)))
    }
}
