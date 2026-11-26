import AppKit
import Combine
import SecurityInterface
import Translation

@MainActor
enum SiteCardPanel {
    private static var card: SiteCard?
    private static var pills: [ObjectIdentifier: () -> NSView?] = [:]
    private static var moved: AnyCancellable?

    static var isShown: Bool { card != nil }
    static var menu: NSMenu? { card?.menu }

    static func register(_ pill: NSView, for browser: Browser) {
        pills[ObjectIdentifier(browser)] = { [weak pill] in pill }
    }

    static func toggle(_ browser: Browser, step: SiteCard.Step = .front) {
        if isShown {
            hide()
            return
        }
        browser.cancelTabEdit()
        guard let tab = browser.active, tab.isWeb, let window = browser.window ?? Links.window else { return }
        if let pill = pills[ObjectIdentifier(browser)]?(), pill.window === window, !browser.folded {
            show(for: tab, in: browser, from: pill.bounds, of: pill, step: step)
        } else if let content = window.contentView {
            let y = content.isFlipped ? 16 : content.bounds.height - 16
            show(for: tab, in: browser, from: NSRect(x: 16, y: y, width: 1, height: 1), of: content, step: step)
        }
        moved = kitObserve(initial: false, { [weak browser] in browser?.activeID }) { _ in hide() }
    }

    private static func show(for tab: Tab, in browser: Browser, from rect: NSRect, of view: NSView, step: SiteCard.Step) {
        let made = SiteCard(browser: browser, tab: tab, step: step)
        card = made
        made.onClose = { [weak made] in
            guard let made, SiteCardPanel.card === made else { return }
            SiteCardPanel.card = nil
            SiteCardPanel.moved = nil
        }
        RunLoop.main.perform(inModes: [.default, .common]) { [weak view] in
            guard SiteCardPanel.card === made, let view, view.window != nil else {
                made.onClose?()
                return
            }
            KitMenu.popUp(made.menu, from: rect, of: view)
        }
    }

    static func hide() {
        moved = nil
        let going = card
        card = nil
        going?.menu.cancelTracking()
    }
}

@MainActor
final class SiteCard: NSObject, NSMenuDelegate {
    enum Step {
        case front, security, permissions, hidden, translate, more, developer
    }

    nonisolated static func site(_ url: URL) -> String {
        if let host = url.host(), !host.isEmpty {
            return Address.withoutWWW(host)
        }
        if url.isFileURL { return "File" }
        return url.scheme ?? url.absoluteString
    }

    let browser: Browser
    let tab: Tab
    let step: Step
    let menu = NSMenu()
    var onClose: (() -> Void)?

    private var certified: Bool?
    private static var languages: [String] = []
    private static var asked = false
    private var translateMenu: NSMenu?
    private var safetyItem: NSMenuItem?
    private var hiddenMenu: NSMenu?
    private var veils: [Veil] = []

    init(browser: Browser, tab: Tab, step: Step = .front) {
        self.browser = browser
        self.tab = tab
        self.step = step
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        rebuild()
        certify()
        askLanguages()
    }

    func rebuild() {
        menu.removeAllItems()
        for item in items(step) { menu.addItem(item) }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === hiddenMenu { browser.stopPeeking() }
        guard menu === self.menu else { return }
        if step == .hidden { browser.stopPeeking() }
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu === hiddenMenu || (step == .hidden && menu === self.menu) else { return }
        if let item, item.tag > 0, veils.indices.contains(item.tag - 1) {
            browser.peek(veils[item.tag - 1])
        } else {
            browser.stopPeeking()
        }
    }

    private func items(_ step: Step) -> [NSMenuItem] {
        switch step {
        case .front: return front()
        case .security:
            guard let safety else { return front() }
            return header + security(safety)
        case .permissions: return header + permissions()
        case .hidden: return header + hiddenHere()
        case .translate: return header + translating()
        case .more: return header + moreItems()
        case .developer: return header + developerItems()
        }
    }

    private func action(_ title: String, key id: String? = nil, on: Bool? = nil, enabled: Bool = true,
                        run: @escaping () -> Void) -> NSMenuItem {
        let item = KitMenuAction(title, key: "", run: run)
        if let id, let key = ShortcutStore.shared.key(for: id)?.menuKey {
            item.keyEquivalent = key.key
            item.keyEquivalentModifierMask = key.mask
        }
        if let on { item.state = on ? .on : .off }
        item.isEnabled = enabled
        return item
    }

