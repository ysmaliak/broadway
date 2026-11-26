import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class TabLifetimeTests {
    @Test func closingATabReleasesItWhileItsBrowserStaysOpen() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let prefs = browser.prefs
        let saved = (prefs.usesSpaces, prefs.splitView, prefs.sharesPins)
        prefs.usesSpaces = false
        prefs.splitView = false
        prefs.sharesPins = false
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SideColumnView(browser: browser)
        window.orderBack(nil)
        defer {
            browser.closeAll()
            (prefs.usesSpaces, prefs.splitView, prefs.sharesPins) = saved
            window.contentView = nil
            window.close()
        }
        _ = browser.open(URL(string: "about:blank")!, foreground: true)
        var tab: Search.Tab? = browser.open(URL(string: "about:blank")!, foreground: false)
        tab?.restore(url: URL(string: "https://fixture.invalid/closed")!, title: "Closing fixture")
        weak var closed = tab
        let id = tab!.id
        let mounted = ProcessInfo.processInfo.systemUptime + 5
        while Bench.pressRows[id] == nil && ProcessInfo.processInfo.systemUptime < mounted {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Bench.pressRows[id] != nil)
        #expect(closed != nil)

        browser.close(tab!)
        tab = nil
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while closed != nil && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(closed == nil)
        #expect(!browser.tabs.isEmpty)
    }
}
