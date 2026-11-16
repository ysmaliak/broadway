import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SettingsWindowPlaceTests {
    @Test func settingsOpensWhereItWasLeftAndTheSizeItWasLeft() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer {
            browser.closeAll()
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame " + SettingsWindow.place)
        }
        let first = SettingsWindow.frame(browser, asked: "general")
        SettingsWindow.restore(first)
        let visible = (first.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let left = NSRect(x: visible.minX + 40, y: visible.minY + 30, width: first.frame.width + 120, height: first.frame.height + 60)
        first.setFrame(left, display: false)
        first.saveFrame(usingName: SettingsWindow.place)
        first.setFrameAutosaveName("")
        first.close()

        let second = SettingsWindow.frame(browser, asked: "general")
        SettingsWindow.restore(second)
        defer { second.close() }

        #expect(second.frameAutosaveName == SettingsWindow.place)
        #expect(second.frame == left)
    }
}
