import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class ClearConfirmTests {
    private var browser: Browser!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.history.forget()
        browser.history.record(URL(string: "https://bank.example/account")!, title: "Account")
    }

    private func tearDown() async {
        Ask.testing = nil
        browser.history.forget()
    }

    @Test func cancellingClearHistoryKeepsIt() {
        Ask.testing = false

        browser.askToClear(.history)

        #expect(!browser.history.recent().isEmpty)
    }

    @Test func confirmingClearHistoryClearsIt() {
        Ask.testing = true

        browser.askToClear(.history)

        #expect(browser.history.recent().isEmpty)
    }

    @Test func eachQuestionNamesWhatGoesAndWhatStays() {
        let asked = Browser.Clearing.allCases

        let details = asked.map(\.detail)

        #expect(asked.map(\.rawValue) == ["clear.history", "clear.cookies", "clear.cache"])
        #expect(details[0].contains("Every address you have been to"))
        #expect(details[0].contains("the list of files you gave to sites, and the video speeds and darkened pages kept for sites"))
        #expect(details[0].contains("sign-ins and the downloads list stay"))
        #expect(details[1].contains("Cookies, sign-ins"))
        #expect(details[2].contains("Sign-ins, cookies, history and tabs stay"))
        #expect(details.allSatisfy { $0.contains("every space") })
        #expect(asked.map(\.title) == ["Clear history?", "Sign out of every site?", "Clear cache?"])
    }

    @Test func everyDangerZoneItemHasAQuestion() {
        let items = SettingsIndex.items(in: "clear")

        let asked = items.compactMap { Browser.Clearing(rawValue: $0.id) }

        #expect(asked.count == items.count)
    }
}
