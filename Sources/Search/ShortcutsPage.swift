import AppKit
import Combine
import WebKit

@MainActor
enum ShortcutsList {
    static func shown(_ command: Command, hunt: String, browser: Browser, store: ShortcutStore, prefs: Preferences) -> Bool {
        if command.section == .spaces, !prefs.usesSpaces { return false }
        if Command.dusk.contains(command.id), !browser.prefs.darkensPages { return false }
        if Command.meeting.contains(command.id), !browser.prefs.nextMeeting { return false }
        if Command.folders.contains(command.id), !browser.prefs.usesTabGroups { return false }
        let words = hunt.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return true }
        let key = store.key(for: command.id)?.display ?? ""
        return command.title.localizedCaseInsensitiveContains(words)
            || key.localizedCaseInsensitiveContains(words.replacingOccurrences(of: " ", with: ""))
    }

    static func commands(hunt: String, browser: Browser, store: ShortcutStore, prefs: Preferences) -> [Command] {
        Command.all.filter { shown($0, hunt: hunt, browser: browser, store: store, prefs: prefs) }
    }

    static func commands(in section: Command.Section, hunt: String, browser: Browser, store: ShortcutStore,
                         prefs: Preferences) -> [Command] {
        commands(hunt: hunt, browser: browser, store: store, prefs: prefs).filter { $0.section == section }
    }

    static func extensionCommands(hunt: String, store: ShortcutStore) -> [ShortcutStore.ExtensionCommand] {
        let words = hunt.trimmingCharacters(in: .whitespaces)
        return store.extensionCommands().filter { item in
            words.isEmpty || item.command.title.localizedCaseInsensitiveContains(words)
                || item.extensionName.localizedCaseInsensitiveContains(words)
                || (store.key(for: item.id)?.display ?? "").localizedCaseInsensitiveContains(words.replacingOccurrences(of: " ", with: ""))
        }
    }

    static func showsReset(hunt: String, store: ShortcutStore, prefs: Preferences) -> Bool {
        (store.anyChanged || prefs.peekClick != .shift) && hunt.isEmpty
    }

    static func resetAll(store: ShortcutStore, prefs: Preferences) {
        store.resetAll()
        prefs.peekClick = .shift
    }

    static func resetToDefault(store: ShortcutStore, id: String) -> String? {
        guard let other = store.reset(id), let key = store.key(for: id) else { return nil }
        return "\(key.display) moved from \(other.title)"
    }

    static func menu(store: ShortcutStore, id: String, announce: @escaping (String) -> Void = { _ in }) -> NSMenu {
        KitMenu.make([
            .action("Clear Shortcut", enabled: store.key(for: id) != nil) { store.clear(id) },
            .action("Reset to Default", enabled: store.isChanged(id)) {
                if let moved = resetToDefault(store: store, id: id) { announce(moved) }
            },
        ])
    }
}

final class ShortcutLineView: NSView, KitFits {
    let store: ShortcutStore
    let id: String
    private let line: KitFormLine
    private weak var browser: Browser?

    init(browser: Browser, store: ShortcutStore, id: String, title: String, detail: String? = nil) {
        self.store = store
        self.id = id
        self.browser = browser
        line = KitFormLine(title, detail: detail, controls: [KeyBoxView(browser: browser, store: store, id: id)])
        line.firstLine = 1
        super.init(frame: .zero)
        kitPin(line)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { line.intrinsicContentSize }

    func kitHeight(width: CGFloat) -> CGFloat { line.kitHeight(width: width) }

    override func menu(for event: NSEvent) -> NSMenu? {
        ShortcutsList.menu(store: store, id: id) { [weak self] in self?.browser?.announce($0) }
    }
}

final class ShortcutsResetRow: NSView, KitFits {
    private let button: KitBroadwayButton

    init(store: ShortcutStore, prefs: Preferences) {
        button = KitBroadwayButton("Reset All to Defaults…")
        super.init(frame: .zero)
        button.action = { [weak self] in
            SettingsQuestion.shortcuts.ask(over: self?.window) { ShortcutsList.resetAll(store: store, prefs: prefs) }
        }
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: button.intrinsicContentSize.height) }

    func kitHeight(width: CGFloat) -> CGFloat { button.intrinsicContentSize.height }

