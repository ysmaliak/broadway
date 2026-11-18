import AppKit

struct LinkChoosing: Equatable {
    enum Outcome: Equatable {
        case none
        case pick(Int)
        case here
        case flip
    }

    let count: Int
    private(set) var lit: Int?

    init(count: Int) {
        self.count = count
        lit = count > 0 ? 0 : nil
    }

    mutating func point(at index: Int) {
        if (0..<count).contains(index) { lit = index }
    }

    mutating func key(_ code: UInt16, _ characters: String?) -> Outcome {
        switch code {
        case 125:
            guard count > 0 else { return .none }
            lit = lit.map { min(count - 1, $0 + 1) } ?? 0
        case 126:
            guard count > 0 else { return .none }
            lit = lit.map { max(0, $0 - 1) } ?? count - 1
        case 36, 76:
            return lit.map { .pick($0) } ?? .none
        case 53:
            return .here
        case 49:
            return .flip
        default:
            guard let characters, characters.count == 1, let digit = Int(characters), (1...9).contains(digit), digit <= count else {
                return .none
            }
            lit = digit - 1
            return .pick(digit - 1)
        }
        return .none
    }
}

@MainActor
final class LinkChooser {
    enum Row: Equatable {
        case space(UUID, name: String)
        case window
        case peek

        var title: String {
            switch self {
            case .space(_, let name): name
            case .window: "New Window"
            case .peek: "Peek"
            }
        }

        var target: LinkRule.Target {
            switch self {
            case .space(let id, _): .space(id, folder: nil)
            case .window: .window(nil)
            case .peek: .peek
            }
        }

        var place: LinkDecision.Place {
            switch self {
            case .space(let id, _): .space(id, folder: nil)
            case .window: .window(nil)
            case .peek: .peek
            }
        }
    }

    private(set) static var shown: LinkChooser?

    let link: IncomingLink
    let url: URL
    let site: String?
    let rows: [Row]
    let world: LinkWorld
    var choosing: LinkChoosing { didSet { view?.lit = choosing.lit } }
    var always = false { didSet { view?.always = always } }
    private weak var browser: Browser?
    private var panel: LinkChooserPanel?
    private var view: LinkChooserView?
    private var monitor: Any?
    private var watching: [NSObjectProtocol] = []
    private(set) var done = false
    var litShown: Bool { view?.litShown ?? true }
    var faint: Bool { view?.faint ?? false }
    private var keyed: Int?
    var windowNumber: Int? { panel?.window.windowNumber }

    static func rows(spaces: [LinkWorld.Space], usesSpaces: Bool, isPrivate: Bool, peekable: Bool) -> [Row] {
        var rows: [Row] = []
        if usesSpaces, !isPrivate { rows += spaces.map { .space($0.id, name: $0.name) } }
        rows.append(.window)
        if peekable { rows.append(.peek) }
        return rows
    }

    init(link: IncomingLink, url: URL, browser: Browser, world: LinkWorld) {
        self.link = link
        self.url = url
        self.browser = browser
        self.world = world
        site = LinkRouter.site(of: url)
        let rows = Self.rows(spaces: world.spaces, usesSpaces: world.usesSpaces, isPrivate: browser.isPrivate,
                             peekable: browser.active.map { !$0.isBlank && !$0.shy } == true && browser.peekTab == nil)
        self.rows = rows
        choosing = LinkChoosing(count: rows.count)
        if let front = world.front, let at = rows.firstIndex(of: .space(front, name: world.name(of: front))) { choosing.point(at: at) }
        keyed = choosing.lit
    }

