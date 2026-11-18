import AppKit
import Combine

final class HelmView: NSView {
    let browser: Browser
    var greys = KitGreys.white { didSet { if greys != oldValue { paint() } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { paint() } } }
    private let side = DoorView(icon: "sidebar.left", help: "Hide Sidebar   ⌘S", act: {})
    private let back = DoorView(icon: "arrow.left", help: "Back   ⌘[", act: {})
    private let forward = DoorView(icon: "arrow.right", help: "Forward   ⌘]", act: {})
    private let reload = ReloadDoorView(size: 15, loading: false, reloads: 0, stops: 0)
    private lazy var reads = KitReads { [weak self] in self?.later() }
    private weak var tab: Tab?
    private var kicks = Tab.Kicks()
    private var lit: [ObjectIdentifier: Bool] = [:]
    private var queued = false
    private var button: Bool?

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        for door in [side, back, forward] {
            door.size = 15
            door.box = 30
            door.wantsLayer = true
            addSubview(door)
        }
        side.act = { [weak browser] in browser?.toggleFold() }
        reload.wantsLayer = true
        addSubview(reload)
        back.act = { [weak browser] in browser?.back() }
        forward.act = { [weak browser] in browser?.forward() }
        reload.reload = { [weak browser] in browser?.reload() }
        reload.stop = { [weak self] in self?.tab?.stop() }
        update(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func later() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            queued = false
            update(animated: true)
        }
    }

    private func update(animated: Bool) {
        reads.track { refresh(animated: animated) }
    }

    private func refresh(animated: Bool) {
        let shows = browser.prefs.sideButton
        if shows != button {
            button = shows
            needsLayout = true
        }
        let now = browser.shownTab
        if now !== tab {
            tab = now
            if let now {
                kicks = now.kicks
                reload.adopt(loading: now.loading, reloads: now.kicks.reload, stops: now.kicks.stop)
            }
        }
        guard let tab else {
            set(back, on: false, animated: animated)
            set(forward, on: false, animated: animated)
            set(reload, on: false, animated: animated)
            back.held = nil
            forward.held = nil
            reload.allowed = false
            return
        }
        let backOn = !tab.isBlank && browser.backGoes(tab)
        let forwardOn = !tab.isBlank && tab.canGoForward
        set(back, on: backOn, animated: animated)
        set(forward, on: forwardOn, animated: animated)
        set(reload, on: tab.isWeb, animated: false)
        back.held = { [weak tab] in tab.flatMap { Rewind.menu($0, back: true) } }
        forward.held = { [weak tab] in tab.flatMap { Rewind.menu($0, back: false) } }
        reload.allowed = tab.isWeb
        reload.see(loading: tab.loading, reloads: tab.kicks.reload, stops: tab.kicks.stop)
        if tab.kicks.back != kicks.back { nudge(back, by: -3.5) }
        if tab.kicks.forward != kicks.forward { nudge(forward, by: 3.5) }
        kicks = tab.kicks
    }

    private func set(_ door: NSView, on: Bool, animated: Bool) {
        let key = ObjectIdentifier(door)
        guard lit[key] != on else { return }
        lit[key] = on
        door.alphaValue = on ? 1 : 0.3
        door.layer?.kitAnimate("opacity", to: Swift.Float(on ? 1 : 0.3), curve: animated ? Motion.kitQuick : .none, key: "lit")
    }

    private func nudge(_ door: DoorView, by reach: CGFloat) {
        guard !Motion.reduced, let symbol = door.subviews.first(where: { $0 is KitSymbol }), let layer = symbol.layer else { return }
        let move = CAKeyframeAnimation(keyPath: "transform.translation.x")
        move.values = [0, reach, 0]
        move.keyTimes = [0, 0.3, 1]
        move.duration = 0.23
        move.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        move.isAdditive = true
        layer.add(move, forKey: "kick")
    }

    static var tintCurve: KitCurve { Motion.reduced ? .none : .easeOut(0.22) }

    private func paint() {
        if window != nil { layer?.kitTransition(Self.tintCurve) }
        for door in [side, back, forward] {
            door.greys = greys
            door.ink = ink
        }
        reload.greys = greys
        reload.ink = ink
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit, hit !== self else { return nil }
        for door in [back, forward, reload] as [NSView] where hit === door || hit.isDescendant(of: door) {
            return lit[ObjectIdentifier(door)] == true ? hit : nil
        }
        return hit
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard reload.frame.contains(point), let tab, !tab.loading, tab.isWeb else { return nil }
        let browser = browser
        let menu = KitMenu.make([
            .action("Reload Page", run: { browser.reload() }),
            .action("Reload Page From Origin", run: { browser.reload(fromOrigin: true) }),
        ])
        for (item, id) in zip(menu.items, ["view.reload", "view.reloadOrigin"]) {
            if let key = ShortcutStore.shared.key(for: id)?.menuKey {
                item.keyEquivalent = key.key
                item.keyEquivalentModifierMask = key.mask
            }
        }
        return menu
    }

    override func layout() {
        super.layout()
        let box: CGFloat = 30
        let gap: CGFloat = 4
        var x = bounds.width
        let y = ((bounds.height - box) / 2).rounded()
        for door in [reload, forward, back] as [NSView] {
            x -= box
            door.frame = NSRect(x: x, y: y, width: box, height: box)
            x -= gap
        }
        side.isHidden = !browser.prefs.sideButton || x - box < 0
        side.frame = NSRect(x: x - box, y: y, width: box, height: box)
        side.icon = browser.prefs.sidePosition == .right ? "sidebar.right" : "sidebar.left"
    }
}

