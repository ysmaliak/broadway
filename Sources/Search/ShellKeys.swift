import AppKit

extension ContentView {
    func watchKeys() {
        let id = ObjectIdentifier(browser)
        if let old = ContentView.monitors[id] { NSEvent.removeMonitor(old) }
        ContentView.monitors[id] = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                guard let window, event.window === window, let height = window.contentView?.bounds.height
                else { return event }
                let at = event.locationInWindow
                browser.clickTakesOver(in: window, at: at)
                return browser.clickTabSwitcher(at: CGPoint(x: at.x, y: height - at.y)) ? nil : event
            }
            guard mine(event) else { return event }
            if browser.floater.handleKey(event) { return nil }
            if CallFloat.shared.handleKey(event) { return nil }
            guard event.type == .keyDown else {
                let held = browser.prefs.showsTabShortcuts && event.modifierFlags.contains(.command)
                if browser.commandHeld != held { browser.commandHeld = held }
                if browser.tabSwitcher.active, !ShortcutStore.shared.recentHeld(event.modifierFlags) {
                    browser.commitTabSwitch()
                }
                if !event.modifierFlags.contains(.command) { browser.landSummon() }
                return event
            }
            if event.keyCode == 53, let page = ContentView.pageFillingScreen(event) {
                if browser.tabSwitcher.active { browser.tabSwitcher.cancel() }
                guard browser.prefs.escapeTwice else { return event }
                return FullScreenEscape.shared.passes(event, to: page) ? event : nil
            }
            if browser.holdKey(event) { return nil }
            if event.keyCode == 53, browser.prefs.escapeTwice, let window, event.window === window,
               window.styleMask.contains(.fullScreen) {
                if event.isARepeat { return nil }
                if take(event) { return nil }
                FullScreenEscape.shared.press(event, leaving: window)
                return nil
            }
            return take(event) ? nil : event
        }
        ContentView.keyHooks[id] = { [weak self] event in
            guard let self else { return event }
            return self.take(event) ? nil : event
        }
    }

    private static var monitors: [ObjectIdentifier: Any] = [:]

    static func forget(_ browser: Browser) {
        let id = ObjectIdentifier(browser)
        if let monitor = monitors.removeValue(forKey: id) { NSEvent.removeMonitor(monitor) }
        keyHooks[id] = nil
    }

    private func mine(_ event: NSEvent) -> Bool {
        if let window = event.window, let owner = Browsers.browser(for: window) {
            return owner.isPopup ? Browsers.acting === browser : window === self.window
        }
        return Browsers.acting === browser
    }

    private static func pageFillingScreen(_ event: NSEvent) -> PageView? {
        guard let page = event.window?.firstResponder as? PageView else { return nil }
        let fills = page.fullscreenState != .notInFullscreen
            || Browsers.all.contains { $0.tabs.contains { $0.immersed && $0.built === page } }
        return fills ? page : nil
    }

    static var keyHooks: [ObjectIdentifier: (NSEvent) -> NSEvent?] = [:]

    private static var passed: NSEvent?

    private func pageFirst(_ event: NSEvent, key: String, shifted: Bool) -> Bool {
        let reserved = (key == "t") || (key == "w") || (key == "n" && shifted)
            || ((key == "[" || key == "]" || key == "{" || key == "}") && shifted)
            || (key == "z" && browser.veiling)
            || (key == "k" && !shifted)
            || (!shifted && (event.keyCode == 123 || event.keyCode == 124) && !caretIn(event))
        guard !reserved, event.window?.firstResponder is PageView else { return false }
        if let passed = ContentView.passed, PageView.same(passed, event) {
            ContentView.passed = nil
            return false
        }
        ContentView.passed = event
        return true
    }

    private func caretIn(_ event: NSEvent) -> Bool {
        event.window?.firstResponder is NSTextView || browser.active?.typing == true
            || browser.active?.built?.inputContext != nil
    }

    private static func caretAtEnd(_ window: NSWindow, typed: String) -> Bool {
        guard let editor = window.firstResponder as? NSTextView, !editor.hasMarkedText() else { return false }
        let text = editor.string as NSString
        let selected = editor.selectedRange()
        guard NSMaxRange(selected) == text.length else { return false }
        return text.substring(to: selected.location) == typed
    }

    private static func inAddressField(_ window: NSWindow) -> Bool {
        guard let editor = window.firstResponder as? NSTextView else { return false }
        return (editor.delegate as? NSTextField)?.delegate is AddressFieldKeys
    }

    private func canSwitchTabs(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        return !browser.reviewing && !browser.bookmarksOpen &&
            !browser.veiling && !browser.summoning && !browser.makingSpace && !browser.spaceAsk.up &&
            browser.peekTab == nil && browser.editingTab == nil &&
            browser.asking == nil && browser.offering == nil && browser.suggesting == nil
    }

    static let digits: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
    ]

    private func take(_ event: NSEvent) -> Bool {
        if event.window?.sheetParent != nil || NSApp.modalWindow != nil { return false }
        if Browsers.isCloseKey(event), !Browsers.ownsKeys(event.window) { return false }
        if let popup = Browsers.browser(for: event.window), popup.isPopup {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, flags.isEmpty, popup.asking != nil {
                popup.cancelCapture()
                return true
            }
            guard event.shortcutCharacters == "w", flags == .command else { return false }
            popup.window?.performClose(nil)
            return true
        }
        guard !ShortcutStore.shared.recording else { return false }
        if browser.aiKey(event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.shortcutCharacters
        let recent = ShortcutStore.shared.recentSwitch(event)

        if browser.tabSwitcher.active, recent == nil {
            if ShortcutStore.shared.recentOnly(flags) {
                let direction: TabSwitcher.Direction? = switch event.keyCode {
                case 123: .left
                case 124: .right
                case 125: .down
                case 126: .up
                default: nil
                }
                if let direction {
                    browser.tabSwitcher.move(direction)
                    return true
                }
            }
            if browser.prefs.switcherKeys, let action = TabSwitcher.Action(event), let id = browser.tabSwitcher.selectedID {
                if !event.isARepeat { browser.act(action, onCard: id) }
                return true
            }
            browser.tabSwitcher.cancel()
            if event.keyCode == 53 { return true }
        }

        if event.keyCode == 53 {
            if browser.downloadsOpen {
                browser.downloadsOpen = false
                return true
            }
            if browser.bookmarksOpen {
                browser.bookmarksOpen = false
                return true
            }
            if browser.editingLook {
                browser.editingLook = false
                return true
            }
            if browser.editingTab != nil {
                browser.cancelTabEdit()
                return true
            }
            if browser.peekTab != nil {
                browser.closePeek()
                return true
            }
            if browser.makingSpace || browser.spaceAsk.up {
                browser.leaveSpaceCreation()
                return true
            }
            if browser.suggesting != nil {
                browser.dropChoice()
                return true
            }
            if browser.aiEscape() { return true }
            if browser.veiling {
                browser.toggleHiding()
                return true
            }
            if browser.reviewing {
                browser.reviewing = false
                return true
            }
            if browser.finding {
                browser.closeFind()
                return true
            }
            if browser.fieldMenu.showing {
                browser.fieldMenu.close()
                return true
            }
            if browser.escapePlace() { return true }
            if browser.escapeEmptyNewTabPage() { return true }
            if browser.letGoOfRow() { return true }
            if browser.escapeNewTab() { return true }
            guard browser.editing, browser.active?.isBlank == false else {
                if let tab = browser.active, tab.loading { tab.stop() }
                return false
            }
            browser.dismiss()
            return true
        }

        if browser.prefs.splitView, browser.activeSplit != nil, let combo = KeyCombo(event: event) {
            let store = ShortcutStore.shared
            if combo == store.key(for: "tabs.focusLeftPane") { browser.focusPane(onLeft: true); return true }
            if combo == store.key(for: "tabs.focusRightPane") { browser.focusPane(onLeft: false); return true }
            if combo == store.key(for: "tabs.focusOtherPane") { browser.focusOtherPane(); return true }
        }

        if event.keyCode == 36 || event.keyCode == 76,
           flags.intersection([.command, .shift, .option, .control]) == .command
            || (browser.prefs.splitView && flags.intersection([.command, .shift, .option, .control]) == [.command, .option]),
           let peek = browser.peekTab, !peek.typing, peek.built?.inputContext == nil {
            browser.keepPeek(beside: flags.contains(.option))
            return true
        }

        if let backwards = recent {
            if canSwitchTabs(event) {
                if !event.isARepeat { browser.switchTabs(backwards: backwards) }
                return true
            }
            browser.step(backwards ? -1 : 1)
            return true
        }
        if browser.fieldShowing, browser.editingTab == nil, let window, event.window === window,
           ContentView.inAddressField(window), browser.fieldKey(event) {
            return true
        }
        if event.keyCode == 49, flags.intersection([.command, .option, .control]).isEmpty,
           browser.fieldShowing, browser.editingTab == nil, let window, event.window === window,
           ContentView.inAddressField(window), ContentView.caretAtEnd(window, typed: browser.typed), browser.lockSiteOnSpace() {
            return true
        }
        if let window, event.window === window, browser.commandKey(event) { return true }
        if event.keyCode == 48, !flags.contains(.command), !flags.contains(.option), !flags.contains(.control) {
            if browser.editingTab != nil { return true }
            if browser.fieldShowing, !flags.contains(.shift), browser.lockSiteOffer() { return true }
            if browser.fieldShowing, !browser.offers.isEmpty {
                browser.walk(flags.contains(.shift) ? -1 : 1)
                return true
            }
            return false
        }

        if let combo = KeyCombo(event: event) {
            if let command = ShortcutStore.shared.customCommand(on: combo) {
                if command.section == .spaces, !browser.showsSpaces { return false }
                if Command.split.contains(command.id), !browser.prefs.splitView { return false }
                if Command.dusk.contains(command.id), !browser.prefs.darkensPages { return false }
                if Command.asking.contains(command.id), !browser.prefs.ai { return false }
                command.run(browser)
                return true
            }
            if ShortcutStore.shared.isFreed(combo) { return false }
        }

        if !flags.intersection([.command, .option, .control]).isEmpty,
           KeyCombo(event: event).map({ !ShortcutStore.shared.keepsFromExtensions($0) }) ?? true,
           Extensions.shared.take(event) {
            return true
        }

        guard flags.contains(.command) else { return false }
        let shifted = flags.contains(.shift)

        if flags.contains(.option), !shifted, !flags.contains(.control),
           event.shortcutKey == "r" {
            if pageFirst(event, key: "r", shifted: false) { return false }
            browser.reload(fromOrigin: true)
            return true
        }

        if flags.contains(.option), shifted, !flags.contains(.control), browser.prefs.darkensPages,
           event.characters(byApplyingModifiers: [])?.lowercased() == "d" {
            browser.pauseDusk()
            return true
        }

        guard !flags.contains(.option), !flags.contains(.control) else { return false }

        if event.keyCode == 36 || event.keyCode == 76, browser.fieldShowing,
           browser.editingTab == nil, let window, event.window === window,
           ContentView.inAddressField(window) {
            browser.submit(aside: true, front: shifted)
            return true
        }

        if !shifted, let number = ContentView.digits[event.keyCode] {
            if number == 0 {
                browser.resetZoom()
            } else {
                browser.select(index: number == 9 ? browser.tabShortcutTargets.count - 1 : number - 1)
            }
            return true
        }

        if shifted, event.keyCode == 51 {
            browser.clearBrowsingData()
            return true
        }

        if pageFirst(event, key: key, shifted: shifted) { return false }

        switch key {
        case "t" where !shifted:
            browser.launch()
        case "t" where shifted:
            browser.reopen()
        case "c" where shifted:
            browser.copyAddress()
        case "d" where !shifted:
            browser.duplicate(browser.keyTabs)
        case "d" where shifted:
            guard browser.prefs.darkensPages else { return false }
            browser.toggleDusk()
        case "n" where shifted:
            Browsers.newPrivateWindow()
        case "y" where !shifted:
            browser.recalling = true
        case "j" where shifted:
            browser.filing = true
        case "v" where shifted:
            if browser.active?.typing == true || browser.active?.built?.inputContext != nil
                || browser.editing || event.window?.firstResponder is NSTextView {
                _ = event.window?.firstResponder?.tryToPerform(#selector(NSTextView.pasteAsPlainText(_:)), with: nil)
            } else {
                browser.pasteAndGo()
            }
        case "p" where !shifted:
            browser.printPage()
        case "f" where !shifted:
            browser.openFind()
        case "g":
            browser.look(forward: !shifted)
        case "m" where shifted:
            browser.pauseMedia()
        case "p" where shifted:
            browser.toggleFloat()
        case "k" where !shifted:
            Command.named("tabs.search")?.run(browser)
        case "s" where !shifted:
            browser.toggleFold()
        case "b" where shifted:
            browser.bookmarkCurrent()
        case "," where !shifted:
            browser.tuning = true
        case "h" where shifted:
            browser.toggleHiding()
        case "u" where shifted:
            browser.reviewing.toggle()
        case "z" where !shifted:
            guard browser.veiling else { return false }
            browser.undoHiding()
        case "=", "+":
            browser.zoom(by: 1.1)
        case "-":
            browser.zoom(by: 1 / 1.1)
        case "0":
            browser.resetZoom()
        case "w" where !shifted:
            browser.closeFront()
        case "w" where shifted:
            browser.closeWindow()
        case "l" where !shifted:
            browser.edit()
        case "r" where !shifted:
            browser.reloadPage()
        case "[":
            shifted ? browser.step(-1) : browser.back()
        case "]":
            shifted ? browser.step(1) : browser.forward()
        default:
            guard !shifted, !caretIn(event) else { return false }
            if event.keyCode == 123 { browser.back(); return true }
            if event.keyCode == 124 { browser.forward(); return true }
            return false
        }
        return true
    }
}
