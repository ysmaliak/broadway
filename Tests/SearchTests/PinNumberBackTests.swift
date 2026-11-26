import AppKit
import Testing
@testable import Search

/// A pin's ⌘ number pressed again on that pin goes back to the tab before
/// it, with the switch on; with it off, nothing moves (idea 216).
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PinNumberBackTests {
    /// Always on since the Settings rework, an old "off" on disk included:
    /// it only gives a key that did nothing something to do.
    @Test func alwaysOn() {
        let saved = Store.settings.object(forKey: "pins.numberBack")
        defer { Store.settings.set(saved, forKey: "pins.numberBack") }
        Store.settings.removeObject(forKey: "pins.numberBack")
        #expect(Preferences().pinNumberGoesBack)
        Store.settings.set(false, forKey: "pins.numberBack")
        #expect(Preferences().pinNumberGoesBack)
    }

    @Test func secondPressGoesBackOnlyWhenOn() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = prefs.pinNumberGoesBack
        defer {
            browser.closeAll()
            prefs.pinNumberGoesBack = saved
        }
        for number in 1...4 {
            if number > 1 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        let pin = browser.tabs[0]
        browser.pin(pin)
        defer { browser.unpin(pin) }
        let reading = browser.tabs.first { $0.pin == nil && $0.title == "Tab 3" }!
        #expect(browser.tabShortcutTargets.first?.tab.id == pin.id, "The pin is ⌘1")

        prefs.pinNumberGoesBack = false
        browser.select(reading)
        browser.select(index: 0)
        #expect(browser.activeID == pin.id)
        browser.select(index: 0)
        #expect(browser.activeID == pin.id, "Off: a second press stays on the pin")

        prefs.pinNumberGoesBack = true
        browser.select(reading)
        browser.select(index: 0)
        #expect(browser.activeID == pin.id, "The first press still goes to the pin")
        browser.select(index: 0)
        #expect(browser.activeID == reading.id, "The second goes back to where you were")
        browser.select(index: 0)
        #expect(browser.activeID == pin.id, "And again to the pin")

        // A tab's number, not a pin's, never goes back.
        let other = browser.tabShortcutTargets[1].tab
        browser.select(index: 1)
        #expect(browser.activeID == other.id)
        browser.select(index: 1)
        #expect(browser.activeID == other.id)
    }
}
