import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PinnedSelfCloseTests {
    private var browser: Browser!
    private var server: LocalPageServer!

    init() throws {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        server = try LocalPageServer([
            "/done": .init(type: "text/html", body: "<!doctype html><title>Signed in</title><p>You can close this window</p>"),
            "/other": .init(type: "text/html", body: "<!doctype html><title>Other</title><p>Other</p>"),
        ])
    }

    private func tearDown() {
        for tab in browser?.tabs ?? [] where tab.pin != nil { browser?.unpin(tab) }
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

    private func settled(_ tab: Tab, at path: String) -> Bool {
        tab.built.map { !$0.isLoading && $0.processID > 0 } == true && tab.committed?.path == path
    }

    @Test func aPinnedPageThatClosesItselfKeepsItsPin() async throws {
        let other = browser.open(server.url("/other"), foreground: true)
        try await until("the other page loads") { settled(other, at: "/other") }
        let tab = browser.open(server.url("/done"), foreground: false)
        _ = tab.web
        try await until("the page loads") { settled(tab, at: "/done") }
        browser.pin(tab)
        try #require(tab.pin != nil)
        let web = try #require(tab.built)

        _ = try? await web.evaluateJavaScript("window.close(); true")
        try await until("the page is let go") { tab.asleep || tab.pin == nil || !browser.tabs.contains { $0 === tab } }

        #expect(tab.asleep)
        #expect(tab.pin != nil)
        #expect(browser.tabs.contains { $0 === tab })
        #expect(browser.activeID == other.id)
    }
}
