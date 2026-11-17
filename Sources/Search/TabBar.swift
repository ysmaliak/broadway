import AppKit
import Combine

@MainActor
enum Rewind {
    static func menu(_ tab: Tab, back: Bool) -> NSMenu? {
        let pages = tab.pages(back: back)
        guard !pages.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for page in pages {
            let title = page.title.flatMap { $0.isEmpty ? nil : $0 } ?? page.url.host() ?? page.url.absoluteString
            let item = Pick(title: title) { [weak tab] in tab?.go(to: page) }
            item.toolTip = page.url.absoluteString
            if let image = Favicons.shared.cached(for: page.url, shy: tab.shy)?.copy() as? NSImage {
                image.size = NSSize(width: 16, height: 16)
                item.image = image
            } else {
                item.image = KitGlyph.plain("globe")
            }
            menu.addItem(item)
        }
        return menu
    }

    private final class Pick: NSMenuItem {
        private let run: () -> Void

        init(title: String, run: @escaping () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) { fatalError() }

        @objc private func fire() { run() }
    }
}

final class TabAddressFieldKeys: NSObject, NSTextFieldDelegate {
    var browser: Browser
    var claimed = false
    var typing = false
    private var deleting = false

    init(browser: Browser) { self.browser = browser }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        typing = true
        defer { typing = false }
        let text = field.stringValue
        let ending = browser.tabTyped(text)
        if !deleting, let ending, let editor = field.currentEditor() as? NSTextView {
            field.stringValue = text + ending
            editor.selectedRange = NSRange(location: (text as NSString).length, length: (ending as NSString).length)
        }
        deleting = false
        browser.tabDraft = field.stringValue
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy command: Selector
    ) -> Bool {
        switch command {
        case #selector(NSResponder.insertNewline(_:)):
            browser.commitTabEdit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            browser.cancelTabEdit()
            return true
        case #selector(NSResponder.moveDown(_:)) where !browser.tabOffers.isEmpty:
            browser.walkTab(1)
            return true
        case #selector(NSResponder.moveUp(_:)) where !browser.tabOffers.isEmpty:
            browser.walkTab(-1)
            return true
        case #selector(NSResponder.deleteBackward(_:)),
             #selector(NSResponder.deleteForward(_:)),
             #selector(NSResponder.deleteWordBackward(_:)),
             #selector(NSResponder.deleteWordForward(_:)),
             #selector(NSResponder.deleteToBeginningOfLine(_:)):
            deleting = true
            return false
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ note: Notification) {
        let browser = browser
        DispatchQueue.main.async { browser.finishTabEdit() }
    }

    private var watcher: Any?

    @MainActor func watch(_ field: NSTextField) {
        guard watcher == nil else { return }
        watcher = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak field] event in
            guard let self, let field, event.window === field.window,
                  !field.bounds.contains(field.convert(event.locationInWindow, from: nil))
            else { return event }
            let browser = self.browser
            DispatchQueue.main.async { browser.finishTabEdit() }
            return event
        }
    }

    @MainActor func unwatch() {
        if let watcher { NSEvent.removeMonitor(watcher) }
        watcher = nil
    }
}

enum HeldInput {
    static var source: () -> (buttons: Int, modifiers: NSEvent.ModifierFlags) = { (NSEvent.pressedMouseButtons, NSEvent.modifierFlags) }
    static var modifiers: NSEvent.ModifierFlags { source().modifiers }
}

