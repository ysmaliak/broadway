import AppKit

struct QuickActionDraft: Identifiable, Equatable {
    var id: String { editing ?? "new" }
    var editing: String?
    var name = ""
    var alias = ""
    var address = ""

    init() {}

    init(_ action: QuickAction) {
        editing = action.id
        name = action.name
        alias = action.short
        address = action.address
    }
}

@MainActor
enum QuickActionsLogic {
    static let heading = "Quick Actions"

    static let footer = "Type a short name in the address field and press Return. With the field empty, they're listed in this order."

    static func empty(_ store: QuickActions) -> String {
        store.builtInsChanged ? "No Quick Actions. Add your own, or bring back doc and meet." : "No Quick Actions. Add your own."
    }

    static func delete(_ action: QuickAction, store: QuickActions, history: History) {
        kitSettle { store.delete(action.id, history: history) }
    }

    static func move(_ id: String, by step: Int, store: QuickActions, history: History) {
        kitSettle { _ = store.move(id, by: step, history: history) }
    }

    static func addRow(browser: Browser, store: QuickActions) -> QuickWordsRow {
        let button = KitBroadwayButton("Add Action…", kind: .primary, label: "Add Action")
        button.action = { [weak button] in
            QuickActionSheetView.present(store: store, history: browser.history, draft: QuickActionDraft(), on: button?.window)
        }
        return QuickWordsRow("Your own", "A name, the short name you type, and the address it opens", button: button)
    }

    static func restoreRow(store: QuickActions) -> QuickWordsRow {
        let asks = store.builtInsEdited
        let button = KitBroadwayButton(asks ? "Restore…" : "Restore", label: "Restore doc and meet")
        button.action = { [weak button] in
            guard asks else { return kitSettle { store.restoreBuiltIns() } }
            SettingsQuestion.builtInActions.ask(over: button?.window) { kitSettle { store.restoreBuiltIns() } }
        }
        return QuickWordsRow("doc and meet", "Bring back New document and New meeting as they were", button: button)
    }

    static func edit(_ draft: QuickActionDraft, store: QuickActions, history: History, from view: NSView) {
        QuickActionSheetView.present(store: store, history: history, draft: draft, on: view.window)
    }
}

final class QuickActionIconView: NSView {
    let size: CGFloat
    private var shown: NSView?
    private var key = ""

    init(size: CGFloat = 22) {
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

    func show(_ action: QuickAction, site: String?) {
        let icon = site.flatMap { Favicons.shared.cached($0) }
        let wanted = icon.map { "icon:\(ObjectIdentifier($0).hashValue)" } ?? "symbol:\(action.id)"
        guard wanted != key else { return }
        key = wanted
        shown?.removeFromSuperview()
        let made: NSView
        if let icon {
            made = MarkView(icon: icon, letter: "", size: size)
        } else {
            let glyph = KitSymbol(Self.symbol(for: action.id), style: .init(size: (size * 0.68).rounded(), weight: IconLook.weight), tint: .secondaryLabelColor)
            glyph.imageAlignment = .alignCenter
            made = glyph
        }
        made.frame = bounds
        made.autoresizingMask = [.width, .height]
        addSubview(made)
        shown = made
    }

    static func symbol(for id: String) -> String {
        switch id {
        case "doc": return "doc.text"
        case "meet", "zoom": return "video"
        case "sheet": return "tablecells"
        case "slides": return "rectangle.on.rectangle"
        case "notion": return "doc.richtext"
        case "figma": return "paintbrush.pointed"
        case "linear": return "checklist"
        case "repo": return "shippingbox"
        case "gist": return "chevron.left.forwardslash.chevron.right"
        case "cal": return "calendar"
        default: return "bolt"
        }
    }
}

final class QuickActionRowView: NSView, KitFits {
    let browser: Browser
    let store: QuickActions
    private(set) var action: QuickAction
    private var first: Bool
    private var last: Bool

    private let icon = QuickActionIconView()
    private let name = KitParagraph("", font: .systemFont(ofSize: 13), color: .labelColor)
    private let detail = KitLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let words = KitFlippedView()
    private var key: KeyBoxView?
    private let edit: KitBroadwayButton
    private let more = KitButton(.plain(press: 1), label: "")
    private let moreGlyph = KitSymbol("ellipsis.circle", style: .init(size: 13), tint: .secondaryLabelColor)

