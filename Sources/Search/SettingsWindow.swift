import AppKit
import Combine

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    static let place = Store.world.map { "settings (\($0))" } ?? "settings"
    private var window: SettingsFrame?
    private var split: SettingsSplit? { window?.contentViewController as? SettingsSplit }
    private var benched: SettingsSplit? {
        split ?? Browsers.all.compactMap { $0.window?.contentView }.lazy
            .compactMap { Self.all(SettingsTab.self, in: $0).first { !$0.isHiddenOrHasHiddenAncestor }?.split }.first
    }

    var isOpen: Bool { window?.isVisible == true }
    var isKey: Bool { window?.isKeyWindow == true }
    var number: Int? { window?.windowNumber }

    func press(_ event: NSEvent) -> Bool {
        window?.performKeyEquivalent(with: event) == true
    }

    static var stands: Bool {
        guard !Store.unitTests else { return false }
        return !Store.testing || Store.shownOnScreen || !Store.settings.bool(forKey: "bench")
    }

    static func frame(_ browser: Browser, asked: String?, found: String? = nil) -> SettingsFrame {
        let split = SettingsSplit(browser: browser, asked: asked, found: found)
        let window = SettingsFrame(contentRect: NSRect(origin: .zero, size: SettingsSize.opening),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        window.contentViewController = split
        window.toolbar = split.chrome.toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        window.contentMinSize = SettingsSize.minimum
        window.setContentSize(SettingsSize.opening)
        split.hold(window)
        return window
    }

    func listener(for browser: Browser) -> Browser {
        split?.browser ?? browser
    }

    static func hand(_ browser: Browser, to target: Browser) {
        guard target !== browser else { return }
        if let asked = browser.settingsAsked {
            target.settingsAsked = asked
            browser.settingsAsked = nil
        }
        if let drill = browser.settingsDrill {
            target.settingsDrill = drill
            browser.settingsDrill = nil
        }
        if let typed = browser.settingsTyped {
            target.settingsTyped = typed
            browser.settingsTyped = nil
        }
        if let rule = browser.settingsRule {
            target.settingsRule = rule
            browser.settingsRule = nil
        }
        if let space = browser.settingsLanguages {
            target.settingsLanguages = space
            browser.settingsLanguages = nil
        }
    }

    func open(_ browser: Browser, section: String?) {
        if let window {
            let target = listener(for: browser)
            Self.hand(browser, to: target)
            if let section, let detail = SettingsDetail.named(section) {
                target.settingsPage = detail.page
                target.settingsDrill = detail
            } else if let section, let page = SettingsPage.named(section) {
                target.settingsPage = page
                target.settingsAsked = page
            }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = Self.frame(browser, asked: section ?? browser.settingsPage.rawValue)
        window.delegate = self
        Self.restore(window)
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    static func restore(_ window: NSWindow) {
        if !window.setFrameUsingName(place) { window.center() }
        window.setFrameAutosaveName(place)
    }

    func benchResize(width: Double, height: Double) {
        guard Store.testing, let window else { return }
        let top = window.frame.maxY
        let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
        window.setFrame(NSRect(x: window.frame.minX, y: top - frame.height, width: frame.width, height: frame.height), display: true)
    }

    func benchClick(x: Double, y: Double, types: [NSEvent.EventType] = [.leftMouseDown, .leftMouseUp]) {
        guard Store.testing, let window else { return }
        Self.benchClick(in: window, x: x, y: y, types: types)
    }

    static func benchClick(in window: NSWindow, x: Double, y: Double, types: [NSEvent.EventType]) {
        guard Store.testing else { return }
        let point = NSPoint(x: x, y: Double(window.frame.height) - y)
        for type in types {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else { continue }
            window.sendEvent(event)
        }
    }

    func benchKey(_ code: UInt16, characters: String, shift: Bool) {
        guard Store.testing, let window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ) else { continue }
            window.sendEvent(event)
        }
    }

    func benchScroll(to y: Double) -> Bool {
        guard Store.testing, let paper = benched?.paper else { return false }
        paper.rise()
        paper.contentView.scroll(to: NSPoint(x: 0, y: paper.top + y))
        paper.reflectScrolledClipView(paper.contentView)
        return true
    }

    func benchWheel(by lines: Double, at point: NSPoint) -> Bool {
        guard Store.testing, let window,
              let source = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-lines), wheel2: 0, wheel3: 0)
        else { return false }
        source.location = CGPoint(x: window.frame.minX + point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - (window.frame.maxY - point.y))
        guard let event = NSEvent(cgEvent: source), let frame = window.contentView?.superview,
              let hit = frame.hitTest(NSPoint(x: point.x, y: window.frame.height - point.y))
        else { return false }
        hit.scrollWheel(with: event)
        return true
    }

    var benchDetail: String { split?.shell.trail.detail?.rawValue ?? "" }

    func benchSpace(_ id: UUID?) {
        guard Store.testing else { return }
        if let split {
            split.shell.space = id
            return
        }
        for root in Browsers.all.compactMap({ $0.window?.contentView }) {
            Self.all(SettingsTab.self, in: root).first?.split.shell.space = id
        }
    }

    func benchPress(_ id: String) -> Bool {
        guard Store.testing else { return false }
        let roots = [window?.contentView].compactMap { $0 } + (Self.stands ? [] : Browsers.all.compactMap { $0.window?.contentView })
        for root in roots {
            guard let found = Self.all(NSView.self, in: root).first(where: { $0.accessibilityIdentifier() == id || $0.identifier?.rawValue == id }) else { continue }
            return found.accessibilityPerformPress()
        }
        return false
    }

    func benchRows() -> [[String: Any]] {
        guard Store.testing else { return [] }
        let roots = [window?.contentView].compactMap { $0 } + (Self.stands ? [] : Browsers.all.compactMap { $0.window?.contentView })
        return roots.flatMap { Self.all(SettingsRowView.self, in: $0) }.filter { !$0.isHiddenOrHasHiddenAncestor }.map { row in
            ["id": row.rowID, "title": row.title.stringValue, "detail": row.detail.stringValue,
             "picked": Self.all(NSPopUpButton.self, in: row).first?.titleOfSelectedItem ?? "",
             "items": Self.all(NSPopUpButton.self, in: row).first?.itemTitles.filter { !$0.isEmpty } ?? []] as [String: Any]
        }
    }

    func benchStage() -> [String: Any] {
        guard Store.testing, let split = benched else { return [:] }
        return split.benchStage()
    }

    func benchPoint(_ row: String) -> Bool {
        guard Store.testing, let split = benched else { return false }
        return split.benchPoint(row)
    }

    func benchFocus(_ row: String) -> Bool {
        guard Store.testing, let split = benched else { return false }
        return split.benchFocus(row)
    }

    func benchChrome() -> [String: Any] {
        guard let window, let frame = window.contentView?.superview else { return [:] }
        func place(_ view: NSView) -> [Double] {
            let rect = view.convert(view.bounds, to: nil)
            return [rect.minX, window.frame.height - rect.maxY, rect.width, rect.height].map { Double($0.rounded()) }
        }
        let scrolls: [[String: Any]] = Self.all(NSScrollView.self, in: frame).map { scroll in
            ["class": String(describing: type(of: scroll)), "frame": place(scroll), "hidden": scroll.isHiddenOrHasHiddenAncestor,
             "insetTop": Double(scroll.contentInsets.top), "adjusts": scroll.automaticallyAdjustsContentInsets,
             "offset": Double(scroll.contentView.bounds.minY), "document": Double(scroll.documentView?.frame.height ?? 0),
             "content": scroll === split?.paper]
        }
        let marks: [[String: Any]] = Self.all(NSView.self, in: frame).compactMap { view in
            let name = String(describing: type(of: view))
            guard ["Separator", "EdgeEffect", "Pocket", "Titlebar", "Toolbar", "Backdrop", "StageEdge"].contains(where: name.contains) else { return nil }
            return ["class": name, "frame": place(view), "hidden": view.isHiddenOrHasHiddenAncestor, "alpha": Double(view.alphaValue)]
        }
        let splits: [[String: Any]] = split?.splitViewItems.map { item in
            ["behavior": item.behavior.rawValue, "separator": item.titlebarSeparatorStyle.rawValue,
             "fullHeight": item.allowsFullHeightLayout, "controller": String(describing: type(of: item.viewController))]
        } ?? []
        var version: [String: Any] = [:]
        if let foot = Self.all(NSTextField.self, in: frame).first(where: { $0.identifier?.rawValue == "settings.version" }) {
            let rect = foot.convert(foot.bounds, to: nil)
            version = ["frame": place(foot), "baseline": Double(rect.minY + foot.lastBaselineOffsetFromBottom)]
        }
        return ["separator": window.titlebarSeparatorStyle.rawValue, "toolbarStyle": window.toolbarStyle.rawValue, "version": version,
                "items": window.toolbar?.items.filter { !$0.isHidden }.map(\.itemIdentifier.rawValue) ?? [], "scrolls": scrolls,
                "marks": marks, "splits": splits, "controller": String(describing: type(of: window.contentViewController)),
                "title": window.title, "query": split?.shell.query ?? ""]
    }

    private static func all<T: NSView>(_ kind: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for child in view.subviews { found += all(kind, in: child) }
        return found
    }

    func benchKey(_ on: Bool) {
        guard Store.testing, let window else { return }
        window.benchKeyed = on
        if on {
            window.becomeKey()
            window.becomeMain()
        } else {
            window.resignKey()
            window.resignMain()
        }
        window.display()
    }

    func focusSearch() {
        guard let window, let field = split?.search.field else { return }
        window.makeFirstResponder(field)
    }

    func windowWillClose(_ notification: Notification) {
        (notification.object as? NSWindow)?.setFrameAutosaveName("")
        DispatchQueue.main.async { self.window = nil }
    }
}

