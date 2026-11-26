import AppKit
import Observation
import Combine

// Several windows, each with its tabs (Drice: "un search dans une window et
// un nouveau search dans une autre window").
//
// Each window has a Browser of its own: its tabs, the space it shows, its
// field and panels. What every window shares lives in `Shared` — settings,
// History, bookmarks, downloads — and the spaces and pins are the same
// everywhere: each window shows one space at a time, of its own choosing.
//
// The first window is SwiftUI's scene, as it always was; any other is an
// AppKit window around the same ContentView. With one window, and nobody
// pressing ⌘N, nothing is different from before.
//
// The session: session.json and the other spaces' files belong to the
// oldest window still open — so 1.0.3 reads a real window's tabs — and every
// other window is a line in windows.json, frame and space included.

/// A window's saved state: where it was, which space it showed, and its
/// row of tabs in every space it has one in. The oldest window's rows are
/// in the session files instead, and its line here only holds the frame.
struct WindowRecord: Codable {
    var id = UUID()
    var frame: String?
    var space: UUID = Space.firstID
    /// Rows by space, keyed by the space's identifier.
    var rows: [String: Session.Shape] = [:]

    init(space: UUID = Space.firstID) { self.space = space }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? values.decode(UUID.self, forKey: .id)) ?? UUID()
        frame = try? values.decode(String.self, forKey: .frame)
        space = (try? values.decode(UUID.self, forKey: .space)) ?? Space.firstID
        rows = (try? values.decode([String: Session.Shape].self, forKey: .rows)) ?? [:]
    }

    var rect: NSRect? { frame.map(NSRectFromString).flatMap { $0.width > 100 && $0.height > 100 ? $0 : nil } }
}

/// The browser whose window is in front, for the menus and everything else
/// that acts on "the" window.
@MainActor
@Observable
final class Front {
    static let shared = Front()
    private(set) var browser: Browser?
    private(set) var browserKey = true
    @ObservationIgnored private var keyWatch: AnyCancellable?

    init() {
        keyWatch = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] note in
                MainActor.assumeIsolated { self?.keyed(note.object as? NSWindow) }
            }
    }

    func keyed(_ window: NSWindow?) {
        let owns = Browsers.ownsKeys(window)
        if browserKey != owns { browserKey = owns }
    }

    func set(_ browser: Browser?) {
        guard browser !== self.browser else { return }
        self.browser = browser
    }
}

/// The browser in SwiftUI's own window. Closed while other windows stay
/// open, that window's tabs go (⇧⌘T brings them back) and the scene, opened
/// again, comes with a fresh browser rather than the old one.
@MainActor
@Observable
final class SceneSlot {
    static let shared = SceneSlot()
    private(set) var browser: Browser

    private init() {
        let browser = Browser()
        browser.inScene = true
        self.browser = browser
        DispatchQueue.main.async { [weak self] in
            guard self?.browser === browser else { return }
            Browsers.register(browser)
        }
    }

    /// Its browser gone with its window: the next time the scene shows, a
    /// fresh one, counted once its window is really there.
    func refresh() {
        let fresh = Browser(record: WindowRecord(space: Browsers.front.flatMap { $0.isPrivate ? nil : $0.spaceID } ?? Space.firstID))
        fresh.inScene = true
        browser = fresh
    }
}

@MainActor
enum Browsers {
    /// Every window's browser, oldest first. The first is the one whose tabs
    /// the session files hold.
    private(set) static var all: [Browser] = []
    /// The window around each browser that isn't the scene's: kept, since
    /// AppKit only lends it.
    private static var frames: [ObjectIdentifier: NSWindow] = [:]
    private static var spaceWatch: [ObjectIdentifier: AnyCancellable] = [:]
    /// Windows closed while others were open, newest last, for ⇧⌘T.
    private(set) static var closed: [(record: WindowRecord, at: Date)] = []

    /// SwiftUI's window's id, which is also the name its frame is kept
    /// under (#204); a test run's own.
    static let sceneID = Store.world.map { "search (\($0))" } ?? "search"

    static var primary: Browser? { all.first { !$0.isPrivate } }
    static var front: Browser? { Front.shared.browser ?? all.last }
    /// The browser to act on when a menu or a link needs one.
    static var acting: Browser { front ?? SceneSlot.shared.browser }