    init(browser: Browser, store: QuickActions, action: QuickAction, first: Bool, last: Bool) {
        self.browser = browser
        self.store = store
        self.action = action
        self.first = first
        self.last = last
        edit = KitBroadwayButton("Edit…")
        super.init(frame: .zero)
        detail.overflow = .middle
        words.addSubview(name)
        words.addSubview(detail)
        words.setAccessibilityElement(true)
        words.setAccessibilityRole(.staticText)
        name.setAccessibilityElement(false)
        detail.setAccessibilityElement(false)
        more.content = moreGlyph
        for view in [icon, words, edit, more] as [NSView] { addSubview(view) }
        edit.action = { [weak self] in self?.openEdit() }
        more.action = { [weak self] in self?.popMore() }
        update(action: action, first: first, last: last)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(action: QuickAction, first: Bool, last: Bool) {
        self.action = action
        self.first = first
        self.last = last
        icon.show(action, site: store.site(of: action))
        name.text = action.name
        detail.text = action.short.isEmpty ? action.target : "\(action.short) · \(action.target)"
        words.setAccessibilityLabel("\(name.text), \(detail.text)")
        if store.isCustom(action.id) {
            if key == nil {
                let made = KeyBoxView(browser: browser, store: .shared, id: "quick:" + action.id, spoken: "Key for \(action.name)")
                addSubview(made)
                key = made
            }
            key?.spoken = "Key for \(action.name)"
        } else {
            key?.removeFromSuperview()
            key = nil
        }
        edit.setAccessibilityLabel("Edit \(action.name)")
        more.setAccessibilityLabel("More for \(action.name)")
        more.toolTip = "More for \(action.name)"
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private var controls: [NSView] { [key, edit, more].compactMap { $0 } }

    private func size(of view: NSView) -> NSSize {
        view === more ? NSSize(width: 15, height: 15) : view.intrinsicContentSize
    }

    private func textRoom(_ width: CGFloat) -> CGFloat {
        let used = controls.map { size(of: $0).width }.reduce(0, +) + CGFloat(controls.count - 1) * 10
        return max(0, width - 22 - 10 - 10 - 12 - 10 - used)
    }

    private func textHeight(_ width: CGFloat) -> CGFloat {
        name.height(for: textRoom(width)) + 2 + detail.intrinsicContentSize.height
    }

    func kitHeight(width: CGFloat) -> CGFloat {
        max(textHeight(width), controls.map { size(of: $0).height }.max() ?? 0, 22) + 4
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: kitHeight(width: bounds.width > 0 ? bounds.width : 560))
    }

    override func layout() {
        super.layout()
        let inner = NSRect(x: 0, y: 2, width: bounds.width, height: bounds.height - 4)
        icon.frame = kitSnap(NSRect(x: 0, y: inner.midY - 11, width: 22, height: 22))
        let room = textRoom(bounds.width)
        let nameHeight = name.height(for: room)
        let detailHeight = detail.intrinsicContentSize.height
        let block = nameHeight + 2 + detailHeight
        words.frame = kitSnap(NSRect(x: 32, y: inner.midY - block / 2, width: room, height: block))
        name.frame = NSRect(x: 0, y: 0, width: min(room, name.naturalWidth), height: nameHeight)
        detail.frame = NSRect(x: 0, y: nameHeight + 2, width: min(room, detail.intrinsicContentSize.width), height: detailHeight)
        var right = bounds.width
        for view in controls.reversed() {
            let size = size(of: view)
            right -= size.width
            view.frame = kitSnap(NSRect(x: right, y: inner.midY - size.height / 2, width: size.width, height: size.height))
            right -= 10
        }
    }

    private func openEdit() {
        QuickActionsLogic.edit(QuickActionDraft(action), store: store, history: browser.history, from: self)
    }

    private func items() -> [KitMenuItem] {
        let id = action.id
        let history = browser.history
        let store = store
        let action = action
        return [
            .action("Edit…") { [weak self] in self?.openEdit() },
            .separator,
            .action("Move Up", enabled: !first) { QuickActionsLogic.move(id, by: -1, store: store, history: history) },
            .action("Move Down", enabled: !last) { QuickActionsLogic.move(id, by: 1, store: store, history: history) },
            .separator,
            .action("Delete…", enabled: store.canDelete(id)) { [weak self] in
                SettingsQuestion.quickAction(action.name).ask(over: self?.window) {
                    QuickActionsLogic.delete(action, store: store, history: history)
                }
            },
        ]
    }

    private func popMore() {
        KitMenu.pop(items(), below: more)
    }

    override func menu(for event: NSEvent) -> NSMenu? { KitMenu.make(items()) }

    private var dragStart: NSPoint?
    private var dragging = false

    private var holder: SettingsFormRow? { superview as? SettingsFormRow }

    private var siblings: [SettingsFormRow] {
        guard let card = holder?.superview else { return [] }
        return card.subviews.compactMap { $0 as? SettingsFormRow }.filter { $0.content is QuickActionRowView }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let holder else { return }
        holder.wantsLayer = true
        guard let layer = holder.layer else { return }
        let dy = event.locationInWindow.y - start.y
        if !dragging {
            guard abs(dy) > 4 else { return }
            dragging = true
            layer.zPosition = 1
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(CGAffineTransform(translationX: 0, y: holder.superview?.isFlipped == true ? -dy : dy))
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragging = false }
        guard dragging, let start = dragStart, let holder, let card = holder.superview else { return }
        let rows = siblings.sorted { card.isFlipped ? $0.frame.minY < $1.frame.minY : $0.frame.minY > $1.frame.minY }
        guard let from = rows.firstIndex(of: holder) else { return }
        let dy = event.locationInWindow.y - start.y
        let moved = card.isFlipped ? -dy : dy
        let centre = holder.frame.midY + moved
        var place = rows.filter { $0 !== holder && (card.isFlipped ? $0.frame.midY < centre : $0.frame.midY > centre) }.count
        if place >= from { place += 1 }
        holder.layer?.zPosition = 0
        let shift = holder.layer?.affineTransform().ty ?? 0
        holder.layer?.setAffineTransform(.identity)
        if let back = Motion.kitSettle.animation("transform.translation.y", from: shift, to: 0) as? CAPropertyAnimation {
            back.isAdditive = true
            holder.layer?.add(back, forKey: "quick.drop")
        }
        guard place != from && place != from + 1 else { return }
        store.move(from: IndexSet(integer: from), to: place, history: browser.history)
    }
}

final class QuickWordsRow: NSView, KitFits {
    private let line: KitFormLine

