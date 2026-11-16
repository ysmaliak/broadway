import AppKit
import Testing
@testable import Search

@MainActor
@Suite(.sharedWorld) struct SiteGroupAppKitTests {
    private func page(_ address: String) -> Tab {
        let tab = Tab(bench: true)
        tab.restore(url: URL(string: address)!, title: "Example")
        return tab
    }

    private func words(_ view: NSView) -> [String] {
        view.subviews.flatMap { child -> [String] in
            if let label = child as? KitLabel { return [label.text] }
            if let label = child as? SiteWrapLabel { return [label.text] }
            return words(child)
        }
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map { $0.title.replacingOccurrences(of: "\n", with: " ") }
    }

    @Test func theCardFrontNamesTheSiteAndItsConnection() {
        let browser = Browser(record: WindowRecord())
        let tab = page("https://www.example.com/a")

        let card = SiteCard(browser: browser, tab: tab)

        let said = titles(card.menu)
        #expect(card.menu.items.first?.isSectionHeader == true)
        #expect(said.first == "example.com")
        #expect(said.contains("Connection is secure"))
        #expect(said.contains("Copy Address"))
        #expect(said.contains("Developer"))
        #expect(card.menu.items.first { $0.title == "Developer" }?.submenu != nil)
        #expect(card.menu.items.first { $0.title == "Copy Address" }?.keyEquivalent == "c")
    }

    @Test func zoomIsThreePlainItemsWithTheirKeys() {
        let browser = Browser(record: WindowRecord())

        let card = SiteCard(browser: browser, tab: page("https://example.com/"))

        let items = card.menu.items
        let zoomIn = items.first { $0.title == "Zoom In" }
        let zoomOut = items.first { $0.title == "Zoom Out" }
        let actual = items.first { $0.title == "Actual Size (100%)" }
        #expect(zoomIn?.keyEquivalent == "+")
        #expect(zoomOut?.keyEquivalent == "-")
        #expect(actual?.keyEquivalent == "0")
    }

    @Test func aPlainHTTPPageSaysItIsNotSecure() {
        let browser = Browser(record: WindowRecord())
        let tab = page("http://plain.example.com/")

        let card = SiteCard(browser: browser, tab: tab, step: .security)

        let said = titles(card.menu)
        #expect(said.contains("Connection is not secure"))
        #expect(!said.contains("Back"))
    }

    @Test func eachStepIsASubmenuOfTheFront() {
        let browser = Browser(record: WindowRecord())

        let front = SiteCard(browser: browser, tab: page("https://example.com/"))
        let developer = SiteCard(browser: browser, tab: page("https://example.com/"), step: .developer)

        let sub = front.menu.items.first { $0.identifier?.rawValue == "site.developer" }?.submenu
        #expect(sub.map(titles)?.contains("Copy for Agent") == true)
        #expect(titles(developer.menu).contains("Copy for Agent"))
        #expect(!titles(developer.menu).contains("Copy Address"))
    }

    @Test func aLongNoteWrapsOnWords() {
        let wrapped = KitMenu.wrap("What you send to this site, like passwords or credit card numbers, is private", width: 30)

        #expect(wrapped.split(separator: "\n").allSatisfy { $0.count <= 30 })
        #expect(wrapped.replacingOccurrences(of: "\n", with: " ") == "What you send to this site, like passwords or credit card numbers, is private")
    }

    @Test func theSwitchFlipsAndSaysSo() {
        var said: [Bool] = []
        let toggle = KitSwitch(isOn: false, small: true, label: "Play Sound by Itself")
        toggle.onChange = { said.append($0) }

        _ = toggle.accessibilityPerformPress()

        #expect(toggle.isOn)
        #expect(said == [true])
        #expect(toggle.accessibilityLabel() == "Play Sound by Itself")
        #expect(toggle.intrinsicContentSize == NSSize(width: 28, height: 16))
    }