    static func register(_ browser: Browser) {
        guard !all.contains(where: { $0 === browser }) else { return }
        all.append(browser)
        if Front.shared.browser == nil { Front.shared.set(browser) }
        KitPopup.sideOnRight = { Browsers.browser(for: $0)?.prefs.sidePosition == .right }
        KitPopup.inSidebar = { view in
            sequence(first: view, next: \.superview).contains { $0 is SideColumnView || $0 is StackedColumnView || $0 is FoldColumnCardView }
        }
        spaceWatch[ObjectIdentifier(browser)] = kitObserve(initial: false, { [weak browser] in browser?.spaceID }) { [weak browser] _ in
            KitPopup.closeAll(in: browser?.window)
        }
        // Extensions see every window (windows.getAll, a tab's windowId).
        Extensions.shared.attach(browser)
    }

    static func forget(_ browser: Browser) {
        guard Store.testing else { return }
        all.removeAll { $0 === browser }
        Extensions.shared.detach(browser)
        frames[ObjectIdentifier(browser)] = nil
        spaceWatch[ObjectIdentifier(browser)] = nil
        if Front.shared.browser === browser { Front.shared.set(all.last) }
    }

    static func browser(for window: NSWindow?) -> Browser? {
        guard let window else { return nil }
        return all.first { $0.window === window }
    }

    static func ownsKeys(_ window: NSWindow?) -> Bool {
        guard let window else { return true }
        if window.sheetParent != nil { return false }
        if browser(for: window) != nil { return true }
        if let parent = window.parent, browser(for: parent) != nil { return true }
        return window is NSPanel && !window.styleMask.contains(.titled)
    }

