import AppKit

@MainActor
enum BenchPages {
    static let names = ["passwords-page", "import-page", "pairing-card", "settings-routes"]
    static let verbs: Set<String> = ["ownpage"]

    static func run(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "ownpage only works on a --test run"]); return }
        guard let window = browser.window, let root = window.contentView else { answer(["error": "no window"]); return }
        func front() -> NSView? {
            let shown: (NSView) -> Bool = { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
            if let holder = root.kitSubviews(of: InternalPageHolder.self).first(where: { shown($0) && $0.tab.id == browser.activeID }) { return holder }
            if let trouble = root.kitSubviews(of: TroubleView.self).first(where: shown) { return trouble }
            return root.kitSubviews(of: NewTabPageView.self).first(where: shown)
        }
        guard let page = front() else { answer(["error": "no page of Broadway's own in front"]); return }
        let holder = page as? InternalPageHolder
        if let words = request["find"] as? String {
            switch holder?.kind {
            case .history: browser.recallHunt = words
            case .files: (holder?.content as? FilesPageView)?.type(words)
            case .bookmarks: (holder?.content as? BookmarksPageView)?.body.search(words)
            case .passwords: browser.hunting = words
            default: break
            }
        }
        if let clearing = request["clearing"] as? Bool { browser.recallMode = clearing ? .clearing : .history }
        if let adding = request["adding"] as? Bool, let passwords = holder?.content as? PasswordsPageView, passwords.body.adding != adding {
            passwords.body.toggleAdding()
        }
        if let site = request["open"] as? Int, let list = (holder?.content as? PasswordsPageView)?.body.list, list.sites.indices.contains(site) {
            list.expandItem(list.sites[site])
        }
        page.needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            page.layoutSubtreeIfNeeded()
            if let kind = request["hover"] as? String {
                let rows = page.kitSubviews(of: KitHoverView.self).filter { "\(type(of: $0))" == kind && !$0.isHiddenOrHasHiddenAncestor }
                let index = request["row"] as? Int ?? 0
                if rows.indices.contains(index) {
                    let row = rows[index]
                    KitHoverView.pointerStandIn = (window, row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil))
                } else {
                    KitHoverView.pointerStandIn = (window, NSPoint(x: -1000, y: -1000))
                }
                page.kitSubviews(of: KitHoverView.self).forEach { $0.settleHover() }
                let accounts = page.kitSubviews(of: PasswordsAccountCell.self)
                if kind == "PasswordsAccountCell", accounts.indices.contains(index) { accounts[index].mouseEntered(with: NSEvent()) }
                page.layoutSubtreeIfNeeded()
            }
            answer(["kind": holder?.kind.rawValue ?? "\(type(of: page))",
                    "size": [Double(page.bounds.width), Double(page.bounds.height)],
                    "views": describe(page, in: page, depth: 0)])
        }
    }

    private static func describe(_ view: NSView, in page: NSView, depth: Int) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for child in view.subviews where !child.isHidden && child.bounds.width > 0 && child.bounds.height > 0 {
            let rect = child.convert(child.bounds, to: page)
            let top = page.isFlipped ? rect.minY : page.bounds.height - rect.maxY
            var entry: [String: Any] = ["kind": "\(type(of: child))", "depth": depth,
                                        "frame": [rect.minX, top, rect.width, rect.height].map { (Double($0) * 4).rounded() / 4 }]
            if let label = child as? KitLabel { entry["text"] = label.text }
            if let paragraph = child as? KitParagraph { entry["text"] = paragraph.text }
            if let field = child as? NSTextField { entry["text"] = field.stringValue.isEmpty ? field.placeholderString ?? "" : field.stringValue }
            if let button = child as? NSButton { entry["text"] = button.title }
            if let button = child as? KitButton { entry["text"] = button.accessibilityLabel() ?? "" }
            if let symbol = child as? KitSymbol { entry["text"] = symbol.name }
            out.append(entry)
            out += describe(child, in: page, depth: depth + 1)
        }
        return out
    }

    static func make(_ name: String, _ request: [String: Any]) -> NSView? {
        guard let browser = Browsers.all.first else { return nil }
        let style = request["style"] as? String
        switch name {
        case "passwords-page":
            browser.hunting = ""
            browser.stage(saved: style == "empty" ? [] : saved)
            return page(PasswordsPageView(browser: browser))
        case "import-page":
            plantProfiles()
            browser.bringingIn = style ?? ""
            return page(ImportPageView(browser: browser))
        case "pairing-card":
            let apple = ApplePasswords(makeLink: { StandInLink() })
            switch style {
            case "starting": apple.stage(.starting)
            case "idle": apple.stage(.idle, trouble: "That code didn't match. Connect again for a new one.")
            default: apple.stage(.code)
            }
            let pairing = Browser.ApplePairing(tab: browser.active?.id ?? UUID(), spot: CGRect(x: 0, y: 0, width: 300, height: 30))
            return PairingCardSurface(browser: browser, apple: apple, pairing: pairing)
        case "settings-routes":
            return routes(browser)
        default:
            return nil
        }
    }

    private static let saved = [
        Kept(host: "github.com", user: "me@example.com"),
        Kept(host: "github.com", user: "work@example.com"),
        Kept(host: "mail.example.org", user: "someone.with.a.long.name@example.org"),
        Kept(host: "news.example", user: ""),
        Kept(host: "shop.example", user: "buyer"),
    ]

    private static func page(_ view: NSView) -> NSView {
        let ground = KitBox(fill: .windowBackgroundColor)
        ground.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        ground.addSubview(view)
        NSLayoutConstraint.activate([
            ground.widthAnchor.constraint(equalToConstant: 820),
            ground.heightAnchor.constraint(equalToConstant: 640),
            view.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
            view.topAnchor.constraint(equalTo: ground.topAnchor),
            view.bottomAnchor.constraint(equalTo: ground.bottomAnchor),
        ])
        return ground
    }

    private static func plantProfiles() {
        let base = Chromium.base
        let marks: [(String, String)] = [("Broadway", "https://broadway.example/"), ("Docs", "https://docs.example/"), ("News", "https://news.example/")]
        let children = marks.map { ["type": "url", "name": $0.0, "url": $0.1] }
        let roots: [String: Any] = [
            "bookmark_bar": ["type": "folder", "name": "Bookmarks bar", "children": children],
            "other": ["type": "folder", "name": "Other bookmarks", "children": []],
            "synced": ["type": "folder", "name": "Mobile bookmarks", "children": []],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: ["roots": roots, "version": 1]) else { return }
        for folder in ["Google/Chrome/Default", "Google/Chrome/Profile 1", "BraveSoftware/Brave-Browser/Default"] {
            let profile = base.appendingPathComponent(folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try? data.write(to: profile.appendingPathComponent("Bookmarks"))
        }
        let state: [String: Any] = ["profile": ["info_cache": ["Default": ["name": "Personal"], "Profile 1": ["name": "Work"]],
                                                "last_used": "Default"]]
        if let local = try? JSONSerialization.data(withJSONObject: state) {
            try? local.write(to: base.appendingPathComponent("Google/Chrome/Local State"))
        }
    }

    private static func routes(_ browser: Browser) -> NSView {
        LinkRules.shared.replaceAll([
            LinkRule(match: .site("notion.so"), target: .peek),
            LinkRule(match: .site("figma.com"), from: .otherApps, target: .window(nil)),
            LinkRule(match: .site("linear.app"), target: .space(browser.spaceID, folder: nil)),
        ])
        let shell = SettingsShell()
        shell.go(to: .links)
        let page = SettingsPageView(browser: browser, shell: shell)
        page.translatesAutoresizingMaskIntoConstraints = false
        page.widthAnchor.constraint(equalToConstant: 620).isActive = true
        page.rebuild()
        page.layoutSubtreeIfNeeded()
        page.frame = NSRect(origin: .zero, size: page.fittingSize)
        return page
    }
}
