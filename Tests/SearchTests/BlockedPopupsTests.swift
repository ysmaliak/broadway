import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class BlockedPopupsTests {
    private var browser: Browser!

    init() {
        keepSetting(Shared.prefs, \.popupSites, "privacy.popupSites")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.prefs.popupSites = []
    }

    private func tearDown() {
        browser.closeAll()
        browser.prefs.popupSites = []
        browser = nil
    }

    private func tab(_ url: String, privateMode: Bool = false) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: privateMode, configuration: configuration)
        tab.setAddressOptimistically(URL(string: url)!)
        return tab
    }

    @Test func onlyWebAddressesCanBeOpened() {
        #expect(BlockedPopups.openable(URL(string: "https://hark.com/a?b=1")) != nil)
        #expect(BlockedPopups.openable(URL(string: "http://127.0.0.1:8080/x")) != nil)
        for refused in ["javascript:alert(1)", "data:text/html,hi", "blob:https://hark.com/1234",
                        "file:///etc/hosts", "about:blank", "about:srcdoc", "ftp://example.com/", "https://"] {
            #expect(BlockedPopups.openable(URL(string: refused)) == nil, "\(refused)")
        }
        #expect(BlockedPopups.openable(nil) == nil)
    }

    @Test func siteIsTheRegistrableDomainOfAWebPage() {
        #expect(BlockedPopups.site(of: URL(string: "https://app.hark.com/chat")) == "hark.com")
        #expect(BlockedPopups.site(of: URL(string: "https://www.bbc.co.uk/")) == "bbc.co.uk")
        #expect(BlockedPopups.site(of: URL(string: "http://127.0.0.1:9000/")) == "127.0.0.1")
        #expect(BlockedPopups.site(of: URL(string: "file:///Users/x/a.html")) == nil)
        #expect(BlockedPopups.site(of: URL(string: "about:blank")) == nil)
        #expect(BlockedPopups.site(scheme: "https", host: "") == nil)
    }

    @Test func allowedSiteOnlyForItsOwnPageAndSameSiteFrames() {
        let sites: Set<String> = ["hark.com"]
        let top = URL(string: "https://app.hark.com/chat")
        #expect(BlockedPopups.allows(sites, top: top, frameScheme: "https", frameHost: "app.hark.com"))
        #expect(BlockedPopups.allows(sites, top: top, frameScheme: "https", frameHost: "cdn.hark.com"))
        // A frame of another site on the allowed page: still needs a click.
        #expect(!BlockedPopups.allows(sites, top: top, frameScheme: "https", frameHost: "ads.example.net"))
        #expect(!BlockedPopups.allows(sites, top: top, frameScheme: "https", frameHost: "hark.com.evil.net"))
        // A sandboxed frame's opaque origin has no host.
        #expect(!BlockedPopups.allows(sites, top: top, frameScheme: "", frameHost: ""))
        // The allowed site's frame on a page of another site.
        #expect(!BlockedPopups.allows(sites, top: URL(string: "https://example.com"), frameScheme: "https", frameHost: "hark.com"))
        #expect(!BlockedPopups.allows([], top: top, frameScheme: "https", frameHost: "app.hark.com"))
        #expect(!BlockedPopups.allows(sites, top: nil, frameScheme: "https", frameHost: "app.hark.com"))
    }

    @Test func listKeepsAFewOncePerAddress() {
        var list: [BlockedPopup] = []
        for n in 1...7 { list = BlockedPopups.noting(URL(string: "https://a.com/\(n)"), in: list) ?? list }
        #expect(list.map { $0.url?.lastPathComponent } == ["3", "4", "5", "6", "7"])
        #expect(BlockedPopups.noting(URL(string: "https://a.com/7"), in: list) == nil)
        // A window with no address (window.open() to write into) is noted once.
        let blank = BlockedPopups.noting(nil, in: [])!
        #expect(blank.count == 1)
        #expect(blank[0].url == nil)
        #expect(BlockedPopups.noting(URL(string: ""), in: blank) == nil)
    }

    @Test func spentOnlyAfterTheInteractionHadItsWindow() {
        var gesture = PopupGesture()
        #expect(gesture.spent(now: 1) == false)
        gesture.record(origin: "https://a.com:443", kind: "click", now: 1)
        #expect(gesture.spent(now: 2) == false)
        #expect(gesture.take(origin: "https://a.com:443", mainFrame: true, now: 2) == true)
        #expect(gesture.spent(now: 3) == true)
        #expect(gesture.spent(now: 7) == false)
        var claimed = PopupGesture()
        claimed.record(origin: "https://a.com:443", kind: "click", now: 1)
        #expect(claimed.claim(now: 1.5) == nil)
        #expect(claimed.spent(now: 2) == true)
    }

    @Test func alwaysAllowIsSavedFromANormalTabAndClearsTheSign() {
        let page = tab("https://app.hark.com/chat")
        page.noteBlocked(URL(string: "https://app.hark.com/answer/1"))
        #expect(page.blockedPopups.count == 1)
        browser.allowPopups(from: page)
        #expect(browser.prefs.popupSites == ["hark.com"])
        #expect(Preferences().popupSites == ["hark.com"])
        #expect(page.blockedPopups.isEmpty)
        browser.prefs.popupSites.remove("hark.com")
        #expect(Preferences().popupSites.isEmpty)
    }

    @Test func privateTabAllowsOnlyForItselfAndWritesNothing() {
        let page = tab("https://app.hark.com/chat", privateMode: true)
        page.noteBlocked(URL(string: "https://app.hark.com/answer/1"))
        browser.allowPopups(from: page)
        #expect(page.popupSites == ["hark.com"])
        #expect(browser.prefs.popupSites.isEmpty)
        #expect(Preferences().popupSites.isEmpty)
        // But the saved list does apply in a private tab.
        browser.prefs.popupSites = ["example.com"]
        #expect(BlockedPopups.allows(browser.prefs.popupSites.union(tab("https://example.com", privateMode: true).popupSites),
                                           top: URL(string: "https://example.com"), frameScheme: "https", frameHost: "example.com"))
    }

    @Test func openMakesAPlainTabAtTheAddressWithNoOpener() throws {
        let page = tab("https://app.hark.test/chat")
        page.noteBlocked(URL(string: "javascript:alert(1)"))
        page.noteBlocked(URL(string: "https://app.hark.test/answer/2"))
        let refused = page.blockedPopups[0]
        #expect(browser.openBlocked(refused, from: page) == nil)
        #expect(page.blockedPopups.count == 1)
        let opened = try #require(browser.openBlocked(page.blockedPopups[0], from: page))
        #expect(opened.address?.absoluteString == "https://app.hark.test/answer/2")
        #expect(opened.opener == nil)
        #expect(!opened.shy)
        #expect(browser.activeID == opened.id)
        #expect(page.blockedPopups.isEmpty)
    }

    @Test func openFromAPrivateWindowIsPrivate() throws {
        let quiet = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { quiet.closeAll() }
        let page = tab("https://example.test", privateMode: true)
        page.noteBlocked(URL(string: "https://example.test/pop"))
        let opened = try #require(quiet.openBlocked(page.blockedPopups[0], from: page))
        #expect(opened.shy)
        #expect(opened.opener == nil)
    }

    @Test func aNewPageClearsTheList() {
        let page = tab("https://example.com")
        page.noteBlocked(URL(string: "https://example.com/pop"))
        page.didCommit()
        #expect(page.blockedPopups.isEmpty)
    }

    @Test func theRowLeavesTheSignToTheAddressPill() {
        let page = tab("https://example.com/")
        page.noteBlocked(URL(string: "https://ads.example.com/pop"))
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 220, height: Metrics.sideRowHeight))
        var state = RowState()
        state.live = true

        row.show(page, in: browser, state: state)
        row.layoutSubtreeIfNeeded()

        #expect(row.kitSubviews(of: PopupSignView.self).isEmpty)
    }

    @Test func theDoorSignIsAPillDoorWithTheSameMenuAndWords() {
        let page = tab("https://example.com/")
        page.noteBlocked(URL(string: "https://ads.example.com/pop"))
        page.noteBlocked(URL(string: "https://ads.example.com/pop-2"))

        let live = PopupDoorView(browser: browser, tab: page, live: true)
        let still = PopupDoorView(browser: browser, tab: page, live: false)

        #expect(live.intrinsicContentSize == NSSize(width: 26, height: 26))
        #expect(live.accessibilityLabel() == "Pop-up blocked")
        #expect(live.toolTip == "2 pop-ups blocked")
        #expect(live.isAccessibilityElement() && !live.inert)
        #expect(live.menu(done: {}) is BlockedPopupsMenu)
        #expect(still.inert && still.toolTip == nil && !still.isAccessibilityElement())
    }
}
