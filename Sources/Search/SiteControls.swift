import AppKit
import Combine

enum SitePermissions {
    struct Entry: Identifiable, Equatable {
        let key: String
        let name: String
        let allowed: Bool
        var id: String { key }
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

    static func remove(_ entry: Entry, from defaults: UserDefaults) {
        defaults.removeObject(forKey: entry.key)
    }

    @MainActor
    static func forget(_ entry: Entry) {
        remove(entry, from: Store.settings)
        LocalNetworkGuard.shared.refitAll()
        SiteNotifications.shared.changed()
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
            return Surface(sign, pad: 4)
        case "translate-sign":
            tab.translation = TranslationMark(from: "fr", to: "en", phase: request["working"] as? Bool == true ? .working : .done)
            let sign = TranslateSignView(tab: tab)
            sign.shown = shown
            return Surface(sign, pad: 4)
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
