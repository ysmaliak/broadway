import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PersonTabCloseTests {
    private var browser: Browser!
    private var socket: AgentSocket!
    private var tabs: [Tab] = []

    init() {
        keepSetting(Shared.prefs, \.usesTabGroups, "tabs.groups")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        tabs = (1...3).map { number in
            let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
            tab.restore(url: URL(string: "https://example.com/\(number)")!, title: "Tab \(number)")
            return tab
        }
        browser.showRow(tabs, active: tabs[0].id)
        browser.prefs.usesTabGroups = false
        socket = AgentSocket()
        socket.box.browser = browser
    }

    private func tearDown() {
        for tab in tabs where tab.pin != nil { browser?.unpin(tab) }
        browser?.closeAll()
        browser = nil
    }

    private func close(_ tab: Tab) async throws -> [String: Any] {
        let verb = try #require(PersonCommands.find("tabs", "close"))
        let call = PersonCall(noun: "tabs", verb: "close", arguments: ["tab": [PersonCommands.short(tab.id)]],
                              browser: browser, box: socket.box)
        return try await verb.run(call)
    }

    private func forms(_ tab: Tab, unsaved: Bool) async {
        await withCheckedContinuation { continuation in
            tab.web.evaluateInSearch("window.__officeForms = {unsaved: () => \(unsaved)}") { _ in continuation.resume() }
        }
    }

    @Test func closingAPersonsTabWithUnsavedWorkIsRefusedAndTheTabStays() async throws {
        await forms(tabs[1], unsaved: true)

        await #expect(throws: PersonRefusal.self) { _ = try await self.close(self.tabs[1]) }

        #expect(browser.tabs.contains { $0 === tabs[1] })
    }

    @Test func closingAPersonsTabWithNothingTypedClosesIt() async throws {
        await forms(tabs[1], unsaved: false)

        let said = try await close(tabs[1])

        #expect(said["message"] as? String == "Closed")
        #expect(!browser.tabs.contains { $0 === tabs[1] })
    }

    @Test func closingAPinIsReportedAsPutDown() async throws {
        browser.pin(tabs[2])

        let said = try await close(tabs[2])

        #expect(said["message"] as? String == "Put down")
        #expect(tabs[2].pin != nil)
        #expect(browser.tabs.contains { $0 === tabs[2] })
    }

    @Test func closingATabInAPinnedFolderPutsItAway() async throws {
        browser.prefs.usesTabGroups = true
        let folder = browser.addTabGroup(containing: tabs[1])
        browser.setFolderPinned(folder, true)
        browser.select(tabs[1])
        try #require(browser.putsAway(tabs[1]))

        let said = try await close(tabs[1])

        #expect(said["message"] as? String == "Put away")
        #expect(browser.tabs.contains { $0 === tabs[1] })
    }
}
