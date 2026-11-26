import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct PasswordPagesTests {
    @Test func removingOnePasswordAsksFirstNamingTheSiteAndAccount() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let testing = Ask.testing
        defer { Ask.testing = testing }
        Ask.testing = false
        let asked = Ask.asked.count

        browser.forget(Kept(host: "shop.example", user: "ada"))

        #expect(Array(Ask.asked.dropFirst(asked)) == ["Remove the password for shop.example?"])
        #expect(Browser.removeQuestion(Kept(host: "shop.example", user: "ada")).detail == "ada will no longer be filled in. This can't be undone.")
        #expect(Browser.removeQuestion(Kept(host: "shop.example", user: "")).detail == "The password with no username will no longer be filled in. This can't be undone.")
    }

    @Test func switchFlipsOnPressAndRefusesWhenDisabled() {
        let made = KitSwitch(isOn: false, label: "Passwords")
        var heard: [Bool] = []
        made.onChange = { heard.append($0) }

        let pressed = made.accessibilityPerformPress()
        made.isEnabled = false
        let refused = made.accessibilityPerformPress()

        #expect(pressed)
        #expect(!refused)
        #expect(made.isOn)
        #expect(heard == [true])
        #expect(made.accessibilityValue() as? String == "on")
        #expect(made.accessibilitySubrole() == .switch)
    }

    @Test func pairingCardKeepsOnlyDigitsAndKeepsItsNames() {
        let browser = Browser(record: WindowRecord())
        let apple = ApplePasswords(makeLink: { StandInLink() })
        apple.stage(.code)
        let pairing = Browser.ApplePairing(tab: UUID(), spot: CGRect(x: 0, y: 0, width: 300, height: 30))
        let card = ApplePairingCardView(browser: browser, apple: apple, pairing: pairing)
        card.frame = NSRect(origin: .zero, size: card.intrinsicContentSize)
        card.layoutSubtreeIfNeeded()

        card.code.text = "12a3"
        card.code.onChange?("12a3")

        #expect(card.code.text == "123")
        #expect(!card.code.isHidden)
        #expect(card.intrinsicContentSize.width == 300)
        #expect(card.identifier?.rawValue == "pairing.card")
        #expect(card.accessibilityLabel() == "Connect Apple Passwords")
    }

    @Test func pairingCardTypesNothingOnceIdle() {
        let browser = Browser(record: WindowRecord())
        let apple = ApplePasswords(makeLink: { StandInLink() })
        apple.stage(.idle, trouble: "That code didn't match.")
        let pairing = Browser.ApplePairing(tab: UUID(), spot: CGRect(x: 0, y: 0, width: 200, height: 30))

        let card = ApplePairingCardView(browser: browser, apple: apple, pairing: pairing)
        card.frame = NSRect(origin: .zero, size: card.intrinsicContentSize)
        card.layoutSubtreeIfNeeded()

        #expect(card.code.isHidden)
        #expect(card.intrinsicContentSize.width == 240)
    }

    @Test func passwordsSearchNarrowsTheBrowsersHunt() {
        let browser = Browser(record: WindowRecord())
        let page = PasswordsPageView(browser: browser)
        page.frame = NSRect(x: 0, y: 0, width: 820, height: 640)
        page.layoutSubtreeIfNeeded()
        let search = page.kitSubviews(of: KitSearchField.self).first

        search?.onChange?("example")

        #expect(search != nil)
        #expect(browser.hunting == "example")
    }
}
