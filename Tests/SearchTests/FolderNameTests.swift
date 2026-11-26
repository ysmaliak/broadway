import AppKit
import Testing
@testable import Search

final class FailingGroupNamer: AIGroupDecider, AIGroupNamer, @unchecked Sendable {
    struct Down: Error {}
    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] { [:] }
    func name(_ ask: AIGroupNameAsk) async throws -> AIGroupName { throw Down() }
}

final class SlowGroupNamer: AIGroupDecider, AIGroupNamer, @unchecked Sendable {
    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] { [:] }
    func name(_ ask: AIGroupNameAsk) async throws -> AIGroupName {
        try await Task.sleep(for: .milliseconds(300))
        return AIGroupName(name: "Lisbon trip", emoji: nil)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FolderNameTests {
    private func browser(_ pages: [(String, String)]) -> Browser {
        keepSetting(AIGroups.shared, \.on, AIGroups.onKey)
        keepSetting(AIGroups.shared, \.emoji, AIGroups.emojiKey)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        for (index, page) in pages.enumerated() {
            if index > 0 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: page.1)!, title: page.0)
            browser.tabs.last?.cameBack = false
        }
        let groups = AIGroups.shared
        groups.on = true
        groups.emoji = true
        groups.quiet = 0.05
        groups.gap = 0.3
        groups.timeout = 5
        let macAvailable = groups.macAvailable
        addTeardownBlock { @MainActor in
            AIGroups.shared.standIn = nil
            AIGroups.shared.macAvailable = macAvailable
            AIGroups.shared.quiet = 1.5
            AIGroups.shared.gap = 4
            AIGroups.shared.timeout = 25
            browser.closeAll()
        }
        return browser
    }

    private static let lisbon = [("Lisbon flights", "https://booking.com/flights"),
                                 ("Lisbon hotels", "https://airbnb.com/s/lisbon"),
                                 ("Porto trains", "https://cp.pt/porto")]

    private func namer() -> ScriptedGroupEngine {
        ScriptedGroupEngine(picking: { _ in [:] }, naming: { ask in
            ask.tabs.contains { $0.title.hasPrefix("Porto") }
                ? AIGroupName(name: "Portugal trip", emoji: "🧳")
                : AIGroupName(name: "Lisbon trip", emoji: "✈️")
        })
    }

    private func titled(_ browser: Browser, _ title: String) -> Tab {
        browser.tabs.first { $0.title == title }!
    }

    private func name(_ id: UUID?, in browser: Browser) -> String? {
        browser.tabGroups.first { $0.id == id }?.name
    }

    private func settle(_ seconds: Double = 0.6) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @Test func aFolderMadeByHandWithTwoTabsIsNamedFromThem() async {
        let browser = browser(Self.lisbon)
        AIGroups.shared.standIn = namer()

        let id = browser.newFolder(with: [titled(browser, "Lisbon flights"), titled(browser, "Lisbon hotels")], editing: false)
        await settle()

        #expect(name(id, in: browser) == "Lisbon Trip")
        #expect(browser.tabGroups.first { $0.id == id }?.ai == false)
        #expect(browser.tabGroups.first { $0.id == id }?.userNamed == false)
    }

    @Test func aFolderMadeByHandWithOneTabKeepsItsName() async {
        let browser = browser(Self.lisbon)
        AIGroups.shared.standIn = namer()

        let id = browser.newFolder(with: [titled(browser, "Lisbon flights")], editing: false)
        let made = name(id, in: browser)
        await settle()

        #expect(made?.hasPrefix("Folder ") == true)
        #expect(name(id, in: browser) == made)
    }

    @Test func aFolderIsNamedWhenItsSecondTabArrives() async {
        let browser = browser(Self.lisbon)
        AIGroups.shared.standIn = namer()
        let id = browser.newFolder(with: [titled(browser, "Lisbon flights")], editing: false)
        await settle()

        browser.move(titled(browser, "Lisbon hotels"), toGroup: id)
        await settle()

        #expect(name(id, in: browser) == "Lisbon Trip")
    }

    @Test func aNamedFolderIsRenamedAsItsTabsChange() async {
        let browser = browser(Self.lisbon)
        AIGroups.shared.standIn = namer()
        let id = browser.newFolder(with: [titled(browser, "Lisbon flights"), titled(browser, "Lisbon hotels")], editing: false)
        await settle()

        browser.move(titled(browser, "Porto trains"), toGroup: id)
        await settle()

        #expect(name(id, in: browser) == "Portugal Trip")
    }

    @Test func aFolderIsNotNamedWhileItsRenameFieldIsOpen() async {
        let browser = browser(Self.lisbon)
        AIGroups.shared.standIn = namer()

        let id = browser.newFolder(with: [titled(browser, "Lisbon flights"), titled(browser, "Lisbon hotels")])
        let made = name(id, in: browser)
        await settle()

        #expect(browser.editingGroupID == id)
        #expect(name(id, in: browser) == made)
    }

    @Test func leavingTheRenameFieldUnchangedCountsAsNotNamedByThePerson() async throws {
        let browser = browser(Self.lisbon)
        AIGroups.shared.standIn = namer()
        let id = try #require(browser.newFolder(with: [titled(browser, "Lisbon flights"), titled(browser, "Lisbon hotels")]))
        let made = try #require(name(id, in: browser))
        await settle()

        browser.commitFolderName(id, typed: made, opened: made)
        await settle()

        #expect(browser.editingGroupID == nil)
        #expect(browser.tabGroups.first { $0.id == id }?.userNamed == false)
        #expect(name(id, in: browser) == "Lisbon Trip")
    }

    @Test func aNameThePersonTypesIsNeverReplaced() async throws {
        let browser = browser(Self.lisbon)
        AIGroups.shared.standIn = namer()
        let id = try #require(browser.newFolder(with: [titled(browser, "Lisbon flights"), titled(browser, "Lisbon hotels")]))
        let made = try #require(name(id, in: browser))

        browser.commitFolderName(id, typed: "December", opened: made)
        await settle()
        browser.move(titled(browser, "Porto trains"), toGroup: id)
        await settle()

        #expect(name(id, in: browser) == "December")
        #expect(browser.tabGroups.first { $0.id == id }?.userNamed == true)
    }

    @Test func aFolderNamedWhenItWasMadeIsLeftAlone() async {
        let browser = browser(Self.lisbon)
        AIGroups.shared.standIn = namer()

        let id = browser.newFolder(with: [titled(browser, "Lisbon flights"), titled(browser, "Lisbon hotels")], named: "Reading", editing: false)
        await settle()

        #expect(name(id, in: browser) == "Reading")
        #expect(browser.tabGroups.first { $0.id == id }?.madeName == nil)
    }

    @Test func withoutANamerTheFolderKeepsItsName() async throws {
        let browser = browser(Self.lisbon)
        AIGroups.shared.standIn = nil
        AIGroups.shared.macAvailable = { false }
        try #require(AIGroups.shared.namerEngine() == nil)

        let id = browser.newFolder(with: [titled(browser, "Lisbon flights"), titled(browser, "Lisbon hotels")], editing: false)
        let made = name(id, in: browser)
        await settle()

        #expect(made?.hasPrefix("Folder ") == true)
        #expect(name(id, in: browser) == made)
    }

    @Test func aNamerThatFailsLeavesTheNameAsItWas() async {
        let browser = browser(Self.lisbon)
        AIGroups.shared.standIn = FailingGroupNamer()

        let id = browser.newFolder(with: [titled(browser, "Lisbon flights"), titled(browser, "Lisbon hotels")], editing: false)
        let made = name(id, in: browser)
        await settle()

        #expect(name(id, in: browser) == made)
    }

    @Test func theNamingLeavesTheFoldersIconAlone() async {
        let browser = browser(Self.lisbon)
        AIGroups.shared.standIn = namer()
        let id = browser.newFolder(with: [titled(browser, "Lisbon flights"), titled(browser, "Lisbon hotels")], editing: false)
        if let index = browser.tabGroups.firstIndex(where: { $0.id == id }) { browser.tabGroups[index].icon = TabIcon(emoji: "📚") }

        await settle()

        #expect(name(id, in: browser) == "Lisbon Trip")
        #expect(browser.tabGroups.first { $0.id == id }?.icon?.emoji == "📚")
    }

    @Test func aGroupAnExtensionMakesWithoutATitleIsNotNamed() async {
        let browser = browser(Self.lisbon)
        AIGroups.shared.standIn = namer()

        let id = browser.addExtensionGroup(containing: titled(browser, "Lisbon flights"))
        browser.move(titled(browser, "Lisbon hotels"), toGroup: id)
        let made = name(id, in: browser)
        await settle()

        #expect(browser.editingGroupID == nil)
        #expect(browser.tabGroups.first { $0.id == id }?.madeName == nil)
        #expect(name(id, in: browser) == made)
    }

    @Test func aNameThatArrivesWhileTheRenameFieldIsOpenIsAskedForAgainWhenItCloses() async throws {
        let browser = browser(Self.lisbon)
        AIGroups.shared.standIn = SlowGroupNamer()
        let id = try #require(browser.newFolder(with: [titled(browser, "Lisbon flights"), titled(browser, "Lisbon hotels")], editing: false))
        let made = name(id, in: browser)
        await settle(0.15)
        browser.editingGroupID = id
        await settle(0.5)
        let whileOpen = name(id, in: browser)

        browser.editingGroupID = nil
        await settle(0.8)

        #expect(whileOpen == made)
        #expect(name(id, in: browser) == "Lisbon Trip")
    }

    @Test func theNameAFolderWasMadeWithIsKeptInTheSession() throws {
        var group = TabGroup(id: UUID(), name: "Folder 2", collapsed: false)
        group.madeName = "Folder 2"
        let old = #"{"id":"\#(UUID().uuidString)","name":"Folder 3","collapsed":false}"#

        let copy = try JSONDecoder().decode(TabGroup.self, from: JSONEncoder().encode(group))
        let older = try JSONDecoder().decode(TabGroup.self, from: Data(old.utf8))

        #expect(copy.madeName == "Folder 2")
        #expect(older.madeName == nil)
    }
}
