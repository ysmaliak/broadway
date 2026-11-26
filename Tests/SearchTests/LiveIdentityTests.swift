import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LiveIdentityTests {
    private var browser: Browser!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

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
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    @Test func oneThingHasOneIdentityHoweverItsAddressIsWritten() {
        let pairs = [
            ("https://linear.app/acme/issue/ROC-12/teach-the-rocket", "https://linear.app/acme/issue/roc-12/count-the-stars"),
            ("https://github.com/Acme/Rocket/pull/7", "https://github.com/acme/rocket/pull/7/"),
            ("https://www.youtube.com/watch?v=abc123&t=42s", "https://youtu.be/abc123"),
            ("https://example.com/post/1/", "https://example.com/post/1#comments"),
            ("https://www.example.com/post/1?utm_source=feed&utm_medium=rss", "https://example.com/post/1"),
            ("https://Example.com/post/1?fbclid=x9", "https://example.com/post/1"),
        ]

        for (one, other) in pairs { #expect(LiveIdentity.of(one) == LiveIdentity.of(other), "\(one) and \(other)") }
        #expect(LiveIdentity.of("https://example.com/post/1?page=2") != LiveIdentity.of("https://example.com/post/1"))
        #expect(LiveIdentity.of("https://github.com/acme/rocket/pull/7") == "github:acme/rocket#7")
        #expect(LiveIdentity.of("https://linear.app/acme/issue/ROC-12/x") == "linear:ROC-12")
    }

    @Test func anIdentityOfAnIdentityIsTheSame() {
        let keys = ["https://github.com/acme/rocket/issues/9", "https://linear.app/acme/issue/ROC-1/a", "https://youtu.be/abc",
                    "https://example.com/a/b/?utm_campaign=x&keep=1#top", "https://example.com/", "old", "file:///tmp/feed.xml",
                    "https://example.com/caf%C3%A9?q=a%20b"]

        for key in keys { #expect(LiveIdentity.of(LiveIdentity.of(key)) == LiveIdentity.of(key), "\(key)") }
    }

    @Test func aRetitledIssueStaysOneRowAndKeepsWhatItKnew() {
        var folder = LiveFolder(space: UUID(), name: "Issues", source: .linear(.assigned))
        let opened = now.addingTimeInterval(-600)
        folder.items = [LiveItem(key: "https://linear.app/acme/issue/ROC-12/old-title", title: "Old title", opened: opened,
                                 arrived: now.addingTimeInterval(-900), activity: now.addingTimeInterval(-700),
                                 noticed: now.addingTimeInterval(-700))]
        folder.state = .fine
        folder.noticing = true

        let next = LiveMerge.merged(folder, fetched: [LiveItem(key: "https://linear.app/acme/issue/ROC-12/new-title", title: "New title",
                                                               activity: now.addingTimeInterval(-700))], now: now)

        #expect(next.items.count == 1)
        #expect(next.items.first?.key == "https://linear.app/acme/issue/ROC-12/new-title")
        #expect(next.items.first?.opened == opened)
        #expect(next.items.first?.arrived == now.addingTimeInterval(-900))
        #expect(next.items.first?.noticed == now.addingTimeInterval(-700))
    }

    @Test func aRetitledIssueKeepsItsTab() {
        let made = LiveFolders.shared.add(name: "Issues", source: .linear(.assigned), space: browser.spaceID)
        LiveFolders.shared.apply(.items([LiveItem(key: "https://linear.app/acme/issue/ROC-12/old-title", title: "Old")], nil), to: made.id)
        browser.syncLive()
        let tab = browser.tabs(in: made.id).first

        LiveFolders.shared.apply(.items([LiveItem(key: "https://linear.app/acme/issue/ROC-12/new-title", title: "New")], nil), to: made.id)
        browser.syncLive()

        #expect(browser.tabs(in: made.id).count == 1)
        #expect(browser.tabs(in: made.id).first === tab)
        #expect(tab?.liveKey == "https://linear.app/acme/issue/ROC-12/new-title")
        #expect(browser.recentlyClosed.isEmpty)
    }

    @Test func pageKnowledgeIsKeptForEachSpaceApart() {
        let key = "https://github.com/acme/rocket/pull/7"
        let work = UUID()
        let home = UUID()
        LiveRefs.known = [:]

        LiveRefs.known[LiveRefs.slot(key, space: work)] = LiveRefs.Known(updated: nil, branch: nil, read: now, state: .merged)

        #expect(LiveRefs.known[LiveRefs.slot("https://github.com/Acme/rocket/pull/7/files", space: work)]?.state == .merged)
        #expect(LiveRefs.known[LiveRefs.slot(key, space: home)] == nil)
        #expect(LiveRefs.identity(of: LiveRefs.slot(key, space: work)) == "github:acme/rocket#7")
        LiveRefs.known = [:]
    }
}
