import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AddressSaidTests {
    private var browser: Browser!
    private var server: LocalPageServer!
    private var other: LocalPageServer!

    init() throws {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        server = try LocalPageServer([
            "/start": .init(type: "text/html", body: "<!doctype html><title>Start</title><p>Start</p>"),
        ])
        other = try LocalPageServer([
            "/slow": .init(type: "text/html", body: "<!doctype html><title>Slow</title><p>Slow</p>", hold: 1.5),
        ])
    }

    private func tearDown() {
        server?.stop()
        other?.stop()
        browser?.closeAll()
        browser = nil
    }

    private func until(_ done: @escaping @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < end else { Issue.record("timed out", sourceLocation: sourceLocation); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func started() async throws -> Tab {
        let tab = browser.open(server.url("/start"), foreground: true)
        try await until { tab.committed == self.server.url("/start") && !tab.loading }
        return tab
    }

    private func pill(_ tab: Tab) -> String? {
        AddressLaneView.line(tab, prefs: browser.prefs)
    }

    @Test func aLoadThePersonStartedIsNamedByThePillAndTheRowWhileItIsOnItsWay() async throws {
        let tab = try await started()

        tab.go(to: other.url("/slow"))
        try await Task.sleep(for: .milliseconds(300))

        #expect(tab.committed == server.url("/start"))
        #expect(tab.saidAddress == other.url("/slow"))
        #expect(pill(tab) == AddressLaneView.text(other.url("/slow"), full: false))
    }

    @Test func anAddressHeldForTheTabWithoutLoadingItIsNamedByThePillAndTheRow() async throws {
        let tab = try await started()
        let asked = try #require(URL(string: "https://shop.example/sign-in"))

        tab.hold(asked)

        #expect(tab.committed == server.url("/start"))
        #expect(tab.saidAddress == asked)
        #expect(pill(tab) == AddressLaneView.text(asked, full: false))
    }

    @Test func aLoadThePageStartedLeavesThePillAndTheRowOnThePageOnScreenUntilTheNewOneArrives() async throws {
        let tab = try await started()

        _ = try await tab.web.evaluateJavaScript("location.href = '\(other.url("/slow").absoluteString)'; 1")
        try await until { tab.address == self.other.url("/slow") }

        #expect(tab.committed == server.url("/start"))
        #expect(tab.saidAddress == server.url("/start"))
        #expect(pill(tab) == AddressLaneView.text(server.url("/start"), full: false))

        try await until { tab.committed == self.other.url("/slow") }
        #expect(tab.saidAddress == other.url("/slow"))
    }
}
