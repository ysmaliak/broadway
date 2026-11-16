import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AwakeSeedTests {
    private let suite = "com.ysmaliak.broadway.test.awake-seed-\(UUID().uuidString)"
    private var store: UserDefaults!
    private var browser: Browser!

    init() {
        keepSetting(Shared.prefs, \.awakeSites, "tabs.awakeSites")
        keepSetting(Shared.prefs, \.keepsSitesAwake)
        addTeardownBlock { self.tearDown() }
        store = UserDefaults(suiteName: suite)
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
    }

    private func tearDown() {
        store.removePersistentDomain(forName: suite)
        browser.closeAll()
        browser = nil
    }

    private func tab(_ url: String, privateMode: Bool = false) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: privateMode, configuration: configuration)
        tab.setAddressOptimistically(URL(string: url)!)
        return tab
    }

    @Test func aFreshStoreIsSeededWithTheChatAndMusicSites() {
        let fresh = store!

        let sites = Preferences.seedAwakeSites(fresh)

        #expect(sites == Preferences.awakeSeeds)
        #expect(sites.contains("web.whatsapp.com"))
        #expect(sites.contains("music.apple.com"))
        #expect(sites.count == 11)
        #expect(Set(fresh.stringArray(forKey: "tabs.awakeSites") ?? []) == Preferences.awakeSeeds)
    }

    @Test func seedingAddsToTheSitesAlreadyKept() {
        store.set(["example.com"], forKey: "tabs.awakeSites")

        let sites = Preferences.seedAwakeSites(store)

        #expect(sites == Preferences.awakeSeeds.union(["example.com"]))
    }

    @Test func seedingHappensOnlyOnce() {
        _ = Preferences.seedAwakeSites(store)
        store.set(["example.com"], forKey: "tabs.awakeSites")

        let sites = Preferences.seedAwakeSites(store)

        #expect(sites == ["example.com"])
        #expect(store.bool(forKey: Preferences.awakeSeededKey))
    }

    @Test func aSeededSiteTurnedOffStaysOff() {
        browser.prefs.keepsSitesAwake = true
        browser.prefs.awakeSites = Preferences.awakeSeeds
        let page = tab("https://web.whatsapp.com/")
        #expect(browser.keepsAwake(page))

        browser.keepAwake(false, for: page)

        #expect(!browser.keepsAwake(page))
        #expect(!Preferences().awakeSites.contains("web.whatsapp.com"))
    }

    @Test func aSeededSiteWithoutWwwKeepsItsWwwPageAwake() {
        browser.prefs.keepsSitesAwake = true
        browser.prefs.awakeSites = ["messenger.com"]
        let page = tab("https://www.messenger.com/t/1")

        let awake = browser.keepsAwake(page)
        browser.keepAwake(false, for: page)

        #expect(awake)
        #expect(!browser.keepsAwake(page))
        #expect(browser.prefs.awakeSites.isEmpty)
    }

    @Test func privateTabsAreNotSeeded() {
        browser.prefs.keepsSitesAwake = true
        browser.prefs.awakeSites = Preferences.awakeSeeds

        let page = tab("https://web.whatsapp.com/", privateMode: true)

        #expect(!browser.keepsAwake(page))
        #expect(page.awakeSites.isEmpty)
    }
}
