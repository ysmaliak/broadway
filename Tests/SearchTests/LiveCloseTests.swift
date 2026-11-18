import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LiveCloseTests {
    private var browser: Browser!
    private let feed = LiveSource(kind: .feed, address: "https://example.com/feed")

    init() async throws {
        keepSetting(Shared.prefs, \.liveFolders, "live.on")
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesTabGroups = true
        browser.prefs.liveFolders = true
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
    }

    private func tearDown() async {
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    private func fill(_ made: LiveFolder, _ keys: [String]) {
        LiveFolders.shared.apply(.items(keys.map { LiveItem(key: $0, title: $0) }, nil), to: made.id)
        browser.syncLive()
    }

    private func facts(made: Bool = true, showsRow: Bool = true, inFront: Bool = false, busy: Bool = false,
                       typed: Bool? = false) -> LiveCloseFacts {
        LiveCloseFacts(made: made, showsRow: showsRow, inFront: inFront, busy: busy, typed: typed)
    }

    @Test func aTabIsClosedOnlyWhenEveryConditionHolds() {
        #expect(LiveClose.fate(facts()) == .close)
        #expect(LiveClose.fate(facts(made: false)) == .keep)
        #expect(LiveClose.fate(facts(showsRow: false)) == .keep)
        #expect(LiveClose.fate(facts(inFront: true)) == .keep)
        #expect(LiveClose.fate(facts(busy: true)) == .keep)
        #expect(LiveClose.fate(facts(typed: true)) == .keep)
        #expect(LiveClose.fate(facts(typed: nil)) == .ask)
        #expect(LiveClose.fate(facts(inFront: true, typed: nil)) == .keep)
    }

    @Test func aRowsOwnPageIncludesItsSubpages() {
        let key = "https://github.com/acme/rocket/pull/7"

        #expect(LiveClose.shows(URL(string: key), row: key))
        #expect(LiveClose.shows(URL(string: "https://github.com/acme/rocket/pull/7/files"), row: key))
        #expect(!LiveClose.shows(URL(string: "https://github.com/acme/rocket/pull/8"), row: key))
        #expect(!LiveClose.shows(URL(string: "https://example.com/elsewhere"), row: key))
    }

    @Test func aSleepingTabOfARowThatLeftIsClosedAndCanBeReopened() {
        let made = LiveFolders.shared.add(name: "News", source: feed, space: browser.spaceID)
        fill(made, ["https://example.com/1", "https://example.com/2"])

        fill(made, ["https://example.com/2"])

        #expect(browser.tabs(in: made.id).map(\.liveKey) == ["https://example.com/2"])
        #expect(!browser.tabs.contains { $0.address?.absoluteString == "https://example.com/1" })
        #expect(browser.recentlyClosed.first?.url.absoluteString == "https://example.com/1")
        #expect(browser.recentlyClosed.first?.groupID == nil)
    }

    @Test func aTabInFrontLeavesTheFolderAndStaysOpen() {
        let made = LiveFolders.shared.add(name: "News", source: feed, space: browser.spaceID)
        fill(made, ["https://example.com/1", "https://example.com/2"])
        let tab = browser.tabs(in: made.id)[0]
        browser.select(tab)

        fill(made, ["https://example.com/2"])

        #expect(browser.tabs.contains { $0 === tab })
        #expect(tab.groupID == nil && tab.liveKey == nil)
        #expect(LiveFolders.shared.folder(made.id)?.hidden == [])
    }

    @Test func aTabTakenToAnotherPageIsNeverClosed() {
        let made = LiveFolders.shared.add(name: "News", source: feed, space: browser.spaceID)
        fill(made, ["https://example.com/1", "https://example.com/2"])
        let tab = browser.tabs(in: made.id)[0]
        tab.restore(url: URL(string: "https://example.com/somewhere-else")!, title: "Elsewhere")

        fill(made, ["https://example.com/2"])

        #expect(browser.tabs.contains { $0 === tab })
        #expect(tab.groupID == nil)
    }

    @Test func aTabMakingSoundIsNeverClosed() {
        let made = LiveFolders.shared.add(name: "News", source: feed, space: browser.spaceID)
        fill(made, ["https://example.com/1", "https://example.com/2"])
        let tab = browser.tabs(in: made.id)[0]
        tab.noisy = true

        fill(made, ["https://example.com/2"])

        #expect(browser.tabs.contains { $0 === tab })
        #expect(tab.groupID == nil)
    }

    @Test func removingAFolderClosesOnlyTheTabsThatMayClose() {
        let made = LiveFolders.shared.add(name: "News", source: feed, space: browser.spaceID)
        fill(made, ["https://example.com/1", "https://example.com/2", "https://example.com/3"])
        let shown = browser.tabs(in: made.id)[0]
        let loud = browser.tabs(in: made.id)[1]
        browser.select(shown)
        loud.noisy = true

        LiveFolders.shared.remove(made.id)
        browser.syncLive()

        #expect(browser.tabs.contains { $0 === shown } && browser.tabs.contains { $0 === loud })
        #expect(!browser.tabs.contains { $0.address?.absoluteString == "https://example.com/3" })
        #expect(!browser.tabs.contains { $0.liveKey != nil })
    }

    @Test func turningLiveFoldersOffFollowsTheSameRule() {
        let made = LiveFolders.shared.add(name: "News", source: feed, space: browser.spaceID)
        fill(made, ["https://example.com/1", "https://example.com/2"])
        let shown = browser.tabs(in: made.id)[0]
        browser.select(shown)

        browser.prefs.liveFolders = false
        browser.syncLive()

        #expect(browser.tabs.contains { $0 === shown })
        #expect(!browser.tabs.contains { $0.address?.absoluteString == "https://example.com/2" })
        #expect(LiveFolders.shared.folder(made.id) != nil)
    }
}