    static func isCloseKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        return event.type == .keyDown && event.keyCode == 13 && (flags == .command || flags == [.command, .shift])
    }

    static var keyTarget: NSWindow? {
        if let event = NSApp.currentEvent, event.type == .keyDown, let window = event.window { return window }
        return NSApp.keyWindow
    }

    static func closeKey(tab: Bool) {
        closeKey(tab: tab, in: keyTarget)
    }

    static func closeKey(tab: Bool, in key: NSWindow?) {
        guard ownsKeys(key), let key = key ?? front?.window else {
            if let key { closeOther(key) }
            return
        }
        let browser = browser(for: key) ?? key.parent.flatMap(browser(for:)) ?? acting
        tab ? browser.closeFront() : browser.closeWindow()
    }

    static func pressClose(shift: Bool, in key: NSWindow?) -> String {
        guard let key, let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: key.windowNumber, context: nil,
            characters: shift ? "W" : "w", charactersIgnoringModifiers: shift ? "W" : "w", isARepeat: false, keyCode: 13
        ) else { return "none" }
        if !Store.unitTests, NSApp.mainMenu != nil {
            NSApp.postEvent(event, atStart: true)
            return "app"
        }
        if let hook = ContentView.keyHooks[ObjectIdentifier(acting)], hook(event) == nil { return "monitor" }
        if key.performKeyEquivalent(with: event) { return "window" }
        closeKey(tab: !shift, in: key)
        return "route"
    }

    private static func closeOther(_ window: NSWindow) {
        guard window.sheetParent != nil else {
            window.performClose(nil)
            return
        }
        guard let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53
        ) else { return }
        if !window.performKeyEquivalent(with: escape) { window.cancelOperation(nil) }
    }

    /// A window of ours came to the front.
    static func becameKey(_ browser: Browser) {
        register(browser)
        browser.shut = false
        Front.shared.set(browser)
        Front.shared.keyed(browser.window)
        if !browser.isPrivate { Spaces.current = browser.spaceID }
        Extensions.shared.focused(browser)
    }

    // MARK: - opening

    /// ⌘N. A window that is closed but kept — the last one, closed with the
    /// app running — comes back first, as a window always did; otherwise a
    /// new one, with one empty tab, in the space of the window in front.
    @discardableResult
    static func newWindow() -> Browser {
        if let kept = all.first(where: { !$0.isOpen && !$0.keepsNothing }) {
            show(kept)
            return kept
        }
        let browser = Browser(record: WindowRecord(space: front.flatMap { $0.isPrivate ? nil : $0.spaceID } ?? Space.firstID))
        open(browser, frame: nil)
        return browser
    }

    @discardableResult
    static func newPrivateWindow() -> Browser {
        let browser = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        open(browser, frame: nil)
        return browser
    }

    static func openPrivate(_ url: URL) {
        let browser = all.last { $0.isPrivate && $0.isOpen } ?? newPrivateWindow()
        browser.arrive(url)
        show(browser)
    }

    /// Brings a browser's window on screen, the scene's included.
    static func show(_ browser: Browser) {
        browser.shut = false
        if let window = browser.window {
            Bench.keepOff(window)
            // A hidden probe stays hidden: ordered front, its window shows
            // the app again (an extension's windows.update focused, which
            // Claude's panel asks for whenever its window isn't key).
            if !(Store.testing && NSApp.isHidden) { window.makeKeyAndOrderFront(nil) }
        } else if browser.inScene {
            _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
        }
        comeForward()
    }

    /// Some window on screen for a link or a menu to act in: the one in
    /// front, or one brought back.
    @discardableResult
    static func ensureWindow() -> Browser {
        if let front, front.isOpen, !front.keepsNothing { return front }
        if let open = all.last(where: { $0.isOpen && !$0.keepsNothing }) { return open }
        let kept = primary ?? SceneSlot.shared.browser
        show(kept)
        return kept
    }

    /// A window around `browser`, made here rather than by SwiftUI.
    static func open(_ browser: Browser, frame: NSRect?, behind: Bool = false) {
        let popup = browser.isPopup
        let host: NSView
        if popup {
            host = PopupWindowView(browser: browser)
        } else {
            host = ContentView(browser: browser)
        }
        // A new window from one in full screen: in full screen of its own,
        // in a Space of its own, as Safari and Chrome do — sized as a window
        // for when it leaves full screen, not as the screen.
        let fullScreen = !popup && !behind && frame == nil && front?.window?.styleMask.contains(.fullScreen) == true
        let size = popup ? NSSize(width: 480, height: 600)
            : fullScreen ? NSSize(width: 1180, height: 780)
            : front?.window?.frame.size ?? NSSize(width: 1180, height: 780)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        // A popup has no ContentView.dress() to tie the browser to its window;
        // tied here, before extensions hear of it (#408, lulkebit).
        browser.window = window
        window.isReleasedWhenClosed = false
        window.delegate = LeaveWindows.shared
        window.tabbingMode = .disallowed
        if browser.keepsNothing { window.isRestorable = false }
        window.contentView = host
        if !popup { window.contentMinSize = NSSize(width: 640, height: 420) }
        if popup {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.minSize = NSSize(width: 200, height: 150)
        }
        if let frame {
            window.setFrame(frame, display: false)
        } else if popup || fullScreen {
            window.center()
        } else if let beside = front?.window {
            // Down and to the right of the window in front, as new windows go.
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: beside.frame.minX, y: beside.frame.maxY)))
        } else {
            window.center()
        }
        frames[ObjectIdentifier(browser)] = window
        // Extensions hear of the window only now, with its real frame there
        // to report: told first, a popup's windows.update and getCurrent met
        // a window with no frame and no NSWindow behind it (#408, lulkebit).
        register(browser)
        Bench.keepOff(window)
        if behind { return orderBehind(window) }
        if !(Store.testing && NSApp.isHidden) { window.makeKeyAndOrderFront(nil) }
        // Never in a test run: full screen would put a probe's window on a screen.
        if fullScreen, !Store.testing { window.toggleFullScreen(nil) }
        comeForward()
    }

    /// An extension unloaded, turned off or removed: the popup windows it
    /// opened go with it.
    static func closePopups(of id: String) {
        for browser in all where browser.extensionPopup == id { browser.window?.close() }
    }

    private static func comeForward() {
        // Never a test run's: a probe started hidden stays off every screen.
        guard !Store.testing else { return }
        NSApp.activate()
    }

    // MARK: - closing

    /// A window is closing. The last one on screen stays, its browser kept,
    /// as the one window always was: opened again, it has its tabs, their
    /// pages asleep meanwhile but for what can't be (see sleepShut). One
    /// closed while others stay open goes, tabs and all, and ⇧⌘T can bring
    /// it back.
    /// The app is quitting: windows closing are not windows closed.
    static var quitting = false

    static func closing(_ window: NSWindow) {
        guard !quitting, let browser = browser(for: window) else { return }
        browser.fileChoice?.cancel()
        browser.privateFileDownloads = []
        browser.cancelFileImport()
        browser.cancelDisplay()
        // A popup goes, and isn't one ⇧⌘T brings back.
        if browser.keepsNothing {
            retire(browser, remembered: false)
            return
        }
        let remembered = unremembered.remove(ObjectIdentifier(browser)) == nil
        let others = all.filter { $0 !== browser && $0.isOpen && !$0.keepsNothing }
        guard !others.isEmpty else {
            // The last one: kept, tabs and all, and written down now. Its
            // pages sleep, as Safari and Chrome close theirs: the tabs are
            // there when it comes back, the one in front woken.
            browser.shut = true
            browser.flushSession()
            save(now: true)
            browser.sleepShut()
            return
        }
        retire(browser, remembered: remembered)
    }

    private static var unremembered: Set<ObjectIdentifier> = []

    static func closeUnremembered(_ browser: Browser) {
        unremembered.insert(ObjectIdentifier(browser))
        browser.window?.close()
    }

    private static func retire(_ browser: Browser, remembered: Bool = true) {
        let wasPrimary = browser === primary
        let owned = browser.usesFiles && !browser.keepsNothing
        if owned { browser.leaveFiles() }
        if remembered {
            closed.append((record(of: browser, rows: true), Date()))
            if closed.count > 10 { closed.removeFirst(closed.count - 10) }
        }
        all.removeAll { $0 === browser }
        Extensions.shared.detach(browser)
        browser.closeAll()
        ContentView.forget(browser)
        LiveOffers.shared.gone(browser)
        frames[ObjectIdentifier(browser)] = nil
        spaceWatch[ObjectIdentifier(browser)] = nil
        if Front.shared.browser === browser {
            Front.shared.set(all.last { $0.isOpen && !$0.keepsNothing } ?? all.last { $0.isOpen && !$0.isPopup } ?? all.last { !$0.keepsNothing })
        }
        if browser.inScene { SceneSlot.shared.refresh() }
        if owned, let heir = all.first(where: { !$0.keepsNothing }) { heir.takeFiles() }
        if wasPrimary, let next = primary { next.becomePrimary() }
        save(now: true)
    }

    /// ⇧⌘T, when the last thing closed was a window rather than a tab: the
    /// window comes back where it was, with its tabs, asleep until looked at.
    static func reopenWindow() -> Bool {
        guard let last = closed.popLast() else { return false }
        let browser = Browser(record: last.record)
        open(browser, frame: last.record.rect)
        save()
        return true
    }

    /// When the newest closed window was closed, to weigh against the newest
    /// closed tab.
    static var lastClosedAt: Date? { closed.last?.at }

    // MARK: - saving

    /// A window's state as a record: frame, space, and — for any but the
    /// oldest, or when it is going away — its rows.
    static func record(of browser: Browser, rows: Bool) -> WindowRecord {
        var record = browser.record
        record.space = browser.spaceID
        if let window = browser.window { record.frame = NSStringFromRect(window.frame) }
        if rows { record.rows = browser.allRows() }
        return record
    }

    private static var file: URL { Store.file("windows.json") }

    /// The windows that are written down, oldest first: popups never come back.
    static var saved: [Browser] { all.filter { !$0.keepsNothing } }

    /// windows.json: the oldest window's frame and space first, then every
    /// other window whole.
    static func save(now: Bool = false) {
        guard let primary else { return }
        var records = [record(of: primary, rows: false)]
        records[0].rows = [:]
        for browser in saved.dropFirst() { records.append(record(of: browser, rows: true)) }
        if !restored { records += read().dropFirst() }
        // Frozen before it goes to the Disk queue.
        let snapshot = records
        Disk.write(file, now: now) { try? JSONEncoder().encode(snapshot) }
    }

    /// Soon, not now: a window being dragged moves many times a second.
    static func saveSoon() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            saving = false
            save()
        }
    }
    private static var saving = false

    static func read() -> [WindowRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([WindowRecord].self, from: data)) ?? []
    }

    /// Start with a fresh window (see Session.startFresh): one window, the
    /// first, where it was; the others' tabs don't come back, and their
    /// pins are every window's anyway (Pins.swift).
    static func startFresh() {
        let records = read()
        guard records.count > 1 else { return }
        let first = [records[0]]
        Disk.write(file, now: true) { try? JSONEncoder().encode(first) }
    }

    /// At launch, once the first window is up.
    static func restoreOnce() {
        guard !restored else { return }
        restored = true
        restore()
    }
    private static var restored = false

    /// At launch: the other windows there were, each as it was left.
    static func restore() {
        let records = read()
        guard records.count > 1 else { return }
        for record in records.dropFirst() {
            open(Browser(record: record), frame: record.rect)
        }
        DispatchQueue.main.async { primary?.window?.makeKeyAndOrderFront(nil) }
    }

    /// Quitting: every window written, now.
    static func flush() {
        for browser in all { browser.flushSession() }
        save(now: true)
    }

    /// The window has moved or changed size.
    static func watchFrames() {
        guard watching.isEmpty else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            watching.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard browser(for: note.object as? NSWindow) != nil else { return }
                    saveSoon()
                }
            })
        }
        watching.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                closing(window)
            }
        })
    }
    nonisolated(unsafe) private static var watching: [Any] = []
}

