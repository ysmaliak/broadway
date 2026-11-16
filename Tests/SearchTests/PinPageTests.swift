import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PinPageTests {
    private var browser: Browser!

    init() {
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        keepSetting(Shared.prefs, \.sharesPins)
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
    }

    private func tearDown() {
        for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
        browser.closeAll()
        browser = nil
    }

    private func pinned(_ url: String) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: configuration)
        tab.setAddressOptimistically(URL(string: url)!)
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
        browser.pin(tab)
        return tab
    }

    private func titles(_ tab: Tab) -> [String] {
        TabMenuItems.items(browser: browser, tab: tab, close: {}).map(\.title)
    }

    @Test func aPinOnItsPageOffersOnlyToEditItsAddress() throws {
        let tab = pinned("https://home.example/")

        let menu = titles(tab)

        #expect(!browser.pinMovedOff(tab))
        #expect(!menu.contains("Set Pinned Page to This Page"))
        #expect(!menu.contains("Go Back to Pinned Page"))
        let unpin = try #require(menu.firstIndex(of: "Unpin"))
        #expect(menu[unpin + 1] == "Edit Pinned Address…")
    }

    @Test func aPinOffItsPageOffersAllThreeUnderUnpinInOrder() throws {
        let tab = pinned("https://home.example/")

        tab.setAddressOptimistically(URL(string: "https://home.example/elsewhere")!)
        let menu = titles(tab)

        #expect(browser.pinMovedOff(tab))
        let unpin = try #require(menu.firstIndex(of: "Unpin"))
        #expect(Array(menu[(unpin + 1)...(unpin + 3)])
                == ["Set Pinned Page to This Page", "Go Back to Pinned Page", "Edit Pinned Address…"])
    }

    @Test func settingThePinnedPageMakesThePageItIsOnItsPage() {
        let tab = pinned("https://home.example/")
        tab.setAddressOptimistically(URL(string: "https://home.example/new")!)

        browser.setPinnedPage(tab)

        #expect(tab.home?.absoluteString == "https://home.example/new")
        #expect(!browser.pinMovedOff(tab))
        #expect(Pins.defs(browser.spaceID).first { $0.id == tab.pinID }?.home == "https://home.example/new")
    }

    @Test func goingBackTakesThePinToItsPage() {
        let tab = pinned("https://home.example/")
        tab.setAddressOptimistically(URL(string: "https://home.example/away")!)

        browser.goBackToPinnedPage(tab)

        #expect(Browser.samePage(URL(string: "https://home.example/")!, tab.pending ?? tab.address))
        #expect(browser.editingPin == nil)
    }

    @Test func goingBackOnItsPageDoesNotChangeTheLetter() {
        let tab = pinned("https://home.example/")

        browser.goBackToPinnedPage(tab)

        #expect(browser.editingPin == nil)
    }

    @Test func anEditedAddressBecomesThePinsPageAndOpens() {
        let tab = pinned("https://home.example/")

        let saved = browser.setPinnedAddress("other.example/inbox", for: tab)

        #expect(saved)
        #expect(tab.home?.absoluteString == "https://other.example/inbox")
        #expect(Browser.samePage(URL(string: "https://other.example/inbox")!, tab.pending ?? tab.address))
        #expect(Pins.defs(browser.spaceID).first { $0.id == tab.pinID }?.home == "https://other.example/inbox")
    }

    @Test func anEditedAddressLeavesAPageThePinWanderedTo() {
        let tab = pinned("https://home.example/")
        tab.setAddressOptimistically(URL(string: "https://home.example/reading")!)

        browser.setPinnedAddress("https://other.example/", for: tab)

        #expect(tab.home?.absoluteString == "https://other.example/")
        #expect(tab.address?.absoluteString == "https://home.example/reading")
    }

    @Test func anAddressThatCannotBeOpenedIsRefused() {
        let tab = pinned("https://home.example/")

        let refused = ["", "hello world", "todo", "mailto:a@b.example", "about:blank", "broadway://history"]
            .filter { !browser.setPinnedAddress($0, for: tab) }

        #expect(refused.count == 6)
        #expect(tab.home?.absoluteString == "https://home.example/")
    }

    @Test func aSharedPinsNewAddressIsEverySpaces() {
        browser.prefs.usesSpaces = true
        browser.prefs.sharesPins = true
        let tab = pinned("https://shared.example/")
        browser.shareEverywhere(tab)
        #expect(tab.everywhere)

        browser.setPinnedAddress("https://shared.example/new", for: tab)

        #expect(Pins.shared().first { $0.id == tab.pinID }?.home == "https://shared.example/new")
        #expect(Pins.defs(browser.spaceID).allSatisfy { $0.id != tab.pinID })
    }
}
