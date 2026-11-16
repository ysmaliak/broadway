import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct MutedTabRestoreTests {
    @Test func reopenedTabsKeepMutedAndUnmutedState() throws {
        try withBrowser { browser, tabs in
            tabs[1].toggleMute()
            browser.close(tabs[1])
            browser.reopen()
            let muted = try #require(browser.tabs.first { $0.address == tabs[1].address })
            #expect(muted.muted)

            browser.close(try #require(browser.tabs.first { $0.address == tabs[2].address }))
            browser.reopen()
            let unmuted = try #require(browser.tabs.first { $0.address == tabs[2].address })
            #expect(!unmuted.muted)
        }
    }

    @Test func batchReopenKeepsEachTabsMute() throws {
        try withBrowser { browser, tabs in
            tabs[1].toggleMute()
            tabs[3].toggleMute()
            let addresses = tabs.compactMap(\.address)
            browser.closeTabsBelow(tabs[0])
            #expect(browser.tabs.count == 1)

            browser.reopen()
            #expect(browser.tabs.compactMap(\.address) == addresses)
            let byAddress = Dictionary(uniqueKeysWithValues: zip(addresses, browser.tabs))
            let mutedAddress = try #require(tabs[1].address)
            let unmutedAddress = try #require(tabs[2].address)
            let mutedAgainAddress = try #require(tabs[3].address)
            let muted = try #require(byAddress[mutedAddress])
            let unmuted = try #require(byAddress[unmutedAddress])
            #expect(muted.muted)
            #expect(!unmuted.muted)
            #expect(try #require(byAddress[mutedAgainAddress]).muted)
            #expect(muted.asleep)
            #expect(muted.built == nil)
        }
    }

    @Test func closedGroupKeepsMutedTabState() throws {
        try withBrowser { browser, tabs in
            browser.prefs.usesTabGroups = true
            tabs[2].toggleMute()
            let group = browser.addTabGroup(containing: tabs[1])
            browser.move(tabs[2], toGroup: group)
            browser.closeTabGroup(group)

            browser.reopen()
            let unmuted = try #require(browser.tabs.first { $0.address == tabs[1].address })
            let muted = try #require(browser.tabs.first { $0.address == tabs[2].address })
            #expect(!unmuted.muted)
            #expect(muted.muted)
        }
    }

    @Test func sessionRestoresMutedTabWhileItIsStillAsleep() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let muted = "https://muted-restore.example/"
        let heard = "https://heard-restore.example/"
        let written = try sessionShape(tabs: [
            ["url": muted, "title": "Muted", "muted": true],
            ["url": heard, "title": "Heard"],
        ], active: 1)
        let browser = makeBrowser()
        defer { browser.closeAll() }
        browser.record.rows[browser.spaceID.uuidString] = written
        let restoredRow = browser.loadRow(browser.spaceID)
        let restored = try #require(restoredRow.tabs.first { $0.address?.absoluteString == muted })
        #expect(restored.muted)
        #expect(restored.asleep)
        #expect(restored.built == nil, "restoring the mute must not wake the tab")
        #expect(try !#require(restoredRow.tabs.first { $0.address?.absoluteString == heard }).muted)
    }

    @Test func legacySessionMuteDefaultsToFalseAndMuteRoundTrips() throws {
        let legacy = try JSONDecoder().decode(
            Session.Entry.self,
            from: JSONSerialization.data(withJSONObject: ["url": "https://legacy.example/", "title": "Legacy"])
        )
        #expect(try !encodedMuted([legacy])[0])

        let muted = try JSONDecoder().decode(
            Session.Entry.self,
            from: JSONSerialization.data(withJSONObject: [
                "url": "https://muted-roundtrip.example/", "title": "Muted", "muted": true,
            ])
        )
        #expect(try encodedMuted([muted]) == [true])
    }

    @Test func toggleSavesMuteAndUnmuteClearsItWithoutAnotherAct() async throws {
        let browser = Browser(record: nil)
        defer { browser.closeAll() }
        let tab = browser.tabs.first { !$0.isBlank } ?? {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "https://mute-save.example/")!, title: "Mute save")
            return browser.tabs.last!
        }()

        tab.toggleMute()
        await waitForSavedMute(browser, address: tab.address, true)
        let savedAfterMute = try savedShape(browser).tabs.map { ($0.url, $0.muted) }
        #expect(try savedMute(browser, address: tab.address) == true, "saved row: \(savedAfterMute)")

        tab.toggleMute()
        await waitForSavedMute(browser, address: tab.address, false)
        let savedAfterUnmute = try savedShape(browser).tabs.map { ($0.url, $0.muted) }
        #expect(try savedMute(browser, address: tab.address) == false, "saved row: \(savedAfterUnmute)")
    }

    /// The mute subscription asks for the session a moment later. None of
    /// these checks after each toggle write one themselves.
    private func waitForSavedMute(_ browser: Browser, address: URL?, _ wanted: Bool) async {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if (try? savedMute(browser, address: address)) == wanted { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func withBrowser(_ body: (Browser, [Tab]) throws -> Void) rethrows {
        let browser = makeBrowser()
        let groups = browser.prefs.usesTabGroups
        defer {
            browser.closeAll()
            browser.prefs.usesTabGroups = groups
        }
        browser.prefs.usesTabGroups = false
        try body(browser, browser.tabs)
    }

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.closeAll()
        browser.record.rows = [:]
        browser.parked = [:]
        browser.tabGroups = []
        for number in 1...4 {
            browser.newTab()
            browser.tabs.last?.restore(
                url: URL(string: "https://muted-\(number).example/")!,
                title: "Tab \(number)"
            )
        }
        return browser
    }

    private func savedMute(_ browser: Browser, address: URL?) throws -> Bool? {
        try savedShape(browser).tabs.first { $0.url == address?.absoluteString }?.muted
    }

    private func savedShape(_ browser: Browser) throws -> Session.Shape {
        browser.usesFiles ? Session.read(space: browser.spaceID) : browser.allRows()[browser.spaceID.uuidString]
            ?? Session.Shape(tabs: [], active: 0)
    }

    private func encodedMuted(_ entries: [Session.Entry]) throws -> [Bool] {
        let data = try JSONEncoder().encode(entries)
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return objects.map { $0["muted"] as? Bool ?? false }
    }

    private func sessionShape(tabs: [[String: Any]], active: Int) throws -> Session.Shape {
        let object: [String: Any] = ["tabs": tabs, "active": active]
        return try JSONDecoder().decode(
            Session.Shape.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
