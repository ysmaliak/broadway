import AppKit
import WebKit

enum SiteClearing {
    static let types: Set<String> = [
        WKWebsiteDataTypeCookies,
        WKWebsiteDataTypeLocalStorage,
        WKWebsiteDataTypeSessionStorage,
        WKWebsiteDataTypeIndexedDBDatabases,
        WKWebsiteDataTypeWebSQLDatabases,
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
        WKWebsiteDataTypeFetchCache,
        WKWebsiteDataTypeServiceWorkerRegistrations,
    ]

    static let detail = "You'll be signed out of this site. Other sites aren't touched."
    static let confirm = "Clear and Reload"

    static func title(_ site: String) -> String { "Clear cookies for \(site)?" }

    static func site(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return Registrable.domain(of: host, isSuffix: AtRest.systemSuffix)
    }

    static func belongs(_ name: String, to site: String) -> Bool {
        Registrable.domain(of: name, isSuffix: AtRest.systemSuffix) == site
    }

    @MainActor static func clear(_ site: String, in store: WKWebsiteDataStore) async {
        SignInKeeper.shared.clearing(store)
        let records = await store.dataRecords(ofTypes: types)
        let mine = records.filter { belongs($0.displayName, to: site) }
        if !mine.isEmpty { await store.removeData(ofTypes: types, for: mine) }
        await SignInKeeper.shared.cleared(store)
    }
}

extension Browser {
    func clearableSite(_ tab: Tab?) -> String? {
        guard let tab, !tab.isBlank else { return nil }
        return SiteClearing.site(of: tab.pageAddress)
    }

    func askToClearSite(_ tab: Tab? = nil) {
        guard let tab = tab ?? active, let site = clearableSite(tab) else { return }
        Ask.sure(SiteClearing.title(site), detail: SiteClearing.detail, confirm: SiteClearing.confirm, returnCancels: true) { [weak self, weak tab] in
            guard let self, let tab else { return }
            Task { @MainActor in await self.clearSite(site, of: tab) }
        }
    }

    func clearSite(_ site: String, of tab: Tab) async {
        await SiteClearing.clear(site, in: tab.store)
        tab.reload(fromOrigin: false)
    }
}
