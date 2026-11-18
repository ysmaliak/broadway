import AppKit

@MainActor
protocol ChatRow: NSView {
    var key: String { get }
    func height(for width: CGFloat) -> CGFloat
}

enum ChatLook {
    static let pad: CGFloat = 14
    static let turnGap: CGFloat = 16
    static let bubbleRadius: CGFloat = 14
    static let bubblePad = NSSize(width: 11, height: 7)
    static let bubbleShare: CGFloat = 0.82
    static let small = NSFont.systemFont(ofSize: 11)
    static let note = NSFont.systemFont(ofSize: 12)
    static let lineGap: CGFloat = 6
    static let caution = "This page has text written for an AI to follow. The answer may have been steered by it."
    static let mayBeWrong = "AI, may be wrong"
}

final class ChatUserTurn: NSView, ChatRow {
    let key: String
    private let bubble = KitBox(fill: NSColor.controlAccentColor, corners: .radius(ChatLook.bubbleRadius))
    private let words = ChatTextView(selectable: true)
    private let waiting: Bool

    init(key: String, text: String, waiting: Bool = false) {
        self.key = key
        self.waiting = waiting
        super.init(frame: .zero)
        addSubview(bubble)
        addSubview(words)
        words.textColor = .white
        set(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func set(_ text: String) {
        let ink: NSColor = .white
        let style = ChatText.style().mutableCopy() as! NSMutableParagraphStyle
        style.paragraphSpacing = 0
        words.set(NSAttributedString(string: text, attributes: [.font: ChatText.body, .foregroundColor: ink, .paragraphStyle: style]))
        bubble.fill = waiting ? NSColor.controlAccentColor.withAlphaComponent(0.45) : NSColor.controlAccentColor
        setAccessibilityLabel(waiting ? "Waiting to send: \(text)" : "You: \(text)")
    }

    private func measure(_ width: CGFloat) -> NSSize {
        let room = max(40, width * ChatLook.bubbleShare - ChatLook.bubblePad.width * 2)
        let height = words.height(for: room)
        return NSSize(width: words.widest(for: room), height: height)
    }

    func height(for width: CGFloat) -> CGFloat { measure(width).height + ChatLook.bubblePad.height * 2 }

    override func layout() {
        super.layout()
        let size = measure(bounds.width)
        let box = NSRect(x: bounds.width - size.width - ChatLook.bubblePad.width * 2, y: 0,
                         width: size.width + ChatLook.bubblePad.width * 2, height: size.height + ChatLook.bubblePad.height * 2)
        bubble.frame = kitSnap(box)
        words.frame = NSRect(x: box.minX + ChatLook.bubblePad.width, y: ChatLook.bubblePad.height, width: size.width, height: size.height)
    }
}

final class ChatNote: NSView {
    private let box = KitBox(fill: Palette.NS.wash, corners: .radius(8))
    private let mark = KitSymbol("exclamationmark.triangle", style: KitSymbol.Style(size: 10, weight: .medium), tint: KitColor.muted)
    private let words = ChatTextView(selectable: true)

    init(_ text: String) {
        super.init(frame: .zero)
        addSubview(box)
        addSubview(mark)
        addSubview(words)
        words.set(NSAttributedString(string: text, attributes: [.font: ChatLook.note, .foregroundColor: KitColor.muted]))
        kitAccess(label: text, role: .staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func height(for width: CGFloat) -> CGFloat { words.height(for: max(20, width - 34)) + 16 }

    override func layout() {
        super.layout()
        box.frame = bounds
        mark.frame = NSRect(x: 8, y: 9, width: 12, height: 12)
        words.frame = NSRect(x: 26, y: 8, width: max(20, bounds.width - 34), height: max(0, bounds.height - 16))
    }
}

final class ChatTroubleView: NSView {
    private let title = ChatTextView(selectable: true)
    private let detail = ChatTextView(selectable: true)
    private let again: KitGlassKey?

    init(_ trouble: ChatTrouble, retry: (() -> Void)?) {
        again = retry.map { KitGlassKey(title: "Try Again", action: $0) }
        super.init(frame: .zero)
        title.set(NSAttributedString(string: trouble.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: KitColor.ink]))
        detail.set(NSAttributedString(string: trouble.detail, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: KitColor.muted]))
        for view in [title, detail] as [NSView] { addSubview(view) }
        if let again { addSubview(again) }
        kitAccess(label: "\(trouble.title). \(trouble.detail)", role: .group)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func height(for width: CGFloat) -> CGFloat {
        title.height(for: width) + 3 + detail.height(for: width) + (again == nil ? 0 : 8 + BroadwaySize.small.height)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let top = title.height(for: width)
        title.frame = NSRect(x: 0, y: 0, width: width, height: top)
        let below = detail.height(for: width)
        detail.frame = NSRect(x: 0, y: top + 3, width: width, height: below)
        if let again {
            let w = again.intrinsicContentSize.width
            again.frame = kitSnap(NSRect(x: 0, y: top + 3 + below + 8, width: w, height: BroadwaySize.small.height))
        }
    }
}

final class ChatAnswerTurn: NSView, ChatRow {
    let key: String
    weak var browser: Browser?
    private var message: ChatMessage
    private var status: String?
    private var last = false
    private var stepsOpen = false
    private var parts: [NSView] = []
    private var shown: String?

    init(key: String, browser: Browser) {
        self.key = key
        self.browser = browser
        message = ChatMessage(role: .assistant, text: "")
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func set(_ message: ChatMessage, status given: String?, last: Bool) {
        let step = message.done ? nil : message.steps.last { !$0.done }
        let status = step.map { $0.summary.isEmpty ? $0.name : $0.summary } ?? given
        let look = "\(message.text.hashValue)|\(message.done)|\(message.failed ?? "")|\(message.stopped)|\(message.strays)|\(message.addressed)|\(message.steps.map { "\($0.id)\($0.done)" })|\(status ?? "")|\(last)|\(stepsOpen)|\(message.model?.plan.rawValue ?? "")"
        self.message = message
        self.status = status
        self.last = last
        guard look != shown || parts.isEmpty else { return }
        shown = look
        rebuild()
    }

    private func rebuild() {
        for view in parts { view.removeFromSuperview() }
        parts = []
        let opens: (URL) -> Void = { [weak browser] url in browser?.open(url, foreground: true, from: browser?.active) }
        if message.text.isEmpty, !message.done {
            let said = KitLabel(status ?? "Thinking", font: .systemFont(ofSize: ChatText.size), color: KitColor.faint)
            parts.append(said)
        }
        for block in ChatText.blocks(message.text) {
            switch block {
            case .words(let words):
                let view = ChatTextView(selectable: true)
                view.opens = opens
                view.set(words)
                parts.append(view)
            case .code(let code):
                parts.append(ChatCodeView(code))
            }
        }
        if !message.done, !message.text.isEmpty, let status, !status.isEmpty, !message.steps.isEmpty {
            parts.append(KitLabel(status, font: ChatLook.small, color: KitColor.faint))
        }
        if message.done, !message.steps.isEmpty {
            let count = message.steps.count
            let row = ChatStepsRow(title: count == 1 ? "1 step" : "\(count) steps", open: stepsOpen) { [weak self] in
                guard let self else { return }
                stepsOpen.toggle()
                shown = nil
                set(self.message, status: status, last: last)
                (superview as? ChatThreadDocument)?.changed()
            }
            parts.append(row)
            if stepsOpen {
                for step in message.steps {
                    let mark = step.failed ? "✕" : "✓"
                    let line = KitLabel("\(mark)  " + (step.summary.isEmpty ? step.name : step.summary),
                                        font: ChatLook.small, color: KitColor.muted)
                    line.lines = 2
                    parts.append(line)
                }
            }
        }
        if message.stopped { parts.append(KitLabel("Stopped", font: ChatLook.note, color: KitColor.faint)) }
        if message.failed != nil {
            let browser = browser
            parts.append(ChatTroubleView(ChatTrouble(message), retry: last ? { browser?.retryChat() } : nil))
        }
        if message.addressed { parts.append(ChatNote(ChatLook.caution)) }
        if !message.strays.isEmpty { parts.append(ChatNote("Not on the page: " + message.strays.joined(separator: ", "))) }
        if message.done, message.failed == nil, !message.text.isEmpty {
            parts.append(ChatAnswerFoot(agent: message.model?.plan.tool ?? "", text: message.text))
        }
        for view in parts { addSubview(view) }
        var spoken = message.text.isEmpty ? (status ?? "Thinking") : ChatText.plain(message.text)
        if let failed = message.failed { spoken = ChatTrouble(message).title + ". " + (failed.isEmpty ? "" : ChatTrouble(message).detail) }
        setAccessibilityLabel("Answer: \(spoken)")
        needsLayout = true
    }

    private func heights(_ width: CGFloat) -> [CGFloat] {
        parts.map { view in
            switch view {
            case let text as ChatTextView: return text.height(for: width)
            case let code as ChatCodeView: return code.height(for: width)
            case let note as ChatNote: return note.height(for: width)
            case let trouble as ChatTroubleView: return trouble.height(for: width)
            case let label as KitLabel: return ceil(label.measure(width: width).height)
            case is ChatStepsRow: return 20
            case is ChatAnswerFoot: return 22
            default: return 0
            }
        }
    }

    func height(for width: CGFloat) -> CGFloat {
        let all = heights(width)
        return all.reduce(0, +) + CGFloat(max(0, all.count - 1)) * ChatLook.lineGap
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (view, height) in zip(parts, heights(bounds.width)) {
            view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height + ChatLook.lineGap
        }
    }
}

final class ChatCodeView: NSView {
    private let box = KitBox(fill: Palette.NS.wash, corners: .radius(8))
    private let words = ChatTextView(selectable: true)
    static let pad: CGFloat = 9

    init(_ code: String) {
        super.init(frame: .zero)
        addSubview(box)
        addSubview(words)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.lineBreakMode = .byCharWrapping
        words.set(NSAttributedString(string: code, attributes: [.font: ChatText.mono, .foregroundColor: KitColor.ink, .paragraphStyle: style]))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func height(for width: CGFloat) -> CGFloat { words.height(for: max(20, width - Self.pad * 2)) + Self.pad * 2 }

    override func layout() {
        super.layout()
        box.frame = bounds
        words.frame = NSRect(x: Self.pad, y: Self.pad, width: max(20, bounds.width - Self.pad * 2), height: max(0, bounds.height - Self.pad * 2))
    }
}

final class ChatStepsRow: KitButton {
    private let label: KitLabel
    private let chevron: KitSymbol

    init(title: String, open: Bool, act: @escaping () -> Void) {
        label = KitLabel(title, font: ChatLook.small, color: KitColor.muted)
        chevron = KitSymbol(open ? "chevron.down" : "chevron.right", style: KitSymbol.Style(size: 9, weight: .semibold), tint: KitColor.faint)
        super.init(.plain(press: 0.96), label: open ? "Hide \(title)" : "Show \(title)", action: act)
        addSubview(label)
        addSubview(chevron)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let size = label.measure(width: .greatestFiniteMagnitude)
        label.frame = kitSnap(NSRect(x: 0, y: (bounds.height - size.height) / 2, width: ceil(size.width), height: ceil(size.height)))
        chevron.frame = NSRect(x: ceil(size.width) + 5, y: (bounds.height - 10) / 2, width: 10, height: 10)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let size = label.measure(width: .greatestFiniteMagnitude)
        return local.x <= ceil(size.width) + 20 && bounds.contains(local) ? self : nil
    }
}

final class ChatAnswerFoot: NSView {
    private let said: KitLabel
    private let copy: KitDoor

    init(agent: String, text: String) {
        said = KitLabel(agent.isEmpty ? ChatLook.mayBeWrong : "\(ChatLook.mayBeWrong) · \(agent)", font: ChatLook.small, color: KitColor.faint)
        copy = KitDoor(icon: "doc.on.doc", help: "Copy Answer", size: 11, box: 22) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ChatText.plain(text), forType: .string)
        }
        super.init(frame: .zero)
        addSubview(said)
        addSubview(copy)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        copy.frame = NSRect(x: bounds.width - 22, y: 0, width: 22, height: 22)
        let size = said.measure(width: max(0, bounds.width - 30))
        said.frame = kitSnap(NSRect(x: 0, y: (22 - size.height) / 2, width: max(0, bounds.width - 30), height: ceil(size.height)))
    }
}
