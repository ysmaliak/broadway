import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PasswordsChangeTests {
    private var browser: Browser!

    init() {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
    }

    private func tearDown() {
        browser?.closeAll()
        browser = nil
    }

    private func list() -> PasswordsList {
        let list = PasswordsList(browser: browser)
        list.show([Browser.SiteRow(host: "shop.example", logins: [Kept(host: "shop.example", user: "ada")])])
        return list
    }

    @Test func theChangePageIsTheSitesWellKnownAddress() {
        #expect(PasswordsList.changePage(for: "shop.example")?.absoluteString == "https://shop.example/.well-known/change-password")
        #expect(PasswordsList.changePage(for: "") == nil)
    }

    @Test func aSiteRowAndAnAccountRowBothOfferIt() {
        let list = list()
        let site = list.sites[0]

        let siteMenu = KitMenu.make(list.menuItems(for: site))
        let accountMenu = KitMenu.make(list.menuItems(for: site.logins[0]))

        #expect(siteMenu.items.map(\.title) == ["Change Password on Site"])
        #expect(accountMenu.items.map(\.title) == ["Change Password on Site"])
    }

    @Test func choosingItOpensTheChangePageInANewTab() throws {
        let list = list()
        let before = browser.tabs.count
        let item = try #require(KitMenu.make(list.menuItems(for: list.sites[0])).items.first as? KitMenuAction)

        _ = item.target?.perform(item.action)

        #expect(browser.tabs.count == before + 1)
        #expect(browser.active?.pageAddress?.absoluteString == "https://shop.example/.well-known/change-password")
    }
}
