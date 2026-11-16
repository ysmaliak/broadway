import AppKit
import Combine
import Symbols
import WebKit

struct BlockedPopup: Identifiable, Equatable {
    let id = UUID()
    let url: URL?
    var reason: PopupRefusal?
}

enum BlockedPopups {
    static let kept = 5

    static func openable(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    static func site(of url: URL?) -> String? {
        guard let url else { return nil }
        return site(scheme: url.scheme ?? "", host: url.host() ?? "")
    }

    static func site(scheme: String, host: String) -> String? {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard ["http", "https"].contains(scheme.lowercased()), !host.isEmpty else { return nil }
        return Vault.registrable(host)
    }

    static func allows(_ sites: Set<String>, top: URL?, frameScheme: String, frameHost: String) -> Bool {
        guard let site = site(of: top), sites.contains(site),
              let asker = self.site(scheme: frameScheme, host: frameHost) else { return false }
        return asker == site
    }

    static func allows(_ sites: Set<String>, top: URL?) -> Bool {
        site(of: top).map(sites.contains) ?? false
    }

    static func noting(_ url: URL?, reason: PopupRefusal? = nil, in list: [BlockedPopup]) -> [BlockedPopup]? {
        let url = url.flatMap { $0.absoluteString.isEmpty ? nil : $0 }
        guard !list.contains(where: { $0.url == url }) else { return nil }
        return Array((list + [BlockedPopup(url: url, reason: reason)]).suffix(kept))
    }

    static func heading(_ list: [BlockedPopup]) -> String {
        if let last = list.last, SignInWindows.looks(last.url) { return "Sign-in window blocked" }
        return list.count == 1 ? "Pop-up blocked" : "\(list.count) pop-ups blocked"
    }

    static func label(_ url: URL) -> String {
        var rest = url.path()
        if let query = url.query(), !query.isEmpty { rest += "?" + query }
        if rest == "/" { rest = "" }
        return String((SiteCard.site(url) + rest).prefix(300))
    }
}

extension Tab {
    func noteBlocked(_ url: URL?, reason: PopupRefusal? = nil) {
        if let list = BlockedPopups.noting(url, reason: reason, in: blockedPopups) { blockedPopups = list }
    }
}

extension Browser {
    func popupsAllowed(_ tab: Tab, from frame: WKFrameInfo, top: URL?) -> Bool {
        BlockedPopups.allows(prefs.popupSites.union(tab.popupSites), top: top,
                             frameScheme: frame.securityOrigin.protocol, frameHost: frame.securityOrigin.host)
    }

    func popupsAllowed(_ tab: Tab, top: URL?) -> Bool {
        BlockedPopups.allows(prefs.popupSites.union(tab.popupSites), top: top)
    }

    @discardableResult
    func openBlocked(_ popup: BlockedPopup, from tab: Tab) -> Tab? {
        tab.blockedPopups.removeAll { $0.id == popup.id }
        guard let url = BlockedPopups.openable(popup.url) else { return nil }
        return open(url, foreground: true, from: tab)
    }

    func allowPopups(from tab: Tab) {
        guard let site = BlockedPopups.site(of: tab.pageAddress) else { return }
        PopupGuard.forgive(site)
        if tab.shy {
            tab.popupSites.insert(site)
        } else {
            prefs.popupSites.insert(site)
        }
        tab.blockedPopups = []
    }
}

class PopupSignView: SignView {
    let browser: Browser

    init(browser: Browser, tab: Tab) {
        self.browser = browser
        super.init(tab: tab, symbol: "rectangle.on.rectangle.slash", label: "Pop-up blocked")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func refresh() {
        kitAccess(help: BlockedPopups.heading(tab?.blockedPopups ?? []))
        rest = 0.75
        let last = tab?.blockedPopups.last?.id
        if let seen, let last, seen != last { symbol.addSymbolEffect(.bounce) }
        seen = last
        super.refresh()
    }

    private var seen: UUID?

    override func menu(done: @escaping () -> Void) -> SignMenu? {
        guard let tab else { return nil }
        return BlockedPopupsMenu(browser: browser, tab: tab, done: done)
    }
}

final class BlockedPopupsMenu: SignMenu {
    let browser: Browser
    let tab: Tab
    let done: () -> Void

    init(browser: Browser, tab: Tab, done: @escaping () -> Void) {
        self.browser = browser
        self.tab = tab
        self.done = done
        super.init()
        follows = true
        rebuild()
    }

    override func parts() -> [SignMenu.Part] {
        let site = BlockedPopups.site(of: tab.pageAddress)
        let openable = tab.blockedPopups.reversed().compactMap { popup in
            BlockedPopups.openable(popup.url).map { (popup, $0) }
        }
        let signIn = tab.blockedPopups.last.map { SignInWindows.looks($0.url) } ?? false
        var out: [SignMenu.Part] = [.heading(BlockedPopups.heading(tab.blockedPopups))]
        var open: [SignMenu.Part] = []
        if !openable.isEmpty {
            open.append(.items(openable.map { popup, url in
                SignMenu.Entry(symbol: "arrow.up.forward.square", title: "Open \(BlockedPopups.label(url))", help: url.absoluteString) { [weak self] in
                    guard let self else { return }
                    self.browser.openBlocked(popup, from: self.tab)
                    self.done()
                }
            }))
        }
        var allow: [SignMenu.Part] = []
        if let site {
            let once = "Only until this private window closes"
            allow.append(.items([SignMenu.Entry(
                symbol: "checkmark.circle",
                title: tab.shy ? "Allow Pop-ups from \(site) in This Tab" : "Always Allow Pop-ups from \(site)",
                help: signIn ? "Then click the sign-in button again" : tab.shy ? once : "Settings › Websites lists the sites you allow"
            ) { [weak self] in
                guard let self else { return }
                self.browser.allowPopups(from: self.tab)
                self.done()
            }]))
        }
        let groups = (signIn ? [allow, open] : [open, allow]).filter { !$0.isEmpty }
        for (index, group) in groups.enumerated() {
            if index > 0 { out.append(.divider) }
            out += group
        }
        return out
    }
}
