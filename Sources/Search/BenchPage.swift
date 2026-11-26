import Foundation
import WebKit

@MainActor
enum BenchPage {
    static let verbs: Set<String> = ["shield", "controls", "mini", "call", "dev", "device", "agent", "uploads", "json", "filebox", "saveask", "trust", "clientcert"]

    static func run(_ verb: String, _ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let action = request["action"] as? String ?? "state"
        let values = request["values"] as? [String] ?? []
        guard action == "state" || Store.testing else {
            answer(["error": "\(verb) \(action) only works on a --test run"])
            return
        }
        switch verb {
        case "shield": shield(action, values, browser, answer)
        case "controls":
            if action == "toggle" { SiteCardPanel.toggle(browser, step: SiteControlsBench.step(values.first)) }
            answer(["shown": SiteCardPanel.isShown])
        case "mini": mini(action, values, browser, answer)
        case "call": call(action, values, browser, answer)
        case "dev": dev(action, values, browser, answer)
        case "device": device(action, values, browser, answer)
        case "uploads": uploads(action, values, browser, answer)
        case "json":
            if action == "forget" { JSONView.copied = nil }
            answer(["copied": JSONView.copied ?? "", "mode": JSONView.mode.rawValue])
        case "filebox": BenchFileChoice.run(action, values, browser, answer)
        case "saveask": BenchSaveAsk.run(action, values, browser, answer)
        case "clientcert":
            switch action {
            case "first": ClientCertificateAsk.answerInTest = .first
            case "cancel": ClientCertificateAsk.answerInTest = .cancel
            case "load":
                guard let held = ClientCertificateAsk.source as? HeldIdentities, values.count == 2,
                      let data = FileManager.default.contents(atPath: values[0]), held.load(data, password: values[1])
                else { return answer(["error": "clientcert load needs a readable PKCS#12 file and its password"]) }
            default: break
            }
            answer(["answer": ClientCertificateAsk.answerInTest.rawValue, "dialogs": Dialogs.askedInTest])
        case "trust":
            if action == "continue" { Dialogs.continuesInTest = true }
            if action == "back" { Dialogs.continuesInTest = false }
            answer(["continues": Dialogs.continuesInTest, "dialogs": Dialogs.askedInTest])
        case "agent":
            if action == "copy" { browser.copyForAgent() }
            if action == "markdown" { browser.copyPageAsMarkdown() }
            answer(["copied": CopyForAgent.copied ?? "", "markdown": PageMarkdown.copied ?? "", "announced": browser.announcement ?? ""])
        default: answer(["error": "unknown command"])
        }
    }

    private static func device(_ action: String, _ values: [String], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard let tab = browser.active else { return answer(["error": "no tab"]) }
        switch action {
        case "state": break
        case "toggle": browser.toggleDevice()
        case "set":
            guard let profile = DeviceProfile.list.first(where: { $0.name == values.first }) else { return answer(["error": "no such device"]) }
            tab.useDevice(DeviceState(profile))
        case "rotate":
            guard var state = tab.device else { return answer(["error": "not in device mode"]) }
            state.rotate()
            tab.useDevice(state)
        case "size":
            guard var state = tab.device, values.count == 2, let width = Double(values[0]), let height = Double(values[1]) else {
                return answer(["error": "device size W H"])
            }
            state.resize(width: width, height: height)
            tab.useDevice(state)
        default:
            return answer(["error": "device state|toggle|set NAME|rotate|size W H"])
        }
        answer(["on": tab.device != nil, "name": tab.device?.name ?? "", "width": tab.device?.width ?? 0, "height": tab.device?.height ?? 0,
                "agent": tab.built?.customUserAgent ?? "", "frameWidth": tab.built?.frame.width ?? 0])
    }

    private static func uploads(_ action: String, _ values: [String], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        var query = ""
        switch action {
        case "state": break
        case "add":
            guard values.count == 2 else { return answer(["error": "uploads add PATH SITE"]) }
            Uploads.shared.add([URL(fileURLWithPath: values[0])], to: values[1])
        case "find": query = values.first ?? ""
        case "open": browser.filing = true
        default: return answer(["error": "uploads state|add PATH SITE|find TEXT|open"])
        }
        let items = FileItem.found(FileItem.merged(downloads: browser.loot.kept, uploads: Uploads.shared.kept), matching: query)
        answer(["items": items.map { ["name": $0.name, "source": $0.source, "path": $0.path, "uploaded": $0.kind == .uploaded] as [String: Any] }])
    }

