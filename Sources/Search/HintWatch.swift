import AppKit
import Combine

@MainActor
enum HintClock {
    private static let start = Date()
    private static var moved: TimeInterval = 0
    static var launched: Date { start }

    static var now: Date { Store.testing ? start + moved : Date() }

    static func advance(_ seconds: TimeInterval) {
        moved += seconds
    }

    static func rewind() {
        moved = 0
    }
}

@MainActor
final class HintBook {
    static let shared = HintBook()
    static let key = "hints.record"

    private let store: UserDefaults
    private(set) var record: HintRecord

    init(store: UserDefaults = Store.settings) {
        self.store = store
        record = store.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(HintRecord.self, from: $0) } ?? HintRecord()
    }

    func change(_ edit: (inout HintRecord) -> Void) {
        var changed = record
        edit(&changed)
        guard changed != record else { return }
        record = changed
        store.set(try? JSONEncoder().encode(record), forKey: Self.key)
    }

    func forget() {
        record = HintRecord()
        store.removeObject(forKey: Self.key)
    }
}

@MainActor
final class HintWatch {
    private weak var browser: Browser?
    private(set) var trail = HintTrail()
    private(set) var showing: String?
    private var pending: HintID?
    private var active: Tab.ID?
    private var ghost: UUID?
    private var ghosts = 0
    private var recalled = false
    private var pairs = 0
    private var watches: [AnyCancellable] = []

    init(_ browser: Browser) {
        self.browser = browser
        _ = HintClock.launched
        active = browser.activeID
        ghost = browser.ghosts.last?.id
        ghosts = browser.ghosts.count
        recalled = browser.recalling
        pairs = browser.splits.count
        watches = [
            kitObserve(initial: false, { [weak browser] in browser?.activeID }) { [weak self] id in self?.switched(to: id) },
            kitObserve(initial: false, { [weak browser] in browser?.ghosts.last?.id }) { [weak self] id in self?.closed(id) },
            kitObserve(initial: false, { [weak browser] in browser?.recalling ?? false }) { [weak self] on in self?.recall(on) },
            kitObserve(initial: false, { [weak browser] in browser?.splits.count ?? 0 }) { [weak self] count in self?.paired(count) },
            kitObserve(initial: false, { [weak browser] in browser?.announcement }) { [weak self] text in self?.announced(text) },
        ]
    }

    private var on: Bool { browser?.prefs.hints == true }

    func closedByPointer() { note(.closedByPointer) }

    func findNextPressed() { note(.findNextByPointer) }

    func searchChanged() { note(.searchChanged) }

    func copied(_ url: URL?) {
        guard let url, CleanLink.clean(url) != url else { return }
        note(.copiedTrackedAddress)
    }

    func copiedFromField(in window: NSWindow) {
        guard on, let editor = window.firstResponder as? NSTextView else { return }
        let range = editor.selectedRange()
        guard range.length > 0, let text = (editor.string as NSString?)?.substring(with: range) else { return }
        copied(Address.url(from: text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func typed(_ url: URL) {
        guard let last = browser?.ghosts.last, Hints.samePage(url, last.url) else { return }
        note(.typedClosedAddress)
    }

    func used(_ command: String) {
        guard on else { return }
        HintBook.shared.change { Hints.used(command, record: &$0) }
    }

    func pressed() {
        guard let browser, let showing, browser.announcement == showing else { return }
        browser.dismissAnnounced()
    }

    func forget() {
        trail = HintTrail()
        pending = nil
    }

    private func switched(to id: Tab.ID?) {
        defer { active = id }
        guard let browser, let from = active, let id, from != id else { return }
        let either = [from, id].contains { tabID in browser.tabs.first { $0.id == tabID }.flatMap(browser.split(for:)) != nil }
        note(.switched(from: from, to: id, splitOn: browser.prefs.splitView, eitherInSplit: either))
    }

    private func closed(_ id: UUID?) {
        let count = browser?.ghosts.count ?? 0
        defer { ghost = id; ghosts = count }
        guard let id, id != ghost, count >= ghosts, browser?.ghosts.last?.batch == nil else { return }
        note(.closedTab)
    }

    private func recall(_ now: Bool) {
        defer { recalled = now }
        if now, !recalled { note(.openedHistory) }
    }

    private func paired(_ count: Int) {
        defer { pairs = count }
        guard count > pairs, on else { return }
        HintBook.shared.change { $0.used.insert(.split) }
    }

    private func announced(_ text: String?) {
        if text != showing { showing = nil }
        guard text == nil, let held = pending else { return }
        pending = nil
        offer(held)
    }

    private func note(_ event: HintEvent) {
        guard on, let id = Hints.note(event, trail: &trail, now: HintClock.now) else { return }
        DispatchQueue.main.async { [weak self] in self?.offer(id) }
    }

    private func due(_ id: HintID, in scene: HintScene) -> String? {
        Hints.due(id, record: HintBook.shared.record, trail: trail, scene: scene, now: HintClock.now,
                  launched: HintClock.launched, calendar: .current, key: { ShortcutStore.shared.key(for: $0) })
    }

    private func offer(_ id: HintID) {
        guard on, let browser else { return }
        var scene = scene(of: browser)
        if let line = due(id, in: scene) {
            show(id, line, in: browser)
            return
        }
        guard scene.announcing else { return }
        scene.announcing = false
        if due(id, in: scene) != nil { pending = id }
    }

    private func show(_ id: HintID, _ line: String, in browser: Browser) {
        pending = nil
        HintBook.shared.change { Hints.shown(id, record: &$0, trail: &trail, now: HintClock.now) }
        browser.announce(line, seconds: Hints.stays)
        showing = line
    }

    private func scene(of browser: Browser) -> HintScene {
        let window = browser.window
        let editor = window?.firstResponder as? NSTextView
        let inField = (editor?.delegate as? NSTextField)?.delegate is AddressFieldKeys
        return HintScene(inAddressField: browser.editing || inField,
                         inPageBox: browser.active?.typing == true,
                         fullScreen: window?.styleMask.contains(.fullScreen) == true,
                         privateWindow: browser.isPrivate,
                         agentTab: browser.active?.agent == true,
                         announcing: browser.announcement != nil)
    }
}
