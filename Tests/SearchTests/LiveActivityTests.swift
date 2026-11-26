import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LiveActivityTests {
    private var browser: Browser!
    private let pull = "https://github.com/acme/rocket/pull/412"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    init() async throws {
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

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("IntegrationFixtures/\(name).json"))
    }

    private func date(_ text: String) -> Date { GitHubAPI.date(text)! }

    private func item(_ key: String, _ activity: Date?) -> LiveItem {
        LiveItem(key: key, title: key, activity: activity)
    }

    private func reviews(space: UUID) -> LiveFolder {
        LiveFolders.shared.add(name: "Pull Requests", source: .reviewRequests, space: space)
    }

    private func current(_ id: UUID, _ key: String) -> LiveItem? {
        LiveFolders.shared.folder(id)?.items.first { $0.key == key }
    }

    @Test func linearSkipsYourOwnAndUnknownActors() throws {
        let linear = try #require(LinearAPI.items(from: try fixture("linear-assigned"), list: .assigned))

        #expect(linear.map(\.activity) == [date("2026-11-03T21:30:00Z"), nil])
        #expect(String(decoding: LinearAPI.body(for: .assigned), as: UTF8.self).contains("viewer { id assignedIssues"))
    }

    @Test func nothingLightsAtTheFirstReadAndNewActivityLightsLater() {
        let made = reviews(space: browser.spaceID)
        LiveFolders.shared.apply(.items([item(pull, start)], nil), to: made.id, now: start)

        let first = current(made.id, pull)
        LiveFolders.shared.apply(.items([item(pull, start.addingTimeInterval(60)), item("https://github.com/acme/rocket/pull/500", start)], nil),
                                 to: made.id, now: start.addingTimeInterval(300))

        #expect(first?.fresh == false)
        #expect(current(made.id, pull)?.fresh == true)
        #expect(current(made.id, "https://github.com/acme/rocket/pull/500")?.fresh == true)
        #expect(LiveFolders.shared.folder(made.id)?.freshCount == 2)
    }

    @Test func aFolderReadBeforeThisBuildStartsQuiet() {
        var folder = LiveFolder(space: UUID(), name: "Pull Requests", source: LiveSource(kind: .repository, address: "https://github.com/pulls"))
        folder.state = .fine
        folder.items = [LiveItem(key: pull, title: "Retry")]

        let next = LiveMerge.merged(folder, fetched: [item(pull, start), item("https://github.com/acme/rocket/pull/1", start)], now: start)
        let later = LiveMerge.merged(next, fetched: [item(pull, start), item("https://github.com/acme/rocket/pull/1", start)], now: start)

        #expect(next.noticing == true)
        #expect(!next.items.contains { $0.fresh })
        #expect(!later.items.contains { $0.fresh })
    }

    @Test func openingTheRowClearsItInThisSpaceOnly() throws {
        let here = reviews(space: browser.spaceID)
        let there = reviews(space: UUID())
        for id in [here.id, there.id] {
            LiveFolders.shared.apply(.items([item(pull, start)], nil), to: id, now: start)
            LiveFolders.shared.apply(.items([item(pull, start.addingTimeInterval(60))], nil), to: id, now: start.addingTimeInterval(300))
        }
        browser.syncLive()
        let tab = try #require(browser.tabs(in: here.id).first)
        #expect(tab.liveItem?.fresh == true)

        browser.select(tab)
        browser.syncLive()

        #expect(current(here.id, pull)?.fresh == false)
        #expect(tab.liveItem?.fresh == false)
        #expect(current(there.id, pull)?.fresh == true)
        LiveFolders.shared.apply(.items([item(pull, start.addingTimeInterval(600))], nil), to: here.id, now: start.addingTimeInterval(900))
        #expect(current(here.id, pull)?.fresh == true)
    }

    @Test func landingOnThePageInAnyTabClearsIt() throws {
        let linear = "https://linear.app/acme/issue/ENG-231/rate-limit-the-export-endpoint"
        let made = reviews(space: browser.spaceID)
        let keys = [pull, linear, "https://github.com/acme/rocket/pull/41"]
        LiveFolders.shared.apply(.items(keys.map { item($0, start) }, nil), to: made.id, now: start)
        LiveFolders.shared.apply(.items(keys.map { item($0, start.addingTimeInterval(60)) }, nil), to: made.id, now: start.addingTimeInterval(300))

        LiveFolders.shared.landed(try #require(URL(string: "https://github.com/acme/rocket/pull/412/files#r99")), space: browser.spaceID)
        LiveFolders.shared.landed(try #require(URL(string: "https://linear.app/acme/issue/eng-231")), space: browser.spaceID)
        LiveFolders.shared.landed(try #require(URL(string: "https://github.com/acme/rocket/pull/4")), space: UUID())

        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.fresh) == [false, false, true])
        #expect(LiveSeen.same(URL(string: "https://www.github.com/acme/rocket/pull/412?w=1")!, as: pull))
        #expect(LiveSeen.same(URL(string: "https://github.com/Acme/Rocket/pull/412")!, as: pull))
        #expect(!LiveSeen.same(URL(string: "https://github.com/acme/rocket/pull/4120")!, as: pull))
        #expect(!LiveSeen.same(URL(string: "https://github.com/acme/rocket/pull")!, as: pull))
        #expect(!LiveSeen.same(URL(string: "https://evil.example/acme/rocket/pull/412")!, as: pull))
        #expect(!LiveSeen.same(URL(string: "https://linear.app/acme/issue/ENG-23")!, as: linear))
    }
}
