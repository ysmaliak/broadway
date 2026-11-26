import Foundation
import Testing
@testable import Search

enum Released04 {
    enum Range: String, Codable { case today, week, month, open }
    enum List: String, Codable { case reviewRequests, teamReviews, needsAction, waiting, ready, drafts, created, assigned, involved }
    enum Checks: String, Codable { case passing, failing, pending }

    struct Source: Codable {
        enum Kind: String, Codable { case feed, pullRequests, repository, issues, subscriptions, page, notifications, linear }
        var kind: Kind
        var address: String
        var range: Range? = nil
        var lists: [List]? = nil
        var statuses: [String]? = nil
    }

    struct Stack: Codable {
        var position: Int
        var count: Int
    }

    struct Branch: Codable {
        var repository: String
        var base: String
        var head: String
        var stack: Int? = nil
        var position: Int? = nil
        var stackRead: Bool? = nil
    }

    struct Item: Codable {
        var key: String
        var title: String
        var label: String? = nil
        var opened: Date? = nil
        var author: String? = nil
        var checks: Checks? = nil
        var updated: Date? = nil
        var arrived: Date? = nil
        var list: List? = nil
        var activity: Date? = nil
        var noticed: Date? = nil
        var stack: Stack? = nil
        var branch: Branch? = nil
        var draft: Bool? = nil
        var unanswered: Int? = nil
        var signsRead: Bool? = nil
        var status: String? = nil
    }

    struct SSO: Codable {
        var org: String?
        var url: String
    }

    struct Folder: Codable {
        enum State: String, Codable {
            case waiting, fine, signIn, failed

            init(from decoder: Decoder) throws {
                self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .waiting
            }
        }

        var id = UUID()
        var space: UUID
        var name: String
        var source: Source
        var paused = false
        var state = State.waiting
        var items: [Item] = []
        var hidden: [String] = []
        var hiddenMissing: [String: Date]? = nil
        var read: Date? = nil
        var noticing: Bool? = nil
        var sso: SSO? = nil
        var order: [String]? = nil
    }
}

@MainActor
struct LiveFileTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func busy() -> LiveFolder {
        var folder = LiveFolder(space: UUID(), name: "PRs", source: .pullRequests)
        var item = LiveItem(key: "https://github.com/acme/rocket/pull/4", title: "Four", list: .created)
        item.on = [.created, .assigned]
        item.pageRead = now
        folder.items = [item]
        folder = LiveTrust.after(folder, .missed(LiveMiss(cause: .limited, wait: 600)), now: now)
        folder.good = now.addingTimeInterval(-3600)
        folder.notFeeds = 2
        folder.emptyFeeds = 1
        return folder
    }

    @Test func aFileWrittenNowLoadsInTheShapeTheReleasedBuildKnows() throws {
        let data = try JSONEncoder().encode([busy(), LiveFolder(space: UUID(), name: "Feed", source: LiveSource(kind: .feed, address: "https://example.com/feed"))])

        let old = try JSONDecoder().decode([Released04.Folder].self, from: data)

        #expect(old.count == 2)
        #expect(old.first?.state == .failed)
        #expect(old.first?.items.first?.list == .created)
    }

    @Test func aFileWrittenByTheReleasedBuildLoadsNow() throws {
        var old = Released04.Folder(space: UUID(), name: "PRs", source: .init(kind: .pullRequests, address: LiveSource.pullRequests.address))
        old.state = .fine
        old.read = now
        old.items = [.init(key: "https://github.com/acme/rocket/pull/4", title: "Four", list: .created)]
        let data = try JSONEncoder().encode([old])

        let loaded = try #require(LiveFolders.sorted(data)).kept

        #expect(loaded.first?.items.first?.on == nil)
        #expect(LiveFolders.woken(loaded).first?.good == now)
    }
}

@MainActor
struct LiveFileEntryTests {
    private let space = UUID()

    private func good(_ name: String) throws -> Data {
        try JSONEncoder().encode(LiveFolder(space: space, name: name, source: LiveSource(kind: .feed, address: "https://example.com/\(name)")))
    }

    private func joined(_ parts: [Data]) -> Data {
        var out = Data("[\n  ".utf8)
        for (index, part) in parts.enumerated() {
            if index > 0 { out.append(contentsOf: Array(",\n  ".utf8)) }
            out.append(part)
        }
        out.append(contentsOf: Array("\n]".utf8))
        return out
    }

    @Test func aFileInTodaysShapeLoads() throws {
        var folder = LiveFolder(space: space, name: "PRs", source: .pullRequests)
        folder.good = Date(timeIntervalSince1970: 1_800_000_000)
        folder.more = "https://github.com/pulls?page=2"

        let loaded = try #require(LiveFile.read(try JSONEncoder().encode([folder]), retiredKinds: []))

        #expect(loaded.kept == [folder])
        #expect(loaded.foreign.isEmpty)
    }

