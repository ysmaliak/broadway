import Foundation
import Testing
@testable import Search

@MainActor
struct LiveLimitTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pulls(_ range: ClosedRange<Int>, list: PullList) -> [LiveItem] {
        range.map { LiveItem(key: "https://github.com/acme/rocket/pull/\($0)", title: "Pull \($0)", list: list) }
    }

    private func linear(_ issues: [[String: Any]], field: String = "assignedIssues", more: Bool = false, cursor: String? = nil) throws -> Data {
        let info: [String: Any] = ["hasNextPage": more, "endCursor": cursor as Any]
        return try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["id": "me", field: ["nodes": issues, "pageInfo": info]]]])
    }

    private func issue(_ id: String) -> [String: Any] {
        ["identifier": id, "title": id, "url": "https://linear.app/acme/issue/\(id)/x", "updatedAt": "2027-01-15T08:00:00.000Z",
         "state": ["name": "Todo", "type": "unstarted", "position": 1]]
    }

    @Test func aPageWithMoreBehindItSaysSoAsItsLastRow() {
        let folder = LiveFolder(space: UUID(), name: "PRs", source: .pullRequests)
        var read = LiveRead(items: pulls(1...3, list: .created), marked: true)
        read.more = "https://github.com/pulls?page=2"

        let next = LiveTrust.after(folder, .read(read), now: now)
        let plain = LiveTrust.after(next, .read(LiveRead(items: pulls(1...3, list: .created), marked: true)), now: now)

        #expect(next.more == "https://github.com/pulls?page=2")
        #expect(LiveMoreView.words(next) == "More on GitHub")
        #expect(plain.more == nil)
    }

    @Test func aMergeThatCutsRowsSaysThereIsMore() {
        let folder = LiveFolder(space: UUID(), name: "Feed", source: LiveSource(kind: .feed, address: "https://example.com/feed"))
        let many = (1...40).map { LiveItem(key: "https://example.com/\($0)", title: "\($0)") }

        let next = LiveTrust.after(folder, .items(many, nil), now: now)

        #expect(next.items.count == folder.source.cap)
        #expect(next.more == "https://example.com/feed")
    }

    @Test func listsShareTheLimitInTurn() {
        let answers: [(PullList, [LiveItem])] = [(.reviewRequests, pulls(1...20, list: .reviewRequests)),
                                                 (.created, pulls(101...120, list: .created))]

        let shared = PullList.shared(answers, cap: 30)

        #expect(shared.answers[0].1.count == 15)
        #expect(shared.answers[1].1.count == 15)
        #expect(shared.cut == [.reviewRequests, .created])
        #expect(PullList.shared([(.created, pulls(1...5, list: .created))], cap: 30).cut.isEmpty)
    }

    @Test func aRowOnTwoListsCountsOnceTowardsTheLimit() {
        let both = pulls(1...10, list: .reviewRequests)

        let shared = PullList.shared([(.reviewRequests, both), (.created, both)], cap: 10)

        #expect(shared.cut.isEmpty)
    }

    @Test func todayStartsAtMidnightWhereThePersonIs() {
        let kazakh = TimeZone(identifier: "Asia/Almaty")!
        let pacific = TimeZone(identifier: "America/Los_Angeles")!
        let moment = ISO8601DateFormatter().date(from: "2027-01-15T02:30:00Z")!

        #expect(LiveSource.since(1, now: moment, zone: kazakh) == "2027-01-15T00:00:00+05:00")
        #expect(LiveSource.since(1, now: moment, zone: pacific) == "2027-01-14T00:00:00-08:00")
        #expect(LiveSource.since(7, now: moment, zone: kazakh) == "2027-01-09T00:00:00+05:00")
        let source = LiveSource(kind: .repository, address: "https://github.com/a/b/pulls", range: .today)
        #expect(source.reading(at: moment, zone: pacific)?.absoluteString
            == "https://github.com/a/b/pulls?q=is%3Apr+is%3Aopen+updated%3A%3E%3D2027-01-14T00%3A00%3A00-08%3A00")
    }

    @Test func aLinearListSaysWhenThereIsMore() throws {
        let page = try #require(LinearAPI.page(from: try linear([issue("A-1")], more: true, cursor: "c1"), list: .assigned))

        #expect(page.more)
        #expect(page.cursor == "c1")
        #expect(String(decoding: LinearAPI.body(for: .assigned), as: UTF8.self).contains("pageInfo { hasNextPage endCursor }"))
        #expect(String(decoding: LinearAPI.body(for: .inbox, after: "c1"), as: UTF8.self).contains(#""after":"c1""#))
    }

    @Test func aTeamNotFoundIsAFailedReadAndACycleNotRunningIsSaid() throws {
        let none = try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["id": "me"], "teams": ["nodes": []]]])
        let idle = try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["id": "me"], "teams": ["nodes": [["id": "t", "activeCycle": NSNull()]]]]])

        #expect(LinearAPI.page(from: none, list: .cycle("ENG")) == nil)
        let page = try #require(LinearAPI.page(from: idle, list: .cycle("ENG")))
        #expect(page.noCycle && page.items.isEmpty)
        var folder = LiveFolder(space: UUID(), name: "Cycle", source: LiveSource(kind: .linear, address: "https://linear.app/acme/team/ENG/cycle/current"))
        folder = LiveTrust.after(folder, .read(LiveRead(items: [], marked: true, noCycle: true)), now: now)
        #expect(folder.state == .fine)
        #expect(folder.emptyWording == "No active cycle")
    }
}
