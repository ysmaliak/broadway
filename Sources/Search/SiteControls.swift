import AppKit
import Combine

enum SitePermissions {
    struct Entry: Identifiable, Equatable {
        let key: String
        let name: String
        let allowed: Bool
        var popup: String? = nil
        var tab: UUID? = nil
        var id: String { key }

        var origin: String? {
            guard key.hasPrefix("capture."), let bar = key.lastIndex(of: "|") else { return nil }
            return String(key[key.index(key.startIndex, offsetBy: "capture.".count)..<bar])
        }

        var kind: String {
            guard popup == nil, let bar = key.lastIndex(of: "|") else { return "popups" }
            return String(key[key.index(after: bar)...])
        }
    }

    struct Site: Equatable {
        let site: String
        let entries: [Entry]
    }

    private static let kinds: [(suffix: String, name: String)] = [
        ("0", "Camera"), ("1", "Microphone"), ("2", "Camera and Microphone"),
        ("location", "Location"), ("notifications", "Notifications"), (LocalNetwork.kind, "Local network"),
    ]

    static func entries(for origin: String, in defaults: [String: Any]) -> [Entry] {
        kinds.compactMap { kind in
            let key = "capture.\(origin)|\(kind.suffix)"
            guard let allowed = defaults[key] as? Bool else { return nil }
            return Entry(key: key, name: kind.name, allowed: allowed)
        }
    }

    static func popups(_ site: String) -> Entry {
        Entry(key: "popups." + site, name: "Pop-ups", allowed: true, popup: site)
    }

    @MainActor
    static func entries(for page: URL?, in defaults: [String: Any], popups sites: Set<String>) -> [Entry] {
        guard let page, let scheme = page.scheme, let host = page.host() else { return [] }
        var out = entries(for: Browser.origin(scheme, host, page.port ?? 0), in: defaults)
        if let site = BlockedPopups.site(of: page), sites.contains(site) { out.append(popups(site)) }
        return out
    }

    @MainActor
    static func all(in defaults: [String: Any], popups sites: Set<String>) -> [Site] {
        let origins = Set(defaults.keys.compactMap { key -> String? in
            guard key.hasPrefix("capture."), let bar = key.lastIndex(of: "|") else { return nil }
            return String(key[key.index(key.startIndex, offsetBy: "capture.".count)..<bar])
        })
        let kept = origins.map { Site(site: $0, entries: entries(for: $0, in: defaults)) }.filter { !$0.entries.isEmpty }
        let popped = sites.map { Site(site: $0, entries: [popups($0)]) }
        return (kept + popped).sorted { (name($0.site), $0.site) < (name($1.site), $1.site) }
    }

    @MainActor
    static func name(_ site: String) -> String {
        guard let url = URL(string: site), let scheme = url.scheme else { return site }
        if Browser.extensionScheme(scheme) { return Browser.extensionName(url.host() ?? "") }
        return SiteCard.site(url)
    }

    static func words(_ entry: Entry) -> String {
        let can = entry.allowed ? "Can" : "Can't"
        switch entry.kind {
        case "0": return "\(can) use your camera"
        case "1": return "\(can) use your microphone"
        case "2": return "\(can) use your camera and microphone"
        case "location": return "\(can) see where you are"
        case "notifications": return "\(can) send notifications"
        case LocalNetwork.kind: return "\(can) reach your local network"
        default: return "Can open pop-ups without a click"
        }
    }

    static func rowID(_ entry: Entry) -> String {
        switch entry.kind {
        case "notifications": return "site.notify." + (entry.origin ?? "")
        case LocalNetwork.kind: return "site.network." + (entry.origin ?? "")
        case "popups": return "site.popup." + (entry.popup ?? "")
        default: return "site.capture." + entry.key.dropFirst("capture.".count)
        }
    }

    static func question(_ entry: Entry, name: String) -> SettingsQuestion {
        switch entry.kind {
        case "notifications": return .notifications(name)
        case LocalNetwork.kind: return .localNetwork(name)
        case "popups": return .popups(entry.popup ?? name)
        case "0": return .capture("camera", name)
        case "1": return .capture("microphone", name)
        case "2": return .capture("camera and microphone", name)
        default: return .capture("location", name)
        }
    }

    static func remove(_ entry: Entry, from defaults: UserDefaults) {
        defaults.removeObject(forKey: entry.key)
    }

    @MainActor
    static func forget(_ entry: Entry) {
        remove(entry, from: Store.settings)
        if entry.kind == "notifications", let origin = entry.origin { PageNotifications.forget(origins: [origin]) }
        LocalNetworkGuard.shared.refitAll()
        SiteNotifications.shared.changed()
    }

