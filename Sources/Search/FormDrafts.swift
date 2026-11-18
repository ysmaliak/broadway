import AppKit
import Combine
import Observation

struct FormDraftAnswer: Equatable, Identifiable {
    let field: FormField
    var text: String

    var id: String { field.id }
}

enum FormDraftPlan {
    static let longest = 4000
    private static let closed = #"captcha|user ?name|\blogin\b|sign ?in|search|coupon|promo|voucher|\bgift|file ?name|\bcard\b|\bcvv\b|\bcvc\b"#

    static func candidates(_ fields: [FormField]) -> [FormField] {
        fields.filter { field in
            guard field.frame.isEmpty, !field.filled, ["text", "textarea"].contains(field.type),
                  FormClassifier.verdict(field) == .stay(.other), !FormClassifier.isCode(field)
            else { return false }
            return field.words.range(of: closed, options: .regularExpression) == nil
        }
    }

    private static func flat(_ text: String, limit: Int) -> String {
        String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(limit))
    }

    static func boxes(_ fields: [FormField]) -> String {
        fields.map { field in
            let limit = field.maxLength > 0 ? " (at most \(field.maxLength) characters)" : ""
            return "Box \(field.index): \(flat([field.label, field.placeholder, field.name].first { !$0.isEmpty } ?? "Box", limit: 200))\(limit)"
        }.joined(separator: "\n")
    }

    static func details(_ profile: AutofillProfile) -> String {
        let known = [("Name", profile.name), ("Email", profile.email), ("Phone", profile.phone), ("Company", profile.company),
                     ("Role", profile.role), ("Location", profile.location), ("Links", profile.links.joined(separator: ", "))]
        let lines = known.filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }
        return lines.isEmpty ? "I haven't given any." : lines.joined(separator: "\n")
    }

    static func request(fields: [FormField], profile: AutofillProfile, page: AIPage.Read?, fence: String) -> ProviderRequest {
        var sources = [AIPrompt.Source(label: "The boxes on the form", text: boxes(fields))]
        if let page { sources.append(AIPrompt.Source(page)) }
        let wanted = """
        Draft short answers, as me, to the questions in the form's boxes above. Use only my details below and what the page says. Leave \
        out any box you can't answer from those, and never make up a fact about me. I will read every answer before it goes in.

        My details:
        \(details(profile))

        Reply with JSON and nothing else: {"answers":[{"box":3,"text":"the answer"}]}
        """
        return ProviderRequest(system: AIPrompt.system(fence: fence, browsing: false),
                               prompt: AIPrompt.compose(fence: fence, sources: sources, history: [], request: wanted))
    }

    static func answers(from reply: String, fields: [FormField]) -> [FormDraftAnswer] {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let found = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any],
              let rows = found["answers"] as? [[String: Any]]
        else { return [] }
        var kept: [FormDraftAnswer] = []
        for row in rows {
            guard let box = row["box"] as? Int, let field = fields.first(where: { $0.index == box }),
                  !kept.contains(where: { $0.field == field }),
                  var text = (row["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { continue }
            if field.type == "text" { text = flat(text, limit: longest) }
            guard text.count <= longest, field.maxLength == 0 || text.count <= field.maxLength,
                  MemoryFilter.secret(in: text) == nil
            else { continue }
            kept.append(FormDraftAnswer(field: field, text: text))
        }
        return kept
    }

    static func same(_ old: FormField, _ new: FormField) -> Bool {
        old.id == new.id && old.label == new.label && old.name == new.name && old.type == new.type
    }
}

@MainActor
@Observable
final class FormDrafts {
    static let onKey = "autofill.drafts"

    struct Preview: Equatable {
        let tab: Tab.ID
        let page: URL?
        let place: String
        let warned: Bool
        var answers: [FormDraftAnswer]
    }

    private(set) var preview: Preview?
    private(set) var working: Tab.ID?
    var on = Store.settings.object(forKey: FormDrafts.onKey) as? Bool ?? true {
        didSet { Store.settings.set(on, forKey: Self.onKey) }
    }

    @ObservationIgnored weak var browser: Browser?
    @ObservationIgnored var pageFor: (Tab) -> FormPageAccess? = { $0.formPage }
    @ObservationIgnored var readPage: (Tab) async -> AIPage.Read? = { $0.canBeRead ? await AIPage.read($0) : nil }
    @ObservationIgnored var book = AutofillBook.shared
    @ObservationIgnored private var session: ProviderSession?

    func begin() {
        guard let tab = browser?.active else { return }
        begin(on: tab)
    }

    func begin(on tab: Tab) {
        guard let browser, working == nil else { return }
        guard on, book.fillsForms else {
            browser.announce("Form drafts are off in Settings › Autofill")
            return
        }
        guard !tab.neverSent else {
            browser.announce("Broadway doesn't draft in private windows")
            return
        }
        guard let page = pageFor(tab) else { return }
        guard let choice = Plans.shared.choice(.forms, browser.prefs) else {
            browser.announce(Plans.shared.trouble(browser.prefs) ?? "Sign in to Claude Code or Codex first")
            return
        }
        working = tab.id
        preview = nil
        Task { await draft(tab, page, choice) }
    }