final class RingView: NSView {
    private let ring = CAShapeLayer()
    private var leaving: Int?
    private var leaves = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = 1.4
        ring.lineCap = .round
        ring.strokeEnd = 0.78
        ring.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "strokeColor": NSNull(), "opacity": NSNull()]
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ on: Bool, animated: Bool) {
        if on {
            guard isHidden || leaving != nil else { return }
            let returning = leaving != nil
            stay()
            if isHidden { isHidden = false } else if returning { begin() }
            return
        }
        guard !isHidden else { return }
        if leaving != nil {
            if !animated { stay(); isHidden = true }
            return
        }
        guard animated, window != nil, let fade = Motion.kitQuick.animation("opacity", from: ring.presentation()?.opacity ?? ring.opacity, to: Swift.Float(0)) else {
            isHidden = true
            return
        }
        leaves += 1
        let token = leaves
        leaving = token
        ring.removeAnimation(forKey: "wait")
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.leaving == token else { return }
            self.stay()
            self.isHidden = true
        }
        ring.opacity = 0
        ring.add(fade, forKey: "leave")
        CATransaction.commit()
    }

    private func stay() {
        leaving = nil
        ring.removeAnimation(forKey: "leave")
        ring.opacity = 1
    }

    override func layout() {
        super.layout()
        let inset = ring.lineWidth / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.strokeColor = Palette.NS.muted.withAlphaComponent(0.7).cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
        if window == nil { end() } else if ring.animation(forKey: "turn") == nil { begin() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        end()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        begin()
    }

    private func begin() {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return end() }
        if ring.animation(forKey: "turn") == nil {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi
            turn.duration = 0.85
            turn.repeatCount = .infinity
            turn.isRemovedOnCompletion = false
            ring.add(turn, forKey: "turn")
        }
        ring.removeAnimation(forKey: "wait")
        guard !Motion.reduced else { return }
        let wait = CABasicAnimation(keyPath: "opacity")
        wait.fromValue = 0
        wait.toValue = 1
        wait.beginTime = CACurrentMediaTime() + 0.2
        wait.duration = 0.12
        wait.fillMode = .backwards
        ring.add(wait, forKey: "wait")
    }

    private func end() {
        if leaving != nil {
            stay()
            if !isHidden { isHidden = true }
        }
        ring.removeAnimation(forKey: "turn")
        ring.removeAnimation(forKey: "wait")
    }
}

final class PinFieldKeys: NSObject, NSTextFieldDelegate {
    var browser: Browser
    var tab: Tab
    var claimed = false
    var typing = false

    init(browser: Browser, tab: Tab) {
        self.browser = browser
        self.tab = tab
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        typing = true
        browser.letter(field.stringValue, for: tab)
        field.stringValue = tab.pin ?? ""
        typing = false
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy command: Selector
    ) -> Bool {
        switch command {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.cancelOperation(_:)),
             #selector(NSResponder.insertTab(_:)):
            browser.endPinEdit()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ note: Notification) {
        let browser = browser
        DispatchQueue.main.async { browser.endPinEdit() }
    }
}

@MainActor
enum TabMenuItems {
    static func menu(browser: Browser, tab: Tab, close: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items(browser: browser, tab: tab, close: close) { menu.addItem(item) }
        return menu
    }