    @MainActor
    static func own(_ tab: Tab) -> [Entry] {
        guard let page = tab.pageAddress else { return [] }
        var out: [Entry] = []
        if let origin = LocalNetwork.origin(page), let allowed = LocalNetworkGuard.shared.answer(for: origin, tab: tab.id, shy: true) {
            out.append(Entry(key: LocalNetwork.key(origin), name: "Local network", allowed: allowed, tab: tab.id))
        }
        if let site = BlockedPopups.site(of: page), tab.popupSites.contains(site) {
            out.append(Entry(key: "popups." + site, name: "Pop-ups", allowed: true, popup: site, tab: tab.id))
        }
        return out
    }

    @MainActor
    static func forget(_ entry: Entry, in tab: Tab?, prefs: Preferences) {
        if let owner = entry.tab {
            guard let tab, tab.id == owner else { return }
            if let site = entry.popup {
                tab.popupSites.remove(site)
            } else if let origin = entry.origin {
                LocalNetworkGuard.shared.forget(origin, tab: owner)
            }
            return
        }
        if let site = entry.popup {
            prefs.popupSites.remove(site)
            return
        }
        forget(entry)
    }
}

enum SiteControlsBench {
    static func step(_ name: String?) -> SiteCard.Step {
        switch name {
        case "security": return .security
        case "permissions": return .permissions
        case "hidden": return .hidden
        case "translate": return .translate
        case "more": return .more
        case "developer": return .developer
        default: return .front
        }
    }
}

@MainActor
enum SiteSurfaces {
    static let names = ["popup-sign", "translate-sign",
                        "capture-question", "screen-question", "password-offer", "shield-offer"]

    static func tab(_ request: [String: Any]) -> Tab {
        let tab = Tab(bench: true)
        tab.restore(url: URL(string: request["url"] as? String ?? "https://www.example.com/news?id=7")!, title: "Example")
        return tab
    }

    static func make(_ name: String, _ request: [String: Any]) -> NSView? {
        guard let browser = Browsers.front ?? Browsers.primary else { return nil }
        let tab = tab(request)
        let shown = request["shown"] as? Bool ?? false
        switch name {
        case "popup-sign":
            tab.blockedPopups = [BlockedPopup(url: URL(string: "https://ads.example.com/pop"))]
            let sign = PopupSignView(browser: browser, tab: tab)
            sign.shown = shown
            return Surface(sign, pad: 5)
        case "translate-sign":
            tab.translation = TranslationMark(from: "fr", to: "en", phase: request["working"] as? Bool == true ? .working : .done)
            let sign = TranslateSignView(tab: tab)
            sign.shown = shown
            return Surface(sign, pad: 5)
        case "capture-question":
            let wants = request["wants"] as? String ?? "camera"
            let ask = Browser.CaptureAsk(host: "meet.example.com", wants: wants, once: wants == "location", keeps: true)
            return Surface(CaptureQuestionView(browser: browser, ask: ask), pad: 8)
        case "screen-question":
            let ask = Browser.CaptureAsk(host: "meet.example.com", wants: "screen", screen: true, sound: request["sound"] as? Bool ?? false)
            return Surface(ScreenQuestionView(browser: browser, ask: ask), pad: 8, width: 460)
        case "password-offer":
            let login = Login(host: "example.com", user: request["user"] as? String ?? "ada@example.com", password: "x")
            return Surface(PasswordOfferView(browser: browser, offer: Browser.Offer(login: login, changed: request["changed"] as? Bool ?? false)), pad: 8)
        case "shield-offer":
            return Surface(ShieldOfferView(browser: browser, shield: Shield.shared, host: "news.example.com"), pad: 8)
        default:
            return nil
        }
    }

    private final class Surface: KitBox {
        let inner: NSView
        let pad: CGFloat
        let size: NSSize

        init(_ inner: NSView, pad: CGFloat, width: CGFloat? = nil, ground: NSColor? = nil) {
            self.inner = inner
            self.pad = pad
            if let question = inner as? QuestionView {
                size = question.fit(width)
            } else {
                size = inner.intrinsicContentSize
            }
            super.init(frame: .zero)
            fill = ground
            addSubview(inner)
            frame = NSRect(origin: .zero, size: fittingSize)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: NSSize { NSSize(width: size.width + pad * 2, height: size.height + pad * 2) }
        override var fittingSize: NSSize { intrinsicContentSize }

        override func layout() {
            super.layout()
            inner.frame = NSRect(x: pad, y: pad, width: size.width, height: size.height)
        }
    }
}
