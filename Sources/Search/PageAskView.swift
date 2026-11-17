import AppKit

final class PageAskView: NSView {
    let browser: Browser
    let line: PageAsk
    private let card: AskAnswerCard
    private let field: AskFieldPanel

    static let gap: CGFloat = 8
    static let widest: CGFloat = 640

    init(browser: Browser, line: PageAsk) {
        self.browser = browser
        self.line = line
        card = AskAnswerCard(line: line)
        field = AskFieldPanel(browser: browser, line: line)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        addSubview(card)
        addSubview(field)
        setAccessibilityElement(false)
        setAccessibilityIdentifier("ask.line")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func height(for width: CGFloat) -> CGFloat {
        let below = field.height(for: width)
        guard line.answering else { return below }
        return card.height(for: width) + Self.gap + below
    }

    override func layout() {
        super.layout()
        let below = field.height(for: bounds.width)
        field.frame = NSRect(x: 0, y: bounds.height - below, width: bounds.width, height: below)
        card.isHidden = !line.answering
        if line.answering {
            let above = card.height(for: bounds.width)
            card.frame = NSRect(x: 0, y: bounds.height - below - Self.gap - above, width: bounds.width, height: above)
            card.needsLayout = true
        }
        field.needsLayout = true
    }
}

final class AskFieldPanel: NSView, NSTextFieldDelegate {
    let browser: Browser
    let line: PageAsk
    private let glass = KitGlass.floating(radius: 14)
    private let stage = KitFlippedView()
    private let input: SelectionField
    private let refused = KitLabel("", font: .systemFont(ofSize: 13), color: KitColor.muted)
    private var chips: [AskChip] = []
    private var hint: CommandHintView?
    private var focused = -1
    private weak var before: NSResponder?

    private static let pad: CGFloat = 12
    private static let chipHeight: CGFloat = 20

    init(browser: Browser, line: PageAsk) {
        self.browser = browser
        self.line = line
        input = SelectionField.make(placeholder: line.placeholder, size: 13)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 44))
        glass.hold(stage)
        addSubview(glass)
        input.delegate = self
        input.target = self
        input.action = #selector(submit)
        input.kitAccess(id: "ask.line.field", label: "Ask")
        refused.text = line.refusal ?? ""
        refused.setAccessibilityIdentifier("ask.line.refused")
        stage.addSubview(input)
        stage.addSubview(refused)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        before = window.firstResponder
        guard line.takes else { return }
        DispatchQueue.main.async { [weak self] in self?.input.focus() }
    }

    override func removeFromSuperview() {
        if let window, let editor = input.currentEditor(), window.firstResponder === editor {
            let back = before.flatMap { ($0 as? NSView)?.window === window ? $0 : nil }
            window.makeFirstResponder(back)
        }
        super.removeFromSuperview()
    }

    @objc private func submit() {
        line.draft = input.stringValue
        line.run()
    }

    func controlTextDidChange(_ notification: Notification) {
        line.draft = input.stringValue
    }

    private var chipWords: [(String, String)] {
        var out: [(String, String)] = []
        if line.blind, line.takes { out.append(("lock", "Private window, answered on this Mac")) }
        for item in line.conversation.attachments { out.append(("doc.text", item.label)) }
        return out
    }

    func height(for width: CGFloat) -> CGFloat {
        var height = Self.pad * 2 + 18
        if line.takes, !chipWords.isEmpty { height += Self.chipHeight + 8 }
        return height
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        stage.frame = glass.bounds
        let inner = bounds.width - Self.pad * 2
        var y = Self.pad
        let wanted = line.takes ? chipWords : []
        if chips.map({ [$0.symbol, $0.text] }) != wanted.map({ [$0.0, $0.1] }) {
            for chip in chips { chip.removeFromSuperview() }
            chips = wanted.map { AskChip(symbol: $0.0, text: $0.1) }
            for chip in chips { stage.addSubview(chip) }
        }
        if !chips.isEmpty {
            var x = Self.pad
            for chip in chips {
                let width = min(chip.intrinsicContentSize.width, 260, max(0, Self.pad + inner - x))
                chip.frame = kitSnap(NSRect(x: x, y: y, width: width, height: Self.chipHeight))
                x += width + 6
            }
            y += Self.chipHeight + 8
        }
        let running = line.conversation.running
        let words: (String, String)? = !line.takes ? ("esc", "Close") : running ? ("esc", "Stop") : ("↩", "Ask")
        if hint?.key != words?.0 || hint?.title != words?.1 {
            hint?.removeFromSuperview()
            hint = words.map { CommandHintView($0.0, $0.1) }
            if let hint { stage.addSubview(hint) }
        }
        var right = bounds.width - Self.pad
        if let hint {
            let size = hint.intrinsicContentSize
            right -= size.width
            hint.frame = kitSnap(NSRect(x: right, y: y + (18 - size.height) / 2, width: size.width, height: size.height))
            right -= 10
        }
        input.isHidden = !line.takes
        refused.isHidden = line.takes
        let room = max(0, right - Self.pad)
        if line.takes {
            input.placeholderAttributedString = NSAttributedString(string: line.placeholder, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.NS.faint,
            ])
            if input.stringValue != line.draft { input.stringValue = line.draft }
            input.isEnabled = !running
            input.frame = NSRect(x: Self.pad - 2, y: y, width: room + 4, height: 18)
            if focused != line.focus {
                focused = line.focus
                if window != nil { DispatchQueue.main.async { [weak self] in self?.input.focus() } }
            }
        } else {
            refused.frame = NSRect(x: Self.pad, y: y, width: room, height: 18)
        }
    }
}