extension Browser {
    /// How a menu names this window: the page in front, as the Window menu
    /// does, and the space when there are spaces.
    var windowName: String {
        let page = active.map { $0.isBlank ? "New Tab" : $0.label } ?? "Window"
        return prefs.usesSpaces ? "\(page) — \(space.name)" : page
    }
}

@MainActor
final class PopupWindowView: NSView {
    let browser: Browser
    private let ground = KitBox(fill: Palette.NS.ground)
    private let title = KitLabel()
    private let stage = StageView()
    private let swipe = SwipeView()
    private let trouble = PopupTroubleView()
    private let overlay: PopupOverlayView
    private var watched: AnyCancellable?
    private weak var tab: Tab?
    private var troubleFor: ObjectIdentifier?
    private var accounts: AccountHost?

    init(browser: Browser) {
        self.browser = browser
        overlay = PopupOverlayView(browser: browser)
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 600))
        wantsLayer = true
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.color = KitColor.muted
        title.overflow = .head
        title.alignment = .center
        for view in [ground, title, stage, trouble, swipe, overlay] as [NSView] { addSubview(view) }
        watched = kitObserve({ [weak self] in self?.heard() }) { [weak self] _ in self?.follow() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func heard() {
        _ = browser.suggesting?.tab
        guard let tab = browser.active else { return }
        _ = (tab.committed, tab.address, tab.title, tab.pull, tab.loading, tab.failure == nil)
    }

    private func follow() {
        tab = browser.active
        refresh()
    }

    private func refresh() {
        guard let tab else {
            title.isHidden = true
            stage.isHidden = true
            swipe.pull = nil
            showAccounts(nil)
            if troubleFor != nil {
                troubleFor = nil
                trouble.tab = nil
            }
            return
        }
        title.isHidden = false
        stage.isHidden = false
        title.text = site(tab)
        stage.show(tab.built ?? tab.web)
        swipe.pull = tab.pull
        trouble.needsLayout = true
        overlay.needsLayout = true
        showAccounts(browser.suggesting.flatMap { $0.tab == tab.id ? $0 : nil })
        if troubleFor != ObjectIdentifier(tab) {
            troubleFor = ObjectIdentifier(tab)
            trouble.tab = tab
        }
        needsLayout = true
    }

    private func showAccounts(_ asked: Browser.Suggesting?) {
        guard let asked else {
            accounts?.removeFromSuperview()
            accounts = nil
            return
        }
        if accounts == nil {
            let host = AccountHost.make(browser, asked)
            addSubview(host, positioned: .below, relativeTo: overlay)
            accounts = host
        }
        accounts?.show(browser, asked)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let bar: CGFloat = 34
        ground.frame = bounds
        let height = ceil(title.measure(width: .greatestFiniteMagnitude).height)
        title.frame = kitSnap(NSRect(x: 10 + 64 + 10, y: (bar - height) / 2,
                                     width: max(0, bounds.width - 2 * (10 + 64 + 10)), height: height))
        let page = NSRect(x: 0, y: bar, width: bounds.width, height: max(0, bounds.height - bar))
        for view in [stage, trouble, swipe] as [NSView] where view.frame != page { view.frame = page }
        if let accounts, accounts.frame != page { accounts.frame = page }
        if overlay.frame != bounds { overlay.frame = bounds }
    }

    private func site(_ tab: Tab) -> String {
        let arrived = tab.committed.flatMap { url -> URL? in
            ["about", "blob"].contains(url.scheme?.lowercased() ?? "") ? nil : url
        }
        guard let url = arrived ?? opened(tab) else { return "" }
        switch url.scheme?.lowercased() {
        case "https": return SiteCard.site(url)
        case "http": return "Not secure, " + SiteCard.site(url)
        case "chrome-extension", "webkit-extension": return "Extension page"
        default: return url.absoluteString == "about:blank" ? "" : "Not a site"
        }
    }

    private func opened(_ tab: Tab) -> URL? {
        guard let id = tab.opener else { return nil }
        return Browsers.all.lazy.flatMap { $0.tabs }.first { $0.id == id }?.committed
    }
}

