import AppKit
import Combine

@main
enum BroadwayApp {
    private static let links = Links()

    static func main() {
        MainActor.assumeIsolated {
            AgentCatalog.printIfAsked()
            _ = Web.pool
            _ = Onboarding.launchedFresh
            if Store.settings.bool(forKey: Preferences.freshKey) {
                Session.startFresh(spaces: Spaces.read().map(\.id))
                Browsers.startFresh()
            }
            SignInKeeper.shared.launch(keeping: Spaces.read())
            let app = NSApplication.shared
            NSWindow.allowsAutomaticWindowTabbing = false
            app.delegate = links
            _ = Front.shared
            MenuBar.install()
            SceneWindow.watchLaunch()
        }
        NSApplication.shared.run()
    }
}

@MainActor
enum SceneWindow {
    private(set) static var window: NSWindow?
    private static weak var holds: Browser?
    private static var slotWatch: AnyCancellable?
    private static var launch: Any?

    static func watchLaunch() {
        launch = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                open()
                MenuBar.refreshAll()
                Updates.shared.start()
                Handoff.start()
            }
        }
    }

    static func untitled() {
        let scene = SceneSlot.shared.browser
        if scene.window == nil, Browsers.all.contains(where: { $0 !== scene && $0.isOpen && !$0.keepsNothing }) { return }
        open()
    }

    static func open() {
        let browser = SceneSlot.shared.browser
        if let window, holds === browser {
            reveal(window)
            return
        }
        let made = build(browser)
        Onboarding.shared.stage = OnboardingShow.shared
        if Onboarding.shared.arrive(in: browser), OnboardingShow.shared.window?.isVisible == true { OnboardingShow.shared.hold(made) }
        reveal(made)
        DispatchQueue.main.async { Browsers.restoreOnce() }
    }

    private static func build(_ browser: Browser) -> NSWindow {
        window?.setFrameAutosaveName("")
        let made = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 1180, height: 780)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        made.title = "Broadway"
        made.isReleasedWhenClosed = false
        made.delegate = LeaveWindows.shared
        made.tabbingMode = .disallowed
        made.titlebarAppearsTransparent = true
        made.titleVisibility = .hidden
        made.contentMinSize = NSSize(width: 640, height: 420)
        if !made.setFrameUsingName(Browsers.sceneID) { made.center() }
        made.setFrameAutosaveName(Browsers.sceneID)
        made.contentView = ContentView(browser: browser)
        window = made
        holds = browser
        watchSlot()
        return made
    }

    private static func reveal(_ window: NSWindow) {
        guard !OnboardingShow.shared.keeps(window) else { return }
        Bench.keepOff(window)
        window.makeKeyAndOrderFront(nil)
    }

    static func show(_ window: NSWindow, below other: NSWindow? = nil) {
        Bench.keepOff(window)
        if let other { window.order(.below, relativeTo: other.windowNumber) } else { window.makeKeyAndOrderFront(nil) }
    }

    private static func watchSlot() {
        guard slotWatch == nil else { return }
        slotWatch = kitObserve(initial: false, { SceneSlot.shared.browser }) { _ in release() }
    }

    private static func release() {
        guard let window, holds !== SceneSlot.shared.browser, !window.isVisible else { return }
        window.setFrameAutosaveName("")
        self.window = nil
        holds = nil
    }
}

@MainActor
final class MenuCommand: NSMenuItem, NSMenuItemValidation {
    var run: (() -> Void)?
    var allowed = true { didSet { isEnabled = allowed } }

    @objc func fire(_ sender: Any?) { run?() }

    override func copy(with zone: NSZone? = nil) -> Any {
        let made = MenuCommand(title: title, action: action, keyEquivalent: keyEquivalent)
        made.target = made
        made.run = run
        made.allowed = allowed
        made.state = state
        made.tag = tag
        made.image = image
        made.keyEquivalentModifierMask = keyEquivalentModifierMask
        made.isEnabled = isEnabled
        made.submenu = submenu?.copy() as? NSMenu
        return made
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { (menuItem as? MenuCommand)?.allowed ?? allowed }
}

@MainActor
final class MenuFill: NSObject, NSMenuDelegate {
    let start: Int
    let fill: () -> [NSMenuItem]