    @Test func aBadEntryAmongGoodOnesIsKeptAsItsBytes() throws {
        let bad = Data(#"{"id":"6B1F7A5E-0000-4000-8000-000000000001","space":"x","name":7,"source":{"kind":"feed","address":"[odd \"quoted\" ]"}}"#.utf8)

        let loaded = try #require(LiveFile.read(joined([try good("one"), bad, try good("two")]), retiredKinds: []))

        #expect(loaded.kept.map(\.name) == ["one", "two"])
        #expect(loaded.foreign == [bad])
        #expect(loaded.foreignIDs == [UUID(uuidString: "6B1F7A5E-0000-4000-8000-000000000001")!])
    }

    @Test func anUnknownKindIsKeptThroughALoadAndASave() throws {
        let newer = Data(#"{"id":"6B1F7A5E-0000-4000-8000-000000000002","space":"6B1F7A5E-0000-4000-8000-000000000003","name":"Merge requests","source":{"kind":"gitlab","address":"https://gitlab.example/x"},"items":[]}"#.utf8)
        let first = try #require(LiveFile.read(joined([try good("one"), newer]), retiredKinds: []))

        let written = try #require(LiveFile.written(first.kept, foreign: first.foreign))
        let again = try #require(LiveFile.read(written, retiredKinds: []))

        #expect(again.kept == first.kept)
        #expect(again.foreign == [newer])
        #expect(try JSONSerialization.jsonObject(with: written) is [Any])
    }

    @Test func aRetiredKindStillLeaves() throws {
        let retired = Data(#"{"id":"6B1F7A5E-0000-4000-8000-000000000004","source":{"kind":"actions"}}"#.utf8)

        let loaded = try #require(LiveFile.read(joined([retired]), retiredKinds: LiveFolders.retiredKinds))

        #expect(loaded.retired == [UUID(uuidString: "6B1F7A5E-0000-4000-8000-000000000004")!])
        #expect(loaded.foreign.isEmpty)
    }

    @Test func aFileThatIsNotAListIsUnreadable() {
        #expect(LiveFile.read(Data("{\"folders\":[]}".utf8), retiredKinds: []) == nil)
        #expect(LiveFile.read(Data("[{\"id\":1},".utf8), retiredKinds: []) == nil)
        #expect(LiveFile.read(Data("garbage".utf8), retiredKinds: []) == nil)
        #expect(LiveFile.read(Data(" [ ] ".utf8), retiredKinds: [])?.kept == [])
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LiveFileLostTests {
    private var browser: Browser!

    init() async throws {
        keepSetting(Shared.prefs, \.liveFolders, "live.on")
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.liveFolders = true
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
    }

    private func tearDown() async {
        LiveFolders.shared.lost = false
        LiveFolders.shared.foreignIDs = []
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    private func filled() -> LiveFolder {
        let made = LiveFolders.shared.add(name: "News", source: LiveSource(kind: .feed, address: "https://example.com/feed"), space: browser.spaceID)
        LiveFolders.shared.apply(.items([LiveItem(key: "https://example.com/1", title: "One"), LiveItem(key: "https://example.com/2", title: "Two")], nil),
                                 to: made.id)
        browser.syncLive()
        return made
    }

    @Test func anUnreadableFileLeavesTheTabsAsAnOrdinaryFolder() {
        let made = filled()
        let tabs = browser.tabs(in: made.id)
        LiveFolders.shared.lost = true

        LiveFolders.shared.remove(made.id)
        browser.syncLive()

        let group = browser.tabGroups.first { $0.id == made.id }
        #expect(group?.live == false)
        #expect(browser.tabs(in: made.id).map(\.id) == tabs.map(\.id))
        #expect(tabs.allSatisfy { $0.liveKey == nil })
        #expect(browser.recentlyClosed.isEmpty)
        #expect(LiveFolders.lostWords == "Your live folders couldn't be loaded. Their tabs were kept as ordinary folders.")
    }

    @Test func aFolderThisBuildCannotReadKeepsItsTabsUntouched() {
        let made = filled()
        let tabs = browser.tabs(in: made.id)
        LiveFolders.shared.foreignIDs = [made.id]

        LiveFolders.shared.remove(made.id)
        browser.syncLive()

        #expect(browser.tabGroups.first { $0.id == made.id }?.live == true)
        #expect(browser.tabs(in: made.id).map(\.id) == tabs.map(\.id))
        #expect(tabs.allSatisfy { $0.liveKey != nil })
    }
}