    private func submenu(_ title: String, id: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(id)
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        sub.delegate = self
        items.forEach(sub.addItem)
        item.submenu = sub
        return item
    }

    private var header: [NSMenuItem] {
        tab.pageAddress.map { [NSMenuItem.sectionHeader(title: SiteCard.site($0))] } ?? []
    }

    private func front() -> [NSMenuItem] {
        var out = header
        let buttons = Array(Extensions.shared.buttons.prefix(8))
        for button in buttons {
            let item = action(button.badge.isEmpty ? button.name : "\(button.name) (\(button.badge))") {
                Extensions.shared.press(button.id)
            }
            item.image = SiteCard.icon(button)
            item.identifier = NSUserInterfaceItemIdentifier("site.extension.\(button.id)")
            out.append(item)
        }
        if !buttons.isEmpty { out.append(.separator()) }
        if let safety {
            let item = submenu(safety.title, id: "site.security", security(safety))
            safetyItem = item
            out.append(item)
        }
        if !siteChoices.isEmpty {
            out.append(submenu("Permissions", id: "site.permissions", permissions()))
        }
        out += blocking
        if tab.isWeb {
            let count = browser.hereVeils.count
            if count > 0 {
                let item = submenu("Hidden Here (\(count))", id: "site.hidden", hiddenHere())
                hiddenMenu = item.submenu
                out.append(item)
            } else {
                out.append(action("Hide Elements…", key: "view.hide") { [weak self] in self?.browser.toggleHiding() })
            }
        }
        if tab.isWeb {
            let item = submenu(tab.translator == nil ? "Translate" : "Translated", id: "site.translate", translating())
            translateMenu = item.submenu
            out.append(item)
        }
        out += zoom
        out.append(.separator())
        out.append(action("Copy Address", key: "tabs.copyAddress") { [weak self] in self?.browser.copyPage(.address) })
        out.append(action("Copy Page as Markdown", key: "edit.copyPageMarkdown") { [weak self] in self?.browser.copyPageAsMarkdown() })
        out.append(.separator())
        if hasMore {
            out.append(submenu("More", id: "site.more", moreItems()))
        }
        out.append(submenu("Developer", id: "site.developer", developerItems()))
        return out
    }

