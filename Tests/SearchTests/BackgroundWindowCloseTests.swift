import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct BackgroundWindowCloseTests {
    private final class CountingWindow: NSWindow {
        var closes = 0
        override func performClose(_ sender: Any?) { closes += 1 }
    }

    @Test func closingTheLastEmptyTabOfAWindowClosesThatWindowNotTheKeyOne() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let window = CountingWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer {
            browser.window = nil
            browser.closeAll()
        }
        browser.window = window
        let blank = try! #require(browser.tabs.first)
        #expect(browser.tabs.count == 1)
        #expect(blank.isBlank)

        browser.close(blank)

        #expect(window.closes == 1)
    }
}
