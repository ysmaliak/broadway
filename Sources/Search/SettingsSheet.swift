import AppKit

@MainActor
final class SettingsSheet: NSObject, NSTextViewDelegate {
    private static var open: [SettingsSheet] = []

    let panel: NSPanel
    private let stack = NSStackView()
    private var checks: [() -> Void] = []
    private var saving: (() -> Bool)?
    private var ready: () -> Bool = { true }
    private var watchers: [SettingsFieldWatcher] = []

    init(title: String, width: CGFloat) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 200), styleMask: [.titled, .docModalWindow],
                        backing: .buffered, defer: true)
        super.init()
        panel.title = title
        let ground = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        ground.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
            stack.topAnchor.constraint(equalTo: ground.topAnchor),
            stack.bottomAnchor.constraint(equalTo: ground.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        panel.contentView = ground
        heading(title)
    }

    private func full(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    }

    func heading(_ text: String) {
        stack.addArrangedSubview(SettingsText(text, font: .systemFont(ofSize: 15, weight: .semibold)))
    }

    @discardableResult
    func note(_ text: String) -> SettingsText {
        let made = SettingsText(text, font: .systemFont(ofSize: 12), color: .secondaryLabelColor, wraps: true)
        full(made)
        return made
    }

    func live(_ text: @escaping () -> String?) {
        let made = note("")
        checks.append { [weak made] in
            let said = text()
            made?.stringValue = said ?? ""
            made?.isHidden = said == nil
        }
    }

    @discardableResult
    func field(_ prompt: String, text: String, secure: Bool = false, set: @escaping (String) -> Void) -> NSTextField {
        let made: NSTextField = secure ? NSSecureTextField(string: text) : NSTextField(string: text)
        made.placeholderString = prompt
        made.bezelStyle = .roundedBezel
        made.usesSingleLineMode = true
        made.font = .systemFont(ofSize: 13)
        made.setAccessibilityLabel(prompt)
        let watcher = SettingsFieldWatcher(set: { [weak self] in
            set($0)
            self?.check()
        }, submit: nil)
        watchers.append(watcher)
        made.delegate = watcher
        full(made)
        return made
    }

    func labeled(_ title: String, prompt: String, text: String, set: @escaping (String) -> Void) {
        stack.addArrangedSubview(SettingsText(title, font: .systemFont(ofSize: 13)))
        field(prompt, text: text, set: set)
        stack.setCustomSpacing(4, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
    }

    private var edits: [ObjectIdentifier: (String) -> Void] = [:]

    @discardableResult
    func editor(_ text: String, height: CGFloat, mono: Bool = false, label: String, set: @escaping (String) -> Void) -> NSTextView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let view = scroll.documentView as? NSTextView ?? NSTextView()
        view.string = text
        view.font = mono ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 13)
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.delegate = self
        view.setAccessibilityLabel(label)
        edits[ObjectIdentifier(view)] = { [weak self] in
            set($0)
            self?.check()
        }
        full(scroll)
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        edits[ObjectIdentifier(view)]?(view.string)
    }

    @discardableResult
    func popUp(_ title: String, titles: [String], picked: Int, set: @escaping (Int) -> Void) -> NSPopUpButton {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let made = NSPopUpButton(frame: .zero, pullsDown: false)
        made.addItems(withTitles: titles)
        made.selectItem(at: picked)
        made.setAccessibilityLabel(title)
        made.kitOnChange { [weak self] control in
            set((control as? NSPopUpButton)?.indexOfSelectedItem ?? 0)
            self?.check()
        }
        row.addArrangedSubview(SettingsText(title, font: .systemFont(ofSize: 13)))
        row.addArrangedSubview(made)
        stack.addArrangedSubview(row)
        return made
    }

    func checks(_ title: String?, _ boxes: [(String, Bool, (Bool) -> Void)]) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        if let title { row.addArrangedSubview(SettingsText(title, font: .systemFont(ofSize: 13))) }
        for (name, on, set) in boxes {
            let box = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            box.state = on ? .on : .off
            box.kitOnChange { [weak self] control in
                set((control as? NSButton)?.state == .on)
                self?.check()
            }
            row.addArrangedSubview(box)
        }
        stack.addArrangedSubview(row)
    }

    func finish(save title: String = "Save", ready: @escaping () -> Bool = { true }, save run: @escaping () -> Bool) {
        self.ready = ready
        saving = run
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: title, target: self, action: #selector(commit(_:)))
        save.keyEquivalent = "\r"
        save.bezelColor = .controlAccentColor
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(cancel)
        row.addArrangedSubview(save)
        full(row)
        self.saveButton = save
        check()
    }

    private weak var saveButton: NSButton?

    func check() {
        checks.forEach { $0() }
        saveButton?.isEnabled = ready()
    }

    @objc private func cancel(_ sender: Any?) { end() }

    @objc private func commit(_ sender: Any?) {
        guard ready(), saving?() ?? true else {
            check()
            return
        }
        end()
    }

    private func end() {
        if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.close() }
        Self.open.removeAll { $0 === self }
    }

    func show(over window: NSWindow?) {
        Self.open.append(self)
        panel.layoutIfNeeded()
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        guard let window else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        window.beginSheet(panel)
    }
}

@MainActor
enum SettingsEditors {
    static func snippet(_ start: Snippet, store: SnippetStore, over window: NSWindow?) {
        var draft = start
        var trouble: String?
        let sheet = SettingsSheet(title: "Snippet", width: 520)
        sheet.labeled("Title", prompt: "Mailing address", text: draft.title) { draft.title = $0 }
        sheet.labeled("Keyword", prompt: "address", text: draft.keyword) { draft.keyword = $0 }
        sheet.note("Type a semicolon and the keyword in the address field. Text stays on this Mac.")
        sheet.editor(draft.text, height: 180, label: "Snippet text") { draft.text = $0 }
        sheet.note("Use {date}, {time}, {clipboard} and {cursor}")
        sheet.live { trouble ?? store.problem(draft) }
        sheet.finish(ready: { store.problem(draft) == nil }) {
            trouble = store.save(draft)
            return trouble == nil
        }
        sheet.show(over: window)
    }
}
