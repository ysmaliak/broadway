import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class ClearSiteTests {
    private var browser: Browser!

    init() {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
    }

    private func tearDown() {
        Ask.testing = nil
        browser.closeAll()
        browser = nil
    }

    private func tab(_ url: String?, store: WKWebsiteDataStore = .nonPersistent()) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let tab = Tab(shy: false, configuration: configuration)
        if let url { tab.setAddressOptimistically(URL(string: url)!) }
        return tab
    }

    private func cookie(_ name: String, _ domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: "1", .domain: domain, .path: "/"])!
    }

    private func cookieDomains(_ store: WKWebsiteDataStore) async -> Set<String> {
        let cookies = await store.httpCookieStore.allCookies()
        return Set(cookies.map(\.domain))
    }

    @Test func theSiteIsTheRegistrableDomainOfThePage() {
        let pages = [
            ("https://accounts.google.com/signin", "google.com"),
            ("https://www.bbc.co.uk/news", "bbc.co.uk"),
            ("http://example.com:8080/a", "example.com"),
        ]

        for (address, site) in pages {
            #expect(browser.clearableSite(tab(address)) == site, "\(address)")
        }
    }

    @Test func aBlankTabOrAnInternalPageHasNothingToClear() {
        let blank = tab(nil)
        let ownPage = tab("\(InternalPage.scheme)://history")
        let file = tab("file:///Users/someone/page.html")
        let about = tab("about:blank")

        #expect(browser.clearableSite(blank) == nil)
        #expect(browser.clearableSite(ownPage) == nil)
        #expect(browser.clearableSite(file) == nil)
        #expect(browser.clearableSite(about) == nil)
        #expect(browser.clearableSite(nil) == nil)
    }

    @Test func aRecordBelongsOnlyToItsOwnSite() {
        let site = "example.com"

        #expect(SiteClearing.belongs("example.com", to: site))
        #expect(SiteClearing.belongs("mail.example.com", to: site))
        #expect(!SiteClearing.belongs("notexample.com", to: site))
        #expect(!SiteClearing.belongs("example.com.evil.org", to: site))
        #expect(!SiteClearing.belongs("example.co.uk", to: site))
    }

    @Test func theQuestionNamesTheSite() {
        let site = "example.com"

        let title = SiteClearing.title(site)

        #expect(title == "Clear cookies for example.com?")
        #expect(SiteClearing.detail == "You'll be signed out of this site. Other sites aren't touched.")
        #expect(SiteClearing.confirm == "Clear and Reload")
    }

    @Test func clearingRemovesTheSitesCookiesAndLeavesOtherSites() async {
        let store = WKWebsiteDataStore.nonPersistent()
        await store.httpCookieStore.setCookie(cookie("a", "example.com"))
        await store.httpCookieStore.setCookie(cookie("b", ".mail.example.com"))
        await store.httpCookieStore.setCookie(cookie("c", "other.org"))
        let page = tab("https://www.example.com/", store: store)

        await browser.clearSite("example.com", of: page)

        #expect(await cookieDomains(store) == ["other.org"])
    }

    @Test func clearingCoversCookiesStorageCachesAndServiceWorkers() {
        let wanted: Set<String> = [
            WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeServiceWorkerRegistrations,
        ]

        let types = SiteClearing.types

        #expect(wanted.isSubset(of: types))
    }

    @Test func cancellingTheQuestionKeepsTheCookies() async {
        let store = WKWebsiteDataStore.nonPersistent()
        await store.httpCookieStore.setCookie(cookie("a", "example.com"))
        let page = tab("https://example.com/", store: store)
        Ask.testing = false

        browser.askToClearSite(page)
        try? await Task.sleep(for: .milliseconds(300))

        #expect(await cookieDomains(store) == ["example.com"])
    }

    @Test func confirmingTheQuestionClearsTheSite() async {
        let store = WKWebsiteDataStore.nonPersistent()
        await store.httpCookieStore.setCookie(cookie("a", "example.com"))
        await store.httpCookieStore.setCookie(cookie("c", "other.org"))
        let page = tab("https://example.com/", store: store)
        Ask.testing = true

        browser.askToClearSite(page)
        var domains = await cookieDomains(store)
        for _ in 0..<40 where domains.contains("example.com") {
            try? await Task.sleep(for: .milliseconds(50))
            domains = await cookieDomains(store)
        }

        #expect(domains == ["other.org"])
    }

    @Test func theCommandIsFoundInTheFieldByItsName() {
        let typed = "Clear Cookies and Reload"

        let rows = FieldCommands.rows(for: typed, in: browser, limit: 8)

        let actions = rows.compactMap { row -> String? in
            if case .action(let id) = row.kind { return id }
            return nil
        }
        #expect(actions.first == "command:view.clearSite")
        #expect(Command.named("view.clearSite")?.defaultKey == nil)
    }
}
