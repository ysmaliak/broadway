import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .enabled(if: !AppleHelper.available), .timeLimit(.minutes(5)))
@MainActor
final class AppleSoonTests {
    private var suite = ""
    private var store: UserDefaults!

    init() {
        keepSetting(Shared.prefs, \.applePasswords, "passwords.apple")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        suite = "bld-ai-offer-store-soon-\(getpid())-\(UUID().uuidString)"
        store = UserDefaults(suiteName: suite)
    }

    private func tearDown() {
        removeTestDefaults(store, suite: suite)
        ApplePasswordsOffer.benchAsks = false
        ApplePasswordsOffer.benchHelper = nil
    }

    private func browser() -> (Browser, StandInLink) {
        let browser = Browser(record: WindowRecord())
        browser.applePasswordsOffer = ApplePasswordsOffer(store: store)
        let link = StandInLink()
        browser.applePasswords = ApplePasswords(makeLink: { link })
        browser.applePasswords.standIn = link
        return (browser, link)
    }

    private func passwordsPage(_ browser: Browser, shell given: SettingsShell? = nil) -> (SettingsPageView, NSWindow) {
        let shell = given ?? SettingsShell()
        shell.go(to: .passwords)
        let page = SettingsPageView(browser: browser, shell: shell)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 1800),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 1800))
        window.contentView = holder
        page.frame = holder.bounds
        holder.addSubview(page)
        page.rebuild()
        page.layoutSubtreeIfNeeded()
        return (page, window)
    }

    @Test func aSavedOnDoesNotSwitchItOnAndStaysSaved() {
        keepSettings("passwords.apple")
        Store.settings.set(true, forKey: "passwords.apple")

        let prefs = Preferences()

        #expect(!prefs.applePasswords)
        #expect(Store.settings.bool(forKey: "passwords.apple"))
    }

    @Test func theRowIsOffAndDisabledWhateverWasSaved() throws {
        keepSettings("passwords.apple")
        Store.settings.set(true, forKey: "passwords.apple")
        let (browser, _) = browser()
        defer { browser.closeAll() }
        browser.applePasswords.stage(.code)

        let (page, window) = passwordsPage(browser)
        defer { window.close() }

        let rows = page.kitSubviews(of: SettingsRowView.self)
        let row = try #require(rows.first { $0.rowID == "passwords.apple" })
        let toggle = try #require(row.kitSubviews(of: KitSwitch.self).first)
        #expect(!toggle.isOn)
        #expect(!toggle.isEnabled)
        #expect(row.alphaValue == 0.5)
        #expect(row.detail.stringValue == "Your Passwords app's accounts under the sign-in box. Coming soon.")
        #expect(!row.kitSubviews(of: NSButton.self).contains { $0.accessibilityLabel()?.hasPrefix("More about") == true })
        #expect(!rows.contains { $0.rowID == "apple.pairing" })
        #expect(!rows.contains { $0.rowID == "passwords.fill" && $0.alphaValue != 1 })
    }

    @Test func findASettingStillLandsOnIt() throws {
        let found = SettingsIndex.find("apple passwords")

        let item = try #require(found.first { $0.id == "passwords.apple" })
        #expect(item.page == .passwords)
        #expect(item.title == "Apple Passwords")
        #expect(item.detail.hasSuffix("Coming soon."))
        #expect(!item.detail.contains("Unofficial"))
        #expect(item.more == nil)
        #expect(!SettingsIndex.applies(item, Shared.prefs))
    }

    @Test func pickingWhatWasFoundOpensPasswordsAndLightsTheRow() throws {
        let (browser, _) = browser()
        defer { browser.closeAll() }
        let shell = SettingsShell()
        let (page, window) = passwordsPage(browser, shell: shell)
        defer { window.close() }
        shell.go(to: .general)
        shell.query = "apple passwords"
        page.rebuild()
        let heading = try #require(page.kitSubviews(of: SettingsResultHeading.self).first { $0.identifier?.rawValue == "settings.result.apple" })
        let result = try #require(page.kitSubviews(of: SettingsRowView.self).first { $0.rowID == "passwords.apple" })

        let pressed = heading.accessibilityPerformPress()
        page.rebuild()

        let row = try #require(page.kitSubviews(of: SettingsRowView.self).first { $0.rowID == "passwords.apple" })
        #expect(result.detail.stringValue.hasSuffix("Coming soon."))
        #expect(pressed)
        #expect(shell.page == .passwords)
        #expect(!shell.searching)
        #expect(shell.lit == "passwords.apple")
        #expect(row.lit)
        #expect(row.alphaValue == 0.5)
        #expect(row.kitSubviews(of: KitSwitch.self).first?.isEnabled == false)
    }

    @Test func theCommandSaysItIsNotAvailableYet() throws {
        let access = try #require(PersonSettings.table["passwords.apple"])

        let on = PersonSettings.refusal("passwords.apple", value: "true")
        let off = PersonSettings.refusal("passwords.apple", value: "false")

        #expect(on?.code == "refused")
        #expect(on?.message == "Apple Passwords isn't available yet")
        #expect(off?.message == "Apple Passwords isn't available yet")
        #expect(access.read(Shared.prefs) as? Bool == false)
        #expect(access.write == nil)
    }

    @Test func nothingHangsUnderASignInBox() {
        let (browser, link) = browser()
        defer { browser.closeAll(); browser.prefs.applePasswords = false }
        ApplePasswordsOffer.benchAsks = true
        ApplePasswordsOffer.benchHelper = true
        let tab = browser.open(URL(string: "https://accounts.example.test/login")!, foreground: true)
        let spot = CGRect(x: 40, y: 120, width: 280, height: 30)

        browser.prefs.applePasswords = true
        tab.onField?(tab, spot, true, false, true)
        let switchedOn = browser.suggesting
        tab.onField?(tab, nil, true, false, true)
        browser.prefs.applePasswords = false
        tab.onField?(tab, spot, true, false, true)
        let switchedOff = browser.suggesting

        #expect(switchedOn == nil)
        #expect(switchedOff == nil)
        #expect(browser.applePasswordsOffer.offered.isEmpty)
        #expect(link.starts == 0)
    }

    @Test func anEligibleBoxIsNotOfferedIt() {
        let offer = ApplePasswordsOffer(store: store)
        let field = ApplePasswordsOffer.Field(page: URL(string: "https://accounts.example.com/login"), privateTab: false)

        let asPeopleHaveIt = offer.site(for: field, .init())
        let wereItOn = offer.site(for: field, .init(available: true))

        #expect(asPeopleHaveIt == nil)
        #expect(wereItOn == "example.com")
    }

    @Test func noRowOrCardStartsAPairing() async throws {
        let (browser, link) = browser()
        defer { browser.closeAll(); browser.prefs.applePasswords = false }
        let tab = UUID()

        browser.testOffer(on: tab, site: "example.com")
        browser.useApplePasswords()
        browser.connectApplePasswords()
        browser.beginApplePairing(on: tab, at: CGRect(x: 10, y: 20, width: 200, height: 30))
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!browser.prefs.applePasswords)
        #expect(browser.applePairing == nil)
        #expect(browser.applePasswords.state == .idle)
        #expect(link.starts == 0)
    }

    @Test func theHelperItselfIsNeverMade() async {
        let apple = ApplePasswords()

        await apple.connect()

        #expect(apple.state == .idle)
        #expect(apple.trouble == "Apple Passwords isn't available yet")
    }
}
