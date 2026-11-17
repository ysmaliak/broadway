import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PullStackRefreshTests {
    private actor Hub {
        struct Pull {
            var base: String
            var head: String
            var stack: (number: Int, position: Int)?
        }

        var pulls: [Int: Pull] = [:]
        var down: Set<Int> = []
        var delay: Duration = .zero
        var asked: [Int] = []

        func set(_ number: Int, base: String, head: String, stack: (Int, Int)? = nil) {
            pulls[number] = Pull(base: base, head: head, stack: stack)
        }

        func fail(_ numbers: Set<Int>) { down = numbers }
        func slow(_ by: Duration) { delay = by }
        func count(_ number: Int) -> Int { asked.filter { $0 == number }.count }

        func answer(_ url: URL) async -> (Data, Int)? {
            guard let number = Int(url.lastPathComponent) else { return nil }
            asked.append(number)
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !down.contains(number), let pull = pulls[number] else { return nil }
            let stack = pull.stack.map { #"{"number":\#($0.number),"position":\#($0.position)}"# } ?? "null"
            let blob = #"{"payload":{"pullRequest":{"baseBranch":"\#(pull.base)","headBranch":"\#(pull.head)","#
                + #""headRepositoryName":"comet","headRepositoryOwnerLogin":"zenith","number":\#(number),"state":"OPEN"},"stack":\#(stack)}}"#
            let html = "<!doctype html><html><body><meta name=\"user-login\" content=\"pat-kit\">"
                + "<div id=\"discussion-timeline-actions\"></div>"
                + "<script type=\"application/json\" data-target=\"react-app.embeddedData\">\(blob)</script></body></html>"
            return (Data(html.utf8), 200)
        }
    }

    private let start = Date(timeIntervalSince1970: 1_793_500_000)
    private let updated = Date(timeIntervalSince1970: 1_793_400_000)

    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    private func pull(_ number: Int) -> LiveItem {
        LiveItem(key: "https://github.com/zenith/comet/pull/\(number)", title: "Change \(number)", updated: updated)
    }

    private func fetch(_ hub: Hub) -> @Sendable (URL) async -> (Data, Int)? {
        { url in await hub.answer(url) }
    }

    private func fill(_ numbers: [Int], previous: [LiveItem], at minutes: Double, hub: Hub, again: Set<String> = [],
                      budget: TimeInterval = LiveRefs.budget) async -> [LiveItem] {
        await LiveRefs.filled(numbers.map(pull), previous: previous, at: at(minutes), budget: budget, again: again, fetch: fetch(hub))
    }

    private func chips(_ items: [LiveItem]) -> [String: String] {
        var out: [String: String] = [:]
        for item in LiveStacks.arranged(items) {
            out[URL(string: item.key)!.lastPathComponent] = item.stack?.said ?? "-"
        }
        return out
    }

    private func sixAndOneMore(_ hub: Hub) async {
        await hub.set(101, base: "main", head: "orbit-1", stack: (21, 1))
        for number in 102...106 {
            await hub.set(number, base: "orbit-\(number - 101)", head: "orbit-\(number - 100)", stack: (21, number - 100))
        }
        await hub.set(107, base: "orbit-6", head: "orbit-7")
    }

    private let seven = Array(101...107)

    @Test func aRowThatJoinsAStackWithItsTimeUnchangedIsReadAgainWhileRunning() async {
        LiveRefs.known = [:]
        let hub = Hub()
        await sixAndOneMore(hub)

        let first = await fill(seven, previous: [], at: 0, hub: hub)
        await hub.set(107, base: "orbit-6", head: "orbit-7", stack: (21, 7))
        let soon = await fill(seven, previous: first, at: 5, hub: hub)
        let later = await fill(seven, previous: soon, at: 11, hub: hub)
        let after = await fill(seven, previous: later, at: 16, hub: hub)

        #expect(chips(first)["101"] == "1/6")
        #expect(chips(first)["107"] == "-")
        #expect(chips(soon)["107"] == "-")
        #expect(chips(later) == ["101": "1/7", "102": "2/7", "103": "3/7", "104": "4/7", "105": "5/7", "106": "6/7", "107": "7/7"])
        #expect(chips(after) == chips(later))
        #expect(await hub.asked.count == 14)
        for number in seven { #expect(await hub.count(number) == 2) }
    }

    @Test func aRowThatJoinedIsReadAgainAfterARelaunch() async {
        LiveRefs.known = [:]
        let hub = Hub()
        await sixAndOneMore(hub)
        let first = await fill(seven, previous: [], at: 0, hub: hub)
        await hub.set(107, base: "orbit-6", head: "orbit-7", stack: (21, 7))
        LiveRefs.known = [:]

        let launched = await fill(seven, previous: first, at: 11, hub: hub)

        #expect(first.allSatisfy { $0.signsRead == true && $0.pageRead == at(0) })
        #expect(chips(launched) == ["101": "1/7", "102": "2/7", "103": "3/7", "104": "4/7", "105": "5/7", "106": "6/7", "107": "7/7"])
        #expect(await hub.count(107) == 2)
        #expect(await hub.count(106) == 2)
        #expect(await hub.asked.count == 14)
    }

    @Test func theReportedKeptRowWithNoReadTimeIsReadAtLaunch() async {
        LiveRefs.known = [:]
        let hub = Hub()
        await sixAndOneMore(hub)
        var first = await fill(seven, previous: [], at: 0, hub: hub)
        await hub.set(107, base: "orbit-6", head: "orbit-7", stack: (21, 7))
        LiveRefs.known = [:]
        first[6].pageRead = nil

        let launched = await fill(seven, previous: first, at: 1, hub: hub)

        #expect(chips(launched)["107"] == "7/7")
        #expect(chips(launched)["101"] == "1/7")
        #expect(await hub.count(107) == 2)
    }

    @Test func aBranchChainThatIsNotAStackIsReadOncePerTenMinutes() async {
        LiveRefs.known = [:]
        let hub = Hub()
        await hub.set(201, base: "main", head: "trail-1")
        await hub.set(202, base: "trail-1", head: "trail-2")
        await hub.set(203, base: "main", head: "lone")

        var items: [LiveItem] = []
        for minutes in stride(from: 0.0, through: 25, by: 5) {
            items = await fill([201, 202, 203], previous: items, at: minutes, hub: hub)
        }

        #expect(await hub.count(201) == 3)
        #expect(await hub.count(202) == 3)
        #expect(await hub.count(203) == 1)
        #expect(chips(items) == ["201": "-", "202": "-", "203": "-"])
    }

    @Test func theAgeLimitReadsAnOldReadingAgainAndLeavesAYoungOne() async {
        LiveRefs.known = [:]
        let hub = Hub()
        await hub.set(301, base: "main", head: "kite")
        await hub.set(302, base: "main", head: "sail")

        let first = await fill([301], previous: [], at: 0, hub: hub)
        let second = await fill([301, 302], previous: first, at: 20, hub: hub)
        let third = await fill([301, 302], previous: second, at: 31, hub: hub)
        LiveRefs.known = [:]
        _ = await fill([301, 302], previous: third, at: 45, hub: hub)

        #expect(await hub.count(301) == 2)
        #expect(await hub.count(302) == 1)
        #expect(third.first?.pageRead == at(31))
        #expect(third.last?.pageRead == at(20))
        let fifty = await fill([301, 302], previous: third, at: 51, hub: hub)
        #expect(await hub.count(302) == 2)
        #expect(fifty.last?.pageRead == at(51))
    }

    @Test func aChangedReadingQueuesTheOtherMembers() async {
        LiveRefs.known = [:]
        let hub = Hub()
        await hub.set(401, base: "main", head: "reed-1", stack: (31, 1))
        await hub.set(402, base: "main", head: "reed-2", stack: (31, 2))
        await hub.set(403, base: "main", head: "reed-3", stack: (31, 3))
        await hub.set(404, base: "main", head: "apart")
        let numbers = [401, 402, 403, 404]
        let first = await fill(numbers, previous: [], at: 0, hub: hub)
        await hub.set(402, base: "main", head: "reed-2", stack: (31, 3))
        await hub.set(403, base: "main", head: "reed-3", stack: (31, 2))

        let shown = await fill(numbers, previous: first, at: 2, hub: hub, again: [LiveIdentity.of(pull(402).key)])

        #expect(await hub.count(401) == 2)
        #expect(await hub.count(402) == 2)
        #expect(await hub.count(403) == 2)
        #expect(await hub.count(404) == 1)
        #expect(LiveStacks.arranged(shown).map { URL(string: $0.key)!.lastPathComponent } == ["402", "403", "401", "404"])
        #expect(chips(shown) == ["401": "1/3", "402": "3/3", "403": "2/3", "404": "-"])
    }

    @Test func membersThatMissTheBudgetStayDue() async {
        LiveRefs.known = [:]
        let hub = Hub()
        await hub.set(401, base: "main", head: "reed-1", stack: (31, 1))
        await hub.set(402, base: "main", head: "reed-2", stack: (31, 2))
        await hub.set(403, base: "main", head: "reed-3", stack: (31, 3))
        let numbers = [401, 402, 403]
        let first = await fill(numbers, previous: [], at: 0, hub: hub)
        await hub.set(402, base: "main", head: "reed-2", stack: (31, 3))
        await hub.set(403, base: "main", head: "reed-3", stack: (31, 2))
        await hub.slow(.milliseconds(400))

        let rushed = await fill(numbers, previous: first, at: 2, hub: hub, again: [LiveIdentity.of(pull(402).key)], budget: 0.5)
        await hub.slow(.zero)
        let next = await fill(numbers, previous: rushed, at: 3, hub: hub)

        let asked = await hub.asked
        #expect(rushed.first?.pageRead == nil)
        #expect(asked.count == 9, "\(asked)")
        #expect(Set(asked.prefix(3)) == [401, 402, 403], "\(asked)")
        #expect(asked.dropFirst(3).first == 402, "\(asked)")
        #expect(Set(asked.dropFirst(4).prefix(2)) == [401, 403], "\(asked)")
        #expect(Set(asked.suffix(3)) == [401, 402, 403], "\(asked)")
        #expect(chips(next) == ["401": "1/3", "402": "3/3", "403": "2/3"])
        let settled = await hub.asked.count
        _ = await fill(numbers, previous: next, at: 4, hub: hub)
        #expect(await hub.asked.count == settled)
    }

    @Test func aRowThatLooksWrongIsReadBeforeTheRestWhenTheBudgetIsShort() async {
        LiveRefs.known = [:]
        let hub = Hub()
        for number in 601...606 { await hub.set(number, base: "main", head: "lone-\(number)") }
        await hub.set(607, base: "main", head: "tide-1", stack: (51, 1))
        await hub.set(608, base: "tide-1", head: "tide-2", stack: (51, 2))
        await hub.set(609, base: "tide-2", head: "tide-3")
        let numbers = Array(601...609)
        var kept = await fill(numbers, previous: [], at: 0, hub: hub)
        for index in kept.indices { kept[index].pageRead = nil }
        LiveRefs.known = [:]
        await hub.set(609, base: "tide-2", head: "tide-3", stack: (51, 3))
        await hub.slow(.milliseconds(400))
        let before = await hub.asked.count

        let rushed = await fill(numbers, previous: kept, at: 1, hub: hub, budget: 0.7)

        let asked = Array(await hub.asked.dropFirst(before))
        #expect(Set(asked.prefix(4)).isSuperset(of: [608, 609]), "\(asked)")
        #expect(chips(rushed)["609"] == "3/3")
        #expect(chips(rushed)["608"] == "2/3")
        #expect(chips(rushed)["607"] == "1/3")
        #expect(rushed.contains { $0.pageRead == nil })
    }

    @Test func aRowWhosePageWasShownIsReadFirst() async {
        LiveRefs.known = [:]
        let hub = Hub()
        for number in 701...709 { await hub.set(number, base: "main", head: "isle-\(number)") }
        let numbers = Array(701...709)
        var kept = await fill(numbers, previous: [], at: 0, hub: hub)
        for index in kept.indices { kept[index].pageRead = nil }
        LiveRefs.known = [:]
        await hub.slow(.milliseconds(400))
        let before = await hub.asked.count

        _ = await fill(numbers, previous: kept, at: 1, hub: hub, again: [LiveIdentity.of(pull(709).key)], budget: 0.7)

        let asked = Array(await hub.asked.dropFirst(before))
        #expect(asked.prefix(4).contains(709), "\(asked)")
    }

    @Test func whenAPassHasNoTimeForAllTheOldestReadingGoesFirstSoNoRowIsLeftOut() async {
        LiveRefs.known = [:]
        let hub = Hub()
        for number in 801...809 { await hub.set(number, base: "main", head: "cove-\(number)") }
        let numbers = Array(801...809)
        var rows = await fill(numbers, previous: [], at: 0, hub: hub)
        await hub.slow(.milliseconds(400))

        for minutes in [31.0, 51, 71] {
            rows = await fill(numbers, previous: rows, at: minutes, hub: hub, budget: 0.7)
        }

        for row in rows {
            #expect((row.pageRead ?? .distantPast) >= at(31), "\(row.key)")
        }
    }

    @Test func aFailedFetchKeepsTheOldReadingAndIsTriedAgain() async {
        LiveRefs.known = [:]
        let hub = Hub()
        await hub.set(501, base: "main", head: "dune-1", stack: (41, 1))
        await hub.set(502, base: "main", head: "dune-2", stack: (41, 2))
        let numbers = [501, 502]
        let first = await fill(numbers, previous: [], at: 0, hub: hub)
        await hub.fail([501, 502])

        let failed = await fill(numbers, previous: first, at: 31, hub: hub)
        LiveRefs.known = [:]
        let relaunched = await fill(numbers, previous: failed, at: 32, hub: hub)
        await hub.fail([])
        let back = await fill(numbers, previous: relaunched, at: 33, hub: hub)

        #expect(chips(failed) == ["501": "1/2", "502": "2/2"])
        #expect(failed.first?.pageRead == at(0))
        #expect(chips(relaunched) == ["501": "1/2", "502": "2/2"])
        #expect(relaunched.first?.pageRead == at(0))
        #expect(back.first?.pageRead == at(33))
        #expect(await hub.count(501) == 4)
        #expect(await hub.count(502) == 4)
    }

    @Test func aKeptFileWithoutTheReadTimeDecodesAndIsDue() async throws {
        LiveRefs.known = [:]
        let hub = Hub()
        await hub.set(601, base: "main", head: "mesa")
        var row = pull(601)
        row.branch = LiveBranch(repository: "zenith/comet", base: "main", head: "mesa", stackRead: true)
        row.signsRead = true
        row.pageRead = at(0)
        var folder = LiveFolder(space: UUID(), name: "Pull requests", source: .pullRequests)
        folder.items = [row]
        let encoded = try JSONEncoder().encode([folder])
        var saved = try #require(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        var items = try #require(saved[0]["items"] as? [[String: Any]])
        #expect(items[0]["pageRead"] != nil)
        items[0]["pageRead"] = nil
        saved[0]["items"] = items
        let old = try JSONSerialization.data(withJSONObject: saved)

        let kept = try #require(LiveFolders.sorted(old)?.kept.first?.items.first)
        let filled = await fill([601], previous: [kept], at: 1, hub: hub)

        #expect(kept.pageRead == nil)
        #expect(kept.branch == row.branch)
        #expect(await hub.count(601) == 1)
        #expect(filled.first?.pageRead == at(1))
        LiveRefs.known = [:]
        _ = await fill([601], previous: filled, at: 2, hub: hub)
        #expect(await hub.count(601) == 1)
    }
}