    static func items(browser: Browser, tab: Tab, close: @escaping () -> Void) -> [NSMenuItem] {
        let chosen = browser.menuTabs(for: tab)
        var items: [NSMenuItem] = []
        if tab.agent {
            items.append(action("Keep Tab") { browser.keepAgentTab(tab) })
            items.append(.separator())
        }
        if chosen.count > 1 {
            items.append(action(tab.pin == nil ? "Pin \(chosen.count) Tabs" : "Unpin \(chosen.count) Tabs",
                                symbol: tab.pin == nil ? MenuSymbol.pin : MenuSymbol.unpin) { browser.togglePin(chosen, like: tab) })
        } else if let pair = browser.shownPinnedSplit(of: tab) {
            items.append(action("Unpin Split View", symbol: MenuSymbol.unpin) { browser.unpinSplit(pair) })
        } else if let pair = browser.split(for: tab), browser.canPinSplit(pair) {
            items.append(action("Pin Split View", symbol: MenuSymbol.pin) { browser.pinSplit(pair) })
        } else if tab.pin != nil {
            items.append(action("Unpin", symbol: MenuSymbol.unpin) { browser.unpin(tab) })
            if browser.pinMovedOff(tab) {
                items.append(action("Set Pinned Page to This Page") { browser.setPinnedPage(tab) })
                items.append(action("Go Back to Pinned Page") { browser.goBackToPinnedPage(tab) })
            }
            items.append(action("Edit Pinned Address…") { browser.editPinnedAddress(tab) })
        } else if tab.isWeb, !tab.shy {
            items.append(action("Pin", symbol: MenuSymbol.pin) { browser.pin(tab) })
        }
        items.append(action("Rename", symbol: MenuSymbol.rename) { browser.beginTabRename(tab) })
        if tab.isWeb, !tab.shy, !tab.bench {
            let kept = tab.address.map(browser.bookmarks.contains) == true
            items.append(action(kept ? "Edit Bookmark…" : "Add Bookmark", symbol: kept ? MenuSymbol.bookmarked : MenuSymbol.bookmark) {
                browser.select(tab)
                browser.bookmarkCurrent()
            })
        }
        items.append(action(tab.muted ? "Unmute Tab" : "Mute Tab", symbol: MenuSymbol.mute(tab.muted)) { tab.toggleMute() })
        items.append(.separator())
        items += split(browser, tab)
        if chosen.contains(where: \.isWeb) {
            let count = chosen.filter(\.isWeb).count
            items.append(submenu("Copy", symbol: MenuSymbol.copy, LinkCopy.Style.allCases.map { style in
                action(LinkCopy.title(style, count: max(count, 1)), enabled: count > 0) { browser.copyLinks(style, of: chosen) }
            }))
        }
        if let move = move(browser, tab, chosen) { items.append(move) }
        items.append(more(browser, tab, chosen))
        items.append(.separator())
        items += closing(browser, tab, close: close)
        return items
    }

    private static func picked(_ browser: Browser, _ tab: Tab) -> Int {
        browser.selectedTabIDs.contains(tab.id) ? browser.visibleSelectedTabCount : 1
    }

    private static func split(_ browser: Browser, _ tab: Tab) -> [NSMenuItem] {
        guard browser.prefs.splitView else { return [] }
        let count = picked(browser, tab)
        var items: [NSMenuItem] = []
        if count > 1 && !browser.pickedTabsArePaired {
            items.append(action("Open 2 Tabs in Split View", symbol: MenuSymbol.split, enabled: browser.pickedPair != nil) {
                browser.pairPickedTabs(focus: tab)
            })
        }
        if browser.split(for: tab) != nil {
            items.append(submenu("Split View", symbol: MenuSymbol.split, [
                action("Swap Pages") {
                    browser.focusPane(tab)
                    browser.swapSplit()
                },
                action("Separate Split Tabs") { browser.detachSplit(tab) },
            ]))
        } else if count == 1, !tab.bench {
            items.append(action("Open in Split View", symbol: MenuSymbol.split) { browser.openInSplit(tab) })
        }
        return items
    }

    private static func move(_ browser: Browser, _ tab: Tab, _ chosen: [Tab]) -> NSMenuItem? {
        let folders = browser.prefs.usesTabGroups && tab.pin == nil && !tab.shy && !tab.bench
        let spaces = browser.prefs.usesSpaces && !browser.isPrivate && !tab.bench && !tab.everywhere
            && tab.address.flatMap({ Browser.extensionHost(of: $0) }) == nil
        let others = Browsers.all.filter { $0 !== browser && $0.isOpen && !$0.isPopup && $0.isPrivate == browser.isPrivate }
        let alone = browser.tabs.count < 2
        let windows = tab.pin == nil && !tab.bench && !(others.isEmpty && alone)
        let route = tab.isWeb && !tab.shy && !tab.bench && !browser.isPrivate ? LinkRouter.site(of: tab.address) : nil
        let shared = tab.pin != nil && chosen.count == 1 && browser.prefs.showsSharedPins
        guard folders || spaces || windows || route != nil || shared else { return nil }
        var items: [NSMenuItem] = []
        if folders { items.append(folder(browser, tab, chosen)) }
        if spaces { items.append(space(browser, chosen)) }
        if windows {
            if others.isEmpty {
                items.append(action("New Window") { browser.moveToWindow(tab, nil) })
            } else {
                var list: [NSMenuItem] = []
                if !alone {
                    list.append(action("New Window") { browser.moveToWindow(tab, nil) })
                    list.append(.separator())
                }
                list += others.map { other in action(other.windowName) { browser.moveToWindow(tab, other) } }
                items.append(submenu("Window", list))
            }
        }
        if shared {
            items.append(action(tab.everywhere ? "Only in This Space" : "Keep in Every Space") {
                if let pair = browser.pinnedSplit(of: tab) {
                    browser.shareSplit(pair, everywhere: !tab.everywhere)
                } else if tab.everywhere {
                    browser.keepHere(tab)
                } else {
                    browser.shareEverywhere(tab)
                }
            })
        }
        if let route {
            items.append(.separator())
            items.append(routes(browser, route))
        }
        return submenu(chosen.count > 1 ? "Move \(chosen.count) Tabs" : "Move", symbol: MenuSymbol.move, items)
    }

