import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct KeepOnTopTests {
    private func withBrowser(_ body: (Browser) throws -> Void) rethrows {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        defer {
            if KeepOnTop.isOn(browser) { KeepOnTop.toggle(browser) }
            browser.fullScreen = false
            browser.closeAll()
        }
        try body(browser)
    }

    @Test func aTestRunRecordsWhatWasAskedAndLeavesTheWindowWhereItIs() {
        withBrowser { browser in
            let before = KeepOnTop.asked.count

            KeepOnTop.toggle(browser)

            #expect(KeepOnTop.isOn(browser))
            #expect(KeepOnTop.asked.dropFirst(before) == [true])
            #expect(KeepOnTop.panelLevel == .floating)
        }
    }

    @Test func choosingItAgainTurnsItOff() {
        withBrowser { browser in
            KeepOnTop.toggle(browser)
            KeepOnTop.toggle(browser)

            #expect(!KeepOnTop.isOn(browser))
            #expect(KeepOnTop.asked.suffix(2) == [true, false])
        }
    }

    @Test func itIsForOneWindowOnly() {
        withBrowser { browser in
            let other = Browser(record: WindowRecord())
            defer { other.closeAll() }

            KeepOnTop.toggle(browser)

            #expect(!KeepOnTop.isOn(other))
        }
    }

    @Test func itIsGreyedInFullScreen() {
        withBrowser { browser in
            browser.fullScreen = true
            let before = KeepOnTop.asked.count

            KeepOnTop.toggle(browser)

            #expect(!KeepOnTop.allowed(browser))
            #expect(!KeepOnTop.isOn(browser))
            #expect(KeepOnTop.asked.count == before)
        }
    }

    @Test func aWindowFloatsAndBroadwaysOwnPanelsStandAboveIt() {
        #expect(KeepOnTop.above.rawValue > NSWindow.Level.floating.rawValue)
        #expect(KeepOnTop.above.rawValue < NSWindow.Level.popUpMenu.rawValue)
        #expect(KeepOnTop.allowed(fullScreen: false, popup: false))
        #expect(!KeepOnTop.allowed(fullScreen: false, popup: true))
    }
}