    private static func dev(_ action: String, _ values: [String], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let tab = browser.active
        let log = tab?.devLog
        func entry() -> DevEntry? { log?.requests.last { $0.url.contains(values.first ?? "") } }
        func state(_ more: [String: Any] = [:]) -> [String: Any] {
            let now: [String: Any] = [
                "offer": Developer.shared.offer ?? "", "on": Developer.shared.isOn(tab?.pageAddress), "panel": tab?.developerPanel ?? false,
                "errors": log?.errors.count ?? 0, "requests": log?.requests.count ?? 0, "count": log?.errorCount ?? 0,
                "messages": log?.errors.map(\.message) ?? [], "urls": log?.requests.map(\.url) ?? [],
                "servers": Array(Developer.shared.servers.keys),
            ]
            return now.merging(more) { $1 }
        }
        switch action {
        case "state": answer(state())
        case "accept":
            guard let key = Developer.shared.offer else { return answer(["error": "no offer"]) }
            browser.setDeveloperMode(true, key: key)
            answer(state())
        case "off":
            browser.toggleDeveloperMode()
            answer(state())
        case "panel":
            browser.toggleDeveloperPanel()
            answer(state())
        case "copy":
            answer(state(["copied": entry().map { DevCopy.agent($0, page: tab?.pageAddress?.absoluteString ?? "") } ?? ""]))
        case "curl":
            answer(state(["copied": entry().map(DevCopy.curl) ?? ""]))
        default:
            answer(["error": "dev state|accept|off|panel|copy URL|curl URL"])
        }
    }

    private static func call(_ action: String, _ values: [String], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let float = CallFloat.shared
        func state() -> [String: Any] {
            let web = float.tab?.built
            return ["showing": float.showing, "tab": float.tab?.id.uuidString.lowercased() ?? "", "x": float.frame.minX,
                    "inPanel": web?.superview?.window === float.window && float.window != nil, "zoom": web?.pageZoom ?? browser.active?.built?.pageZoom ?? 1,
                    "mic": float.status.mic as Any, "camera": float.status.camera as Any, "leaves": float.status.leaves,
                    "window": float.window?.windowNumber ?? 0, "tilesOnly": float.tilesOnly,
                    "away": float.away.tab?.uuidString.lowercased() ?? "", "corners": float.cornersShown,
                    "width": float.frame.width, "height": float.frame.height, "picture": float.sizing.picture ?? 0,
                    "largest": CallShape.largest(screen: (float.window?.screen ?? NSScreen.main)?.frame), "y": float.frame.minY,
                    "room": (float.window?.screen?.visibleFrame).map { [$0.minX, $0.minY, $0.width, $0.height] } ?? []]
        }
        switch action {
        case "state": break
        case "mute": float.toggleMic()
        case "camera": float.toggleCamera()
        case "leave": float.leave()
        case "return": float.goBack()
        case "away": float.putAway()
        case "hover": float.hover(values.first != "off")
        case "global": browser.muteCall()
        case "tiles": float.tilesOnly = values.first != "off"
        case "draw":
            guard let web = float.tab?.built, web.superview?.window === float.window, let path = values.first else {
                return answer(["error": "call draw PATH: no call is floating"])
            }
            web.takeSnapshot(with: nil) { image, _ in
                MainActor.assumeIsolated {
                    guard let data = image?.tiffRepresentation, let picture = NSBitmapImageRep(data: data),
                          let png = picture.representation(using: .png, properties: [:]),
                          (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
                        return answer(["error": "the call gave no picture"])
                    }
                    answer(state().merging(["drawn": path]) { _, new in new })
                }
            }
            return
        case "size": float.sizing.choose(width: CGFloat(Double(values.first ?? "") ?? 0))
        case "edge": float.sizing.shrink()
        case "show", "hide":
            let area = NSScreen.main?.visibleFrame ?? .zero
            let size = float.window?.frame.size ?? .zero
            let shown = action == "show"
            float.window?.level = shown ? .benchBehind : KeepOnTop.panelLevel
            float.window?.setFrameOrigin(shown ? NSPoint(x: area.minX + 40, y: area.maxY - 200 - size.height) : NSPoint(x: -20000, y: -20000))
            if shown { float.window?.orderBack(nil) }
        case "close": browser.closeFront()
        case "key":
            if values.first == "d" { float.toggleMic() } else { float.toggleCamera() }
        default:
            answer(["error": "call state|mute|camera|leave|return|away|hover on|off|global|key d|e|size WIDTH|edge"])
            return
        }
        answer(state())
    }

