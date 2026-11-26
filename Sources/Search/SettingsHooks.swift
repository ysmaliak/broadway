import AppKit

@MainActor
enum HookWords {
    static let line = "Programs of your own that decide where links open, where downloads go and how sites' requests are answered"
    static let warning = "This program will be able to allow or refuse a site's request for your camera, microphone, location and notifications"
    static let add = "Add Hook…"
    static let choose = "Choose Program…"

    static let picks: [(HookEvent, Int?)] = [(.link, nil), (.download, nil), (.permission, nil)]
        + Hook.choiceMinutes.map { (HookEvent.timer, $0) }

    static func pickTitle(_ pick: (HookEvent, Int?)) -> String {
        guard let minutes = pick.1 else { return pick.0.title }
        return Hook.every(minutes)
    }

    static func symbol(_ event: HookEvent) -> String {
        switch event {
        case .link: "link"
        case .download: "arrow.down.circle"
        case .permission: "hand.raised"
        case .timer: "clock"
        }
    }

    static func place(_ hook: Hook, home: URL? = nil) -> String {
        let folder = hook.program.deletingLastPathComponent().path
        let root = (home ?? HookGate.home).path
        let shown = folder == root ? "~" : folder.hasPrefix(root + "/") ? "~" + folder.dropFirst(root.count) : folder
        return "\(hook.program.lastPathComponent) in \(shown)"
    }

    static func detail(_ hook: Hook, book: HookBook, now: Date = Date()) -> String {
        var status = book.line(hook, now: now)
        if hook.off == nil, let said = book.results[hook.id]?.said, book.results[hook.id]?.problem != nil,
           let last = said.split(whereSeparator: \.isNewline).last.map({ $0.trimmingCharacters(in: .whitespaces) }), !last.isEmpty {
            status += ". It said: " + String(last.suffix(120))
        }
        return place(hook) + "\n" + status
    }

    static func needsApproval(_ hook: Hook, book: HookBook) -> Bool {
        hook.event.bound && (hook.hash == nil || book.changed.contains(hook.id))
    }
}

@MainActor
enum HookSettings {
    static var open = false
    static var revealed: [String] = []
}

extension SettingsPageView {
    func hooks() {
        let book = HookBook.shared
        let lit = shell.lit?.hasPrefix("agents.hook") == true
        if lit { HookSettings.open = true }
        let open = HookSettings.open
        shape { [HookSettings.open, book.revision] as [AnyHashable] }
        section("Developer") {
            let mark = NSButton(title: "", target: nil, action: nil)
            mark.bezelStyle = .disclosure
            mark.setButtonType(.pushOnPushOff)
            mark.state = open ? .on : .off
            let flip = { [weak self] in
                HookSettings.open = !open
                self?.refresh()
            }
            mark.kitOnChange { _ in flip() }
            mark.kitAccess(id: "settings.hooks.fold")
            let fold = SettingsFoldRow(id: "agents.hooks", title: "Hooks", detail: HookWords.line, open: open, control: mark, flip: flip)
            fold.lit = shell.lit == "agents.hooks"
            put(fold)
            guard open else { return }
            book.look()
            for hook in book.hooks {
                hookRow(hook, book: book)
            }
            let add = button(HookWords.add) { [weak self] in HookSheet.show(over: self?.window) }
            add.kitAccess(id: "settings.hooks.add", label: HookWords.add)
            put(SettingsRowView(id: "agents.hooks.add", symbol: nil, title: "", control: add))
        }
    }

    private func hookRow(_ hook: Hook, book: HookBook) {
        let id = hook.id
        let more = KitButton(.plain(press: 1), label: "More for \(hook.purpose)")
        more.content = KitSymbol("ellipsis.circle", style: .init(size: 13), tint: .secondaryLabelColor)
        more.kitAccess(id: "settings.hook.more.\(id.uuidString.lowercased())", label: "More for \(hook.purpose)")
        more.action = { [weak more] in
            guard let more else { return }
            KitMenu.pop(HookSettings.actions(id, book: book), below: more)
        }
        let flip = toggle("hook.\(id.uuidString.lowercased())", get: { book.hook(id)?.on ?? false }, set: { on in book.turn(id, on: on) })
        flip.kitAccess(id: "settings.hook.\(id.uuidString.lowercased())", label: hook.purpose)
        let controls = NSStackView(views: [more, flip])
        controls.orientation = .horizontal
        controls.spacing = 10
        let made = SettingsRowView(id: "agents.hook.\(id.uuidString.lowercased())", symbol: HookWords.symbol(hook.event), title: hook.purpose,
                                   detail: HookWords.detail(hook, book: book), control: controls)
        made.lit = shell.lit == made.rowID
        update { [weak made] in
            guard let now = book.hook(id) else { return }
            made?.say(HookWords.detail(now, book: book))
        }
        put(made)
    }
}

