import AppKit
import Testing
@testable import Search

/// A pinned tab going between an extension's page and a website is swapped
/// for a new tab (Browser.replace): it has to stay the same pin, at the same
/// home, in the same spaces. In a test world of its own, nothing shown.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PinCrossTests {
    private var browser: Browser!
    private let home = URL(string: "chrome-extension://pin-cross/options.html")!
    private let site = URL(string: "https://signin.example/")!

    init() {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
    }

    private func tearDown() {
        browser.closeAll()
        browser = nil
    }

    /// A pin at its home, in the row.
    private func pin(everywhere: Bool = false) -> Tab {
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.setAddressOptimistically(home)
        tab.pin = "P"
        tab.pinID = UUID()
        tab.home = home
        tab.everywhere = everywhere
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
        return tab
    }

    /// The tab standing where `tab` stood, once it has gone to `site`.
    private func cross(_ tab: Tab) throws -> Tab {
        let index = try #require(browser.tabs.firstIndex { $0 === tab })
        browser.replace(tab, going: site)
        let fresh = browser.tabs[index]
        #expect(!(fresh === tab), "The tab should have been swapped for a new one")
        return fresh
    }

    @Test func aPinThatCrossesIsTheSamePin() throws {
        let tab = pin()
        let id = tab.pinID
        let fresh = try cross(tab)
        #expect(fresh.pin == "P")
        // A new id would have every other window close its tab for this pin.
        #expect(fresh.pinID == id)
        // A double-click still goes back to where it was pinned, not to the
        // page the swap went to.
        #expect(fresh.home == home)
    }

    @Test func aPinEverySpaceShowsStaysInEverySpace() throws {
        let fresh = try cross(pin(everywhere: true))
        #expect(fresh.everywhere, "A shared pin would be written back as this space's own")
    }

    @Test func aPinOnlyHereStaysOnlyHere() throws {
        #expect(try !cross(pin()).everywhere)
    }
}
