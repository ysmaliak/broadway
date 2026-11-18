import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct BenchBehindTests {
    private func window() -> NSWindow {
        let made = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 120, height: 80), styleMask: .borderless, backing: .buffered,
                            defer: false)
        made.isReleasedWhenClosed = false
        return made
    }

    @Test func aBenchWindowIsShownBelowEveryOrdinaryWindow() {
        let made = window()
        defer { made.close() }

        made.benchShowBehind()

        #expect(made.level.rawValue == NSWindow.Level.normal.rawValue - 1)
        #expect(made.level.rawValue < NSWindow.Level.normal.rawValue)
        #expect(made.isVisible)
    }

    @Test func itNeverBecomesKeyOrMainAndTheAppIsNotMadeActive() {
        let made = window()
        defer { made.close() }
        let active = NSApp.isActive

        made.benchShowBehind()

        #expect(!made.isKeyWindow)
        #expect(!made.isMainWindow)
        #expect(NSApp.isActive == active)
    }

    @Test func aWindowAlreadyLowerKeepsItsLevel() {
        let made = window()
        defer { made.close() }
        let lower = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        made.level = lower

        made.benchShowBehind()

        #expect(made.level == lower)
        #expect(made.isVisible)
    }

    @Test func aWindowAboveTheOrdinaryOnesIsBroughtDown() {
        let made = window()
        defer { made.close() }
        made.level = .floating

        made.benchShowBehind()

        #expect(made.level == .benchBehind)
    }
}