    private func draft(_ tab: Tab, _ page: FormPageAccess, _ choice: ModelChoice) async {
        defer { if working == tab.id { working = nil } }
        let address = tab.pageAddress
        let fields = FormDraftPlan.candidates(await page.fields())
        guard !fields.isEmpty else {
            browser?.announce("Nothing here for Broadway to draft")
            return
        }
        let read = await readPage(tab)
        let request = FormDraftPlan.request(fields: fields, profile: await book.fetchedProfile(), page: read, fence: AIPage.newFence())
        let live = Plans.shared.start(request, on: choice)
        session = live
        var reply = ""
        do {
            for try await event in live.events {
                if case .text(let piece) = event { reply += piece }
            }
        } catch ProviderError.cancelled {
            return
        } catch {
            browser?.announce("Couldn't draft: \(error.localizedDescription)")
            return
        }
        session = nil
        guard working == tab.id, tab.pageAddress == address else { return }
        let answers = FormDraftPlan.answers(from: reply, fields: fields)
        guard !answers.isEmpty else {
            browser?.announce("Broadway has nothing to put in those boxes")
            return
        }
        let warned = read?.addressed == true || AIPage.addressesAI(FormDraftPlan.boxes(fields))
        preview = Preview(tab: tab.id, page: address, place: choice.plan == .thisMac ? "On this Mac" : choice.plan.name, warned: warned, answers: answers)
    }

    func stop() {
        session?.cancel()
        session = nil
        working = nil
    }

    func edit(_ id: String, _ text: String) {
        guard let index = preview?.answers.firstIndex(where: { $0.id == id }) else { return }
        preview?.answers[index].text = text
    }

    func cancel() { preview = nil }

    func confirm() {
        guard let up = preview, let tab = browser?.tabs.first(where: { $0.id == up.tab }), let page = pageFor(tab) else {
            preview = nil
            return
        }
        preview = nil
        guard tab.pageAddress == up.page, !tab.neverSent else { return }
        Task {
            let current = FormDraftPlan.candidates(await page.fields())
            let still = up.answers.filter { answer in
                !answer.text.isEmpty && current.contains { FormDraftPlan.same(answer.field, $0) }
            }
            guard !still.isEmpty, tab.pageAddress == up.page else {
                browser?.announce("Those boxes have changed, so nothing went in")
                return
            }
            let values = still.map { FormValue(fieldID: $0.field.id, value: $0.text, source: .draft) }
            let applied = await page.apply(values, fields: still.map(\.field))
            guard applied.filled > 0 else {
                browser?.announce("Couldn't find those boxes anymore")
                return
            }
            browser?.forms.show(filled: applied, tab: tab.id)
        }
    }
}

@MainActor
final class FormDraftWorkingBar: FormGlassBar {
    init(drafts: FormDrafts) {
        super.init(radius: 20)
        items = [KitLabel("Drafting answers…", font: .systemFont(ofSize: 13)),
                 KitGlassKey(title: "Stop", quiet: true) { [weak drafts] in drafts?.stop() }]
    }
}

