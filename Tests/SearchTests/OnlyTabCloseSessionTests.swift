import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct OnlyTabCloseSessionTests {
    @Test func closingAWindowsOnlyPageWritesTheSession() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let tab = try #require(browser.tabs.first)
        tab.restore(url: URL(string: "https://example.com/only")!, title: "Only")
        try await Task.sleep(for: .milliseconds(1500))
        try #require(!browser.remembering)

        browser.close(tab)

        #expect(browser.tabs.count == 1)
        #expect(browser.tabs.first?.isBlank == true)
        #expect(browser.remembering)
    }
}