    init(_ title: String, _ detail: String, button: KitBroadwayButton) {
        line = KitFormLine(title, detail: detail, callout: true, controls: [button])
        line.labelGap = 24
        super.init(frame: .zero)
        kitPin(line)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { line.intrinsicContentSize }

    func kitHeight(width: CGFloat) -> CGFloat { line.kitHeight(width: width) }
}

final class KitNote: NSView, KitFits {
    let words: KitParagraph
    let padding: CGFloat

    init(_ text: String, padding: CGFloat = 0) {
        words = KitParagraph(text, font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
        self.padding = padding
        super.init(frame: .zero)
        addSubview(words)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func kitHeight(width: CGFloat) -> CGFloat { words.height(for: width) + padding * 2 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: kitHeight(width: bounds.width > 0 ? bounds.width : 560))
    }

    override func layout() {
        super.layout()
        words.frame = kitSnap(NSRect(x: 0, y: padding, width: min(bounds.width, words.naturalWidth), height: words.height(for: bounds.width)))
    }
}

final class QuickActionSheetView: KitFlippedView {
    let store: QuickActions
    let history: History
    private(set) var draft: QuickActionDraft
    var close: (() -> Void)?

    static let width: CGFloat = 440

    private let title = KitParagraph("", font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor)
    private let subtitle = KitParagraph("Type the short name in the address field and press Return to open the address",
                                        font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let said = KitParagraph(" ", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let card = KitFormCard()
    private let cancel = KitBroadwayButton("Cancel")
    private let save: KitBroadwayButton
    private let ground = KitBox(fill: KitForm.ground)
    let nameField: KitField
    let aliasField: KitField
    let addressField: KitField

    init(store: QuickActions, history: History, draft: QuickActionDraft) {
        self.store = store
        self.history = history
        self.draft = draft
        nameField = KitField(placeholder: "Optional", text: draft.name, label: "Name")
        aliasField = KitField(placeholder: "cv", text: draft.alias, label: "Short name")
        addressField = KitField(placeholder: "example.com/new", text: draft.address, label: "Address")
        save = KitBroadwayButton(draft.editing == nil ? "Add" : "Save", kind: .primary)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 300))
        title.text = draft.editing == nil ? "New Quick Action" : "Edit Quick Action"
        title.setAccessibilityRole(.staticText)
        card.rows = [row("Name", nameField), row("Short name", aliasField), row("Address", addressField)]
        for view in [ground, title, subtitle, card, said, cancel, save] as [NSView] { addSubview(view) }
        nameField.onChange = { [weak self] in self?.draft.name = $0; self?.refresh() }
        aliasField.onChange = { [weak self] in self?.draft.alias = $0; self?.refresh() }
        addressField.onChange = { [weak self] in self?.draft.address = $0; self?.refresh() }
        for field in [nameField, aliasField, addressField] { field.onSubmit = { [weak self] in self?.commit() } }
        cancel.action = { [weak self] in self?.dismiss() }
        save.action = { [weak self] in self?.commit() }
        refresh()
        frame.size.height = fittedHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func row(_ label: String, _ field: KitField) -> NSView {
        let row = KitFlippedView()
        let words = KitLabel(label, font: .systemFont(ofSize: 13), color: .labelColor)
        row.addSubview(words)
        row.addSubview(field)
        words.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: KitField.height(small: false)),
            words.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            words.widthAnchor.constraint(equalToConstant: 92),
            words.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: words.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            field.topAnchor.constraint(equalTo: row.topAnchor),
            field.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    var problem: String? { store.problem(editing: draft.editing, alias: draft.alias, address: draft.address) }

    var shownProblem: String? {
        guard draft.editing != nil || !draft.alias.isEmpty || !draft.address.isEmpty else { return nil }
        return problem
    }

    private func refresh() {
        said.text = shownProblem ?? " "
        save.isEnabled = problem == nil
    }

    private let top: CGFloat = 20
    private let side: CGFloat = 20

    private func fittedHeight() -> CGFloat {
        let inner = Self.width - side * 2
        let header = title.height(for: inner - 20) + 3 + subtitle.height(for: inner - 60)
        return top + header + 16 + card.kitHeight(width: inner) + 9 + said.height(for: inner - 20) + 12 + 28 + 18
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let inner = bounds.width - side * 2
        var y = top
        let titleHeight = title.height(for: inner - 20)
        title.frame = kitSnap(NSRect(x: side + 10, y: y, width: min(inner - 20, title.naturalWidth), height: titleHeight))
        y += titleHeight + 3
        let subHeight = subtitle.height(for: inner - 60)
        subtitle.frame = kitSnap(NSRect(x: side + 10, y: y, width: inner - 60, height: subHeight))
        y += subHeight + 16
        let cardHeight = card.kitHeight(width: inner)
        card.frame = NSRect(x: side, y: y, width: inner, height: cardHeight)
        y += cardHeight + 9
        said.frame = kitSnap(NSRect(x: side + 10, y: y, width: inner - 20, height: said.height(for: inner - 20)))
        let saveSize = save.intrinsicContentSize
        let cancelSize = cancel.intrinsicContentSize
        let buttons = bounds.height - 18 - 28
        save.frame = NSRect(x: bounds.width - side - saveSize.width, y: buttons, width: saveSize.width, height: 28)
        cancel.frame = NSRect(x: save.frame.minX - 8 - cancelSize.width, y: buttons, width: cancelSize.width, height: 28)
    }

    func commit() {
        guard problem == nil else { return }
        var done = false
        let draft = draft
        let store = store
        let history = history
        kitSettle {
            if let id = draft.editing {
                done = store.edit(id, name: draft.name, alias: draft.alias, address: draft.address, history: history)
            } else {
                done = store.add(name: draft.name, alias: draft.alias, address: draft.address) != nil
            }
        }
        if done { dismiss() }
    }

    func dismiss() { close?() }

    func focusFirst() {
        window?.makeFirstResponder(nameField.field)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.initialFirstResponder = nameField.field
        nameField.field.nextKeyView = aliasField.field
        aliasField.field.nextKeyView = addressField.field
        addressField.field.nextKeyView = nameField.field
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.focusFirst() } }
    }