final class AskChip: NSView {
    let symbol: String
    let text: String
    private let plate = KitBox(fill: Palette.NS.wash.withAlphaComponent(0.7), corners: .capsule)
    private let icon: KitSymbol
    private let label: KitLabel

    init(symbol: String, text: String) {
        self.symbol = symbol
        self.text = text
        icon = KitSymbol(symbol, style: KitSymbol.Style(size: 10, weight: .regular), tint: KitColor.muted)
        label = KitLabel(text, font: .systemFont(ofSize: 11), color: KitColor.muted)
        super.init(frame: .zero)
        addSubview(plate)
        addSubview(icon)
        addSubview(label)
        icon.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 7 + 12 + 4 + ceil(label.intrinsicContentSize.width) + 2 + 9, height: 20)
    }

    override func layout() {
        super.layout()
        plate.frame = bounds
        icon.frame = kitSnap(NSRect(x: 7, y: (bounds.height - 12) / 2, width: 12, height: 12))
        let height = label.intrinsicContentSize.height
        label.frame = kitSnap(NSRect(x: 23, y: (bounds.height - height) / 2, width: max(0, bounds.width - 23 - 9), height: height))
    }
}

final class AskAnswerCard: NSView {
    let line: PageAsk
    private let glass = KitGlass.floating(radius: 14)
    private let stage = KitFlippedView()
    private let scroll = NSScrollView()
    private let words = NSTextView()
    private let footer = KitLabel("", font: .systemFont(ofSize: 10.5), color: KitColor.faint)
    private var hints: [CommandHintView] = []
    private var shown = ""

    private static let pad: CGFloat = 14
    private static let most: CGFloat = 340

