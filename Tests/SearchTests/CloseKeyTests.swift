import AppKit
import Testing
@testable import Search

@MainActor
@Suite("Close keys follow the key window", .sharedWorld, .timeLimit(.minutes(5)))
struct CloseKeyTests {
    init() {
        _ = NSApplication.shared
    }

    private func browserWithTabs() -> (Browser, NSWindow) {
        let browser = Browser(record: WindowRecord())
        browser.open(URL(string: "https://a.example/")!, foreground: true)
        browser.open(URL(string: "https://b.example/")!, foreground: true)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        Browsers.register(browser)
        addTeardownBlock {
            browser.window = nil
            window.close()
        }
        return (browser, window)
    }

    @Test func commandWWithSettingsInFrontClosesSettingsAndNoTab() throws {
        let (browser, window) = browserWithTabs()
        defer { browser.closeAll() }
        window.orderFront(nil)
        let settings = SettingsWindow.frame(browser, asked: "tabs")
        settings.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        settings.orderFront(nil)
        let tabs = browser.tabs.count

        let taken = Browsers.pressClose(shift: false, in: settings)

        #expect(taken != "monitor")
        #expect(!settings.isVisible)
        #expect(browser.tabs.count == tabs)
        #expect(window.isVisible)
    }

    @Test func shiftCommandWWithSettingsInFrontLeavesTheBrowserWindow() throws {
        let (browser, window) = browserWithTabs()
        defer { browser.closeAll() }
        window.orderFront(nil)
        let settings = SettingsWindow.frame(browser, asked: "tabs")
        settings.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        settings.orderFront(nil)
        defer { settings.close() }
        let tabs = browser.tabs.count

        _ = Browsers.pressClose(shift: true, in: settings)

        #expect(window.isVisible)
        #expect(browser.tabs.count == tabs)
    }

    @Test func commandWWithTheBrowserInFrontClosesATab() throws {
        let (browser, window) = browserWithTabs()
        defer { browser.closeAll() }
        window.orderFront(nil)
        let tabs = browser.tabs.count

        _ = Browsers.pressClose(shift: false, in: window)

        #expect(browser.tabs.count == tabs - 1)
        #expect(window.isVisible)
    }

    @Test func onlyBrowserWindowsAndTheirPanelsOwnTheCloseKeys() throws {
        let (browser, window) = browserWithTabs()
        defer { browser.closeAll() }
        let settings = SettingsWindow.frame(browser, asked: "general")
        defer { settings.close() }

        #expect(Browsers.ownsKeys(window))
        #expect(!Browsers.ownsKeys(settings))
        #expect(Browsers.ownsKeys(nil))
    }
}