@MainActor
final class PopupTroubleView: KitFlippedView {
    weak var tab: Tab? { didSet { needsLayout = true } }
    private var trouble: TroubleView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        guard let tab, let failure = tab.failure else {
            trouble?.removeFromSuperview()
            trouble = nil
            return
        }
        let host = tab.popupTroubleHost
        let waiting = tab.troubleWaits(before: trouble?.waiting ?? false)
        let view = trouble ?? {
            let made = TroubleView(message: failure, host: host, waiting: waiting, retry: { [weak tab] in tab?.reload() })
            addSubview(made)
            trouble = made
            return made
        }()
        view.onRetry = { [weak tab] in tab?.reload() }
        if view.message != failure || view.host != host || view.waiting != waiting {
            view.show(message: failure, host: host, waiting: waiting)
        }
        view.frame = bounds
    }
}

@MainActor
final class PopupOverlayView: KitFlippedView {
    let browser: Browser
    private let stack = BarStack()
    private let book = NoticeBook()
    private var capture: CaptureQuestionView?
    private var screen: ScreenQuestionView?
    private var offer: PasswordOfferView?
    private var fillCard: FormFillCard?
    private var fillDone: FormFillBar?
    private var fillOffer: FormFillBar?

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        stack.bottom = 0
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        stack.frame = bounds.insetBy(dx: 12, dy: 12)
        var bars: [BarStack.Bar] = []
        guard browser.active != nil else {
            book.begin()
            book.end()
            stack.show([])
            return
        }
        book.begin()
        if let ask = browser.asking, ask.screen {
            let view = screen ?? ScreenQuestionView(browser: browser, ask: ask)
            screen = view
            capture = nil
            view.ask = ask
            bars.append(.init(view: view, kind: .question))
        } else if let ask = browser.asking {
            let view = capture ?? CaptureQuestionView(browser: browser, ask: ask)
            capture = view
            screen = nil
            view.ask = ask
            bars.append(.init(view: view, kind: .question))
        } else {
            capture = nil
            screen = nil
        }
        if let asked = browser.offering {
            let view = offer ?? PasswordOfferView(browser: browser, offer: asked)
            offer = view
            view.offer = asked
            bars.append(.init(view: view, kind: .offer, clock: NoticeOffers.password(book, browser, asked, view)))
        } else {
            offer = nil
        }
        let forms = browser.forms
        let tab = browser.active?.id
        if let up = forms.preview, up.tab == tab {
            let book = AutofillBook.shared
            let view = fillCard ?? FormFillCard(forms: forms)
            fillCard = view
            view.show(up, addresses: book.addresses.map { ($0.id, $0.note) }, cards: book.cards.map { ($0.id, $0.title) })
            bars.append(.init(view: view, kind: .offer, clock: NoticeOffers.fill(self.book, browser, up, view)))
        } else {
            fillCard = nil
        }
        if let up = forms.done, up.tab == tab {
            let view = fillDone ?? FormFillBar(forms: forms)
            fillDone = view
            view.kind = .done(up)
            bars.append(.init(view: view, kind: .action, clock: NoticeOffers.filled(book, browser, up, view)))
        } else {
            fillDone = nil
        }
        if let up = forms.offer, up.tab == tab {
            let view = fillOffer ?? FormFillBar(forms: forms)
            fillOffer = view
            view.kind = .offer(up)
            bars.append(.init(view: view, kind: .offer, clock: NoticeOffers.save(book, browser, up, view)))
        } else {
            fillOffer = nil
        }
        book.end()
        stack.show(bars)
    }
}