    private static func folder(_ browser: Browser, _ tab: Tab, _ chosen: [Tab]) -> NSMenuItem {
        var items = [action("New Folder") { browser.addTabGroup(containing: tab) }]
        let picked = browser.selectedTabIDs.contains(tab.id) ? browser.tabs.filter { browser.selectedTabIDs.contains($0.id) } : []
        if picked.count > 1 {
            items.append(action("New Folder with \(picked.count) Tabs") { browser.newFolder(with: picked) })
        }
        if !browser.tabGroups.isEmpty { items.append(.separator()) }
        for group in browser.tabGroups.filter({ !$0.live }) {
            items.append(action(String(repeating: "    ", count: browser.folderDepth(group.id)) + group.name,
                                enabled: !chosen.allSatisfy { $0.groupID == group.id }) {
                browser.move(chosen, toGroup: group.id)
            })
        }
        if chosen.contains(where: { $0.groupID != nil }) {
            items.append(.separator())
            items.append(action("Remove from Folder") { browser.move(chosen, toGroup: nil) })
        }
        return submenu("Folder", items)
    }

    private static func space(_ browser: Browser, _ chosen: [Tab]) -> NSMenuItem {
        var items: [NSMenuItem] = browser.spaces.filter { $0.id != browser.spaceID }.map { space in
            let item = action(space.name) { browser.move(chosen, toSpace: space.id) }
            item.image = space.menuImage
            return item
        }
        if browser.spaces.count > 1 { items.append(.separator()) }
        items.append(action("New Space…", symbol: MenuSymbol.newSpace) {
            let going = chosen
            browser.askForSpace { space in
                browser.move(going, toSpace: space.id) {
                    browser.switchSpace(to: space.id)
                }
            }
        })
        let made = submenu("Space", items)
        made.toolTip = "Pages moved to a space with different accounts reopen there"
        return made
    }

    private static func routes(_ browser: Browser, _ site: String) -> NSMenuItem {
        let routes = LinkRules.shared
        func choice(_ title: String, _ target: LinkRule.Target) -> NSMenuItem {
            let on = routes.target(of: site) == target
            let item = action(title) {
                if on { routes.forget(site) } else { routes.always(site, to: target) }
            }
            item.state = on ? .on : .off
            return item
        }
        var items: [NSMenuItem] = []
        if browser.prefs.usesSpaces {
            items += browser.spaces.map { choice($0.name, .space($0.id, folder: nil)) }
            items.append(.separator())
        }
        items.append(choice("This Window", .window(browser.record.id)))
        items.append(choice("A New Window", .window(nil)))
        items.append(choice("A Peek", .peek))
        return submenu("Always Open \(site) In", items)
    }

