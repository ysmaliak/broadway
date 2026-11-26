import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized)
@MainActor
final class ScriptingTests {
    private var browser: Browser!
    private var window: NSWindow!
    private let allowed = Scripting.allowed

    init() {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        let mine = Tab(configuration: Web.configuration(space: browser.spaceID))
        mine.restore(url: URL(string: "https://example.com/mine")!, title: "Mine")
        browser.showRow([mine], active: mine.id)
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        Browsers.register(browser)
    }

    private func tearDown() {
        Scripting.allowed = allowed
        if let browser { Browsers.forget(browser) }
        browser?.window = nil
        window?.close()
        browser?.closeAll()
        browser = nil
    }

    @Test func aScriptReadsTabsOnlyWhileScriptsMayDriveBroadway() {
        Scripting.allowed = { false }
        let off = window.scriptTabs.count
        let offFront = window.scriptCurrentTab
        Scripting.allowed = { true }
        let on = window.scriptTabs.count

        #expect(off == 0)
        #expect(offFront == nil)
        #expect(on == 1)
    }
}