    private static func icon(_ button: Extensions.Button) -> NSImage? {
        let size = NSSize(width: 16, height: 16)
        guard let source = button.icon else { return KitGlyph.plain("puzzlepiece.extension") }
        return NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: button.enabled ? 1 : 0.4)
            return true
        }
    }

    private var keepsAwakeRow: Bool { browser.prefs.keepsSitesAwake && tab.awakeHost != nil }

    private var web: Bool {
        guard let url = tab.pageAddress else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased())
    }

    private var hasMore: Bool {
        guard let url = tab.pageAddress else { return keepsAwakeRow || browser.canDusk(tab) }
        let web = ["http", "https"].contains(url.scheme?.lowercased()) && url.host() != nil && !tab.shy
        let sounds = web && !Store.settings.bool(forKey: Preferences.waitsKey)
        let floats = web && Players.knows(url)
        return sounds || floats || browser.canDusk(tab) || keepsAwakeRow || clearable
    }

    private var clearable: Bool { browser.clearableSite(tab) != nil }

    private func moreItems() -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        if !tab.shy, !Store.settings.bool(forKey: Preferences.waitsKey), web, let url = tab.pageAddress, let host = url.host() {
            let call = CallSound.plays(url, agent: tab.agent)
            let on = call || Autoplay.allowed(host)
            let item = action("Play Sound by Itself", on: on, enabled: !call) { Autoplay.set(!on, for: host) }
            item.toolTip = call ? CallSound.always : "Takes effect from the next page"
            out.append(item)
        }
        if !tab.shy, web,
           let url = tab.pageAddress, Players.knows(url), let host = url.host() {
            let on = Grounded.holds(host)
            out.append(action("Don't Float Videos Here", on: on) { Grounded.set(!on, for: host) })
        }
        if browser.canDusk(tab) {
            let on = tab.dusked
            out.append(action("Darken This Site", key: "view.dusk", on: on) { [weak self] in
                guard let self else { return }
                self.browser.dusk(!on, self.tab)
            })
        }
        if keepsAwakeRow {
            let on = browser.keepsAwake(tab)
            let item = action("Keep This Site Awake", on: on) { [weak self] in
                guard let self else { return }
                self.browser.keepAwake(!on, for: self.tab)
            }
            item.toolTip = tab.shy ? "Only in this private window, until you close it. Uses more memory."
                : "Keeps the tab from sleeping or closing itself, even when memory is low. You can still close it."
            out.append(item)
        }
        if clearable {
            out.append(action("Clear Cookies and Reload", key: "view.clearSite") { [weak self] in
                guard let self else { return }
                self.browser.askToClearSite(self.tab)
            })
        }
        return out
    }

    private func developerItems() -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        if tab.isWeb {
            out.append(action(tab.device == nil ? "Device Mode" : "Leave Device Mode", key: "view.device") { [weak self] in
                self?.browser.toggleDevice()
            })
        }
        if tab.isWeb, !tab.shy, let server = LocalServer.key(tab.pageAddress) {
            let on = Developer.shared.servers[server] == true
            out.append(action("Developer Mode", on: on) { [weak self] in self?.browser.setDeveloperMode(!on, key: server) })
        }
        out.append(action("Copy for Agent", key: "edit.copyForAgent") { [weak self] in self?.browser.copyForAgent() })
        return out
    }

    private var siteChoices: [SitePermissions.Entry] {
        if tab.shy { return SitePermissions.own(tab) }
        return SitePermissions.entries(for: tab.pageAddress, in: Store.settings.dictionaryRepresentation(), popups: browser.prefs.popupSites)
    }

    private func permissions() -> [NSMenuItem] {
        var out = [NSMenuItem.sectionHeader(title: "Forget a Choice")]
        for entry in siteChoices {
            let item = action(entry.name) { [weak self] in
                guard let self else { return }
                SitePermissions.forget(entry, in: self.tab, prefs: self.browser.prefs)
            }
            item.subtitle = entry.allowed ? "Allowed" : "Refused"
            item.identifier = NSUserInterfaceItemIdentifier("site.permission.\(entry.key)")
            out.append(item)
        }
        return out
    }

    private func hiddenHere() -> [NSMenuItem] {
        veils = browser.hereVeils
        var out = [NSMenuItem.sectionHeader(title: "Restore")]
        for (index, veil) in veils.enumerated() {
            let item = action(veil.label) { [weak self] in
                guard let self else { return }
                self.browser.stopPeeking()
                self.browser.restore(veil)
            }
            item.tag = index + 1
            out.append(item)
        }
        out.append(.separator())
        out.append(action("Restore All") { [weak self] in
            guard let self else { return }
            self.browser.stopPeeking()
            self.browser.restoreAll()
        })
        out.append(action("Hide Something Else…") { [weak self] in self?.browser.toggleHiding() })
        return out
    }

    private func translating() -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        if tab.translator != nil {
            out.append(action("Show Original") { [weak self] in self?.tab.toggleTranslation() })
        } else {
            let name = PageTranslator.name(PageTranslator.code(PageTranslator.reader(for: tab)))
            out.append(action("Translate to \(name)") { [weak self] in self?.tab.toggleTranslation() })
        }
        let languages = SiteCard.languages
        guard !languages.isEmpty else { return out }
        out.append(.separator())
        out.append(.sectionHeader(title: "Translate To"))
        for code in languages {
            out.append(action(PageTranslator.name(code)) { [weak self] in
                guard let tab = self?.tab else { return }
                tab.translator?.end(restore: true)
                PageTranslator.start(tab, to: Locale.Language(identifier: code))
            })
        }
        return out
    }

    private func askLanguages() {
        guard tab.isWeb, !SiteCard.asked else { return }
        SiteCard.asked = true
        Task { @MainActor [weak self] in
            let found = await LanguageAvailability().supportedLanguages
            SiteCard.languages = Set(found.map(PageTranslator.code)).sorted { PageTranslator.name($0) < PageTranslator.name($1) }
            guard let self else { return }
            if let sub = self.translateMenu {
                sub.removeAllItems()
                self.translating().forEach(sub.addItem)
            } else if self.step == .translate {
                self.rebuild()
            }
        }
    }

    private var blocking: [NSMenuItem] {
        guard !tab.shy, browser.prefs.shielded, let url = tab.pageAddress, ["http", "https"].contains(url.scheme?.lowercased()),
              let host = browser.curtain.host(of: url) else { return [] }
        let on = !Shield.shared.isPaused(on: host)
        let item = action("Block Ads and Trackers", on: on) { [weak self] in
            Shield.shared.pause(host, on)
            self?.browser.reload()
        }
        item.identifier = NSUserInterfaceItemIdentifier("site.shield")
        return [item]
    }

    private var zoom: [NSMenuItem] {
        let percent = Int((tab.zoom * 100).rounded())
        return [
            action("Zoom In", key: "view.zoomIn") { [weak self] in self?.browser.zoom(by: 1.1) },
            action("Zoom Out", key: "view.zoomOut") { [weak self] in self?.browser.zoom(by: 1 / 1.1) },
            action("Actual Size (\(percent)%)", key: "view.actualSize") { [weak self] in self?.browser.resetZoom() },
        ]
    }

    private func security(_ safety: Safety) -> [NSMenuItem] {
        var out = [NSMenuItem.sectionHeader(title: safety.title), KitMenu.note(safety.detail)]
        if let trust = safety.trust {
            out.append(.separator())
            out.append(action(certified == false ? "Show Invalid Certificate" : "Show Certificate") { SiteCard.show(trust) })
        }
        return out
    }

    private struct Safety {
        let symbol: String
        let title: String
        let detail: String
        let trust: SecTrust?
    }

    private var safety: Safety? {
        switch tab.pageAddress?.scheme {
        case "https":
            let trust = tab.built?.serverTrust
            if certified == false {
                return Safety(
                    symbol: "lock.open", title: "Connection is not secure",
                    detail: "This site's certificate isn't trusted by this Mac. Someone could be reading what you send.",
                    trust: trust
                )
            }
            if tab.built?.hasOnlySecureContent == false {
                return Safety(
                    symbol: "lock.trianglebadge.exclamationmark", title: "Parts of this page are not secure",
                    detail: "This page is private, but some of what it shows came over plain http, where anyone on the network could read or change it",
                    trust: trust
                )
            }
            return Safety(
                symbol: "lock", title: "Connection is secure",
                detail: "What you send to this site, like passwords or credit card numbers, is private",
                trust: trust
            )
        case "http":
            return Safety(
                symbol: "lock.open", title: "Connection is not secure",
                detail: "Don't enter passwords or credit card numbers here, because anything sent to this site can be read on the way",
                trust: nil
            )
        default:
            return nil
        }
    }

    private func certify() {
        guard certified == nil, let trust = tab.built?.serverTrust else { return }
        weak var card = self
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = SecTrustEvaluateWithError(trust, nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let card else { return }
                    card.certified = ok
                    card.refreshSafety()
                }
            }
        }
    }

    private func refreshSafety() {
        guard let safety else { return }
        if let item = safetyItem, let sub = item.submenu {
            item.title = safety.title
            sub.removeAllItems()
            security(safety).forEach(sub.addItem)
        } else if step == .security {
            rebuild()
        }
    }

    private static func show(_ trust: SecTrust) {
        guard let window = Links.window else { return }
        SFCertificatePanel.shared().beginSheet(
            for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust, showGroup: false
        )
    }
}