    static func present(store: QuickActions, history: History, draft: QuickActionDraft, on parent: NSWindow?) {
        let view = QuickActionSheetView(store: store, history: history, draft: draft)
        let sheet = QuickActionSheetWindow(contentRect: NSRect(origin: .zero, size: view.frame.size),
                                           styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        sheet.titleVisibility = .hidden
        sheet.titlebarAppearsTransparent = true
        sheet.isReleasedWhenClosed = false
        sheet.contentView = view
        sheet.form = view
        view.close = { [weak sheet] in
            guard let sheet else { return }
            if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
        }
        if let parent {
            parent.beginSheet(sheet)
        } else {
            sheet.center()
            sheet.makeKeyAndOrderFront(nil)
        }
    }
}

final class QuickActionSheetWindow: NSWindow {
    weak var form: QuickActionSheetView?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { form?.dismiss() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            form?.commit()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
enum QuickActionsSurface {
    static func fixture(_ request: [String: Any]) -> QuickActions {
        let file = Store.file("bench-quickactions.json")
        try? FileManager.default.removeItem(at: file)
        let store = QuickActions(file: file)
        store.add(name: "Résumé", alias: "cv", address: "https://example.com/cv")
        if request["changed"] as? Bool == true { store.delete("meet", history: Browsers.acting.history) }
        return store
    }

    static func draft(_ request: [String: Any], store: QuickActions) -> QuickActionDraft {
        var draft = QuickActionDraft()
        if request["taken"] as? Bool == true {
            draft.name = "Docs"
            draft.alias = "cv"
            draft.address = "https://docs.example.com/new"
        }
        return draft
    }
}
