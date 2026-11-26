import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PageOpenedTabTests {
    private var browser: Browser!
    private var server: LocalPageServer!

    init() throws {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        server = try LocalPageServer([
            "/shop": .init(type: "text/html", body: "<!doctype html><title>Shop</title><p>Shop</p>"),
            "/help": .init(type: "text/html", body: "<!doctype html><title>Help</title><p>Help</p>"),
        ])
    }

    private func tearDown() {
        server?.stop()
        browser?.closeAll()
        browser = nil
    }

    private func until(_ what: String, within seconds: TimeInterval = 8, _ done: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !done() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("timed out: \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    @Test func aTabAPageOpensInFrontIsSelectedAsOpeningATabIsAndClearsTheField() async throws {
        let shop = server.url("/shop")
        let opener = browser.open(shop, foreground: true)
        try await until("the page loads") { opener.built.map { !$0.isLoading && $0.processID > 0 } == true && opener.committed?.path == "/shop" }
        opener.popupSites = [try #require(BlockedPopups.site(of: shop))]
        let before = browser.tabs.count
        browser.typed = "draft words"

        _ = try? await opener.web.evaluateJavaScript("window.open('/help'); true")
        try await until("the page's tab opens") { browser.tabs.count == before + 1 }

        let opened = try #require(browser.tabs.first { $0.id != opener.id && $0.opener == opener.id })
        #expect(browser.activeID == opened.id)
        #expect(browser.typed == "")
    }
}