    init(_ start: Int, _ fill: @escaping () -> [NSMenuItem]) {
        self.start = start
        self.fill = fill
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        MenuBar.refill(menu, at: start, fill())
    }
}

extension KeyCombo {
    var menuKey: (key: String, mask: NSEvent.ModifierFlags)? {
        let character: String
        switch key {
        case "left": character = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case "right": character = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case "up": character = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case "down": character = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case "return": character = "\r"
        case "delete": character = "\u{8}"
        case "space": character = " "
        default:
            if isFunctionKey, let n = Int(key.dropFirst()), let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
                character = String(Character(scalar))
            } else if key.count == 1 {
                character = key
            } else {
                return nil
            }
        }
        var mask: NSEvent.ModifierFlags = []
        if command { mask.insert(.command) }
        if shift { mask.insert(.shift) }
        if option { mask.insert(.option) }
        if control { mask.insert(.control) }
        return (character, mask)
    }
}

@MainActor
enum MenuBar {
    static let tag = 0x4D42
    private static var fills: [(menu: NSMenu, fill: MenuFill)] = []
    private static var shortcutWatch: AnyCancellable?

    private static var current: Browser { Front.shared.browser ?? SceneSlot.shared.browser }

    static func install() {
        let bar = NSMenu(title: "Main Menu")
        bar.addItem(top(appMenu()))
        bar.addItem(top(dynamic("File", file)))
        bar.addItem(top(editMenu()))
        bar.addItem(top(dynamic("View", view)))
        bar.addItem(top(dynamic("Tabs", tabs, auto: false)))
        bar.addItem(top(dynamic("Bookmarks", bookmarks, auto: false)))
        bar.addItem(top(dynamic("History", history, auto: false)))
        let window = windowMenu()
        bar.addItem(top(window))
        let help = helpMenu()
        bar.addItem(top(help))
        NSApp.mainMenu = bar
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        shortcutWatch = kitObserve(initial: false, { (ShortcutStore.shared.recording, ShortcutStore.shared.anyChanged) }) { _ in refreshAll() }
    }

    static func refreshAll() {
        for (menu, fill) in fills { refill(menu, at: fill.start, fill.fill()) }
    }

    static func refill(_ menu: NSMenu, at start: Int, _ items: [NSMenuItem]) {
        let at = menu.items.firstIndex { $0.tag == tag } ?? min(start, menu.items.count)
        for item in menu.items where item.tag == tag { menu.removeItem(item) }
        for (n, item) in items.enumerated() {
            item.tag = tag
            menu.insertItem(item, at: min(at + n, menu.items.count))
        }
    }

    private static func top(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func dynamic(_ title: String, _ fill: @escaping () -> [NSMenuItem], auto: Bool = true) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = auto
        attach(menu, fill)
        return menu
    }

    private static func attach(_ menu: NSMenu, at start: Int = 0, _ fill: @escaping () -> [NSMenuItem]) {
        let delegate = MenuFill(start, fill)
        fills.append((menu, delegate))
        menu.delegate = delegate
    }