    override func layout() {
        super.layout()
        let size = button.intrinsicContentSize
        button.frame = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
}

final class KeyBoxView: KitBroadwayButton {
    let browser: Browser
    let store: ShortcutStore
    let id: String
    var spoken: String? { didSet { refresh() } }

    private let words = KitLabel("", font: .systemFont(ofSize: 12))
    private let holder: KitFlippedView
    private var listening = false { didSet { refresh() } }
    private var monitor: Any?
    private var resigned: NSObjectProtocol?
    private static weak var current: KeyBoxView?
    private var note: String? { didSet { refresh() } }
    private var taking: KeyCombo? { didSet { refresh() } }
    private var watch: AnyCancellable?

    init(browser: Browser, store: ShortcutStore, id: String, spoken: String? = nil) {
        self.browser = browser
        self.store = store
        self.id = id
        self.spoken = spoken
        let holder = KitFlippedView()
        self.holder = holder
        super.init(content: holder, kind: .secondary, small: true, label: "")
        holder.addSubview(words)
        words.alignment = .center
        action = { [weak self] in self?.listen() }
        toolTip = "Click, then press the new shortcut"
        setAccessibilityHelp("Click, then press the new shortcut")
        watch = kitTrack { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var label: String {
        if let taking, let other = store.owner(of: taking, except: id) {
            return "Press again to take it from \(other.title)"
        }
        if let note { return note }
        if listening { return "Type a shortcut" }
        return store.key(for: id)?.display ?? "None"
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(48, words.intrinsicContentSize.width) + padding * 2, height: height ?? 22)
    }

    override func layout() {
        super.layout()
        let size = words.intrinsicContentSize
        words.frame = kitSnap(NSRect(x: 0, y: (holder.bounds.height - size.height) / 2, width: holder.bounds.width, height: size.height))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    func refresh() {
        let text = label
        if words.text != text {
            words.text = text
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
            superview?.invalidateIntrinsicContentSize()
            needsLayout = true
        }
        words.font = .systemFont(ofSize: 12, weight: store.isChanged(id) ? .semibold : .regular)
        words.color = listening || store.key(for: id) != nil ? .labelColor : .secondaryLabelColor
        look = .pill(listening ? .primary : .secondary)
        setAccessibilityLabel(spoken ?? text)
    }

    func listen() {
        guard !listening else { return stop() }
        if let other = KeyBoxView.current, other !== self { other.stop() }
        KeyBoxView.current = self
        listening = true
        note = nil
        taking = nil
        store.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let swallowed = MainActor.assumeIsolated { self?.swallows(event) ?? false }
            return swallowed ? nil : event
        }
        if let window {
            resigned = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
    }

    func swallows(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else {
            stop()
            return false
        }
        guard event.type == .keyDown else {
            if !bounds.contains(convert(event.locationInWindow, from: nil)) { stop() }
            return false
        }
        take(event)
        return true
    }

    func take(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, flags.isEmpty { return stop() }
        if [51, 117].contains(event.keyCode), flags.isEmpty {
            store.clear(id)
            return stop()
        }
        guard let combo = KeyCombo(event: event) else { return }
        guard combo.isUsable else { return say("Add ⌘, ⌥ or ⌃") }
        if let reason = KeyCombo.reserved(combo) { return say(reason) }
        guard id != Command.recentTabs || combo.control || combo.option || combo.command
        else { return say("Hold ⌃, ⌥ or ⌘ with it") }
        guard !id.hasPrefix("ext:") || combo.key.count == 1 else { return say("Not for an extension") }
        guard !id.hasPrefix("ext:") || !KeyCombo.isBrowserOnly(combo) else { return say("Not for an extension") }
        if store.owner(of: combo, except: id) != nil, taking != combo {
            taking = combo
            return
        }
        let other = store.owner(of: combo, except: id)
        store.assign(combo, to: id)
        stop()
        if let other { browser.announce("\(combo.display) moved from \(other.title)") }
    }

    private func say(_ text: String) {
        note = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated { if self?.note == text { self?.note = nil } }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resigned { NotificationCenter.default.removeObserver(resigned) }
        if KeyBoxView.current === self { KeyBoxView.current = nil }
        let was = listening
        monitor = nil
        resigned = nil
        listening = false
        note = nil
        taking = nil
        if was { store.recording = false }
    }
}