    @Test func theBlockedPopupsMenuOffersEachWindowAndTheSite() {
        let browser = Browser(record: WindowRecord())
        let tab = page("https://www.example.com/")
        tab.blockedPopups = [BlockedPopup(url: URL(string: "https://ads.example.com/pop")),
                             BlockedPopup(url: URL(string: "javascript:void(0)"))]

        let menu = BlockedPopupsMenu(browser: browser, tab: tab) {}

        let said = titles(menu.menu)
        #expect(menu.menu.items.first?.isSectionHeader == true)
        #expect(said.contains("2 pop-ups blocked"))
        #expect(said.contains("Open ads.example.com/pop"))
        #expect(said.contains("Always Allow Pop-ups from example.com"))
        #expect(menu.menu.items.contains { $0.isSeparatorItem })
    }

    @Test func aBlockedSignInWindowSaysSoAndOffersTheSiteFirst() {
        let browser = Browser(record: WindowRecord())
        let tab = page("https://www.example.com/")
        tab.blockedPopups = [BlockedPopup(url: URL(string: "https://ads.example.com/pop")),
                             BlockedPopup(url: URL(string: "https://appleid.apple.com/auth/authorize?client_id=x"), reason: .unseen)]

        let menu = BlockedPopupsMenu(browser: browser, tab: tab) {}
        let sign = PopupSignView(browser: browser, tab: tab)
        sign.refresh()

        let said = titles(menu.menu)
        let allow = said.firstIndex(of: "Always Allow Pop-ups from example.com")
        let open = said.firstIndex(of: "Open appleid.apple.com/auth/authorize?client_id=x")
        #expect(said.first == "Sign-in window blocked")
        #expect(allow != nil && open != nil && (allow ?? 0) < (open ?? 0))
        #expect(menu.menu.items.first { $0.title.hasPrefix("Always Allow") }?.toolTip == "Then click the sign-in button again")
        #expect(sign.toolTip == "Sign-in window blocked")
    }

    @Test func theTranslateMenuSaysWhatHappened() {
        let tab = page("https://example.fr/")
        tab.translation = TranslationMark(from: "fr", to: "en", phase: .done)

        let menu = TranslateMenu(tab: tab) {}

        let said = titles(menu.menu)
        #expect(said.first == TranslateMenu.heading(tab.translation!))
        #expect(said.contains("Show Original"))
        #expect(said.contains("Translated on this Mac. Nothing is sent anywhere."))
        #expect(menu.menu.items.first { $0.title == "Always Translate French" }?.state == .off)
    }

    @Test func theSignsAreTheSizeOfTheOtherMarks() {
        let browser = Browser(record: WindowRecord())
        let tab = page("https://example.com/")
        tab.blockedPopups = [BlockedPopup(url: URL(string: "https://ads.example.com/pop"))]
        tab.translation = TranslationMark(from: "fr", to: "en", phase: .working)

        let popup = PopupSignView(browser: browser, tab: tab)
        let translate = TranslateSignView(tab: tab)

        #expect(popup.intrinsicContentSize == NSSize(width: 17, height: 15))
        #expect(translate.intrinsicContentSize == NSSize(width: 17, height: 15))
        #expect(popup.accessibilityLabel() == "Pop-up blocked")
        #expect(translate.accessibilityLabel() == "Translating from French…")
        #expect(translate.rest == 0.4)
    }

    @Test func aQuestionGoesOnOneLineWhenItFitsAndWrapsWhenNot() {
        let browser = Browser(record: WindowRecord())
        let ask = Browser.CaptureAsk(host: "meet.example.com", wants: "camera")
        let view = CaptureQuestionView(browser: browser, ask: ask)

        let wide = view.fit(nil)
        let narrow = view.fit(260)

        #expect(wide.height == 40)
        #expect(narrow.width <= 260)
        #expect(narrow.height > wide.height)
    }

    @Test func theShieldOfferAsksOnOneLineAndNotNowLetsItGo() {
        let shield = Shield.shared
        shield.offer = "news.example.com"
        let view = ShieldOfferView(browser: Browser(record: WindowRecord()), shield: shield, host: "news.example.com")

        let size = view.fit(nil)

        #expect(words(view) == ["Page not working?", "Not Now", "Allow Ads Here"])
        #expect(view.keys.map { $0.accessibilityLabel() } == ["Not Now", "Allow Ads Here"])
        #expect(size.height == view.keys[0].intrinsicContentSize.height + 18)

        _ = view.keys[0].accessibilityPerformPress()

        #expect(shield.offer == nil)
    }
}