@MainActor
final class SettingsSplit: NSSplitViewController {
    let shell = SettingsShell()
    let chrome = SettingsToolbar()
    let paper = SettingsPaper()
    let search = SettingsSearch()
    let rail = SettingsRail()
    let page: SettingsPageView
    let tab: Bool
    let browser: Browser
    private let bar = SettingsTabBar()
    private(set) lazy var pane = SettingsStagePane(paper: paper, bar: tab ? bar : nil)
    private var watching: Set<AnyCancellable> = []
    private var shown: SettingsTrail?
    private var staged: SettingsPlace?
    private lazy var reads = KitReads { [weak self] in self?.refresh() }

    init(browser: Browser, asked: String?, found: String?, tab: Bool = false) {
        self.browser = browser
        self.tab = tab
        page = SettingsPageView(browser: browser, shell: shell)
        super.init(nibName: nil, bundle: nil)
        if let found { shell.query = found }
        shell.follow(asked)
        if let space = browser.settingsLanguages {
            shell.openLanguages(space: space)
            DispatchQueue.main.async { browser.settingsLanguages = nil }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        paper.hasVerticalScroller = true
        paper.autohidesScrollers = true
        paper.drawsBackground = false
        paper.automaticallyAdjustsContentInsets = !tab
        paper.hold(page)
        let holder = NSViewController()
        let side: NSSplitViewItem
        if tab {
            let column = NSViewController()
            column.view = SettingsTabRail(search: search.field, rail: rail.view)
            side = NSSplitViewItem(viewController: column)
        } else {
            side = NSSplitViewItem(sidebarWithViewController: rail)
            side.addTopAlignedAccessoryViewController(search)
        }
        holder.view = pane
        side.canCollapse = false
        side.minimumThickness = SettingsSize.rail
        side.maximumThickness = SettingsSize.rail
        let content = NSSplitViewItem(viewController: holder)
        content.minimumThickness = SettingsSize.minimum.width - SettingsSize.rail
        content.titlebarSeparatorStyle = .none

        addSplitViewItem(side)
        addSplitViewItem(content)
        splitView.dividerStyle = .thin

        search.field.stringValue = shell.query
        search.field.target = self
        search.field.action = #selector(searched)
        rail.picked = { [weak self] page in
            guard let self else { return }
            shell.query = ""
            shell.go(to: page)
        }
        chrome.goBack = { [weak self] in _ = self?.shell.back() }
        chrome.goForward = { [weak self] in _ = self?.shell.forward() }
        bar.goBack = chrome.goBack
        bar.goForward = chrome.goForward
        page.litAt = { [weak self] frame in
            DispatchQueue.main.async { self?.paper.center(frame.midY) }
        }
        page.covered = { [weak self] point in self?.pane.covers(point) ?? false }
        page.pointed = { [weak self] in self?.mark() }
        watch()
        page.rebuild()
        refresh()
        if Store.settings.string(forKey: "settings.page") != shell.page.rawValue {
            Store.settings.set(shell.page.rawValue, forKey: "settings.page")
            browser.settingsMoved(to: shell.page)
        }
    }

    func hold(_ window: SettingsFrame) {
        window.title = shell.title
        window.back = { [weak self] in self?.shell.back() ?? false }
        window.forward = { [weak self] in self?.shell.forward() ?? false }
        window.up = { [weak self] in self?.shell.up() ?? false }
        window.find = { [weak window, weak self] in
            guard let field = self?.search.field else { return }
            window?.makeFirstResponder(field)
        }
    }

    func follow(_ asked: String?) { shell.follow(asked) }

    @objc private func searched() {
        guard shell.query != search.field.stringValue else { return }
        shell.query = search.field.stringValue
    }

    private func watch() {
        shown = shell.trail
        kitObserve(initial: false, { [weak self] in self?.shell.trail }) { [weak self] next in
            guard let self, let next else { return }
            turn(from: shown ?? next, to: next)
            shown = next
        }
        .store(in: &watching)
        kitObserve(initial: false, distinct: true, { [weak self] in self?.shell.query }) { [weak self] query in
            guard let self, let query else { return }
            if search.field.stringValue != query { search.field.stringValue = query }
            paper.rise()
        }
        .store(in: &watching)
        kitObserve(initial: false, { [weak self] in self?.browser.settingsAsked }) { [weak self] asked in
            guard let self, let asked else { return }
            shell.follow(asked.rawValue)
            DispatchQueue.main.async { [weak self] in self?.browser.settingsAsked = nil }
        }
        .store(in: &watching)
        kitObserve(initial: false, { [weak self] in self?.browser.settingsTyped }) { [weak self] typed in
            guard let self, let typed else { return }
            shell.query = typed
            DispatchQueue.main.async { [weak self] in self?.browser.settingsTyped = nil }
        }
        .store(in: &watching)
        kitObserve(initial: false, { [weak self] in self?.browser.settingsRule }) { [weak self] rule in
            guard let self, let rule else { return }
            DispatchQueue.main.async { [weak self] in self?.browser.settingsRule = nil }
            shell.openLinkRule(rule)
        }
        .store(in: &watching)
        kitObserve(initial: false, { [weak self] in self?.browser.settingsLanguages }) { [weak self] space in
            guard let self, let space else { return }
            DispatchQueue.main.async { [weak self] in self?.browser.settingsLanguages = nil }
            shell.openLanguages(space: space)
        }
        .store(in: &watching)
        kitObserve(initial: false, { [weak self] in self?.browser.settingsDrill }) { [weak self] drill in
            guard let self, let drill else { return }
            DispatchQueue.main.async { [weak self] in self?.browser.settingsDrill = nil }
            shell.drill(drill)
        }
        .store(in: &watching)
    }

    private func turn(from old: SettingsTrail, to next: SettingsTrail) {
        guard next.here != old.here else { return }
        if next.page != old.page {
            Store.settings.set(next.page.rawValue, forKey: "settings.page")
            browser.settingsMoved(to: next.page)
        }
        paper.rise()
    }

    private func refresh() {
        reads.track { refreshNow() }
    }

    var stage: SettingsStageFacts? {
        SettingsStageWords.facts(shell: shell, browser: browser, space: page.spaceID)
    }

    private func marked(_ facts: SettingsStageFacts) -> SettingsStageSpot? {
        guard let row = page.markedRow, let claim = SettingsStageMap.claim(row) else { return facts.rest }
        switch claim {
        case .spot(let spot): return spot
        case .rest: return facts.rest
        case .nowhere: return nil
        }
    }

    private func mark() {
        guard let facts = pane.band.facts, !pane.folded else { return }
        pane.band.mark(marked(facts))
    }

    func benchStage() -> [String: Any] {
        view.layoutSubtreeIfNeeded()
        let band = pane.band
        let tall = view.window?.frame.height ?? view.bounds.height
        func place(_ view: NSView, _ rect: NSRect? = nil) -> [Double] {
            let rect = view.convert(rect ?? view.bounds, to: nil)
            return [rect.minX, tall - rect.maxY, rect.width, rect.height].map { Double(($0 * 2).rounded() / 2) }
        }
        let names = page.cards.flatMap { card in card.rows.map { card.name(of: $0) ?? "" } }
        var reply: [String: Any] = [
            "folded": pane.folded, "compact": pane.compact, "height": Double(pane.room), "folds": pane.folds,
            "line": place(pane, pane.lineFrame), "lined": pane.lined,
            "titleBox": place(band.title),
            "rows": names, "pointed": page.markedRow ?? "", "marked": band.picture.marked?.rawValue ?? "",
            "moves": band.picture.moves, "picture": place(band.picture), "band": place(band), "well": place(pane, pane.wellFrame),
            "insetTop": Double(paper.contentInsets.top), "offset": Double(paper.contentView.bounds.minY),
            "heading": page.heading?.title.stringValue ?? "", "headingCrumb": page.heading.map { $0.crumb.isHidden ? "" : $0.crumb.stringValue } ?? "",
        ]
        if let ring = band.picture.ringFrame { reply["ring"] = place(band.picture, ring) }
        reply["pane"] = place(pane)
        if let row = page.markedRow.flatMap(page.named) { reply["row"] = place(row) }
        if let lit = shell.lit, let frame = page.frame(of: lit) { reply["lit"] = place(page, frame) }
        guard let facts = band.facts else { return reply }
        let scene = facts.scene
        reply["title"] = facts.title
        reply["summary"] = facts.summary
        reply["crumb"] = facts.crumb ?? ""
        reply["rest"] = facts.rest?.rawValue ?? ""
        reply["unclaimed"] = names.filter { SettingsStageMap.claim($0) == nil }
        reply["scene"] = [
            "right": scene.right, "card": scene.card, "sideButton": scene.sideButton, "stacked": scene.stacked.map { $0 ? "all" : "one" } ?? "none",
            "content": "\(scene.content)", "floating": scene.floating, "zoom": scene.zoom, "ads": "\(scene.ads)", "countdown": scene.countdown,
            "grouped": scene.grouped, "emoji": scene.emoji, "live": scene.live, "agents": scene.agents, "door": scene.door,
            "video": scene.video, "quality": scene.quality ?? "",
        ] as [String: Any]
        return reply
    }

    func benchPoint(_ row: String) -> Bool {
        guard !row.isEmpty else {
            page.point(at: nil)
            return true
        }
        view.layoutSubtreeIfNeeded()
        guard let found = page.named(row) else { return false }
        let clip = paper.contentView
        let frame = found.convert(found.bounds, to: page)
        let top = clip.bounds.minY + paper.contentInsets.top
        if frame.minY < top || frame.maxY > clip.bounds.maxY {
            let room = clip.bounds.height - paper.contentInsets.top
            let wanted = frame.midY - paper.contentInsets.top - room / 2
            let last = max(paper.top, page.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: min(max(wanted, paper.top), last)))
            paper.reflectScrolledClipView(clip)
        }
        return page.point(at: found.convert(NSPoint(x: found.bounds.midX, y: found.bounds.midY), to: nil)) == row
    }