enum MenuMetrics {
    static let font = NSFont.menuFont(ofSize: 0)
    static let row: CGFloat = 24
    static let separator: CGFloat = 11
    static let pad: CGFloat = 5
    static let inset: CGFloat = 5
    static let text: CGFloat = 17
    static let trailing: CGFloat = 17
    static let rule: CGFloat = 16
    static let highlight: CGFloat = 6
    static let corner: CGFloat = 12
    static let selection = NSColor(name: nil) { appearance in
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? accent.blended(withFraction: 0.15, of: .black) ?? accent
            : accent.blended(withFraction: 0.42, of: .white) ?? accent
    }
    static let edge = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.26)
    }

    static let ink = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.898) : NSColor(white: 0, alpha: 0.698)
    }
    static let quiet = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0, alpha: 0.498)
    }
    static let line = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.137) : NSColor(white: 0, alpha: 0.098)
    }

    static func symbolSize(_ symbol: KitSymbol) -> NSSize {
        symbol.image?.size ?? symbol.intrinsicContentSize
    }

    static let strong = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.white : NSColor.black
    }

    static func scale(_ view: NSView?) -> CGFloat {
        view?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    static func width(_ label: KitLabel) -> CGFloat {
        let scale = scale(label)
        return ceil(label.measure(width: .greatestFiniteMagnitude).width * scale) / scale
    }

    static func label(_ text: String, size: CGFloat? = nil, weight: NSFont.Weight = .regular, color: NSColor = MenuMetrics.ink) -> KitLabel {
        let font = size.map { NSFont.systemFont(ofSize: $0, weight: weight) } ?? MenuMetrics.font
        let label = KitLabel(text, font: font, color: color)
        return label
    }
}
