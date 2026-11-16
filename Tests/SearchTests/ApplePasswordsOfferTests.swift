import AppKit
import Testing
@testable import Search

/// "Use your Apple passwords?" under a sign-in box (25 Oct 2026): off
/// by default, offered once per site where Search keeps nothing, never again
/// after two unanswered or one ✕, never where it must not be. Apple's helper
/// is never run: the pairing it starts is a stand-in's.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class ApplePasswordsOfferTests {
    private var suite = ""
    private var store: UserDefaults!

    init() {
        keepSetting(Shared.prefs, \.applePasswords, "passwords.apple")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        suite = "bld-ai-offer-store-\(getpid())-\(UUID().uuidString)"
        store = UserDefaults(suiteName: suite)
    }

    private func tearDown() {
        removeTestDefaults(store, suite: suite)
        ApplePasswordsOffer.benchAsks = false
        ApplePasswordsOffer.benchHelper = nil
    }

    private let page = URL(string: "https://accounts.example.com/login")!
    /// As a person would have it: no test run, the helper there.
    private let person = ApplePasswordsOffer.Settings(available: true)

    private func field(_ url: URL? = nil, privateTab: Bool = false, frame: String? = nil,
                       passwords: Bool = true, kept: Int = 0) -> ApplePasswordsOffer.Field {
        .init(page: url ?? page, privateTab: privateTab, frameHost: frame, passwords: passwords, kept: kept)
    }

    // MARK: - where

    @Test func offeredOnAnHttpsPageWithNothingKept() {
        let offer = ApplePasswordsOffer(store: store)
        #expect(offer.site(for: field(), person) == "example.com")
        // A frame of the page's own site is the page's.
        #expect(offer.site(for: field(frame: "login.example.com"), person) == "example.com")
    }

    @Test func neverWhereItMustNotBe() {
        let offer = ApplePasswordsOffer(store: store)
        #expect(offer.site(for: field(kept: 1), person) == nil, "an account of Search's own for the site")
        #expect(offer.site(for: field(privateTab: true), person) == nil, "a private tab")
        #expect(offer.site(for: field(URL(string: "http://accounts.example.com/login")), person) == nil, "http")
        #expect(offer.site(for: field(frame: "auth.other.test"), person) == nil, "a frame of another site")
        #expect(offer.site(for: field(passwords: false), person) == nil, "a box for passkeys alone")
        #expect(offer.site(for: field(URL(string: "file:///tmp/login.html")), person) == nil)
        #expect(offer.site(for: field(URL(string: "chrome-extension://abc/popup.html")), person) == nil)
        var settings = person
        settings.appleOn = true
        #expect(offer.site(for: field(), settings) == nil, "already on")
        settings = person
        settings.fills = false
        #expect(offer.site(for: field(), settings) == nil, "filling turned off")
        settings = person
        settings.helper = false
        #expect(offer.site(for: field(), settings) == nil, "no helper on this Mac (or macOS before 15.4)")
        #expect(offer.offered.isEmpty, "asking writes nothing down")
    }

    @Test func neverInATestRunUnlessTheBenchAsks() {
        let offer = ApplePasswordsOffer(store: store)
        var settings = person
        settings.testRun = true
        #expect(offer.site(for: field(), settings) == nil)
        settings.benchAsks = true
        #expect(offer.site(for: field(), settings) == "example.com")
    }

    // MARK: - how often

    @Test func oncePerSite() {
        let offer = ApplePasswordsOffer(store: store)
        offer.shown(on: "example.com")
        #expect(offer.site(for: field(), person) == nil)
        #expect(offer.site(for: field(URL(string: "https://www.example.com/")), person) == nil, "the same site, another host")
        #expect(offer.site(for: field(URL(string: "https://bank.test/")), person) == "bank.test")
    }

    @Test func twiceUnansweredAndItStops() {
        let offer = ApplePasswordsOffer(store: store)
        offer.unanswered()
        #expect(!offer.retired)
        #expect(offer.site(for: field(), person) == "example.com")
        offer.unanswered()
        #expect(offer.retired)
        #expect(offer.site(for: field(URL(string: "https://bank.test/")), person) == nil)
    }

    @Test func theCrossStopsItAtOnce() {
        let offer = ApplePasswordsOffer(store: store)
        offer.dismissed()
        #expect(offer.retired)
        #expect(offer.site(for: field(), person) == nil)
        offer.forget()
        #expect(offer.site(for: field(), person) == "example.com")
    }

    @Test(.enabled(if: AppleHelper.available)) func theHelperIsNeverRunFromATest() async {
        // The default connection, in a test run, refuses before running
        // anything: Apple's helper would show its window on a real screen.
        let apple = ApplePasswords()
        await apple.connect()
        #expect(apple.state == .idle)
        #expect(apple.trouble == "Apple's Passwords helper isn't run in a test")
    }

    // MARK: - the row in the list

    private func browser() -> Browser {
        let browser = Browser(record: WindowRecord())
        browser.applePasswordsOffer = ApplePasswordsOffer(store: store)
        let link = StandInLink()
        browser.applePasswords = ApplePasswords(makeLink: { link })
        browser.applePasswords.standIn = link
        return browser
    }

    @Test(.enabled(if: AppleHelper.available)) func clickingTurnsItOnAndPairs() async throws {
        let browser = browser()
        defer { browser.closeAll(); browser.prefs.applePasswords = false }
        browser.prefs.applePasswords = false
        let tab = UUID()
        browser.testOffer(on: tab, site: "example.com")
        #expect(browser.suggesting?.appleOffer == "example.com")
        #expect(browser.applePasswordsOffer.offered == ["example.com"])
        browser.useApplePasswords()
        #expect(browser.suggesting == nil)
        #expect(browser.prefs.applePasswords, "the switch is on")
        #expect(browser.applePairing?.tab == tab, "the pairing card where the list was")
        try await settle { (browser.applePasswords.standIn as? StandInLink)?.starts == 1 }
        // Taken, not ignored.
        #expect(store.integer(forKey: ApplePasswordsOffer.unansweredKey) == 0)
        #expect(!browser.applePasswordsOffer.retired)
    }

    @Test func aClickTooSoonIsNotAChoice() {
        let browser = browser()
        defer { browser.closeAll(); browser.prefs.applePasswords = false }
        browser.prefs.applePasswords = false
        browser.testOffer(on: UUID(), site: "example.com", age: 0)
        browser.useApplePasswords()
        browser.neverOfferApplePasswords()
        #expect(browser.suggesting?.appleOffer != nil)
        #expect(!browser.prefs.applePasswords)
        #expect(!browser.applePasswordsOffer.retired)
    }

    @Test func theCrossInTheList() {
        let browser = browser()
        defer { browser.closeAll() }
        browser.testOffer(on: UUID(), site: "example.com")
        browser.neverOfferApplePasswords()
        #expect(browser.suggesting == nil, "the offer alone: the list goes with it")
        #expect(store.bool(forKey: ApplePasswordsOffer.neverKey))
        #expect(store.integer(forKey: ApplePasswordsOffer.unansweredKey) == 0, "a ✕ is an answer")
        #expect(!browser.prefs.applePasswords)
        #expect(browser.applePairing == nil)
    }

    @Test func leftUnansweredIsCounted() {
        let browser = browser()
        defer { browser.closeAll() }
        browser.testOffer(on: UUID(), site: "example.com")
        browser.testOffer(on: nil)
        #expect(store.integer(forKey: ApplePasswordsOffer.unansweredKey) == 1)
        browser.testOffer(on: UUID(), site: "bank.test")
        browser.testOffer(on: nil)
        #expect(browser.applePasswordsOffer.retired)
        #expect(browser.applePasswordsOffer.site(for: field(URL(string: "https://third.test/")), person) == nil)
        #expect(browser.applePasswordsOffer.offered == ["bank.test", "example.com"])
    }

    private func settle(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(done())
    }
}