    private static func command(_ title: String, key id: String? = nil, enabled: Bool = true, on: Bool = false,
                                _ run: @escaping () -> Void) -> NSMenuItem {
        let item = MenuCommand(title: title, action: #selector(MenuCommand.fire(_:)), keyEquivalent: "")
        item.target = item
        item.run = {
            if let id { current.hints.used(id) }
            run()
        }
        item.allowed = enabled
        item.state = on ? .on : .off
        if let id, let key = ShortcutStore.shared.key(for: id)?.menuKey {
            item.keyEquivalent = key.key
            item.keyEquivalentModifierMask = key.mask
        }
        return item
    }

    private static func act(_ title: String, key id: String? = nil, enabled: Bool = true, on: Bool = false,
                            _ run: @escaping (Browser) -> Void) -> NSMenuItem {
        command(title, key: id, enabled: enabled, on: on) { run(current) }
    }

    private static func standard(_ title: String, _ action: Selector, _ key: String = "",
                                 _ mask: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mask
        return item
    }

    private static func submenu(_ title: String, enabled: Bool = true, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        for item in items {
            if !enabled { item.isEnabled = false; (item as? MenuCommand)?.allowed = false }
            menu.addItem(item)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        item.isEnabled = enabled
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Broadway")
        menu.addItem(command("About Broadway") { AboutWindow.show() })
        menu.addItem(Updates.shared.installItem())
        let updates = Updates.shared.menuItem()
        if let updates { menu.addItem(updates) }
        menu.addItem(.separator())
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(standard("Hide Broadway", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(standard("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(standard("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        let quit = command("Quit Broadway") { if Links.shouldQuit() { NSApp.terminate(nil) } }
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
        attach(menu, at: updates == nil ? 3 : 4) {
            [
                act("Settings…", key: "app.settings") { $0.tuning = true },
                act("Passwords", key: "app.passwords") { $0.managing = true },
                act("Warn Before Quitting", on: current.prefs.confirmsQuit) { $0.prefs.confirmsQuit.toggle() },
                act("Open at Login", on: OpenAtLogin.on) { OpenAtLogin.toggle(in: $0) },
            ]
        }
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(standard("Undo", Selector(("undo:")), "z"))
        menu.addItem(standard("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(standard("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(standard("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(standard("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(standard("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        menu.addItem(standard("Delete", #selector(NSText.delete(_:))))
        menu.addItem(standard("Select All", #selector(NSText.selectAll(_:)), "a"))
        attach(menu, at: menu.items.count, edit)
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(standard("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(standard("Zoom", #selector(NSWindow.performZoom(_:))))
        attach(menu, at: menu.items.count, windowRows)
        return menu
    }

    private static func windowRows() -> [NSMenuItem] {
        [
            act("Keep Window on Top", key: "window.keepOnTop", enabled: KeepOnTop.allowed(current), on: KeepOnTop.isOn(current)) { KeepOnTop.toggle($0) },
            .separator(),
            command("Broadway") { SceneWindow.open() },
            .separator(),
            standard("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
            act("Merge All Windows", key: "window.mergeAll", enabled: WindowMerge.canMerge(into: current)) { WindowMerge.run(into: $0) },
        ]
    }

    static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(command("Show Welcome Again") { Onboarding.replay() })
        menu.addItem(command("Contact Support") { Support.write { current.announce($0) } })
        menu.addItem(.separator())
        menu.addItem(act("Broadway on GitHub") { Support.showSource(in: $0) })
        let freeze = command("Copy Last Freeze", enabled: FreezeBook.shared.latest != nil) {
            Freezes.copyLast { current.announce($0) }
        }
        menu.addItem(freeze)
        FreezeMenuWatch.shared.item = freeze as? MenuCommand
        menu.delegate = FreezeMenuWatch.shared
        return menu
    }

    private static func file() -> [NSMenuItem] {
        let browser = current
        let web = browser.active?.isWeb ?? false
        var items: [NSMenuItem] = [
            command("New Window", key: "file.newWindow") { Browsers.newWindow() },
            act("New Tab", key: "file.newTab") { $0.launch() },
            command("New Private Window", key: "file.newPrivateWindow") { Browsers.newPrivateWindow() },
            act(browser.reopenTitle, key: "file.reopen", enabled: !(browser.ghosts.isEmpty && Browsers.lastClosedAt == nil)) { $0.reopen() },
            .separator(),
            act("Open Address…", key: "file.openAddress") { $0.edit() },
            .separator(),
            act("Bring Things Over", key: "file.import") { $0.bringingIn = "" },
            .separator(),
        ]
        if Front.shared.browserKey {
            items.append(command("Close Tab", key: "file.closeTab") { Browsers.closeKey(tab: true) })
            items.append(command("Close Window", key: "file.closeWindow") { Browsers.closeKey(tab: false) })
        } else {
            items.append(command("Close Window", key: "file.closeTab") { Browsers.closeKey(tab: true) })
        }
        items += [
            .separator(),
            act("Share…", key: "file.share", enabled: web) { $0.share() },
            act("Save Page As…", key: "file.savePage", enabled: web) { $0.savePage() },
            act("Export as PDF…", key: "file.exportPDF", enabled: web) { $0.exportPDF() },
            act("Print…", key: "file.print", enabled: web) { $0.printPage() },
        ]
        return items
    }

    private static func edit() -> [NSMenuItem] {
        let browser = current
        let web = browser.active?.isWeb ?? false
        let substitutions = [command("Show Substitutions") { Substitution.showPanel() }, .separator()]
            + Substitution.allCases.map { kind in
                act(kind.title, on: browser.substitutes(kind)) { $0.toggleSubstitution(kind) }
            }
        return [
            .separator(),
            act("Copy for Agent", key: "edit.copyForAgent") { $0.copyForAgent() },
            act("Copy Page as Markdown", key: "edit.copyPageMarkdown", enabled: web) { $0.copyPageAsMarkdown() },
            act(LinkCopy.title(.clean, count: browser.keyTabs.filter(\.isWeb).count), key: "edit.copyCleanLink",
                enabled: !(browser.active?.isBlank ?? true)) { $0.copyCleanLink() },
            act("Copy Link to Highlight", key: "edit.copyLinkToHighlight", enabled: browser.canCopyLinkToHighlight) { $0.copyLinkToHighlight() },
            act("Fill Whole Form", key: "edit.fillForm", enabled: web) { $0.forms.begin() },
            act("Insert Snippet…", key: "edit.snippets") { $0.enterPlace(.snippets) },
            .separator(),
            act("Find on Page…", key: "edit.find", enabled: web || browser.active?.page?.kind == .settings) { $0.openFind() },
            act("Find Next", key: "edit.findNext", enabled: browser.canFindAgain) { $0.look(forward: true) },
            act("Find Previous", key: "edit.findPrevious", enabled: browser.canFindAgain) { $0.look(forward: false) },
            act("Use Selection for Find", key: "edit.useSelectionForFind", enabled: browser.canUseSelectionForFind) { $0.useSelectionForFind() },
            .separator(),
            submenu("Substitutions", substitutions),
            submenu("Spelling and Grammar", [
                act("Correct Spelling Automatically", on: browser.prefs.autocorrect) { $0.prefs.autocorrect.toggle() },
            ]),
        ]
    }

    private static func view() -> [NSMenuItem] {
        let browser = current
        let active = browser.active
        var items: [NSMenuItem] = [
            act(browser.folded ? "Show Sidebar" : "Hide Sidebar", key: "view.fold") { $0.toggleFold() },
            act("Sidebar on Right", on: browser.prefs.sidePosition == .right) { $0.prefs.sidePosition = $0.prefs.sidePosition == .right ? .left : .right },
            act("Stack Spaces", on: browser.prefs.stackedSpaces) { $0.prefs.stackedSpaces.toggle() },
            act("Shut All Folders", key: "view.foldGroups", enabled: browser.canFoldAllGroups) { $0.foldAllGroups(true) },
            act("Open All Folders", key: "view.unfoldGroups", enabled: browser.canUnfoldAllGroups) { $0.foldAllGroups(false) },
            .separator(),
            act("Reload Page", key: "view.reload") { $0.reloadPage() },
            act("Reload Page From Origin", key: "view.reloadOrigin") { $0.reload(fromOrigin: true) },
            act("Float Video", key: "view.float") { $0.toggleFloat() },
            act("Site Controls", key: "view.siteControls") { SiteCardPanel.toggle($0) },
            act("Mute Call", key: "view.muteCall", enabled: browser.callToMute != nil) { $0.muteCall() },
        ]
        if browser.prefs.sitesInPanel, !browser.isPrivate {
            items.append(submenu("Side Panel", [
                act(browser.sidePanelShown ? "Close Side Panel" : "Show Side Panel", key: "view.sitePanel") { $0.toggleSitePanel() },
                .separator(),
            ] + PanelSites.offered.map { site in
                act(site.name) { $0.showSiteInPanel(site.url) }
            } + [
                .separator(),
                act("This Page", enabled: (active?.isWeb ?? false) && !(active?.shy ?? true)) { browser in
                    if let tab = browser.active { browser.openInSidePanel(tab) }
                },
            ]))
        }
        items += [
            .separator(),
            act("Darken Bright Pages", on: browser.prefs.darkensPages) { $0.prefs.darkensPages.toggle() },
        ]
        if browser.prefs.darkensPages {
            items += [
                act("Darken This Site", key: "view.dusk", enabled: browser.canDusk, on: active?.dusked ?? false) { $0.toggleDusk() },
                act("Pause Darkening", key: "view.duskPause", on: Dusk.shared.paused) { $0.pauseDusk() },
            ]
        }
        items += [
            .separator(),
            act("Hide Elements…", key: "view.hide") { $0.toggleHiding() },
            act("Hidden on This Site", key: "view.hidden") { $0.reviewing.toggle() },
            .separator(),
            act("Zoom In", key: "view.zoomIn") { $0.zoom(by: 1.1) },
            act("Zoom Out", key: "view.zoomOut") { $0.zoom(by: 1 / 1.1) },
            act("Actual Size", key: "view.actualSize") { $0.resetZoom() },
            .separator(),
            submenu("Developer", [
                act("Developer Mode", key: "view.developerMode") { $0.toggleDeveloperMode() },
                act("Errors and Network", key: "view.developerPanel") { $0.toggleDeveloperPanel() },
                act("Device Mode", key: "view.device") { $0.toggleDevice() },
                .separator(),
                act("Web Inspector", key: "view.inspector") { $0.toggleInspector() },
                act("JavaScript Console", key: "view.console") { $0.showConsole() },
                act("Inspect Element", key: "view.inspect") { $0.inspectElement() },
                .separator(),
                act("Allow Scripts to Drive Broadway", on: browser.prefs.bench) { $0.prefs.bench.toggle() },
            ]),
        ]
        return items
    }

    private static func tabs() -> [NSMenuItem] {
        let browser = current
        let active = browser.active
        let split = browser.activeSplit != nil
        var items: [NSMenuItem] = [
            act("Back", key: "tabs.back", enabled: browser.backGoes(active)) { $0.back() },
            act("Forward", key: "tabs.forward", enabled: active?.canGoForward == true) { $0.forward() },
            .separator(),
            act("Next Tab", key: "tabs.next") { $0.step(1) },
            act("Previous Tab", key: "tabs.previous") { $0.step(-1) },
            act("Search Tabs…", key: "tabs.search") { Command.named("tabs.search")?.run($0) },
            .separator(),
        ]
        if browser.prefs.splitView {
            items += [
                submenu("Split View", [
                    act("Split Current Page", key: "tabs.split", enabled: active != nil && active?.bench != true) { $0.startSplit() },
                    act("Focus Left Page", key: "tabs.focusLeftPane", enabled: split) { $0.focusPane(onLeft: true) },
                    act("Focus Right Page", key: "tabs.focusRightPane", enabled: split) { $0.focusPane(onLeft: false) },
                    act("Swap Pages", key: "tabs.swapSplit", enabled: split) { $0.swapSplit() },
                    act("Separate Split Tabs", key: "tabs.separateSplit", enabled: split) { browser in
                        if let tab = browser.active { browser.detachSplit(tab) }
                    },
                    act("Close Both Pages", enabled: split) { $0.closeSplit() },
                ]),
                .separator(),
            ]
        }
        items += [
            act("Pick All Tabs", key: "tabs.pickAll", enabled: !browser.pickableTabs.isEmpty) { $0.pickAllTabs() },
            act("Move Tab Up", key: "tabs.moveUp", enabled: active != nil) { $0.moveTab(by: -1) },
            act("Move Tab Down", key: "tabs.moveDown", enabled: active != nil) { $0.moveTab(by: 1) },
        ]
        if browser.showsSpaces, browser.spaces.count > 1 {
            let count = browser.keyTabs.filter(browser.movable(toSpace:)).count
            let spaces = browser.spaces.enumerated().map { index, space -> NSMenuItem in
                let elsewhere = space.id != browser.spaceID
                if index < 9 {
                    return act(space.name, key: "spaces.send.\(index + 1)", enabled: elsewhere) { $0.sendToSpace(index: index) }
                }
                return act(space.name, enabled: elsewhere) { $0.move($0.keyTabs, toSpace: space.id) }
            }
            items.append(submenu(count > 1 ? "Move \(count) Tabs to Space" : "Move Tab to Space", enabled: count > 0, spaces))
        }
        items.append(.separator())
        if let tab = active {
            let chosen = browser.keyTabs
            if chosen.count > 1 {
                items.append(act(tab.pin == nil ? "Pin \(chosen.count) Tabs" : "Unpin \(chosen.count) Tabs") { browser in
                    if let tab = browser.active { browser.togglePin(browser.keyTabs, like: tab) }
                })
            } else if browser.shownPinnedSplit(of: tab) != nil {
                items.append(act("Unpin Split View") { $0.togglePinFront() })
            } else if let pair = browser.activeSplit {
                items.append(act("Pin Split View", enabled: browser.canPinSplit(pair)) { $0.togglePinFront() })
            } else if tab.pin == nil {
                items.append(act("Pin Tab", enabled: tab.isWeb && !tab.shy) { browser in
                    if let tab = browser.active { browser.pin(tab) }
                })
            } else {
                items.append(act("Change Letter") { browser in
                    if let tab = browser.active { browser.editLetter(tab) }
                })
                items.append(act("Unpin Tab") { browser in
                    if let tab = browser.active { browser.unpin(tab) }
                })
            }
        }
        let pages = browser.keyTabs.filter(\.isWeb).count
        let paste = act(PasteTitle.go, key: "tabs.pasteAndGo") { $0.pasteAndGo() }
        paste.title = PasteTitle.shared.title(page: browser.active?.address) { [weak paste] in paste?.title = $0 }
        items += [
            act("Rename Tab", key: "tabs.rename", enabled: active != nil) { browser in
                if let tab = browser.active { browser.beginTabRename(tab) }
            },
            act(pages > 1 ? "Duplicate \(pages) Tabs" : "Duplicate Tab", key: "tabs.duplicate", enabled: pages > 0) { $0.duplicate($0.keyTabs) },
            act(LinkCopy.title(.address, count: pages), key: "tabs.copyAddress", enabled: pages > 0) { $0.copyAddress() },
            act(LinkCopy.title(.markdown, count: pages), key: "tabs.copyMarkdown", enabled: pages > 0) { $0.copyMarkdownLink() },
            act(LinkCopy.title(.rich, count: pages), key: "tabs.copyRich", enabled: pages > 0) { $0.copyLinks(.rich) },
            paste,
            .separator(),
            act("Close Other Tabs", key: "tabs.closeOthers", enabled: browser.tabs.count >= 2) { browser in
                if let tab = browser.active { browser.closeOthers(but: tab) }
            },
            act("Stop Sound in Tab", key: "tabs.mute", enabled: active != nil && browser.canPauseMedia) { browser in
                if browser.active != nil { browser.pauseMedia() }
            },
            act("Mute Other Tabs", key: "tab.muteOthers", enabled: browser.canMuteOtherTabs) { $0.muteOtherTabs() },
        ]
        return items
    }

    private static func bookmarks() -> [NSMenuItem] {
        let browser = current
        return [
            act(browser.pageKept ? "Edit Bookmark\u{2026}" : "Add This Page", key: "bookmarks.add",
                enabled: browser.active?.isWeb ?? false) { $0.bookmarkCurrent() },
            act("Show Bookmarks", key: "bookmarks.show") { $0.bookmarking = true },
            act("Show Bookmarks Bar", key: "bookmarks.bar", on: browser.prefs.bookmarksBar) { $0.prefs.bookmarksBar.toggle() },
        ]
    }

    private static func history() -> [NSMenuItem] {
        let browser = current
        var items: [NSMenuItem] = []
        let visited = browser.recentlyVisited
        if !visited.isEmpty {
            items.append(.sectionHeader(title: "Recently Visited"))
            for trace in visited {
                let url = trace.url
                items.append(line(command(trace.title.isEmpty ? Address.withoutWWW(trace.address) : trace.title) {
                    current.open(url, foreground: true)
                }, url))
            }
        }
        if !browser.ghosts.isEmpty {
            if !items.isEmpty { items.append(.separator()) }
            items.append(.sectionHeader(title: "Recently Closed"))
            for ghost in browser.recentlyClosed.prefix(10) {
                items.append(line(act(browser.closedTitle(for: ghost)) { $0.reopen(ghost) }, ghost.url))
            }
        }
        if !items.isEmpty { items.append(.separator()) }
        items += [
            act("Show History", key: "history.show") { $0.recalling = true },
            act("Downloads", key: "history.downloads") { $0.hoarding = true },
            act("Files", key: "history.files") { $0.filing = true },
            .separator(),
            act("Clear Browsing Data…", key: "history.clearData") { $0.clearBrowsingData() },
            act("Clear History", key: "history.clear") { $0.clearHistory() },
        ]
        return items
    }

    private static func line(_ item: NSMenuItem, _ url: URL) -> NSMenuItem {
        if let icon = Favicons.shared.cached(for: url), let small = icon.copy() as? NSImage {
            small.size = NSSize(width: 16, height: 16)
            item.image = small
        }
        return item
    }
}

@MainActor
final class ImportProgressView: NSView {
    static let width: CGFloat = 250
    private static let inset: CGFloat = 14
    private static let gap: CGFloat = 7

    private let browser: Browser
    private let glass = KitGlass(radius: 12, tint: Palette.NS.glassTint)
    private let name = KitLabel("", font: .systemFont(ofSize: 13, weight: .medium))
    private let message = KitLabel("", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private let track = KitBox(fill: KitColor.hairline, corners: .capsule)
    private let done = KitBox(fill: KitColor.ink.withAlphaComponent(0.7), corners: .capsule)
    private let count = KitLabel("", font: .systemFont(ofSize: 11), color: KitColor.muted)
    private let cancel: KitPushButton
    private var fraction: CGFloat?

    var job: Browser.FileImportJob? { didSet { refresh() } }

    init(browser: Browser) {
        self.browser = browser
        cancel = KitPushButton("Cancel") { [weak browser] in browser?.cancelFileImport() }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        cancel.bezelStyle = .glass
        name.overflow = .middle
        for view in [glass, name, message, track, done, count, cancel] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var footer: CGFloat { max(cancel.intrinsicContentSize.height, ceil(count.measure(width: .greatestFiniteMagnitude).height)) }

    override var intrinsicContentSize: NSSize {
        let inner = Self.width - Self.inset * 2
        let height = Self.inset + ceil(name.measure(width: inner).height) + Self.gap + ceil(message.measure(width: inner).height)
            + Self.gap + 3 + Self.gap + footer + Self.inset
        return NSSize(width: Self.width, height: height)
    }

    private func refresh() {
        guard let job else { return }
        name.text = job.filename
        message.text = job.message
        if let total = job.total, total > 0 {
            fraction = min(1, CGFloat(job.completed) / CGFloat(total))
            count.text = "\(job.completed.formatted()) of \(total.formatted())"
            count.isHidden = false
        } else {
            fraction = nil
            count.isHidden = true
        }
        cancel.title = job.cancelling ? "Cancelling…" : "Cancel"
        cancel.isEnabled = !job.cancelling
        setAccessibilityLabel("Importing \(job.filename), \(job.message)")
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let inner = bounds.width - Self.inset * 2
        var y = Self.inset
        let nameHeight = ceil(name.measure(width: inner).height)
        name.frame = kitSnap(NSRect(x: Self.inset, y: y, width: inner, height: nameHeight))
        y += nameHeight + Self.gap
        let messageHeight = ceil(message.measure(width: inner).height)
        message.frame = kitSnap(NSRect(x: Self.inset, y: y, width: inner, height: messageHeight))
        y += messageHeight + Self.gap
        track.frame = kitSnap(NSRect(x: Self.inset, y: y, width: inner, height: 3))
        done.isHidden = fraction == nil
        done.frame = kitSnap(NSRect(x: Self.inset, y: y, width: inner * (fraction ?? 0), height: 3))
        y += 3 + Self.gap
        let row = footer
        let button = cancel.intrinsicContentSize
        cancel.frame = kitSnap(NSRect(x: Self.inset + inner - button.width, y: y + (row - button.height) / 2,
                                      width: button.width, height: button.height))
        let counted = count.measure(width: max(0, inner - button.width - 8))
        count.frame = kitSnap(NSRect(x: Self.inset, y: y + (row - ceil(counted.height)) / 2,
                                     width: max(0, inner - button.width - 8), height: ceil(counted.height)))
    }
}
