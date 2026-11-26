import AppKit
import Combine

@MainActor
class SettingsForm: SettingsFormStack {
    private var reads: KitReads?
    private var built: AnyHashable?
    private var kept: [String: NSView] = [:]
    private var using: [String: NSView] = [:]

    init(follows: Bool = false) {
        super.init(frame: .zero)
        if follows {
            reads = KitReads { [weak self] in self?.reload() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var shape: AnyHashable { 0 }

    func build() {}

    func update() {}

    private func tracked(_ work: () -> Void) {
        if let reads { reads.track(work) } else { work() }
    }

    func load() {
        tracked {
            built = shape
            using = [:]
            close()
            clear()
            build()
            close()
            kept = using
            update()
        }
    }

    func reload() {
        guard built != nil else { return load() }
        guard shape != built else { return tracked { _ = shape; update() } }
        let typing = SettingsFocus(in: self)
        let before = window == nil ? [:] : kept.compactMapValues { $0.window == nil ? nil : $0.convert($0.bounds, to: self) }
        load()
        guard window != nil else { return }
        layoutSubtreeIfNeeded()
        typing?.restore()
        animate(from: before)
    }

    func existing(_ key: String) -> SettingsFormRow? { kept[key] as? SettingsFormRow }

    func keep<View: NSView>(_ key: String, _ make: () -> View) -> View {
        let view = kept[key] as? View ?? make()
        using[key] = view
        return view
    }

    @discardableResult
    func row(_ key: String, lead: CGFloat = SettingsMetrics.inset, _ make: () -> NSView) -> SettingsFormRow {
        let row = keep(key) { SettingsFormRow(make(), lead: lead) }
        row.separatorLead = lead
        row.name = key
        fitted(row)
        return row
    }

    private func animate(from before: [String: NSRect]) {
        guard !before.isEmpty else { return }
        for (key, view) in using {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            let now = view.convert(view.bounds, to: self)
            if let old = before[key] {
                guard old.minY != now.minY,
                      let move = Motion.kitSettle.animation("transform.translation.y", from: old.minY - now.minY, to: 0) as? CAPropertyAnimation
                else { continue }
                move.isAdditive = true
                layer.add(move, forKey: "settings.move")
            } else if let fade = Motion.kitSettle.animation("opacity", from: 0, to: 1) {
                layer.add(fade, forKey: "settings.arrive")
            }
        }
    }
}

@MainActor
struct SettingsFocus {
    let field: NSTextField
    let range: NSRange

    init?(in view: NSView) {
        guard let editor = view.window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField, field.isDescendant(of: view) else { return nil }
        self.field = field
        range = editor.selectedRange()
    }

    func restore() {
        guard let window = field.window, window.firstResponder !== field.currentEditor() else { return }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = range
    }
}

@MainActor
final class ExtensionsForm: SettingsForm {
    let browser: Browser
    let extensions: Extensions

    init(browser: Browser, extensions: Extensions = .shared) {
        self.browser = browser
        self.extensions = extensions
        super.init(follows: true)
        load()
    }

    override var shape: AnyHashable { [extensions.installed.map(\.id), ExtensionCapture.allowedIDs] }

    override func build() {
        let browser = browser
        let extensions = extensions
        section {
            row("store") { ExtensionsLogic.store(browser) }
            row("link") { ExtensionLinkRow(extensions: extensions) }
        }
        section {
            row("bring") { ExtensionsLogic.bringOver(browser) }
        }
        if extensions.installed.isEmpty {
            section {
                row("none") { KitNote("No extensions yet") }
            }
        } else {
            section(footer: ExtensionsLogic.privateNote, footerSize: 11) {
                for item in extensions.installed {
                    row("extension-" + item.id) { ExtensionRowView(item: item, extensions: extensions) }
                }
            }
        }
        let ids = ExtensionCapture.allowedIDs
        if !ids.isEmpty {
            section {
                for id in ids {
                    row("recorder-" + id) { ExtensionsLogic.recorder(id) }
                }
            }
        }
        section {
            row("unpacked") { ExtensionsLogic.unpacked(extensions) }
        }
    }

    override func update() {
        for item in extensions.installed {
            (existing("extension-" + item.id)?.content as? ExtensionRowView)?.update(item)
        }
    }
}

@MainActor
final class ShortcutsForm: SettingsForm {
    let browser: Browser
    let store: ShortcutStore
    let prefs: Preferences
    let hunt = NSSearchField()

    init(browser: Browser, store: ShortcutStore = .shared, prefs: Preferences) {
        self.browser = browser
        self.store = store
        self.prefs = prefs
        super.init(follows: true)
        hunt.placeholderString = "Search commands or keys"
        hunt.sendsSearchStringImmediately = true
        hunt.setAccessibilityLabel("Search commands or keys")
        hunt.target = self
        hunt.action = #selector(searched)
        load()
    }

    private var words: String { hunt.stringValue }

    @objc private func searched() { reload() }

    private func sections() -> [(Command.Section, [Command])] {
        Command.Section.allCases.compactMap { section in
            let commands = ShortcutsList.commands(in: section, hunt: words, browser: browser, store: store, prefs: prefs)
            return commands.isEmpty ? nil : (section, commands)
        }
    }

    override var shape: AnyHashable {
        [AnyHashable(sections().map { [$0.0.rawValue] + $0.1.map(\.id) }),
         AnyHashable(ShortcutsList.extensionCommands(hunt: words, store: store).map(\.id)),
         AnyHashable(ShortcutsList.showsReset(hunt: words, store: store))]
    }

    override func build() {
        let browser = browser
        let store = store
        let prefs = prefs
        section {
            row("hunt") { SettingsHuntRow(hunt) }
            if ShortcutsList.commands(hunt: words, browser: browser, store: store, prefs: prefs).isEmpty {
                row("none") { KitNote("No command by that name or key") }
            }
        }
        for (section, commands) in sections() {
            self.section(section.rawValue) {
                for command in commands {
                    row("command-" + command.id) { ShortcutLineView(browser: browser, store: store, id: command.id, title: command.title) }
                }
            }
        }
        let extensions = ShortcutsList.extensionCommands(hunt: words, store: store)
        if !extensions.isEmpty {
            section("Extensions") {
                for item in extensions {
                    row("extension-" + item.id) {
                        ShortcutLineView(browser: browser, store: store, id: item.id, title: item.command.title, detail: item.extensionName)
                    }
                }
            }
        }
        if ShortcutsList.showsReset(hunt: words, store: store) {
            section {
                row("reset") { ShortcutsResetRow(store: store) }
            }
        }
    }
}

final class SettingsHuntRow: NSView, KitFits {
    let field: NSSearchField

    init(_ field: NSSearchField) {
        self.field = field
        super.init(frame: .zero)
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func kitHeight(width: CGFloat) -> CGFloat { 24 }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: kitHeight(width: 0)) }

    override func layout() {
        super.layout()
        field.frame = bounds.insetBy(dx: -1, dy: -1)
    }
}

@MainActor
final class QuickActionsForm: SettingsForm {
    let browser: Browser
    let store: QuickActions

    init(browser: Browser, store: QuickActions = .shared) {
        self.browser = browser
        self.store = store
        super.init(follows: true)
        load()
    }

    private var actions: [QuickAction] { store.shown(history: browser.history) }

    override var shape: AnyHashable {
        [AnyHashable(actions.map(\.id)), AnyHashable(store.builtInsChanged),
         AnyHashable(store.builtInsEdited)]
    }

    override func build() {
        let browser = browser
        let store = store
        let actions = actions
        section(QuickActionsLogic.heading, footer: QuickActionsLogic.footer) {
            if actions.isEmpty {
                row("empty") { KitNote(QuickActionsLogic.empty(store), padding: 6) }
            }
            for action in actions {
                row("action-" + action.id) { QuickActionRowView(browser: browser, store: store, action: action, first: false, last: false) }
            }
        }
        section {
            row("add") { QuickActionsLogic.addRow(browser: browser, store: store) }
            if store.builtInsChanged {
                row(store.builtInsEdited ? "restore.asks" : "restore") { QuickActionsLogic.restoreRow(store: store) }
            }
        }
    }

    override func update() {
        let actions = actions
        for (place, action) in actions.enumerated() {
            (existing("action-" + action.id)?.content as? QuickActionRowView)?.update(action: action, first: place == 0, last: place == actions.count - 1)
        }
        (existing("empty")?.content as? KitNote)?.words.text = QuickActionsLogic.empty(store)
    }
}

@MainActor
enum SettingsForms {
    static func extensions(_ browser: Browser) -> NSView { ExtensionsForm(browser: browser) }

    static func shortcuts(_ browser: Browser) -> NSView { ShortcutsForm(browser: browser, prefs: browser.prefs) }

    static func quickActions(_ browser: Browser) -> NSView { QuickActionsForm(browser: browser) }
}
