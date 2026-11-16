import AppKit
import Combine

@MainActor
final class GetToKnowRowView: KitFormSection {
    private weak var browser: Browser?
    private let meet: GetToKnow
    private let plans: Plans
    private var sheet: NSWindow?
    private lazy var stopButton = KitForm.button("Stop") { [weak self] in self?.meet.stop() }
    private lazy var startButton = KitForm.button("Start…") { [weak self] in self?.confirm() }
    private lazy var notesButton = KitForm.button("Notes About You") { [weak self] in self?.meet.reviewing = true }
    private lazy var againButton = KitForm.button("Start Again…") { [weak self] in self?.confirm() }

    init(browser: Browser?, meet: GetToKnow = .shared, plans: Plans = .shared) {
        self.browser = browser
        self.meet = meet
        self.plans = plans
        super.init(frame: .zero)
    }

    var line: String {
        switch meet.stage {
        case .idle: return "An agent reads your signed-in sites for about ten minutes, then suggests notes, your profile and addresses. Nothing is kept until you say so."
        case .reading: return "Reading your sites. You can go on browsing."
        case .done: return meet.waiting.isEmpty ? "Everything has been looked over" : (meet.waiting.count == 1 ? "1 thing to look over" : "\(meet.waiting.count) things to look over")
        }
    }

    override func spec() -> [KitFormLine] {
        let controls: [NSView]
        switch meet.stage {
        case .reading: controls = [stopButton]
        case .idle: controls = [startButton]
        case .done: controls = [notesButton, againButton]
        }
        return [line("meet", "Get to Know Me", meet.trouble ?? line, symbol: "person.crop.circle.badge.checkmark", spacing: 6, controls)]
    }

