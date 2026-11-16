import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class KeepAwakeTests {
    private var browser: Browser!

    init() {
        keepSetting(Shared.prefs, \.awakeSites, "tabs.awakeSites")
        keepSetting(Shared.prefs, \.tabLife, "tabs.close.after")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.prefs.keepsSitesAwake = false
        browser.prefs.awakeSites = []
    }

    private func tearDown() {
        browser.closeAll()
        browser.prefs.keepsSitesAwake = false
        browser.prefs.awakeSites = []
        browser.prefs.tabLife = .never
        browser = nil
    }

    private func tab(_ url: String, privateMode: Bool = false) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: privateMode, configuration: configuration)
        tab.setAddressOptimistically(URL(string: url)!)
        return tab
    }

    @Test func optInExactHostsAndPersistence() {
        let page = tab("https://EXAMPLE.com:8443/path")
        browser.keepAwake(true, for: page)
        #expect(!browser.keepsAwake(page))
        browser.prefs.keepsSitesAwake = true
        #expect(browser.keepsAwake(page))
        #expect(browser.keepsAwake(tab("http://example.com/other")))
        #expect(!browser.keepsAwake(tab("https://sub.example.com")))
        #expect(!browser.keepsAwake(tab("https://example.company")))
        #expect(!browser.keepsAwake(tab("file:///example.com")))
        #expect(Preferences().awakeSites == ["example.com"])
        browser.prefs.keepsSitesAwake = false
        #expect(!browser.keepsAwake(page))
        #expect(browser.prefs.awakeSites == ["example.com"])
        browser.keepAwake(false, for: page)
        #expect(Preferences().awakeSites.isEmpty)
    }

    @Test func privateChoicesNeverReadOrWriteNormalChoices() {
        browser.prefs.keepsSitesAwake = true
        browser.keepAwake(true, for: tab("https://example.com"))
        let privatePage = tab("https://example.com", privateMode: true)
        #expect(!browser.keepsAwake(privatePage))
        browser.keepAwake(true, for: privatePage)
        #expect(browser.keepsAwake(privatePage))
        #expect(!browser.keepsAwake(tab("https://example.com", privateMode: true)))
        privatePage.setAddressOptimistically(URL(string: "https://other.example")!)
        #expect(!browser.keepsAwake(privatePage))
        browser.keepAwake(true, for: privatePage)
        #expect(Preferences().awakeSites == ["example.com"])
        #expect(privatePage.built == nil, "Checking an exception must not load a page")
    }

    @Test func exceptionAddedDuringFormCheckPreventsDiscard() async {
        browser.prefs.keepsSitesAwake = true
        let page = tab("https://example.com")
        browser.insert(page, at: browser.tabs.count)
        await withCheckedContinuation { continuation in
            page.web.evaluateInSearch("window.__officeForms = {unsaved: () => false}") { _ in continuation.resume() }
        }
        let reason = await withCheckedContinuation { continuation in
            browser.sleep(page) { continuation.resume(returning: $0) }
            browser.keepAwake(true, for: page)
        }
        #expect(reason == "kept awake for this site")
        #expect(page.built != nil)
    }

    @Test func exceptionPreventsSleepAndAutomaticClosureButNotManualClose() async throws {
        browser.prefs.keepsSitesAwake = true
        browser.prefs.tabLife = .halfDay
        let page = tab("https://example.com")
        _ = page.web
        page.touch(at: .distantPast)
        browser.prepare(page)
        browser.insert(page, at: browser.tabs.count)
        browser.keepAwake(true, for: page)
        #expect(browser.awake(because: page) == "kept awake for this site")
        #expect(browser.stays(because: page) == "kept awake for this site")
        browser.sleepIdle(within: 0)
        browser.closeLeftAlone()
        try await Task.sleep(for: .milliseconds(100))
        #expect(page.built != nil)
        #expect(browser.tabs.contains { $0 === page })
        browser.keepAwake(false, for: page)
        #expect(browser.busy(page) == nil)
        browser.keepAwake(true, for: page)
        browser.close(page)
        #expect(!browser.tabs.contains { $0 === page })
    }
}