extension HookSettings {
    static func actions(_ id: UUID, book: HookBook) -> [KitMenuItem] {
        guard let hook = book.hook(id) else { return [] }
        var items: [KitMenuItem] = [
            .action("Show in Finder", id: "hook.reveal") {
                if Store.testing {
                    revealed.append(hook.program.path)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([hook.program])
                }
            },
        ]
        if HookWords.needsApproval(hook, book: book) {
            items.append(.action("Approve Again", id: "hook.approve") { book.approve(id) })
        }
        items.append(.separator)
        items.append(.action("Remove", id: "hook.remove") { book.remove(id) })
        return items
    }
}

@MainActor
enum HookSheet {
    static var chosenForTests: URL?
    private(set) static weak var shown: NSPanel?

    static func show(over window: NSWindow?, first: HookEvent = .link, book: HookBook = .shared) {
        var at = HookWords.picks.firstIndex { $0.0 == first && ($0.1 == nil || $0.1 == 15) } ?? 0
        let sheet = SettingsSheet(title: "Add Hook", width: 440)
        sheet.note(HookWords.line)
        let titles = HookWords.picks.map(HookWords.pickTitle)
        let menu = sheet.popUp("For", titles: titles, picked: at) { picked in
            at = picked
            DispatchQueue.main.async { [weak sheet] in
                guard let panel = sheet?.panel else { return }
                panel.layoutIfNeeded()
                panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
            }
        }
        menu.setAccessibilityIdentifier("hooks.sheet.for")
        var trouble: String?
        sheet.live { HookWords.picks[at].0 == .permission ? HookWords.warning : nil }
        sheet.live { trouble }
        sheet.finish(save: HookWords.choose) {
            trouble = nil
            let pick = HookWords.picks[at]
            guard let program = choose(over: sheet.panel) else { return false }
            trouble = add(program, event: pick.0, minutes: pick.1 ?? 15, book: book)
            guard trouble != nil else { return true }
            DispatchQueue.main.async { [weak sheet] in
                guard let panel = sheet?.panel else { return }
                panel.layoutIfNeeded()
                panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
            }
            return false
        }
        shown = sheet.panel
        sheet.show(over: window)
    }

    static func add(_ program: URL, event: HookEvent, minutes: Int, book: HookBook) -> String? {
        guard book.add(event, program: program, minutes: minutes) != nil else { return "Broadway couldn't read that file" }
        HookSettings.open = true
        return nil
    }

    static func choose(over panel: NSWindow) -> URL? {
        if Store.testing { return chosenForTests.flatMap { HookGate.allows($0) ? $0 : nil } }
        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        open.resolvesAliases = true
        open.treatsFilePackagesAsDirectories = true
        open.prompt = "Choose"
        open.message = "Choose a program of your own. Broadway runs it by itself, with no shell."
        guard open.runModal() == .OK, let url = open.url else { return nil }
        return url
    }
}

@MainActor
enum BenchHooks {
    static let verbs: Set<String> = ["hooks"]

    static func run(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "hooks only works on a --test run"]) }
        let book = HookBook.shared
        switch request["action"] as? String ?? "list" {
        case "list":
            break
        case "sheet":
            let first = (request["event"] as? String).flatMap(HookEvent.init(rawValue:)) ?? .link
            let settings = SettingsWindow.shared.number.flatMap { NSApp.window(withWindowNumber: $0) }
            guard let parent = settings ?? browser.window else { return answer(["error": "sheet needs a window"]) }
            HookSheet.show(over: parent, first: first)
            HookSheet.shown?.level = parent.level
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                answer(["sheet": HookSheet.shown?.windowNumber ?? 0])
            }
            return
        case "closesheet":
            if let panel = HookSheet.shown {
                panel.sheetParent?.endSheet(panel)
                panel.close()
            }
        case "picture":
            let number = request["window"] as? Int ?? SettingsWindow.shared.number
            guard let path = request["path"] as? String,
                  let window = number.flatMap({ NSApp.window(withWindowNumber: $0) }) ?? browser.window
            else { return answer(["error": "picture takes a path"]) }
            return answer(["picture": picture(window, to: path) ? path : ""])
        case "tick":
            let minutes = request["minutes"] as? Double ?? 0
            HookClock.tick(now: Date().addingTimeInterval(minutes * 60))
        case "asked":
            return answer(["asked": HookGate.asked])
        case "look":
            book.look()
        default:
            return answer(["error": "hooks takes list, sheet, closesheet, picture, tick, asked or look"])
        }
        answer(["hooks": book.hooks.map { hook in
            ["id": hook.id.uuidString, "event": hook.event.rawValue, "program": hook.program.lastPathComponent, "on": hook.on,
             "line": book.line(hook), "said": book.results[hook.id]?.said ?? ""] as [String: Any]
        }, "unknown": book.entries.filter { $0.hook == nil }.count])
    }

    static func picture(_ window: NSWindow, to path: String) -> Bool {
        guard let frame = window.contentView?.superview else { return false }
        window.layoutIfNeeded()
        frame.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let scale: CGFloat = 2
        let size = frame.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = size
        frame.cacheDisplay(in: frame.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
