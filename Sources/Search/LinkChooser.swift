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
        case app(bundleID: String, name: String, path: String)

        var title: String {
            switch self {
            case .space(_, let name): name
            case .window: "New Window"
            case .peek: "Peek"
            case .app(_, let name, _): name
            }
        }

        var target: LinkRule.Target {
            switch self {
            case .space(let id, _): .space(id, folder: nil)
            case .window: .window(nil)
            case .peek: .peek
            case .app(let bundle, let name, _): .app(bundleID: bundle, name: name)
            }
        }

        var place: LinkDecision.Place {
            switch self {
            case .space(let id, _): .space(id, folder: nil)
            case .window: .window(nil)
            case .peek: .peek
            case .app(let bundle, let name, _): .app(bundleID: bundle, name: name)
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
    private var popup: KitPopup?
    private var view: LinkChooserView?
    private var monitor: Any?
    private(set) var done = false
    var litShown: Bool { view?.litShown ?? true }

    init(link: IncomingLink, url: URL, browser: Browser, world: LinkWorld, browsers: [(bundleID: String, name: String, path: String)]) {
        self.link = link
        self.url = url
        self.browser = browser
        self.world = world
        site = LinkRouter.site(of: url)
        var rows: [Row] = []
        if world.usesSpaces, !browser.isPrivate {
            rows += world.spaces.map { .space($0.id, name: $0.name) }
        }
        rows.append(.window)
        if browser.active.map({ !$0.isBlank && !$0.shy }) == true, browser.peekTab == nil { rows.append(.peek) }
        rows += browsers.map { .app(bundleID: $0.bundleID, name: $0.name, path: $0.path) }
        self.rows = rows
        choosing = LinkChoosing(count: rows.count)
        if let front = world.front, let at = rows.firstIndex(of: .space(front, name: world.name(of: front))) { choosing.point(at: at) }
    }

    static func otherBrowsers(for url: URL) -> [(bundleID: String, name: String, path: String)] {
        guard !Store.testing else { return [] }
        return installedBrowsers(for: url)
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
        shown?.finish(nil)
        let chooser = LinkChooser(link: link, url: url, browser: browser, world: world, browsers: otherBrowsers(for: url))
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
        guard !done, let window = browser.window, let content = window.contentView else { return }
        var marks: [UUID: NSImage] = [:]
        for space in browser.spaces { if let mark = space.menuMark ?? space.menuImage { marks[space.id] = mark } }
        let made = LinkChooserView(rows: rows, site: site, address: url.absoluteString, marks: marks)
        made.lit = choosing.lit
        made.choose = { [weak self] in self?.finish($0) }
        made.point = { [weak self] in self?.choosing.point(at: $0) }
        made.flip = { [weak self] in self?.always.toggle() }
        view = made
        let spot = LinkChooser.spot(in: window, content: content, browser: browser)
        popup = KitPopup.show(made, size: made.fittingSize, from: spot, of: content, edge: .below, focus: true) { [weak self] in
            guard let self, !self.done else { return }
            self.popup = nil
            self.finish(nil)
        }
        made.reveal(choosing.lit)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.heard(event) == true } ? nil : event
        }
    }

    static func spot(in window: NSWindow, content: NSView, browser: Browser) -> NSRect {
        let pointer = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if content.bounds.insetBy(dx: 40, dy: 40).contains(pointer) {
            return NSRect(x: pointer.x, y: pointer.y, width: 1, height: 1)
        }
        let x = browser.prefs.sidePosition == .right ? max(12, content.bounds.width - LinkChooserView.width - PopupLook.inset * 2 - 12) : 12
        let top = min(96, content.bounds.height / 4)
        let y = content.isFlipped ? top : content.bounds.height - top
        return NSRect(x: x - 1, y: y - 1, width: 2, height: 2)
    }

    private func heard(_ event: NSEvent) -> Bool {
        guard !done, event.window === popup?.panel || event.window === browser?.window else { return false }
        return key(event.keyCode, event.charactersIgnoringModifiers)
    }

    @discardableResult
    func key(_ code: UInt16, _ characters: String?) -> Bool {
        switch choosing.key(code, characters) {
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

    func finish(_ index: Int?) {
        guard !done else { return }
        done = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let closing = popup
        popup = nil
        closing?.close()
        if LinkChooser.shown === self { LinkChooser.shown = nil }
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

final class LinkChooserView: NSView {
    var lit: Int? { didSet { if lit != oldValue { for (index, row) in rows.enumerated() { row.lit = lit == index } } } }

    func reveal(_ index: Int?) {
        guard let index, rows.indices.contains(index) else { return }
        layoutSubtreeIfNeeded()
        rows[index].scrollToVisible(rows[index].bounds.insetBy(dx: 0, dy: -4))
    }

    var litShown: Bool {
        guard let lit, rows.indices.contains(lit) else { return true }
        return rows[lit].visibleRect.height >= rows[lit].bounds.height - 0.5
    }
    var always = false { didSet { toggle.set(always, animated: true) } }
    var choose: ((Int) -> Void)?
    var point: ((Int) -> Void)?
    var flip: (() -> Void)?

    private let head: KitLabel
    private let address: KitLabel
    private var rows: [LinkChooserRow] = []
    private let rule = KitBox(fill: PopupLook.edge)
    private let foot: KitLabel
    private let toggle = KitSwitch(isOn: false, small: true, system: false)
    static let width: CGFloat = 280

    init(rows choices: [LinkChooser.Row], site: String?, address text: String, marks: [UUID: NSImage]) {
        head = KitLabel("Open Link In", font: .systemFont(ofSize: 11, weight: .semibold), color: KitColor.muted)
        address = KitLabel(site ?? text, font: .systemFont(ofSize: 12), color: KitColor.muted)
        foot = KitLabel(site.map { "Always for \($0)" } ?? "Always for this site", font: .systemFont(ofSize: 12), color: KitColor.ink)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("link.chooser")
        rows = choices.enumerated().map { index, choice in
            let row = LinkChooserRow(choice, number: index < 9 ? index + 1 : nil, marks: marks)
            row.action = { [weak self] in self?.choose?(index) }
            row.moved = { [weak self] in
                guard let self, self.lit != index else { return }
                self.point?(index)
            }
            return row
        }
        for view in [head, address, rule, foot, toggle] as [NSView] { addSubview(view) }
        rows.forEach { addSubview($0) }
        toggle.onChange = { [weak self] on in
            guard let self, on != self.always else { return }
            self.flip?()
        }
        toggle.kitAccess(id: "link.chooser.always", label: foot.text)
        head.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Open Link In")
        setAccessibilityModal(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var headHeight: CGFloat { 40 }
    private var footHeight: CGFloat { 38 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width, height: headHeight + CGFloat(rows.count) * PopupLook.row + 9 + footHeight)
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func layout() {
        super.layout()
        let width = bounds.width
        let headSize = head.intrinsicContentSize
        head.frame = kitSnap(NSRect(x: 10, y: 5, width: width - 20, height: headSize.height))
        let addressSize = address.intrinsicContentSize
        address.frame = kitSnap(NSRect(x: 10, y: head.frame.maxY + 2, width: min(addressSize.width, width - 20), height: addressSize.height))
        var y = headHeight
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: width, height: PopupLook.row)
            y += PopupLook.row
        }
        y += 4
        rule.frame = kitSnap(NSRect(x: 10, y: y, width: width - 20, height: 1))
        y += 5
        let switchSize = toggle.intrinsicContentSize
        toggle.frame = kitSnap(NSRect(x: width - 10 - switchSize.width, y: y + (footHeight - switchSize.height) / 2,
                                      width: switchSize.width, height: switchSize.height))
        let footSize = foot.intrinsicContentSize
        foot.frame = kitSnap(NSRect(x: 10, y: y + (footHeight - footSize.height) / 2, width: toggle.frame.minX - 20, height: footSize.height))
    }
}

private final class LinkChooserRow: KitButton {
    var lit = false { didSet { if lit != oldValue { paint() } } }
    var moved: (() -> Void)?

    private let ground = KitBox(fill: nil, corners: .radius(PopupLook.rowCorner))
    private let art: NSView
    private let title: KitLabel
    private let number: KitLabel?
    private var motion: NSTrackingArea?

    init(_ choice: LinkChooser.Row, number at: Int?, marks: [UUID: NSImage]) {
        title = KitLabel(choice.title, font: PopupLook.font, color: KitColor.ink)
        number = at.map { KitLabel("\($0)", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: KitColor.muted) }
        switch choice {
        case .space(let id, _):
            if let image = marks[id] {
                art = NSImageView(image: image)
            } else {
                art = KitSymbol("square.stack", style: KitSymbol.Style(size: 13), tint: KitColor.ink)
            }
        case .window:
            art = KitSymbol("macwindow.badge.plus", style: KitSymbol.Style(size: 13), tint: KitColor.ink)
        case .peek:
            art = KitSymbol("eye", style: KitSymbol.Style(size: 13), tint: KitColor.ink)
        case .app(_, _, let path):
            let image = NSWorkspace.shared.icon(forFile: path)
            image.size = NSSize(width: 18, height: 18)
            art = NSImageView(image: image)
        }
        super.init(.plain(press: 0.98), label: choice.title)
        identifier = NSUserInterfaceItemIdentifier("link.chooser.row." + choice.title)
        addSubview(ground, positioned: .below, relativeTo: nil)
        addSubview(art)
        addSubview(title)
        title.setAccessibilityElement(false)
        art.setAccessibilityElement(false)
        if let number {
            number.setAccessibilityElement(false)
            addSubview(number)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let motion { removeTrackingArea(motion) }
        let made = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(made)
        motion = made
    }

    override func mouseMoved(with event: NSEvent) { moved?() }

    override func isAccessibilitySelected() -> Bool { lit }

    private func paint() {
        ground.layer?.kitTransition(Motion.kitQuick)
        ground.fill = lit ? KitColor.ink.withAlphaComponent(0.09) : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ground.needsDisplay = true
    }

    override func layout() {
        super.layout()
        ground.frame = bounds.insetBy(dx: 0, dy: 0)
        let size: NSSize = (art as? NSImageView) != nil ? NSSize(width: 18, height: 18) : art.intrinsicContentSize
        art.frame = kitSnap(NSRect(x: 6 + (22 - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        var right = bounds.width - 10
        if let number {
            let size = number.intrinsicContentSize
            number.frame = kitSnap(NSRect(x: right - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
            right -= size.width + 10
        }
        let x: CGFloat = 6 + 22 + 10
        let height = title.intrinsicContentSize.height
        title.frame = kitSnap(NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, min(title.intrinsicContentSize.width, right - x)),
                                     height: height))
    }
}
