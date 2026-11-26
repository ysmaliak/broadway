import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FailedAddressTests {
    private func until(_ done: () -> Bool) async throws {
        for _ in 0..<1000 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aLoadThatFailsKeepsTheFailedAddressAndBackShowsThePageBefore() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let server = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><title>Before</title><p>Before</p>")])
        defer { server.stop() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let before = server.url("/page")
        let failing = try #require(URL(string: "https://shop.example/basket"))
        let tab = browser.open(before, foreground: true)
        try await until { !tab.loading && tab.committed != nil && tab.title == "Before" }

        tab.go(to: failing)
        try await until { tab.failure != nil && !tab.loading }
        try await Task.sleep(for: .milliseconds(300))
        let failed = (address: tab.address, failure: tab.failure, back: tab.canGoBack, shown: tab.shownURL,
                      kept: browser.tabsInSession.contains(tab.id), label: tab.label)

        tab.reload()
        try await Task.sleep(for: .milliseconds(100))
        try await until { tab.failure != nil && !tab.loading }
        try await Task.sleep(for: .milliseconds(300))
        let again = (address: tab.address, failure: tab.failure)

        browser.back(tab)
        let back = (address: tab.address, failure: tab.failure, title: tab.title, label: tab.label)

        #expect(failed.address == failing)
        #expect(failed.shown == failing)
        #expect(failed.failure != nil)
        #expect(failed.back)
        #expect(failed.kept)
        #expect(failed.label == Address.pretty(failing))
        #expect(again.address == failing)
        #expect(again.failure != nil)
        #expect(back.address == before)
        #expect(back.failure == nil)
        #expect(back.title == "Before")
        #expect(back.label == "Before")
    }
}