    func benchFocus(_ row: String) -> Bool {
        guard let window = view.window else { return false }
        guard !row.isEmpty else { return window.makeFirstResponder(nil) }
        guard let found = page.named(row) else { return false }
        let before = KitFocus.keyboardAccess
        KitFocus.keyboardAccess = { true }
        defer { KitFocus.keyboardAccess = before }
        guard let taker = found.kitSubviews(of: NSView.self).first(where: { $0 !== found && $0.acceptsFirstResponder && !($0 is NSText) }) else {
            return false
        }
        return window.makeFirstResponder(taker)
    }

    private func refreshNow() {
        page.refresh()
        let facts = stage
        let here = shell.trail.here
        pane.show(facts, marked: facts.flatMap(marked), animated: view.window != nil && staged == here)
        staged = here
        chrome.update(canGoBack: shell.trail.canGoBack, canGoForward: shell.trail.canGoForward)
        bar.update(canGoBack: shell.trail.canGoBack, canGoForward: shell.trail.canGoForward)
        if !tab { view.window?.title = shell.title }
        rail.show(chosen: shell.searching ? nil : shell.page,
                  counts: shell.searching ? Dictionary(grouping: shell.hits, by: \.page).mapValues(\.count) : [:],
                  searching: shell.searching)
    }
}