    static func installedBrowsers(for url: URL) -> [(bundleID: String, name: String, path: String)] {
        let own = Bundle.main.bundleIdentifier?.lowercased()
        var seen: Set<String> = []
        return NSWorkspace.shared.urlsForApplications(toOpen: url).compactMap { app -> (String, String, String)? in
            guard let bundle = Bundle(url: app)?.bundleIdentifier, bundle.lowercased() != own, seen.insert(bundle.lowercased()).inserted
            else { return nil }
            return (bundle, FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""), app.path)
        }
        .prefix(6)
        .map { $0 }
    }

    static func ask(_ link: IncomingLink, url: URL, in browser: Browser, world: LinkWorld) {
        shown?.finish(nil, animated: false)
        let chooser = LinkChooser(link: link, url: url, browser: browser, world: world)
        shown = chooser
        chooser.present()
    }

    private func present() {
        guard let browser else { return }
        guard !Store.unitTests else { return }
        if !Store.testing { NSApp.activate() }
        Links.onceShown { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + (NSApp.isActive || Store.testing ? 0 : 0.2)) { [weak self] in
                self?.show(in: browser)
            }
        }
    }

    private func show(in browser: Browser) {
        guard !done, let window = browser.window, window.contentView != nil else { return }
        KitPopup.closeAll(in: window)
        if browser.editing { browser.quitField() }
        var marks: [UUID: LinkChooserView.Mark] = [:]
        for space in browser.spaces { marks[space.id] = LinkChooserView.Mark(icon: space.shownIcon, look: space.look ?? SpaceLook()) }
        let made = LinkChooserView(rows: rows, url: url, site: site, marks: marks)
        made.lit = choosing.lit
        made.always = always
        made.look = browser.makingSpace ? browser.draftLook : browser.space.look ?? SpaceLook()
        made.choose = { [weak self] in self?.finish($0) }
        made.point = { [weak self] in self?.point(at: $0) }
        made.flip = { [weak self] in self?.always.toggle() }
        made.here = { [weak self] in self?.finish(nil) }
        made.open = { [weak self] in
            guard let self, let lit = self.choosing.lit else { return }
            self.finish(lit)
        }
        view = made
        let panel = LinkChooserPanel(made) { [weak self] in self?.finish(nil) }
        self.panel = panel
        panel.show(over: window)
        made.reveal(choosing.lit)
        watch(window, panel.window)
    }

    func point(at index: Int) {
        guard !done, rows.indices.contains(index) else { return }
        choosing.point(at: index)
        view?.faint = index != keyed
    }

    private func watch(_ window: NSWindow, _ panel: NSWindow) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.heard(event) == true } ? nil : event
        }
        let center = NotificationCenter.default
        let gone: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil, animated: false) }
        }
        let resigned: (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.done, let panel = self.panel else { return }
                let key = NSApp.keyWindow
                let fieldUp = key === self.browser?.window && self.browser?.editing == true
                if fieldUp || (key !== panel.window && key !== self.browser?.window) { self.finish(nil) }
            }
        }
        watching = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main, using: gone),
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: resigned),
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main, using: resigned),
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: gone),
            center.addObserver(forName: KitPopup.willShow, object: window, queue: .main, using: gone),
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panel?.place() }
            },
        ]
    }

    private func heard(_ event: NSEvent) -> Bool {
        guard !done, let panel else { return false }
        guard event.type == .keyDown else {
            if event.window !== panel.window { finish(nil) }
            return false
        }
        guard event.window === panel.window || event.window === browser?.window else { return false }
        return key(event.keyCode, event.charactersIgnoringModifiers)
    }

    @discardableResult
    func key(_ code: UInt16, _ characters: String?) -> Bool {
        let outcome = choosing.key(code, characters)
        keyed = choosing.lit
        view?.faint = false
        switch outcome {
        case .none:
            view?.reveal(choosing.lit)
            return code == 125 || code == 126
        case .pick(let index):
            finish(index)
        case .here:
            finish(nil)
        case .flip:
            always.toggle()
        }
        return true
    }

    func drop(animated: Bool = false) {
        guard !done else { return }
        done = true
        close(animated: animated)
    }

    private func close(animated: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        watching.forEach { NotificationCenter.default.removeObserver($0) }
        watching = []
        let closing = panel
        panel = nil
        closing?.leave(animated: animated)
        if LinkChooser.shown === self { LinkChooser.shown = nil }
    }

    func finish(_ index: Int?, animated: Bool = true) {
        guard !done else { return }
        done = true
        close(animated: animated)
        guard let browser else { return }
        guard let index, rows.indices.contains(index) else {
            Browsers.apply(LinkDecision(url: url, place: .here, rule: nil, steps: ["You chose where you are"], background: false),
                           link: link, from: browser, world: world)
            return
        }
        let row = rows[index]
        if always, let site { LinkRules.shared.always(site, to: row.target) }
        let decision = LinkDecision(url: url, place: row.place == .space(browser.spaceID, folder: nil) ? .here : row.place,
                                    rule: nil, steps: ["You chose \(row.title)"], background: false)
        let landing = Browsers.apply(decision, link: link, from: browser, world: world, chosen: decision.place != .here)
        if landing.forward, !Store.testing { landing.browser.window?.makeKeyAndOrderFront(nil) }
    }
}

@MainActor
final class LinkChooserPanel {
    static let arrival = KitArrival(anchor: KitArrival.top, scale: 0.98)
    static let leaveSeconds = 0.2

    let window: KitPopupPanel
    private let stage: LinkChooserStage
    private let card: LinkChooserView
    private weak var parent: NSWindow?
    private static var leaving: [LinkChooserPanel] = []

    init(_ card: LinkChooserView, outside: @escaping () -> Void) {
        self.card = card
        stage = LinkChooserStage(card)
        stage.outside = outside
        window = KitPopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.takesKey = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = stage
    }

    func show(over parent: NSWindow) {
        self.parent = parent
        place()
        stage.layoutSubtreeIfNeeded()
        card.kitArrive(false, Self.arrival, animated: false)
        parent.addChildWindow(window, ordered: .above)
        if window.level < parent.level { window.level = parent.level }
        window.makeKey()
        card.kitArrive(true, Self.arrival)
        NSAccessibility.post(element: card, notification: .created)
        NSAccessibility.post(element: card, notification: .layoutChanged, userInfo: [.uiElements: [card]])
    }

    func place() {
        guard let parent, let content = parent.contentView else { return }
        let box = LinkChooserLook.frame(in: content.bounds.size, rows: card.count)
        let local = content.isFlipped ? box : NSRect(x: box.minX, y: content.bounds.height - box.maxY, width: box.width, height: box.height)
        let onScreen = parent.convertToScreen(content.convert(local, to: nil))
        window.setFrame(onScreen.insetBy(dx: -LinkChooserLook.room, dy: -LinkChooserLook.room), display: true)
    }

    func leave(animated: Bool) {
        window.ignoresMouseEvents = true
        if window.isKeyWindow { parent?.makeKey() }
        guard animated else { return drop() }
        Self.leaving.append(self)
        card.kitArrive(false, Self.arrival)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveSeconds) { [self] in drop() }
    }

    private func drop() {
        Self.leaving.removeAll { $0 === self }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }
}

final class LinkChooserStage: NSView {
    var outside: (() -> Void)?
    private let card: NSView

    init(_ card: NSView) {
        self.card = card
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        if let layer = card.layer, !CATransform3DIsIdentity(layer.transform) { return }
        let box = bounds.insetBy(dx: LinkChooserLook.room, dy: LinkChooserLook.room)
        if card.frame != box { card.frame = box }
    }

    override func mouseDown(with event: NSEvent) {
        outside?()
    }
}