    private static func more(_ browser: Browser, _ tab: Tab, _ chosen: [Tab]) -> NSMenuItem {
        var items: [NSMenuItem] = []
        if chosen.contains(where: \.isWeb) {
            items.append(action(chosen.count > 1 ? "Duplicate \(chosen.count) Tabs" : "Duplicate") { browser.duplicate(chosen) })
        }
        if tab.liveKey == nil, !tab.isBlank, !tab.bench {
            items.append(action("Change Icon…") { browser.iconPicker.pick(.tab(tab.id)) })
            if tab.customIcon != nil {
                items.append(action("Restore Site Icon") { browser.setIcon(nil, of: .tab(tab.id)) })
            }
        }
        if tab.pin != nil, chosen.count == 1 {
            items.append(action("Change Letter") { browser.editLetter(tab) })
        }
        if browser.prefs.liveFolders, tab.isWeb, !tab.shy, !tab.bench, tab.liveKey == nil {
            items.append(action(tab.pin == nil ? "Follow Site in a Folder" : "Live Folder from Site") { browser.followSite(tab) })
        }
        if browser.prefs.sitesInPanel, tab.isWeb, !tab.shy {
            items.append(action("Open in Side Panel") { browser.openInSidePanel(tab) })
        }
        if browser.awake(because: tab) == nil {
            items.append(action("Put to Sleep") {
                browser.sleep(tab) { outcome in
                    if outcome != "asleep" { browser.announce("Stays awake: \(outcome)") }
                }
            })
        }
        if !tab.isBlank, tab.address != nil, tab.pin == nil {
            items.append(.separator())
            items.append(action("Site Controls") {
                if browser.activeID != tab.id { browser.select(tab) }
                SiteCardPanel.toggle(browser)
            })
        }
        if let key = LocalServer.key(tab.pageAddress), !tab.shy {
            let on = Developer.shared.isOn(tab.pageAddress)
            items.append(action(on ? "Turn Off Developer Mode" : "Turn On Developer Mode") {
                browser.setDeveloperMode(!on, key: key)
            })
        }
        return submenu("More", items)
    }

    private static func closing(_ browser: Browser, _ tab: Tab, close: @escaping () -> Void) -> [NSMenuItem] {
        let count = picked(browser, tab)
        var items: [NSMenuItem] = []
        if count > 1 {
            items.append(action("Close \(count) Tabs", symbol: MenuSymbol.close) { browser.closePickedTabs() })
        } else if browser.putsAway(tab) {
            items.append(action("Put Away Tab", symbol: MenuSymbol.close, close))
            items.append(action(tab.liveKey == nil ? "Close Tab" : "Hide from Folder") { browser.close(tab) })
        } else if tab.liveKey != nil {
            items.append(action("Hide from Folder", symbol: MenuSymbol.close) { browser.close(tab) })
        } else {
            items.append(action("Close Tab", symbol: MenuSymbol.close, close))
        }
        if browser.prefs.splitView, count == 1, browser.split(for: tab) != nil {
            items.append(action("Close Both Pages") {
                browser.focusPane(tab)
                browser.closeSplit()
            })
        }
        if browser.tabs.count > 1 {
            items.append(action("Close Other Tabs") { browser.closeOthers(but: tab) })
        }
        if !browser.tabsAbove(tab).isEmpty {
            items.append(action("Close Tabs Above") { browser.closeTabsAbove(tab) })
        }
        if !browser.tabsBelow(tab).isEmpty {
            items.append(action("Close Tabs Below") { browser.closeTabsBelow(tab) })
        }
        if !browser.ghosts.isEmpty {
            items.append(action(browser.reopenTitle) { browser.reopen() })
        }
        return items
    }

    private static func action(_ title: String, symbol: String? = nil, enabled: Bool = true, _ run: @escaping () -> Void) -> NSMenuItem {
        KitMenu.item(.action(title, symbol: symbol, enabled: enabled, run: run))
    }

    private static func submenu(_ title: String, symbol: String? = nil, _ items: [NSMenuItem]) -> NSMenuItem {
        let made = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { made.image = KitGlyph.plain(symbol) }
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        for item in items { menu.addItem(item) }
        made.submenu = menu
        return made
    }
}
