import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct SplitStageSwitchTests {
    @Test func aTabSelectedWithSplitViewOnIsOnTheStage() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let prefs = browser.prefs
        let saved = prefs.splitView
        defer {
            browser.closeAll()
            prefs.splitView = saved
        }
        prefs.splitView = true
        browser.newTab()
        let first = try #require(browser.active)
        first.go(to: URL(string: "about:blank")!)
        first.web.showFirstFrame()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = ContentView(browser: browser)
        window.orderFrontRegardless()
        defer {
            ContentView.forget(browser)
            window.contentView = nil
            window.close()
        }
        try await waitUntil { first.web.window === window }

        browser.close(first)
        try await Task.sleep(for: .milliseconds(300))
        browser.newTab()
        let second = try #require(browser.active)
        second.go(to: URL(string: "about:blank")!)
        second.web.showFirstFrame()
        browser.select(second)

        try await waitUntil { second.built?.window === window }
        #expect(second.built?.window === window)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out")
    }
}