    init(line: PageAsk) {
        self.line = line
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 80))
        glass.hold(stage)
        addSubview(glass)
        words.isEditable = false
        words.isSelectable = true
        words.drawsBackground = false
        words.textContainerInset = .zero
        words.textContainer?.lineFragmentPadding = 0
        words.textContainer?.widthTracksTextView = true
        words.isVerticallyResizable = true
        words.setAccessibilityIdentifier("ask.line.answer")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = words
        footer.setAccessibilityIdentifier("ask.line.footer")
        stage.addSubview(scroll)
        stage.addSubview(footer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shown = ""
        needsLayout = true
    }

    private func body(dark: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        guard let answer = line.conversation.lastAnswer else { return out }
        func add(_ string: String, size: CGFloat, color: NSColor, gap: CGFloat = 8) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = size >= 13 ? 2.5 : 1
            paragraph.paragraphSpacingBefore = out.length > 0 ? gap : 0
            out.append(NSAttributedString(string: (out.length > 0 ? "\n" : "") + string, attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: color.kitResolved(dark: dark), .paragraphStyle: paragraph,
            ]))
        }
        func caution(_ string: String) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = out.length > 0 ? 8 : 0
            let ink = KitColor.muted.kitResolved(dark: dark)
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            if let image = KitGlyph.image("exclamationmark.triangle", KitSymbol.Style(size: 10, weight: .medium, palette: [ink])) {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = NSRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
                let mark = NSMutableAttributedString(attachment: attachment)
                mark.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: mark.length))
                out.append(mark)
            }
            out.append(NSAttributedString(string: " " + string, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: ink, .paragraphStyle: paragraph,
            ]))
        }
        if answer.addressed { caution("This page has text written for an AI to follow. The answer may have been steered by it.") }
        if answer.text.isEmpty, !answer.done { add(line.conversation.status ?? "…", size: 13, color: KitColor.faint) }
        if !answer.text.isEmpty { add(answer.text, size: 13, color: KitColor.ink) }
        if let failed = answer.failed { add(failed, size: 12, color: KitColor.muted) }
        if answer.stopped { add("Stopped", size: 11.5, color: KitColor.faint) }
        if !answer.strays.isEmpty { caution("Not on the page: " + answer.strays.joined(separator: ", ")) }
        return out
    }

    private func textHeight(for width: CGFloat) -> CGFloat {
        let rect = body(dark: kitDark).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(Self.most, max(17, ceil(rect.height)))
    }

    func height(for width: CGFloat) -> CGFloat {
        Self.pad + textHeight(for: width - Self.pad * 2) + 10 + 15 + Self.pad
    }

    private var hintWords: [(String, String)] {
        guard !line.conversation.running, line.conversation.lastAnswer?.text.isEmpty == false else { return [] }
        return [("⌘C", "Copy"), ("⌘↩", "Done")]
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        stage.frame = glass.bounds
        let inner = bounds.width - Self.pad * 2
        let string = body(dark: kitDark)
        let height = textHeight(for: inner)
        if string.string != shown || words.textStorage?.length != string.length {
            words.textStorage?.setAttributedString(string)
            shown = string.string
        }
        scroll.frame = NSRect(x: Self.pad, y: Self.pad, width: inner, height: height)
        words.frame = NSRect(x: 0, y: 0, width: inner, height: max(height, words.frame.height))
        words.sizeToFit()
        if line.conversation.running { words.scrollToEndOfDocument(nil) }
        let y = Self.pad + height + 10
        let wanted = hintWords
        if hints.map({ [$0.key, $0.title] }) != wanted.map({ [$0.0, $0.1] }) {
            for hint in hints { hint.removeFromSuperview() }
            hints = wanted.map { CommandHintView($0.0, $0.1) }
            for hint in hints { stage.addSubview(hint) }
        }
        var x = bounds.width - Self.pad
        for hint in hints.reversed() {
            let size = hint.intrinsicContentSize
            x -= size.width
            hint.frame = kitSnap(NSRect(x: x, y: y + (15 - size.height) / 2, width: size.width, height: size.height))
            x -= 10
        }
        let agent = line.conversation.lastAnswer?.model?.plan ?? line.agent
        footer.text = agent.map { "AI, may be wrong · \($0.tool)" } ?? "AI, may be wrong"
        footer.frame = NSRect(x: Self.pad, y: y, width: max(0, x - Self.pad), height: 15)
    }
}