    override func layout() {
        super.layout()
        let wanted = meet.reviewing && window != nil
        if wanted != (sheet != nil) { DispatchQueue.main.async { [weak self] in self?.present() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        if window == nil, let sheet { sheet.sheetParent?.endSheet(sheet) }
    }

    private func present() {
        if meet.reviewing, sheet == nil, let window {
            let content = NiceToMeetYouView(meet: meet) { [weak self] in self?.meet.reviewing = false }
            let made = NSWindow(contentRect: NSRect(origin: .zero, size: content.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
            made.contentView = content
            made.setContentSize(content.fittingSize)
            sheet = made
            window.beginSheet(made) { [weak self] _ in
                self?.sheet = nil
                if self?.meet.reviewing == true { self?.meet.reviewing = false }
            }
        } else if !meet.reviewing, let sheet {
            sheet.sheetParent?.endSheet(sheet)
        }
    }

    private func confirm() {
        Ask.sure("Let an agent read your sites?", detail: "For about ten minutes it reads the sites you use most, signed in as you, and what it reads goes to your plan's maker. It only reads. It skips banks and password managers, never saves passwords, codes or card numbers, and keeps nothing until you look it over.",
                 confirm: "Start") { [weak self] in
            guard let self, let browser else { return }
            let plans = plans
            let meet = meet
            Task { @MainActor in
                if !plans.looked { await plans.refresh() }
                meet.start(browser: browser, choice: plans.choice(.tasks, browser.prefs))
            }
        }
    }
}

@MainActor
final class NiceToMeetYouView: KitFlippedView {
    var ground = false { didSet { needsDisplay = true } }
    private let meet: GetToKnow
    private let done: () -> Void
    private var fixing: String?
    private var words = ""
    private var place = AutofillAddress()
    private var said: String?
    private var shownState: [String] = []

    private let title = KitParagraph("Nice to meet you", font: .systemFont(ofSize: 17, weight: .semibold), color: .labelColor)
    private let intro = KitParagraph("This is what Broadway found. Nothing is kept until you press Keep. Cross out what's wrong and fix what's close.",
                                     font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let scroll = NSScrollView()
    private let list = KitFlippedView()
    private let saidText = KitParagraph("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private lazy var tidyButton = KitForm.button("Tidy Up") { [weak self] in self?.tidy() }
    private lazy var closeButton = KitForm.button("Close") { [weak self] in self?.done() }
    private lazy var keepButton = KitForm.button("Keep") { [weak self] in
        self?.meet.keep()
        self?.said = "Kept"
        self?.needsLayout = true
    }

    static let width: CGFloat = 540

    init(meet: GetToKnow = .shared, done: @escaping () -> Void) {
        self.meet = meet
        self.done = done
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        tidyButton.kitAccess(help: "Clears old addresses and copies")
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = list
        for view in [title, intro, scroll, saidText, tidyButton, closeButton, keepButton] as [NSView] { addSubview(view) }
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: height) }

    private var inner: CGFloat { Self.width - 40 }

    private var height: CGFloat {
        var y: CGFloat = 20 + title.height(for: inner) + 12 + intro.height(for: inner) + 12 + 340 + 12
        if said != nil { y += saidText.height(for: inner) + 12 }
        return y + 28 + 20
    }

    override func draw(_ dirtyRect: NSRect) {
        guard ground else { return }
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    private var shown: [Finding] { meet.findings.filter { $0.state != .crossed || fixing == $0.id } }
    private var crossed: [Finding] { meet.findings.filter { $0.state == .crossed } }

    override func layout() {
        let state = meet.findings.map { "\($0.id)\($0.state)\($0.text)" } + meet.refused.map(\.id) + [fixing ?? ""]
        if state != shownState { rebuild() }
        super.layout()
        saidText.text = said ?? ""
        saidText.isHidden = said == nil
        keepButton.isEnabled = !meet.waiting.isEmpty
        var y: CGFloat = 20
        for view in [title, intro] {
            let h = view.height(for: inner)
            view.frame = NSRect(x: 20, y: y, width: inner, height: h)
            y += h + 12
        }
        scroll.frame = NSRect(x: 20, y: y, width: inner, height: 340)
        y += 340 + 12
        if said != nil {
            let h = saidText.height(for: inner)
            saidText.frame = NSRect(x: 20, y: y, width: inner, height: h)
            y += h + 12
        }
        let tidy = tidyButton.intrinsicContentSize
        tidyButton.frame = NSRect(x: 20, y: y, width: tidy.width, height: 28)
        let keep = keepButton.intrinsicContentSize
        keepButton.frame = NSRect(x: Self.width - 20 - keep.width, y: y, width: keep.width, height: 28)
        let close = closeButton.intrinsicContentSize
        closeButton.frame = NSRect(x: keepButton.frame.minX - 8 - close.width, y: y, width: close.width, height: 28)
        layoutList()
        if abs(frame.height - height) > 0.5 { invalidateIntrinsicContentSize() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, keepButton.isEnabled, fixing == nil {
            _ = keepButton.accessibilityPerformPress()
        } else {
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    private func rebuild() {
        shownState = meet.findings.map { "\($0.id)\($0.state)\($0.text)" } + meet.refused.map(\.id) + [fixing ?? ""]
        list.subviews.forEach { $0.removeFromSuperview() }
        for finding in shown { list.addSubview(FindingRow(finding: finding, host: self)) }
        if !crossed.isEmpty {
            list.addSubview(heading("Crossed out"))
            for finding in crossed { list.addSubview(CrossedRow(finding: finding) { [weak self] in self?.meet.restore(finding.id) }) }
        }
        if !meet.refused.isEmpty {
            list.addSubview(heading("Refused"))
            for item in meet.refused {
                list.addSubview(KitParagraph("\(item.kind.title.prefix(1).uppercased() + item.kind.title.dropFirst()) on \(item.site)",
                                             font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
            }
        }
        if meet.findings.isEmpty, meet.refused.isEmpty {
            list.addSubview(KitParagraph("Nothing yet", font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
        }
        needsLayout = true
    }

    private func heading(_ text: String) -> KitParagraph {
        let made = KitParagraph(text, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        made.identifier = NSUserInterfaceItemIdentifier("heading")
        return made
    }

    private func layoutList() {
        var y: CGFloat = 0
        for (index, view) in list.subviews.enumerated() {
            if index > 0 { y += 8 }
            if view.identifier?.rawValue == "heading" { y += 6 }
            let h: CGFloat
            if let row = view as? FindingRow { h = row.height(for: inner) }
            else if let paragraph = view as? KitParagraph { h = paragraph.height(for: inner) }
            else { h = view.fittingSize.height }
            view.frame = NSRect(x: 0, y: y, width: inner, height: h)
            y += h
        }
        list.frame = NSRect(x: 0, y: 0, width: inner, height: max(y, 340))
    }

    fileprivate func startFixing(_ finding: Finding) {
        fixing = finding.id
        words = finding.text
        place = finding.address ?? AutofillAddress()
        needsLayout = true
    }

    fileprivate func cancelFixing() {
        fixing = nil
        needsLayout = true
    }

    fileprivate func save(_ finding: Finding, words: String, place: AutofillAddress) {
        let refused = finding.kind == .address ? meet.fix(finding.id, address: place) : meet.fix(finding.id, text: words)
        if let refused {
            said = "That looks like \(refused.title). Broadway never keeps those."
        } else {
            said = nil
            fixing = nil
        }
        needsLayout = true
    }

    fileprivate func cross(_ finding: Finding) { meet.cross(finding.id) }
    fileprivate var editing: (id: String?, words: String, place: AutofillAddress) { (fixing, words, place) }

    private func tidy() {
        let plan = meet.tidyPlan()
        guard !plan.isEmpty else {
            MemoryStore.shared.dropCopies()
            said = "Nothing to tidy"
            needsLayout = true
            return
        }
        let count = plan.addresses.count + plan.findings.count
        Ask.sure("Tidy up?", detail: count == 1 ? "This removes 1 old or copied item, including any saved addresses" : "This removes \(count) old or copied items, including any saved addresses", confirm: "Tidy Up") { [weak self] in
            self?.meet.tidyUp()
            self?.said = "Tidied"
            self?.needsLayout = true
        }
    }
}

@MainActor
private final class FindingRow: KitBox {
    private let finding: Finding
    private weak var host: NiceToMeetYouView?
    private let head: [KitLabel]
    private let text = NSTextField(labelWithString: "")
    private var buttons: [KitButton] = []
    private var fields: [NSTextField] = []
    private var editorButtons: [KitFormButton] = []

    init(finding: Finding, host: NiceToMeetYouView) {
        self.finding = finding
        self.host = host
        var head = [KitLabel(finding.heading, font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor),
                    KitLabel("from \(finding.site)", font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)]
        if finding.state == .kept { head.append(KitLabel("Kept", font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)) }
        self.head = head
        super.init(frame: .zero)
        fill = .controlBackgroundColor
        corners = .radius(10)
        head.forEach(addSubview)
        let editing = host.editing
        if finding.state == .waiting, editing.id != finding.id {
            buttons.append(Self.plain("Fix") { [weak host] in host?.startFixing(finding) })
        }
        buttons.append(Self.plain("Cross Out") { [weak host] in host?.cross(finding) })
        buttons.forEach(addSubview)
        if editing.id == finding.id {
            if finding.kind == .address {
                let place = editing.place
                fields = [Self.field("Street", place.line1), Self.field("City", place.city), Self.field("Postal code", place.postal), Self.field("Country", place.country)]
            } else {
                fields = [Self.field("", editing.words)]
            }
            fields.forEach(addSubview)
            editorButtons = [KitForm.button("Cancel") { [weak host] in host?.cancelFixing() },
                             KitForm.button("Save") { [weak self] in self?.save() }]
            editorButtons.forEach(addSubview)
        } else {
            text.stringValue = finding.text
            text.font = .systemFont(ofSize: 13)
            text.textColor = .labelColor
            text.isSelectable = true
            text.lineBreakMode = .byWordWrapping
            text.maximumNumberOfLines = 0
            addSubview(text)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func plain(_ title: String, run: @escaping () -> Void) -> KitButton {
        let made = KitButton(.plain(press: 0.94), label: title, action: run)
        made.content = KitLabel(title, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        made.content?.setAccessibilityElement(false)
        return made
    }

    private static func field(_ placeholder: String, _ value: String) -> NSTextField {
        let made = NSTextField(string: value)
        made.placeholderString = placeholder
        made.bezelStyle = .roundedBezel
        made.setAccessibilityLabel(placeholder.isEmpty ? "Finding" : placeholder)
        return made
    }

    private func save() {
        guard let host else { return }
        var place = host.editing.place
        if finding.kind == .address, fields.count == 4 {
            place.line1 = fields[0].stringValue
            place.city = fields[1].stringValue
            place.postal = fields[2].stringValue
            place.country = fields[3].stringValue
        }
        host.save(finding, words: fields.first?.stringValue ?? "", place: place)
    }

    private func textHeight(_ width: CGFloat) -> CGFloat {
        ceil(text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width + 4, height: 10_000)).height ?? 16)
    }

    func height(for width: CGFloat) -> CGFloat {
        let inner = width - 20
        var h: CGFloat = 10 + 14 + 4
        if fields.isEmpty {
            h += textHeight(inner)
        } else {
            h += CGFloat(fields.count) * 22 + CGFloat(fields.count) * 4 + 28
        }
        return h + 10
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - 20
        var right = bounds.width - 10
        for button in buttons.reversed() {
            let size = button.content?.intrinsicContentSize ?? .zero
            button.frame = NSRect(x: right - size.width, y: 10, width: size.width, height: 14)
            right -= size.width + 8
        }
        var x: CGFloat = 10
        for label in head {
            let size = label.measure(width: .greatestFiniteMagnitude)
            label.frame = NSRect(x: x, y: 10, width: min(ceil(size.width), max(0, right - x)), height: 14)
            x += ceil(size.width) + 8
        }
        var y: CGFloat = 28
        if fields.isEmpty {
            text.frame = NSRect(x: 8, y: y, width: inner + 4, height: textHeight(inner))
        } else {
            for field in fields {
                field.frame = NSRect(x: 10, y: y, width: inner, height: 22)
                y += 26
            }
            var x: CGFloat = 10
            for button in editorButtons {
                let size = button.intrinsicContentSize
                button.frame = NSRect(x: x, y: y, width: size.width, height: 28)
                x += size.width + 8
            }
        }
    }
}

@MainActor
private final class CrossedRow: KitFlippedView {
    private let label: StruckText
    private let back: KitButton

    init(finding: Finding, restore: @escaping () -> Void) {
        label = StruckText(finding.text)
        back = KitButton(.plain(press: 0.94), label: "Put Back", action: restore)
        back.content = KitLabel("Put Back", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        super.init(frame: .zero)
        addSubview(label)
        addSubview(back)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 15) }
    override var fittingSize: NSSize { NSSize(width: 0, height: 15) }

    override func layout() {
        super.layout()
        let size = back.content?.intrinsicContentSize ?? .zero
        back.frame = NSRect(x: bounds.width - size.width, y: 0, width: size.width, height: bounds.height)
        label.frame = NSRect(x: 0, y: 0, width: max(0, back.frame.minX - 8), height: bounds.height)
    }
}

@MainActor
enum GetToKnowSurface {
    static func meet(_ request: [String: Any]) -> GetToKnow {
        let stage = request["stage"] as? String ?? "idle"
        let file = Store.file("bench-get-to-know-\(stage).json")
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        var findings: [Finding] = []
        var refused: [RefusedFinding] = []
        if stage == "done" {
            findings = [
                Finding(id: "a", kind: .note, subject: .you, name: "Work", text: "Designs browsers at Acme and ships on Fridays", seen: seen, site: "linkedin.com"),
                Finding(id: "b", kind: .profile, field: "email", text: "sam@acme.test", seen: seen, site: "github.com"),
                Finding(id: "c", kind: .address, text: "1 Infinite Loop, Cupertino, 95014, United States",
                        address: AutofillAddress(id: "home", line1: "1 Infinite Loop", city: "Cupertino", postal: "95014", country: "United States"),
                        seen: seen, site: "amazon.com"),
                Finding(id: "d", kind: .note, subject: .you, name: "Coffee", text: "Takes oat milk", seen: seen, site: "starbucks.com", state: .kept),
                Finding(id: "e", kind: .profile, field: "phone", text: "+1 555 0100", seen: seen, site: "uber.com", state: .crossed),
            ]
            refused = [RefusedFinding(id: "r", kind: .cardNumber, site: "shop.test")]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let saved: [String: Any] = [
            "stage": stage,
            "findings": findings.compactMap { try? JSONSerialization.jsonObject(with: encoder.encode($0)) },
            "refused": refused.compactMap { try? JSONSerialization.jsonObject(with: encoder.encode($0)) },
        ]
        try? JSONSerialization.data(withJSONObject: saved).write(to: file)
        return GetToKnow(file: file)
    }

    static func sheet(_ request: [String: Any]) -> NSView {
        let meet = meet(["stage": "done"])
        let view = NiceToMeetYouView(meet: meet, done: {})
        view.ground = true
        return view
    }
}

private final class StruckText: KitFlippedView {
    let text: String

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor,
                                                      .strikethroughStyle: NSUnderlineStyle.single.rawValue, .paragraphStyle: paragraph])
            .draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
