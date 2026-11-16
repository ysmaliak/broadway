import AppKit
import WebKit
import Testing
@testable import Search

/// Pins in a space you aren't in sleep after the usual wait, except a pin
/// whose site may send notifications; pins in the space on screen stay
/// awake as before (#569). In a test world of its own, nothing shown.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PinSleepTests {
    private var browser: Browser!
    private let site = "https://pinned.example"
    private var notifying: String { SiteNotifications.key(site) }

    init() {
        keepSetting(Shared.prefs, \.siteNotifications, "notifications.ask")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.prefs.siteNotifications = true
        Store.settings.removeObject(forKey: notifying)
    }

    private func tearDown() {
        Store.settings.removeObject(forKey: notifying)
        browser.parked = [:]
        browser.closeAll()
        browser = nil
    }

    /// A pinned tab with its page made, last looked at long ago.
    private func pin(_ url: String) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: configuration)
        tab.setAddressOptimistically(URL(string: url)!)
        _ = tab.web
        tab.pin = "P"
        tab.touch(at: .distantPast)
        return tab
    }

    private func park(_ tabs: [Tab]) {
        browser.parked[UUID()] = Parked(tabs: tabs, active: nil)
    }

    @Test func pinInTheSpaceOnScreenStaysAwake() {
        let here = pin(site)
        browser.prepare(here)
        browser.insert(here, at: browser.tabs.count)
        #expect(browser.awake(because: here) == "pinned")
    }

    @Test func pinInAnotherSpaceMaySleep() {
        let away = pin(site)
        park([away])
        #expect(browser.awake(because: away) == nil, "Nothing should keep a parked pin awake")
    }

    @Test func pinWhoseSiteMayNotifyStaysAwake() {
        let away = pin(site + "/inbox")
        park([away])
        Store.settings.set(true, forKey: notifying)
        #expect(browser.mayNotify(away))
        #expect(browser.awake(because: away) != nil)
        // Answered no, or notifications off in Settings: it may sleep.
        Store.settings.set(false, forKey: notifying)
        #expect(browser.awake(because: away) == nil)
        Store.settings.set(true, forKey: notifying)
        browser.prefs.siteNotifications = false
        #expect(!browser.mayNotify(away))
        #expect(browser.awake(because: away) == nil)
    }

    @Test func anotherSitesPermissionDoesNotCount() {
        Store.settings.set(true, forKey: notifying)
        let other = pin("https://elsewhere.example")
        park([other])
        #expect(browser.awake(because: other) == nil)
        let port = pin("https://pinned.example:8443")
        park([port])
        #expect(browser.awake(because: port) == nil, "Another port is another origin")
    }

    @Test func parkedPinStillKeptAwakeByWhatItIsDoing() {
        let away = pin(site)
        away.noisy = true
        park([away])
        #expect(browser.awake(because: away) == "playing sound")
    }

    @Test func aParkedPinGoesToSleep() async throws {
        let away = pin(site)
        await withCheckedContinuation { continuation in
            away.web.evaluateInSearch("window.__officeForms = {unsaved: () => false}") { _ in continuation.resume() }
        }
        park([away])
        let said = await withCheckedContinuation { continuation in
            browser.sleep(away) { continuation.resume(returning: $0) }
        }
        #expect(said == "asleep")
        #expect(away.asleep)
    }
}
