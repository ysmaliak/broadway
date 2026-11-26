import AppKit

@MainActor
enum BenchMenus {
    private static weak var shown: NSMenu?
    private static var watcher: Any?
    private static var found = ""
    private static var log: [String] = []
    private static var ender: Any?

    static func run(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "ctxmenu is for test runs"]); return }
        switch request["action"] as? String ?? "open" {
        case "close":
            let was = shown != nil
            shown?.cancelTracking()
            shown = nil
            answer(["closed": was])
        case "read":
            guard let menu = shown else { answer(["error": "no menu open"]); return }
            answer(["items": describe(menu)])
        case "pick":
            guard var menu = shown else { answer(["error": "no menu open"]); return }
            let path = request["path"] as? [String] ?? []
            for (depth, title) in path.enumerated() {
                guard let at = menu.items.firstIndex(where: { $0.title == title }) else { answer(["error": "no item \(title)"]); return }
                if depth == path.count - 1 {
                    shown?.cancelTracking()
                    shown = nil
                    let last = menu
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        last.performActionForItem(at: at)
                        answer(["picked": title])
                    }
                    return
                }
                guard let next = menu.items[at].submenu else { answer(["error": "\(title) opens no menu"]); return }
                menu = next
            }
            answer(["error": "pick needs a path"])
        case "keys":
            guard let menu = shown, let window = browser.window else { answer(["error": "no menu open"]); return }
            for key in request["keys"] as? [String] ?? [] { press(key, window: window) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { answer(["items": describe(menu)]) }
        default:
            open(request, browser: browser, answer)
        }
    }

    private static func point(_ request: [String: Any], browser: Browser) -> CGPoint? {
        if let at = request["at"] as? [Double], at.count == 2 { return CGPoint(x: at[0], y: at[1]) }
        if let ref = (request["id"] as? String)?.lowercased(), !ref.isEmpty,
           let tab = browser.tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(ref) }),
           let frame = Bench.rowFrames[tab.id] {
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        return nil
    }

    private static func open(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard let window = browser.window, let content = window.contentView else { answer(["error": "no window"]); return }
        shown?.cancelTracking()
        shown = nil
        if let watcher { NotificationCenter.default.removeObserver(watcher) }
        watcher = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                log.append("begin \((note.object as? NSMenu)?.items.count ?? -1) super \((note.object as? NSMenu)?.supermenu != nil)")
                guard shown == nil, let menu = note.object as? NSMenu, menu.supermenu == nil, menu !== NSApp.mainMenu else { return }
                shown = menu
            }
        }
        let kind = request["kind"] as? String ?? "row"
        let fallback = CGPoint(x: 120, y: 120)
        let at = point(request, browser: browser) ?? fallback
        let base = NSPoint(x: at.x, y: content.isFlipped ? at.y : content.bounds.height - at.y)
        let hold = request["hold"] as? Double ?? 0
        found = ""
        log = []
        if ender == nil {
            ender = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { note in
                MainActor.assumeIsolated { log.append("end \((note.object as? NSMenu)?.items.count ?? -1)") }
            }
        }
        RunLoop.main.perform(inModes: [.default, .common]) {
            let point = content.convert(base, to: nil)
            guard let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { return }
            switch kind {
            case "space": NSMenu.popUpContextMenu(SpaceMenu.menu(for: browser), with: event, for: content)
            case "plus": NSMenu.popUpContextMenu(PlusMenu.menu(for: browser), with: event, for: content)
            case "column": NSMenu.popUpContextMenu(PlusMenu.column(for: browser), with: event, for: content)
            case "site": SiteCardPanel.toggle(browser, step: SiteControlsBench.step(request["step"] as? String))
            case "pluslist": browser.plusOpen = true
            case "extensions": Extensions.shared.menuOpen = true
            case "bookmarks":
                browser.bookmarkCard = nil
                browser.bookmarksOpen = true
            case "sign":
                guard let sign = signs(in: content).first else { found = "no sign on screen"; return }
                found = "\(type(of: sign))"
                sign.open()
            case let bar where bar.hasPrefix("bar:"):
                let title = String(bar.dropFirst(4))
                guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == title })?.submenu?.copy() as? NSMenu else {
                    found = "no \(title) menu"; return
                }
                MenuIcons.leave = menu
                NSMenu.popUpContextMenu(menu, with: event, for: content)
            case "page":
                guard let ref = (request["id"] as? String)?.lowercased(),
                      let tab = browser.tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(ref) }),
                      let x = request["x"] as? Double, let y = request["y"] as? Double else { found = "page needs id x y"; return }
                let web = tab.web
                let inView = NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y)
                let spot = web.convert(inView, to: nil)
                guard let press = NSEvent.mouseEvent(
                    with: .rightMouseDown, location: spot, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ) else { return }
                found = "page"
                web.rightMouseDown(with: press)
            default:
                var view = content.superview?.hitTest(point) ?? content.hitTest(base)
                while let here = view {
                    if let menu = here.menu(for: event) {
                        found = "\(type(of: here))"
                        NSMenu.popUpContextMenu(menu, with: event, for: here)
                        return
                    }
                    view = here.superview
                }
                found = "none under \(content.superview?.hitTest(point).map { "\(type(of: $0))" } ?? "nothing")"
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (kind == "page" ? 1.5 : 0.8)) {
            guard let menu = shown else { answer(["error": "no menu came up: \(found) \(log)", "at": [at.x, at.y]]); return }
            answer(["items": describe(menu), "at": [at.x, at.y]])
            if hold > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                    if shown === menu { menu.cancelTracking(); shown = nil }
                }
            }
        }
    }

    private static func signs(in view: NSView) -> [SignView] {
        if let sign = view as? SignView, !sign.isHiddenOrHasHiddenAncestor { return [sign] }
        return view.subviews.flatMap { signs(in: $0) }
    }

    private static func press(_ key: String, window: NSWindow) {
        let named: [String: (UInt16, String)] = [
            "down": (125, "\u{F701}"), "up": (126, "\u{F700}"), "right": (124, "\u{F703}"), "left": (123, "\u{F702}"),
        ]
        let (code, characters) = named[key] ?? (0, key)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    static func describe(_ menu: NSMenu) -> [[String: Any]] {
        menu.update()
        return menu.items.filter { !$0.isHidden }.map { item in
            if item.isSeparatorItem { return ["separator": true] }
            let leading = item.image == nil && item.offStateImage != nil
            var out: [String: Any] = [
                "title": item.title,
                "image": leading || item.image != nil && item.image !== MenuIcons.blank,
                "shown": leading || item.image != nil && item.preferredImageVisibility == .visible,
                "enabled": item.isEnabled,
                "on": item.state == .on,
            ]
            if !item.keyEquivalent.isEmpty {
                out["key"] = item.keyEquivalent
                out["modifiers"] = Int(item.keyEquivalentModifierMask.rawValue)
            }
            if item.isSectionHeader { out["header"] = true }
            if leading { out["leading"] = true }
            if item.isAlternate { out["alternate"] = true }
            if let id = item.identifier?.rawValue { out["id"] = id }
            if let sub = item.submenu { out["submenu"] = describe(sub) }
            return out
        }
    }
}
