import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PullRowTests {
    private func scanned(_ links: [[String: Any]]) throws -> String {
        let scan: [String: Any] = ["links": links, "password": false, "href": "https://github.com/pulls", "user": "octo-sam", "pending": 0]
        return String(decoding: try JSONSerialization.data(withJSONObject: scan), as: UTF8.self)
    }

    private func link(_ number: Int, title: String, author: String, said: String, draft: Bool = false,
                      checks: String? = nil) -> [String: Any] {
        ["url": "https://github.com/acme/rocket/pull/\(number)", "title": title, "row": "\(title) \(said)", "said": said,
         "failing": checks == "failing", "author": author, "checks": checks as Any, "draft": draft, "merged": false, "closed": false]
    }

    @Test func theSignedInPageGivesAuthorDraftAndReviewState() throws {
        let json = try scanned([
            link(41, title: "Cache the build graph", author: "dana", said: "#41 · dana opened 2 days ago · Changes requested", checks: "failing"),
            link(38, title: "Audio: upload", author: "octo-sam", said: "#38 · octo-sam opened yesterday · Review required", draft: true),
            link(44, title: "Bump Swift", author: "lee", said: "#44 · lee opened today · Approved", checks: "passing"),
        ])

        let items = try #require(LiveReader.items(scanned: json, pulls: true))

        #expect(items.map(\.byline) == ["dana • Changes requested", "octo-sam • Draft", "lee • Approved"])
        #expect(items.map(\.draft) == [nil, true, nil])
        #expect(items.map(\.checks) == [.failing, nil, .passing])
    }

    @Test func aWordInTheTitleIsNotTheState() throws {
        let json = try scanned([link(7, title: "Draft the approved release notes", author: "dana", said: "#7 · dana opened today")])

        let items = try #require(LiveReader.items(scanned: json, pulls: true))

        #expect(items.first?.label == nil)
        #expect(items.first?.byline == "dana")
    }

    @Test func aDraftIconIsDraftEvenWhenAMorePressingStateWins() {
        #expect(LiveLabels.pullRequest(row: "#3 · lee opened today", draft: true) == "Draft")
        #expect(LiveLabels.pullRequest(row: "#3 · lee opened today · Changes requested", draft: true) == "Changes requested")
        #expect(LiveLabels.pullRequest(row: "#3 · Approved", merged: true) == "Merged")
        #expect(LiveLabels.pullRequest(row: "#3", closed: true) == "Closed")
    }

    @Test func aMergedDraftIsNotDimmed() throws {
        var merged = link(9, title: "Old work", author: "lee", said: "#9", draft: true)
        merged["merged"] = true

        let items = try #require(LiveReader.items(scanned: try scanned([merged]), pulls: true))

        #expect(items.first?.draft == nil)
        #expect(items.first?.label == "Merged")
    }

    @Test func aStackRunHoldsOnlyNeighboursOfOneStack() {
        func item(_ position: Int?, of count: Int = 3, in repository: String = "acme/rocket") -> LiveItem {
            LiveItem(key: UUID().uuidString, title: "PR", stack: position.map { LiveStack(position: $0, count: count) },
                     branch: LiveBranch(repository: repository, base: "b", head: "h"))
        }
        let items = [item(nil), item(3), item(2), item(1), item(2, of: 2, in: "acme/site"), item(1, of: 2, in: "acme/site"), item(nil)]

        let tops = LiveStackRuns.tops(items)

        #expect(tops == [nil, 1, 1, 1, 4, 4, nil])
    }

    @Test func aStackWithAMissingMiddleDoesNotBridgeTheGap() {
        let items = [3, 1].map { LiveItem(key: "\($0)", title: "PR", stack: LiveStack(position: $0, count: 3)) }

        let tops = LiveStackRuns.tops(items)

        #expect(tops == [nil, nil])
    }

    @Test func twoLinesFitInANormalRow() {
        let line = NSFont.systemFont(ofSize: Metrics.liveLine)

        let needed = SideLook.titleLine + SideLook.bylineLine

        #expect(needed <= Metrics.sideRowHeight - 2)
        #expect(ceil(line.ascender - line.descender) <= SideLook.bylineLine + 1)
        #expect(line.pointSize == 11)
    }
}
