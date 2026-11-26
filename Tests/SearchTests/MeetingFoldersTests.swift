import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class MeetingFoldersTests {
    private var browser: Browser!
    private var window: NSWindow!
    private let call = URL(string: "http://call.invalid/qwe-rtyu-iop")!
    private let notes = URL(string: "http://notes.invalid/agenda")!
    private var saved: (groups: Bool, spaces: Bool, folders: Bool)!
    private var live: [UUID] = []

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        _ = NSApplication.shared
        MeetingLink.testHosts = ["call.invalid": .meet]
        MeetingFolders.shared.forget()
        keepSetting(Shared.prefs, \.liveFolders, "live.on")
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        saved = (browser.prefs.usesTabGroups, browser.prefs.usesSpaces, browser.prefs.meetingFolders)
        browser.prefs.usesTabGroups = true
        browser.prefs.usesSpaces = false
        browser.prefs.meetingFolders = true
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        LinkRules.shared.replaceAll([])
    }

    private func tearDown() async {
        for id in live { LiveFolders.shared.remove(id) }
        MeetingLink.testHosts = [:]
        MeetingFolders.shared.forget()
        browser.prefs.usesTabGroups = saved.groups
        browser.prefs.usesSpaces = saved.spaces
        browser.prefs.meetingFolders = saved.folders
        window.contentView = nil
        window.close()
        browser.closeAll()
        browser = nil
    }

    private func settle() async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private var event: CalendarEvent {
        CalendarEvent(id: "design-review", title: "Design review", start: Date(), end: Date().addingTimeInterval(1800), url: call)
    }

    private func joined() async throws -> Tab {
        browser.joinMeeting(call, event: event)
        try await settle()
        return try #require(browser.tabs.last { $0.address == call })
    }

    private func liveFolder() -> UUID {
        browser.prefs.liveFolders = true
        let made = LiveFolders.shared.add(name: "PRs", source: LiveSource(kind: .pullRequests, address: "http://127.0.0.1:9/pulls"),
                                          space: browser.spaceID)
        live.append(made.id)
        LiveFolders.shared.apply(.items([LiveItem(key: "http://127.0.0.1:9/acme/rocket/pull/1", title: "PR 1")], nil), to: made.id)
        browser.syncLive()
        return made.id
    }

    private func meetingFolder() -> TabGroup? {
        browser.tabGroups.first { $0.meeting != nil }
    }

    private func link(from tab: Tab, _ url: URL? = nil) -> Tab {
        browser.open(url ?? notes, foreground: false, from: tab, link: true)
    }

    @Test func aPageOpenedFromTheCallGathersWithItInAFolderNamedAfterTheMeeting() async throws {
        let tab = try await joined()
        #expect(meetingFolder() == nil)

        let page = link(from: tab)
        try await settle()

        let folder = try #require(meetingFolder())
        #expect(folder.name == "Design review")
        #expect(!folder.ai)
        #expect(Set(browser.tabs(in: folder.id).map(\.id)) == [tab.id, page.id])
        #expect(browser.announcement == MeetingFolderRule.made)
        #expect(browser.announcedUndo != nil)
    }

    @Test func joinWithALiveFoldersRowInFrontOpensTheCallLoose() async throws {
        let made = liveFolder()
        let row = try #require(browser.tabs(in: made).first)
        browser.select(row)

        let tab = try await joined()

        #expect(browser.active?.id == tab.id)
        #expect(tab.groupID == nil)
        #expect(browser.group(of: tab) == nil)
        #expect(browser.tabs(in: made).map(\.id) == [row.id])
    }

    @Test func joinWithAFoldersTabInFrontOpensTheCallLoose() async throws {
        let page = browser.open(notes, foreground: true)
        let folder = try #require(browser.newFolder(with: [page], named: "Plans", editing: false))
        browser.select(page)

        let tab = try await joined()

        #expect(browser.active?.id == tab.id)
        #expect(tab.groupID == nil)
        #expect(browser.group(of: tab) == nil)
        #expect(browser.tabs(in: folder).map(\.id) == [page.id])
    }

    @Test func aTabOpenedByHandDuringTheCallStaysOutside() async throws {
        let tab = try await joined()
        _ = link(from: tab)
        try await settle()
        browser.select(tab)

        let own = browser.open(URL(string: "http://elsewhere.invalid/")!, foreground: true, from: tab)
        try await settle()

        #expect(browser.group(of: own) == nil)
    }

    @Test func endingTheCallClosesAndMovesNothing() async throws {
        let tab = try await joined()
        let page = link(from: tab)
        try await settle()
        let folder = try #require(meetingFolder())

        tab.go(to: URL(string: "http://call.invalid/")!)
        try await settle()

        #expect(browser.tabs.contains { $0 === tab })
        #expect(browser.tabs.contains { $0 === page })
        #expect(browser.tabGroups.first { $0.id == folder.id }?.name == "Design review")
        #expect(Set(browser.tabs(in: folder.id).map(\.id)) == [tab.id, page.id])
    }

    @Test func joiningTheSameMeetingAgainUsesItsFolder() async throws {
        let tab = try await joined()
        _ = link(from: tab)
        try await settle()
        let folder = try #require(meetingFolder())
        tab.go(to: URL(string: "http://call.invalid/")!)
        try await settle()

        let again = try await joined()

        #expect(again !== tab)
        #expect(browser.group(of: again) == folder.id)
        #expect(browser.tabGroups.filter { $0.meeting != nil }.count == 1)
    }

    @Test func anAgentsTabIsLeftOut() async throws {
        let tab = try await joined()

        let agent = browser.benchOpen(notes)
        agent.agent = true
        agent.linkedFrom = tab.id
        try await settle()

        #expect(meetingFolder() == nil)
        #expect(browser.group(of: agent) == nil)
    }

    @Test func nothingHappensInAPrivateWindow() async throws {
        let quiet = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { quiet.closeAll() }
        let tab = quiet.open(call, foreground: true)
        MeetingFolders.shared.joined(tab, link: call, event: event)

        let page = quiet.open(notes, foreground: false, from: tab, link: true)
        try await settle()

        #expect(quiet.tabGroups.isEmpty)
        #expect(quiet.group(of: page) == nil)
    }

    @Test func turnedOffNothingGathers() async throws {
        browser.prefs.meetingFolders = false
        let tab = try await joined()

        _ = link(from: tab)
        try await settle()

        #expect(meetingFolder() == nil)
    }

    @Test func undoPutsTheTabsBackAndMakesNoFolderForThatCallAgain() async throws {
        let tab = try await joined()
        let row = browser.tabs.map(\.id)
        let page = link(from: tab)
        try await settle()
        #expect(meetingFolder() != nil)

        browser.undoAnnounced()

        #expect(meetingFolder() == nil)
        #expect(tab.groupID == nil)
        #expect(page.groupID == nil)
        #expect(browser.tabs.map(\.id).filter(row.contains) == row)

        let later = link(from: tab)
        try await settle()

        #expect(meetingFolder() == nil)
        #expect(browser.group(of: later) == nil)
    }

    @Test func groupTabsAutomaticallyLeavesTheMeetingsFolderAlone() async throws {
        let tab = try await joined()
        _ = link(from: tab)
        try await settle()
        let folder = try #require(meetingFolder())

        #expect(!AIGrouper.named(folder))
        #expect(!Browser.dissolves(folder))
        #expect(!folder.ai)
    }

    @Test func theFolderKeepsItsMeetingThroughASavedSession() throws {
        var folder = TabGroup(id: UUID(), name: "Design review", collapsed: false)
        folder.meeting = "meet:qwe-rtyu-iop"

        let back = try JSONDecoder().decode(TabGroup.self, from: JSONEncoder().encode(folder))

        #expect(back.meeting == "meet:qwe-rtyu-iop")
        #expect(back.name == "Design review")
    }

    @Test func theSwitchIsInSettingsAndFoundByItsWords() {
        let item = SettingsIndex.item(Preferences.meetingFoldersKey)

        #expect(item?.title == "A folder for each meeting")
        #expect(item?.detail == "Pages opened from a call gather in a folder named after the meeting")
        #expect(item?.keys == [Preferences.meetingFoldersKey])
        #expect(item?.page == .tabs)
        let prefs = Preferences()
        let before = prefs.meetingFolders
        defer { prefs.meetingFolders = before }
        #expect(SettingsIndex.apply(Preferences.meetingFoldersKey, false, to: prefs))
        #expect(!prefs.meetingFolders)
    }

    @Test func aClosedTabLeavesNothingBehindInTheMeetingFolders() {
        let first = browser.open(URL(string: "about:blank")!, foreground: true)
        let tab = browser.open(URL(string: "about:blank")!, foreground: true)
        MeetingFolders.shared.joined(tab, link: call, event: nil)
        let held = MeetingFolders.shared.joined[tab.id] != nil

        browser.close(tab)

        #expect(held)
        #expect(MeetingFolders.shared.joined[tab.id] == nil)
        #expect(MeetingFolders.shared.firstSeen([tab]).map(\.id) == [tab.id])
        #expect(first.id != tab.id)
    }
}