final class SplitSignView: NSView, SideGrounded {
    let browser: Browser
    private(set) var left: Tab
    private(set) var right: Tab
    let height: CGFloat
    var ground = RowGround() { didSet { if ground != oldValue { refresh() } } }
    let item: SplitTabItemView
    let interactive: Bool
    weak var host: TabRowHost?
    private var catches: [Tab.ID: SplitChipCatch] = [:]
    private lazy var reads = KitReads { [weak self] in self?.later() }
    private var queued = false

    init(browser: Browser, left: Tab, right: Tab, height: CGFloat, interactive: Bool = true) {
        self.browser = browser
        self.left = left
        self.right = right
        self.height = height
        self.interactive = interactive
        item = SplitTabItemView(browser: browser, left: left, right: right)
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: height))
        for tab in interactive ? [left, right] : [] {
            let made = SplitChipCatch(browser: browser, tab: tab)
            made.sign = self
            catches[tab.id] = made
            addSubview(made)
        }
        addSubview(item)
        item.onChips = { [weak self] rects in self?.place(rects) }
        reads.track { refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func later() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            queued = false
            reads.track { self.refresh() }
        }
    }

    private func refresh() {
        let active = browser.activeID
        let live = active.map { [left.id, right.id].contains($0) } ?? false
        item.update(left: left, right: right,
                    setup: .init(height: height, live: live, focusedID: active, interactive: interactive,
                                 onFrame: ground.greys.onFrame, ink: ground.ink, greys: ground.greys, numbers: browser.tabShortcutNumbers))
        for (id, chip) in catches {
            chip.focused = live && active == id
            chip.editing = browser.editingTab == id
        }
    }

    private func place(_ rects: [Tab.ID: CGRect]) {
        for (id, chip) in catches {
            if let rect = rects[id] {
                chip.isHidden = false
                chip.frame = rect
            } else {
                chip.isHidden = true
            }
        }
    }

    override func layout() {
        super.layout()
        item.frame = bounds
    }
}

final class SplitChipCatch: NSView {
    let browser: Browser
    let tab: Tab
    weak var sign: SplitSignView?
    var focused = false
    var editing = false
    private var selectedOnPress = false
    private var down = false