    private static func mini(_ action: String, _ values: [String], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let player = browser.mini
        let number = Double(values.first ?? "") ?? 0
        switch action {
        case "state": break
        case "toggle": player.toggle()
        case "next": player.track(next: true)
        case "previous": player.track(next: false)
        case "back": player.skip(back: true)
        case "forward": player.skip(back: false)
        case "seek": player.seek(to: number)
        case "speed": player.speed(number)
        case "open": player.open()
        case "dismiss": player.dismiss()
        case "mute": player.mute(values.first.flatMap { tab($0, in: browser) }?.id)
        case "choose":
            if let tab = tab(values.first, in: browser) { player.choose(tab.id) }
        case "hover":
            miniView(browser)?.benchPillHover(values.first != "off")
        case "linehover":
            miniView(browser)?.benchLineHover(values.first != "off")
        case "menu":
            answer(["menu": player.item.map { MiniPlayerView.menuItems($0, mini: player).compactMap(Self.title) } ?? []])
            return
        case "pick":
            let items = player.item.map { MiniPlayerView.menuItems($0, mini: player) } ?? []
            guard let run = items.lazy.compactMap({ item -> (() -> Void)? in
                if case .action(let title, _, _, _, _, let enabled, _, let run) = item, title == values.first, enabled { return run }
                return nil
            }).first else { return answer(["error": "mini pick TITLE: no such item in the card's menu"]) }
            run()
        case "stage":
            guard Store.testing else { return answer(["error": "mini stage only works on a --test run"]) }
            player.staged = values.first.flatMap { staged($0, browser) }
        case "ground":
            guard Store.testing else { return answer(["error": "mini ground only works on a --test run"]) }
            browser.prefs.cards = values.first != "plain"
        case "stacked":
            guard Store.testing else { return answer(["error": "mini stacked only works on a --test run"]) }
            browser.prefs.stackedSpaces = values.first == "on"
        case "point":
            guard Store.testing, let view = miniView(browser) else { return answer(["error": "mini point only works on a --test run"]) }
            view.benchPoint(values.first ?? "off", Double(values.dropFirst().first ?? "") ?? 0)
        case "act":
            guard Store.testing, let view = miniView(browser), let data = values.first?.data(using: .utf8),
                  let given = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return answer(["error": "mini act JSON only works on a --test run"])
            }
            let folder = given["film"] as? String
            view.benchAct(given["steps"] as? [[String: Any]] ?? [], for: given["for"] as? Double ?? 1, film: folder != nil) { watch in
                let saved = folder.map { MiniPlayerView.benchSave(watch, to: URL(fileURLWithPath: $0)) } ?? 0
                answer(["rows": watch.rows, "saved": saved])
            }
            return
        case "film":
            guard Store.testing, let view = miniView(browser) else { return answer(["error": "mini film only works on a --test run"]) }
            if values.first == "on" {
                view.filming = []
            } else if let folder = values.first {
                let saved = view.saveFilm(to: URL(fileURLWithPath: folder))
                view.filming = nil
                return answer(["saved": saved])
            }
        default:
            answer(["error": "mini state|toggle|next|previous|back|forward|seek F|speed R|open|dismiss|mute|choose ID|menu|pick TITLE|hover [off]|linehover [off]|point line|card|off [SHARE]|act JSON|stage JSON|off|ground plain|glass|stacked on|off|film on|FOLDER"])
            return
        }
        answer(miniState(browser))
    }

    private static func staged(_ text: String, _ browser: Browser) -> MiniPlayer.Item? {
        guard let data = text.data(using: .utf8), let given = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func picture(_ name: String) -> NSImage? {
            let colours: [String: (NSColor, NSColor)] = ["warm": (.systemOrange, .systemPink), "cool": (.systemTeal, .systemIndigo),
                                                         "green": (.systemGreen, .systemTeal)]
            guard let (one, two) = colours[name] else { return nil }
            return NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
                NSGradient(starting: one, ending: two)?.draw(in: rect, angle: 60)
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn: NSRect(x: 105, y: 105, width: 90, height: 90)).fill()
                return true
            }
        }
        let duration = given["duration"] as? Double ?? 0
        let playing = given["playing"] as? Bool ?? true
        let art = given["art"] as? String ?? ""
        let icon = art == "icon" ? browser.tabs.compactMap(\.icon).first ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil) : nil
        return MiniPlayer.Item(
            id: browser.tabs.first?.id ?? UUID(), title: given["title"] as? String ?? "", detail: given["detail"] as? String ?? "",
            site: given["site"] as? String ?? "", art: picture(art), playing: playing,
            pair: MiniPair(rawValue: given["pair"] as? String ?? "") ?? .tracks, previous: true, next: true,
            position: duration > 0 ? MiniPosition(time: given["time"] as? Double ?? 0, duration: duration, rate: given["rate"] as? Double ?? 1,
                                                  playing: playing, at: Date()) : nil,
            live: given["live"] as? Bool ?? false, rate: given["rate"] as? Double ?? 1, speed: given["speed"] as? Bool ?? false,
            seekable: given["seekable"] as? Bool ?? (duration > 0), muted: given["muted"] as? Bool ?? false, skip: 15, icon: icon)
    }

    private static func title(_ item: KitMenuItem) -> String? {
        switch item {
        case .action(let title, _, _, _, _, _, _, _): return title
        case .picture(let title, _, _): return title
        case .submenu(let title, _, _): return title
        case .header(let title): return title
        case .separator: return nil
        }
    }

    static func miniState(_ browser: Browser) -> [String: Any] {
        let player = browser.mini
        func row(_ item: MiniPlayer.Item) -> [String: Any] {
            let now = Date()
            return ["id": item.id.uuidString, "title": item.title, "detail": item.detail, "site": item.site, "playing": item.playing,
                    "pair": item.pair.rawValue, "previous": item.previous, "next": item.next, "art": item.art != nil,
                    "time": item.position?.elapsed(now: now) ?? -1, "duration": item.position?.duration ?? 0,
                    "rate": item.rate, "speed": item.speed, "seekable": item.seekable, "live": item.live, "skip": item.skip,
                    "muted": item.muted, "waiting": item.waiting, "icon": item.icon != nil]
        }
        let roles = (browser.tabs + browser.parkedTabs).filter { $0.sound.role != .none }
            .map { (Bench.short($0), $0.sound.role.rawValue) }
        return ["shown": player.item.map(row) ?? NSNull(), "items": player.items.map(row),
                "roles": Dictionary(roles, uniquingKeysWith: { a, _ in a }), "view": miniView(browser)?.benchState ?? NSNull()]
    }

    static func miniView(_ browser: Browser) -> MiniPlayerView? {
        func find(_ view: NSView) -> MiniPlayerView? {
            if let found = view as? MiniPlayerView { return found }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return browser.window?.contentView.flatMap(find)
    }

    static func tab(_ id: String?, in browser: Browser) -> Tab? {
        guard let id else { return browser.active }
        return (browser.tabs + browser.parkedTabs).first { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }
    }

    private static func shield(_ action: String, _ values: [String], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let lists = ShieldLists.shared
        func state() -> [String: Any] {
            ["enabled": Shield.shared.enabled, "fallback": Shield.shared.fallback != nil, "downloaded": Shield.shared.downloaded.count,
             "rules": lists.saved.rules, "skipped": lists.saved.skipped, "checked": lists.saved.checked?.timeIntervalSince1970 ?? 0,
             "identifiers": lists.saved.identifiers, "busy": lists.busy, "trouble": lists.trouble ?? "",
             "paused": Array(Shield.shared.paused).sorted(), "offer": Shield.shared.offer ?? ""]
        }
        switch action {
        case "state":
            answer(state())
        case "fetch":
            lists.sources = values.enumerated().map { index, address in
                FilterLists.Source(id: "bench-\(index)", name: "Bench \(index)", address: address)
            }
            Task {
                await lists.refresh(force: true)
                answer(state())
            }
        case "pause":
            guard let host = values.first else { return answer(["error": "shield pause HOST [off]"]) }
            Shield.shared.pause(host, values.dropFirst().first != "off")
            answer(state())
        case "reloaded":
            guard let host = values.first else { return answer(["error": "shield reloaded HOST"]) }
            Shield.shared.reloaded(host)
            answer(state())
        default:
            answer(["error": "shield state|fetch URL…|pause HOST [off]|reloaded HOST"])
        }
    }
}
