import AppKit
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5)))
@MainActor
struct SettingsLiveFoldersTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func trace(_ address: String, count: Int, daysAgo: Double = 1) -> History.Trace {
        let url = URL(string: address)!
        return History.Trace(key: History.identity(for: url), address: address, title: "Page", url: url,
                             last: now.addingTimeInterval(-daysAgo * 86_400), count: count)
    }

    @Test func gitHubIsSuggestedWithItsTwoMostVisitedRepositories() {
        let traces = [
            trace("https://github.com/apple/swift/pull/1", count: 40),
            trace("https://github.com/apple/swift/issues", count: 20),
            trace("https://github.com/org/repo2/pulls", count: 30),
            trace("https://github.com/org/three", count: 5),
            trace("https://github.com/notifications", count: 90),
        ]

        let made = LiveSuggestions.from(traces, folders: [], now: now)

        #expect(made.count == 1)
        #expect(made.first?.title == "GitHub Pull Requests")
        #expect(made.first?.name == LiveSource.pullRequestsName)
        #expect(made.first?.source == .pullRequests)
        #expect(made.first?.line == "185 visits · apple/swift · org/repo2")
    }

    @Test func mostVisitedComeFirstAndAtMostFive() {
        let traces = [
            trace("https://linear.app/acme/issue/ACM-1", count: 3),
            trace("https://www.youtube.com/watch?v=1", count: 50),
            trace("https://github.com/a/b", count: 10),
            trace("https://gitlab.com/group/project/-/merge_requests/2", count: 7),
            trace("https://vercel.com/team/site/deployments", count: 6),
            trace("https://example.com/feed.xml", count: 4),
            trace("https://blog.example.org/rss", count: 1),
        ]

        let made = LiveSuggestions.from(traces, folders: [], now: now)

        #expect(made.map(\.title) == ["YouTube Subscriptions", "GitHub Pull Requests", "example.com", "Linear My Issues",
                                      "blog.example.org"])
    }

    @Test func onlyTheLastThirtyDaysCount() {
        let traces = [
            trace("https://github.com/a/b", count: 100, daysAgo: 31),
            trace("https://linear.app/acme/issue/ACM-1", count: 2, daysAgo: 29),
        ]

        let made = LiveSuggestions.from(traces, folders: [], now: now)

        #expect(made.map(\.title) == ["Linear My Issues"])
        #expect(made.first?.line == "2 visits · acme")
    }

    @Test func aSourceThatAlreadyHasAFolderIsNotSuggested() {
        let space = UUID()
        let folders = [
            LiveFolder(space: space, name: "PRs", source: .reviewRequests),
            LiveFolder(space: space, name: "example.com", source: LiveSource(kind: .feed, address: "https://example.com/")),
        ]
        let traces = [
            trace("https://github.com/a/b", count: 10),
            trace("https://example.com/feed.xml", count: 4),
            trace("https://www.youtube.com/@channel", count: 1),
        ]

        let made = LiveSuggestions.from(traces, folders: folders, now: now)

        #expect(made.map(\.title) == ["YouTube Subscriptions"])
        #expect(made.first?.line == "1 visit · @channel")
    }

    @Test func onlyAddressesThatLookLikeFeedsAreFeeds() {
        let traces = [
            trace("https://news.example.com/article/12", count: 80),
            trace("https://site.example.com/atom.xml", count: 2),
            trace("https://site.example.com/sitemap.xml", count: 9),
            trace("https://pod.example.com/show.rss", count: 3),
        ]

        let made = LiveSuggestions.from(traces, folders: [], now: now)

        #expect(made.map(\.title) == ["pod.example.com", "site.example.com"])
        #expect(made.allSatisfy { $0.source.kind == .feed })
        #expect(made.last?.source.address == "https://site.example.com/atom.xml")
    }

    @Test func thePageSitsAfterAIAndOpensAFolder() {
        var trail = SettingsTrail(page: .liveFolders)
        let id = UUID()

        trail.open(.liveFolder, folder: id)
        let opened = trail.folder
        let wentUp = trail.up()

        #expect(SettingsPage.blocks[1] == [.agents, .liveFolders, .passwords, .privacy, .extensions])
        #expect(SettingsPage(rawValue: SettingsPage.liveFolders.rawValue) == .liveFolders)
        #expect(trail.page == .liveFolders)
        #expect(opened == id)
        #expect(wentUp)
        #expect(trail.here == SettingsPlace(page: .liveFolders))
    }

    @Test func findReachesTheLiveFoldersPage() {
        for words in ["live folders", "pull requests", "feeds", "rss", "linear", "youtube"] {
            #expect(SettingsIndex.find(words).contains { $0.page == .liveFolders }, "\(words)")
        }
        #expect(PersonSettings.table["live.folders"] != nil)
        #expect(PersonSettings.table["live.suggestions"] != nil)
    }

    @Test func everySourceSymbolIsASystemSymbol() {
        let kinds: [LiveSource.Kind] = [.feed, .pullRequests, .repository, .issues, .subscriptions, .page, .notifications, .linear]

        let missing = kinds.map { LiveSuggestions.symbol(LiveSource(kind: $0, address: "https://example.com")) }
            .filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }

        #expect(missing.isEmpty, "\(missing)")
    }
}
