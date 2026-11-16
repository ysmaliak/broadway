import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FolderEmojiTests {
    private var browser: Browser!
    private var fake: FakeGroupEngine!
    private var kept: (Bool, Bool, Bool, Bool)!

    init() async throws {
        keepSettings("ai", AIGroups.onKey, AIGroups.emojiKey)
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.closeAll()
        browser.tabGroups = []
        browser.newTab()
        kept = (browser.prefs.ai, browser.prefs.usesTabGroups, AIGroups.shared.on, AIGroups.shared.emoji)
        browser.prefs.ai = true
        browser.prefs.usesTabGroups = true
        AIGroups.shared.on = false
        AIGroups.shared.emoji = true
        fake = FakeGroupEngine()
        FolderEmojis.shared.standIn = fake
        browser.tabs[0].restore(url: URL(string: "https://swift.example/docs")!, title: "Swift documentation")
    }

    private func tearDown() async {
        await settled()
        FolderEmojis.shared.standIn = nil
        browser.closeAll()
        browser.prefs.ai = kept.0
        browser.prefs.usesTabGroups = kept.1
        AIGroups.shared.on = kept.2
        AIGroups.shared.emoji = kept.3
        browser = nil
    }

    private func settled() async {
        for _ in 0..<200 where FolderEmojis.shared.busy {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FolderEmojis.shared.busy)
    }

    @Test func newFolderWithTabsGetsAnEmojiWithoutAutomaticGroupingOrRenaming() async throws {
        let tab = browser.tabs[0]

        let id = try #require(browser.newFolder(with: [tab], named: "References", editing: false))
        await settled()

        let group = try #require(browser.tabGroups.first { $0.id == id })
        #expect(group.name == "References")
        #expect(group.icon?.emoji == "🧑‍💻")
        #expect(!group.ai)
        #expect(!group.userIcon)
        #expect(fake.nameAsks.count == 1)
        #expect(fake.nameAsks.first?.tabs.map(\.id) == [tab.id])
        #expect(browser.record.rows[browser.spaceID.uuidString]?.groups?.first?.icon == group.icon)
    }

    @Test func folderFromOneTabGetsAnEmoji() async {
        let id = browser.addTabGroup(containing: browser.tabs[0])
        await settled()

        #expect(browser.tabGroups.first { $0.id == id }?.icon?.emoji == "🧑‍💻")
        #expect(browser.editingGroupID == id)
    }

    @Test func unavailableAndFailedModelsLeaveTheFolderAlone() async throws {
        FolderEmojis.shared.standIn = nil

        let unavailable = try #require(browser.newFolder(named: "Unavailable", editing: false))
        await settled()
        fake.failing = true
        FolderEmojis.shared.standIn = fake
        let failed = try #require(browser.newFolder(named: "Failed", editing: false))
        await settled()

        #expect(browser.tabGroups.first { $0.id == unavailable }?.icon == nil)
        #expect(browser.tabGroups.first { $0.id == failed }?.icon == nil)
    }

    @Test func theEmojiSwitchAndTabGroupsAreRespected() async {
        AIGroups.shared.emoji = false

        _ = browser.newFolder(named: "Off", editing: false)
        await settled()
        AIGroups.shared.emoji = true
        browser.prefs.usesTabGroups = false
        _ = browser.newFolder(named: "Groups off", editing: false)
        await settled()

        #expect(fake.nameAsks.isEmpty)
        #expect(browser.tabGroups.allSatisfy { $0.icon == nil })
    }

    @Test func choosingOrClearingAnIconWhileTheModelWorksWins() async throws {
        for icon in [TabIcon(emoji: "🌵"), nil] {
            fake.delay = 0.1
            let id = try #require(browser.newFolder(with: browser.tabs, named: "Manual", editing: false))
            try await Task.sleep(for: .milliseconds(30))

            browser.setIcon(icon, of: .folder(id))
            await settled()

            #expect(browser.tabGroups.first { $0.id == id }?.icon == icon)
            #expect(browser.tabGroups.first { $0.id == id }?.userIcon == true)
            browser.removeTabGroup(id)
        }
    }

    @Test func removingTheFolderWhileTheModelWorksDoesNotBringItBack() async throws {
        fake.delay = 0.1
        let id = try #require(browser.newFolder(named: "Going", editing: false))
        try await Task.sleep(for: .milliseconds(30))

        browser.removeTabGroup(id)
        await settled()

        #expect(!browser.tabGroups.contains { $0.id == id })
    }

    @Test func turningOffEmojiWhileTheModelWorksDoesNotSetOne() async throws {
        fake.delay = 0.1
        let id = try #require(browser.newFolder(named: "Off soon", editing: false))
        try await Task.sleep(for: .milliseconds(30))

        AIGroups.shared.emoji = false
        await settled()

        #expect(browser.tabGroups.first { $0.id == id }?.icon == nil)
    }
}