    init(browser: Browser, tab: Tab) {
        self.browser = browser
        self.tab = tab
        super.init(frame: .zero)
        setAccessibilityElement(false)
        toolTip = tab.label.isEmpty ? "New Tab" : tab.label
        if Store.testing { Bench.rowPress(tab.id) { _ in } }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewWillDraw() {
        super.viewWillDraw()
        let said = tab.label.isEmpty ? "New Tab" : tab.label
        if toolTip != said { toolTip = said }
    }

    override func mouseDown(with event: NSEvent) {
        if let sign, sign.host?.rowPressed(sign, event: event) == true { return }
        down = true
        selectedOnPress = false
        guard !editing, event.modifierFlags.intersection([.command, .control, .shift]).isEmpty else { return }
        selectedOnPress = !focused
        TabPress.brought = !focused
        if selectedOnPress {
            browser.clearTabSelection()
            browser.focusPane(tab)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !editing, let sign else { return }
        sign.host?.rowDragged(sign, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let sign, sign.host?.rowReleased(sign, event: event) == true {
            down = false
            selectedOnPress = false
            return
        }
        guard down else { return }
        down = false
        defer { selectedOnPress = false }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        let mods = event.modifierFlags
        if !mods.intersection([.command, .shift]).isEmpty {
            if !editing { browser.extendTabSelection(to: tab, modifiers: mods) }
            return
        }
        guard !selectedOnPress else { return }
        browser.clearTabSelection()
        if focused { browser.beginTabEdit(tab) } else { browser.focusPane(tab) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let tab = tab
        return TabMenuItems.menu(browser: browser, tab: tab, close: { [weak browser] in browser?.closeTab(tab) })
    }
}

final class SiteControlsAnchorView: NSView {
    init(browser: Browser) {
        super.init(frame: .zero)
        SiteCardPanel.register(self, for: browser)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class BookmarksAnchorView: NSView {
    let browser: Browser
    var edge: NSRectEdge = .maxX
    private var watch: AnyCancellable?
    private var popup: KitPopup?
    private var shown: NSMenu?
    private var carded: Bookmark.ID?

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        watch = kitObserve(initial: false, { [weak browser] in (browser?.bookmarksOpen, browser?.bookmarkCard) }) { [weak self] _ in self?.follow() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        follow()
    }

    private func follow() {
        let open = browser.bookmarksOpen && window != nil && !isHiddenOrHasHiddenAncestor
        let card = open ? browser.bookmarkCard : nil
        if card == nil || !open, let going = popup {
            popup = nil
            going.close(animated: !open)
        }
        if card != nil || !open, let going = shown {
            shown = nil
            going.cancelTracking()
        }
        guard open else { return }
        if card != nil {
            if popup == nil || carded != card {
                let going = popup
                popup = nil
                going?.close(animated: false)
                showCard()
            }
        } else if shown == nil {
            showList()
        }
    }

    private func showCard() {
        guard let id = browser.bookmarkCard else { return }
        carded = id
        let card = BookmarkCardView(browser: browser, bookmarks: browser.bookmarks, id: id)
        let size = NSSize(width: BookmarkCardView.width, height: card.intrinsicContentSize.height)
        popup = KitPopup.show(card, size: size, from: bounds, of: self, edge: .auto, focus: true, bleeds: true) { [weak self] in
            guard let self, self.popup != nil else { return }
            self.popup = nil
            if self.browser.bookmarksOpen { self.browser.bookmarksOpen = false }
        }
    }

    private func showList() {
        carded = nil
        let made = BookmarksDropdown(browser: browser, bookmarks: browser.bookmarks)
        shown = made.menu
        RunLoop.main.perform(inModes: [.default, .common]) { [weak self] in
            guard let self, self.shown === made.menu, self.window != nil else {
                if let self, self.shown === made.menu {
                    self.shown = nil
                    self.letGo()
                }
                return
            }
            KitMenu.popUp(made.menu, from: self.bounds, of: self)
            guard self.shown === made.menu else { return }
            self.shown = nil
            self.letGo()
        }
    }

    private func letGo() {
        if browser.bookmarksOpen, browser.bookmarkCard == nil { browser.bookmarksOpen = false } else { follow() }
    }
}

@MainActor
enum FolderMenus {
    static func menu(browser: Browser, group: TabGroup) -> NSMenu {
        let menu = KitMenu.make(group.live ? live(browser, group.id) : folder(browser, group))
        let others = browser.spaces.filter { $0.id != browser.spaceID }
        if !group.live, let move = menu.items.first(where: { $0.title == "Move" })?.submenu,
           let space = move.items.first(where: { $0.title == "Space" })?.submenu {
            for (item, other) in zip(space.items, others) { item.image = other.menuImage }
        }
        return menu
    }

    private static func folder(_ browser: Browser, _ group: TabGroup) -> [KitMenuItem] {
        var items: [KitMenuItem] = [
            .action(group.collapsed ? "Open Folder" : "Shut Folder", run: { browser.toggleTabGroup(group.id) }),
            .action("Rename Folder", symbol: MenuSymbol.rename, run: { browser.editingGroupID = group.id }),
        ]
        if group.parent == nil {
            items.append(.action(group.pinned ? "Unpin Folder" : "Pin Folder", symbol: group.pinned ? MenuSymbol.unpin : MenuSymbol.pin,
                                 run: { browser.setFolderPinned(group.id, !group.pinned) }))
        }
        items.append(.separator)
        items.append(.action("New Tab in Folder", symbol: MenuSymbol.newTab, run: { browser.newTabInFolder(group.id) }))
        if FolderTree.canAddChild(to: group.id, groups: browser.tabGroups) {
            items.append(.action("New Folder Inside", symbol: MenuSymbol.newFolder, run: { browser.newFolder(inside: group.id) }))
            let picked = browser.selectedTabIDs.count
            if picked > 1 {
                items.append(.action("New Folder with \(picked) Tabs", run: {
                    browser.newFolder(with: browser.tabs.filter { browser.selectedTabIDs.contains($0.id) }, inside: group.id)
                }))
            }
        }
        let links = browser.folderTabs(group.id).filter(\.isWeb).count
        if links > 0 {
            items.append(.submenu("Copy Links", symbol: MenuSymbol.copy, LinkCopy.Style.allCases.map { style in
                .action(LinkCopy.title(style, count: links), run: { browser.copyFolderLinks(group.id, as: style) })
            }))
        }
        let spaces = browser.showsSpaces && browser.spaces.count > 1
        if spaces || group.parent != nil {
            var moves: [KitMenuItem] = []
            if spaces {
                moves.append(.submenu("Space", browser.spaces.filter { $0.id != browser.spaceID }.map { space in
                    .action(space.name, run: { browser.move(group: group.id, toSpace: space.id) })
                }))
            }
            if group.parent != nil {
                moves.append(.action("Out of Folder", run: {
                    let above = browser.tabGroups.first { $0.id == group.parent }?.parent
                    browser.nest(group.id, in: above, before: group.parent)
                }))
            }
            items.append(.submenu("Move", symbol: MenuSymbol.move, moves))
        }
        var more: [KitMenuItem] = [.action("Change Icon…", run: { browser.iconPicker.pick(.folder(group.id)) })]
        if group.icon != nil {
            more.append(.action("Restore Folder Icon", run: { browser.setIcon(nil, of: .folder(group.id)) }))
        }
        if browser.tabGroups.contains(where: { $0.parent == group.id }) {
            more.append(.action("Open or Shut All Inside", run: { browser.toggleFolderWhole(group.id) }))
        }
        more.append(.action("Put Tabs to Sleep", run: { browser.sleepFolder(group.id) }))
        items.append(.submenu("More", more))
        items.append(.separator)
        items.append(.action(group.query == nil ? "Remove Folder, Keep Tabs" : "Ungroup", run: { browser.removeTabGroup(group.id) }))
        items.append(.action("Close Folder and Tabs", symbol: MenuSymbol.close, run: { browser.closeTabGroupAsking(group.id) }))
        return items
    }

    private static func live(_ browser: Browser, _ id: UUID) -> [KitMenuItem] {
        let live = LiveFolders.shared
        guard let folder = live.folder(id) else { return [] }
        var items: [KitMenuItem] = LiveQuiet.detail(folder, reading: live.reading.contains(id), now: Date(), online: live.online).map { .header($0) } + [
            .action("Update Now", symbol: MenuSymbol.reload, enabled: !live.reading.contains(id), run: { live.update(id, asked: true) }),
            .action(folder.paused ? "Start Updating" : "Stop Updating", run: { live.pause(id, !folder.paused) }),
        ]
        if folder.state == .signIn {
            items.append(.action(folder.sso == nil ? "Sign In" : "Single Sign-On", run: { browser.signInToLive(id) }))
        }
        if let lists = folder.source.pullLists {
            items.append(.submenu("Lists", PullList.allCases.map { list in
                let on = lists.contains(list)
                return .action(list.title, on: on, enabled: lists != [list], run: {
                    live.setLists(id, on ? lists.filter { $0 != list } : lists + [list])
                })
            }))
        }
        if let statuses = folder.source.linearStatuses {
            items.append(.submenu("Statuses", LinearStatus.allCases.map { status in
                let on = statuses.contains(status)
                return .action(status.title, on: on, enabled: statuses != [status], run: {
                    live.setStatuses(id, on ? statuses.filter { $0 != status } : statuses + [status])
                })
            }))
        }
        if folder.source.kind == .repository {
            items.append(.submenu("Pull Requests", LiveRange.allCases.map { range in
                .action(range.title, enabled: folder.source.range != range, run: { live.setRange(id, range) })
            }))
        }
        items.append(.action("Open Source", run: { browser.openLiveSource(id) }))
        if folder.hiddenInFeed > 0 {
            items.append(.action("Show \(folder.hiddenInFeed) Hidden", run: { live.showHidden(id) }))
        }
        if folder.order != nil {
            items.append(.action("Restore Automatic Order", run: { live.setOrder(id, nil) }))
        }
        items.append(.separator)
        items.append(.action("Rename Folder", symbol: MenuSymbol.rename, run: { browser.editingGroupID = id }))
        items.append(.action("Change Icon…", run: { browser.iconPicker.pick(.folder(id)) }))
        if browser.tabGroups.first(where: { $0.id == id })?.icon != nil {
            items.append(.action("Restore Folder Icon", run: { browser.setIcon(nil, of: .folder(id)) }))
        }
        items.append(.separator)
        items.append(.action("Remove Folder", symbol: MenuSymbol.close, run: { live.remove(id) }))
        return items
    }
}

extension TabPageView {
    static func peek(_ tab: Tab) -> TabPageView {
        let view = TabPageView(tab: tab, browser: nil)
        view.update(.init(holdsPage: false), tab: tab, browser: nil)
        return view
    }
}