@MainActor
final class FormDraftCard: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 400

    private unowned let drafts: FormDrafts
    private let glass = KitGlass.floating(radius: 16)
    private let inside = KitBox(fill: nil)
    private let title = KitLabel("Draft answers", font: SurfaceLook.title)
    private let place = KitLabel("", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private let scroll = NSScrollView()
    private let list = KitFieldRows(fill: nil)
    private let caption = KitLabel("", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private let notNow: KitGlassKey
    private let fill: KitGlassKey
    private var rows: [(id: String, title: KitLabel, field: NSTextField)] = []

    var preview: FormDrafts.Preview? {
        didSet {
            guard let preview, preview != oldValue else { return }
            show(preview, from: oldValue)
        }
    }

    init(drafts: FormDrafts) {
        self.drafts = drafts
        notNow = KitGlassKey(title: "Not Now") { [weak drafts] in drafts?.cancel() }
        fill = KitGlassKey(title: "Fill", kind: .primary) { [weak drafts] in drafts?.confirm() }
        super.init(frame: .zero)
        addSubview(glass)
        glass.contentView = inside
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = list
        for view in [title, place, scroll, caption, notNow, fill] as [NSView] { inside.addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func show(_ up: FormDrafts.Preview, from old: FormDrafts.Preview?) {
        place.text = up.place
        caption.text = up.warned ? "This page has words written for an AI. Read these closely." : "Read these first. Nothing goes in until you say so."
        if rows.map(\.id) == up.answers.map(\.id) {
            for (row, answer) in zip(rows, up.answers) where row.field.stringValue != answer.text && row.field.currentEditor() == nil {
                row.field.stringValue = answer.text
            }
        } else {
            for row in rows {
                row.title.removeFromSuperview()
                row.field.removeFromSuperview()
            }
            rows = up.answers.map { answer in
                let label = KitLabel(answer.field.title, font: .systemFont(ofSize: 12), color: KitColor.muted)
                let field = NSTextField(string: answer.text)
                field.isBordered = false
                field.isBezeled = false
                field.drawsBackground = false
                field.focusRingType = .none
                field.font = .systemFont(ofSize: 12)
                field.textColor = Palette.NS.ink
                field.usesSingleLineMode = false
                field.cell?.wraps = true
                field.cell?.isScrollable = false
                field.lineBreakMode = .byWordWrapping
                field.maximumNumberOfLines = 5
                field.delegate = self
                field.setAccessibilityLabel(answer.field.title)
                field.identifier = NSUserInterfaceItemIdentifier(answer.id)
                list.addSubview(label)
                list.addSubview(field)
                return (answer.id, label, field)
            }
            list.rows = rows.map { ($0.title, $0.field) }
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField, let id = field.identifier?.rawValue else { return }
        drafts.edit(id, field.stringValue)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private var inner: CGFloat { Self.width - 28 }

    private func fieldHeight(_ field: NSTextField) -> CGFloat {
        let font = field.font ?? .systemFont(ofSize: 12)
        let bounds = NSRect(x: 0, y: 0, width: inner + 4, height: .greatestFiniteMagnitude)
        let natural = ceil(field.cell?.cellSize(forBounds: bounds).height ?? 0)
        let line = NSLayoutManager().defaultLineHeight(for: font)
        let one = ceil(Self.probe(font).cellSize(forBounds: bounds).height)
        return max(one, min(natural, ceil(one + line * 4)))
    }

    private static func probe(_ font: NSFont) -> NSTextFieldCell {
        let cell = NSTextFieldCell(textCell: "X")
        cell.font = font
        return cell
    }

    private var listContent: CGFloat {
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            y += row.title.intrinsicContentSize.height + 3 + fieldHeight(row.field)
            if index < rows.count - 1 { y += 9 }
        }
        return y
    }

    private func layoutList() {
        var y: CGFloat = 0
        for row in rows {
            let titleHeight = row.title.intrinsicContentSize.height
            row.title.frame = kitSnap(NSRect(x: 2, y: y, width: inner, height: titleHeight))
            y += titleHeight + 3
            let height = fieldHeight(row.field)
            row.field.frame = NSRect(x: 0, y: y, width: inner + 4, height: height)
            y += height + 9
        }
        list.frame = NSRect(x: 0, y: 0, width: inner + 4, height: max(listContent, scroll.bounds.height))
    }

    private func place(apply: Bool) -> CGFloat {
        var y: CGFloat = 14
        let head = max(title.intrinsicContentSize.height, place.intrinsicContentSize.height)
        if apply {
            let size = title.intrinsicContentSize
            title.frame = kitSnap(NSRect(x: 14, y: y + (head - size.height) / 2, width: size.width, height: size.height))
            let other = place.intrinsicContentSize
            place.frame = kitSnap(NSRect(x: 14 + inner - other.width, y: y + (head - other.height) / 2, width: other.width, height: other.height))
        }
        y += head + 10
        let listHeight = min(240, listContent)
        if apply {
            scroll.frame = NSRect(x: 12, y: y, width: inner + 4, height: listHeight)
            layoutList()
        }
        y += listHeight + 10
        let captionSize = caption.intrinsicContentSize
        if apply { caption.frame = kitSnap(NSRect(x: 14, y: y, width: min(inner, captionSize.width), height: captionSize.height)) }
        y += captionSize.height + 10
        let fillSize = fill.intrinsicContentSize
        let notSize = notNow.intrinsicContentSize
        if apply {
            fill.frame = NSRect(x: 14 + inner - fillSize.width, y: y, width: fillSize.width, height: fillSize.height)
            notNow.frame = NSRect(x: fill.frame.minX - SurfaceLook.keyGap - notSize.width, y: y, width: notSize.width, height: notSize.height)
        }
        return y + max(fillSize.height, notSize.height) + 14
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: place(apply: false)) }

    override func layout() {
        super.layout()
        glass.frame = bounds
        inside.frame = glass.bounds
        _ = place(apply: true)
    }
}

extension FormDrafts {
    static func surface(_ kind: String) -> NSView {
        let drafts = FormDrafts()
        let tab = UUID()
        let view: NSView
        if kind == "working" {
            view = FormDraftWorkingBar(drafts: drafts)
        } else {
            let answers = [("Why do you want this role?", "I have spent six years building tools for small teams and would like to do it at a larger scale."),
                           ("Anything else?", "Available from March.")]
                .enumerated().map { FormDraftAnswer(field: FormField(index: $0.offset, type: "textarea", label: $0.element.0), text: $0.element.1) }
            let card = FormDraftCard(drafts: drafts)
            card.preview = Preview(tab: tab, page: nil, place: "On this Mac", warned: kind == "warned", answers: answers)
            view = card
        }
        let size = view.intrinsicContentSize
        let stage = KitBox(fill: nil)
        stage.frame = NSRect(x: 0, y: 0, width: size.width + 16, height: size.height + 16)
        view.frame = NSRect(x: 8, y: 8, width: size.width, height: size.height)
        stage.addSubview(view)
        return KitFixedView(stage, keep: drafts)
    }
}
