import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SettingsHandTests {
    init() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    @Test func whatASecondWindowAsksOfSettingsReachesTheWindowSettingsWatches() {
        let first = Browser(record: WindowRecord())
        let second = Browser(record: WindowRecord())
        let space = UUID()
        let rule = UUID()
        second.settingsAsked = .links
        second.settingsTyped = "zoom"
        second.settingsRule = rule
        second.settingsLanguages = space

        SettingsWindow.hand(second, to: first)

        #expect(first.settingsAsked == .links)
        #expect(first.settingsTyped == "zoom")
        #expect(first.settingsRule == rule)
        #expect(first.settingsLanguages == space)
        #expect(second.settingsAsked == nil && second.settingsTyped == nil && second.settingsRule == nil && second.settingsLanguages == nil)
    }

    @Test func withNoSettingsWindowTheAskingWindowIsTheOneWatched() {
        let browser = Browser(record: WindowRecord())

        #expect(SettingsWindow.shared.listener(for: browser) === browser)
    }
}
