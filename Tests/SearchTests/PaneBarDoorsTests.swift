import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PaneBarDoorsTests {
    private var browser: Browser!
    private var left: Tab!
    private var right: Tab!
    private let host = "pane-\(UUID().uuidString.prefix(8).lowercased()).example"
    private let shieldWas = Shield.shared.enabled

    init() {
        keepSetting(Shared.prefs, \.splitView, "splitView")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.prefs.splitView = true
        left = Tab(configuration: Web.configuration(space: browser.spaceID))
        left.restore(url: URL(string: "https://example.com/left")!, title: "Left")
        right = Tab(configuration: Web.configuration(space: browser.spaceID))
        right.restore(url: URL(string: "https://\(host)/right")!, title: "Right")
        browser.showRow([left, right], active: left.id)
        browser.pair(right, with: left, onLeft: false)
        browser.focusPane(left)
        Shield.shared.enabled = true
    }

    private func tearDown() {
        Shield.shared.offer = nil
        Shield.shared.enabled = shieldWas
        browser?.closeAll()
        browser = nil
    }

    @Test func quickReloadsFromAPanesOwnBarBringTheOfferToPauseBlocking() {
        #expect(browser.activeID == left.id)

        for _ in 0..<3 { browser.reload(right) }

        #expect(Shield.shared.offer == host)
    }

    @Test func backOnAPanesOwnBarNeverClosesThePane() {
        right.linkedFrom = left.id
        browser.focusPane(right)
        #expect(browser.activeID == right.id)

        browser.back(right)
        browser.focusPane(left)
        browser.back(right)

        #expect(browser.tabs.contains { $0 === right })
        #expect(browser.split(for: right) != nil)
    }
}