final class SettingsTabRail: NSView {
    init(search: NSSearchField, rail: NSView) {
        super.init(frame: .zero)
        search.translatesAutoresizingMaskIntoConstraints = false
        rail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(search)
        addSubview(rail)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            search.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.trailingAnchor.constraint(equalTo: trailingAnchor),
            rail.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class SettingsTabBar: NSStackView {
    var goBack: (() -> Void)?
    var goForward: (() -> Void)?
    private let back = NSButton()
    private let forward = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal
        spacing = 12
        for (button, symbol, title, action) in [(back, "chevron.left", "Back", #selector(stepBack)),
                                                (forward, "chevron.right", "Forward", #selector(stepForward))] {
            button.image = KitGlyph.plain(symbol, label: title)
            button.imagePosition = .imageOnly
            button.bezelStyle = .texturedRounded
            button.toolTip = title
            button.target = self
            button.action = action
            button.setAccessibilityLabel(title)
        }
        let pair = NSStackView(views: [back, forward])
        pair.spacing = 4
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        addArrangedSubview(pair)
        addArrangedSubview(spacer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(canGoBack: Bool, canGoForward: Bool) {
        back.isEnabled = canGoBack
        forward.isEnabled = canGoForward
    }

    @objc private func stepBack() { goBack?() }
    @objc private func stepForward() { goForward?() }
}

@MainActor
final class SettingsTab: NSView {
    let split: SettingsSplit
    var asked: String? { didSet { if asked != oldValue { split.follow(asked) } } }

    init(browser: Browser, asked: String?) {
        self.asked = asked
        split = SettingsSplit(browser: browser, asked: asked, found: nil, tab: true)
        super.init(frame: .zero)
        let view = split.view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        identifier = NSUserInterfaceItemIdentifier("settings.tab")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func cancelOperation(_ sender: Any?) {
        if split.shell.up() { return }
        super.cancelOperation(sender)
    }
}
