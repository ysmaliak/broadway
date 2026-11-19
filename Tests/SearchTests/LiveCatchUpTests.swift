import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LiveCatchUpTests {
    private actor Hub {
        struct Pull {
            var base: String
            var head: String
            var stack: (number: Int, position: Int)?
            var state = "OPEN"
            var draft = false
        }

        var pulls: [Int: Pull] = [:]
        var named = true
        var headless = false
        var comments: [Int: Date] = [:]
        var asked: [Int] = []

        func set(_ number: Int, base: String, head: String, stack: (Int, Int)? = nil, state: String = "OPEN", draft: Bool = false) {
            pulls[number] = Pull(base: base, head: head, stack: stack, state: state, draft: draft)
        }

        func naming(_ on: Bool) { named = on }
        func heading(_ on: Bool) { headless = !on }
        func comment(on number: Int, at date: Date) { comments[number] = date }
        func count(_ number: Int) -> Int { asked.filter { $0 == number }.count }

        func answer(_ url: URL) -> (Data, Int)? {
            guard let number = Int(url.lastPathComponent) else { return nil }
            asked.append(number)
            guard let pull = pulls[number] else { return nil }
            let members = pulls.filter { $0.key != number && $0.value.stack?.number == pull.stack?.number && pull.stack != nil }
                .keys.sorted().map { #"{"number":\#($0),"state":"OPEN"}"# }.joined(separator: ",")
            let list = named ? #","pullRequests":[\#(members)]"# : ""
            let stack = pull.stack.map { #"{"number":\#($0.number),"position":\#($0.position)\#(list)}"# } ?? "null"
            let blob = #"{"payload":{"pullRequest":{"baseBranch":"\#(pull.base)","headBranch":"\#(pull.head)","#
                + #""headRepositoryName":"rocket","headRepositoryOwnerLogin":"acme","number":\#(number),"state":"\#(pull.state)"},"stack":\#(stack)}}"#
            let status = pull.draft ? "draft" : ["OPEN": "pullOpened", "MERGED": "pullMerged", "CLOSED": "pullClosed"][pull.state] ?? "pullOpened"
            let header = headless ? ""
                : #"<div data-component="PageHeader.Description"><span data-component="StateLabel" data-status="\#(status)">State</span></div>"#
            let talk = comments[number].map { date in
                #"<div class="js-timeline-item js-timeline-progressive-focus-container" data-gid="IC_kwDO1"><div class="TimelineItem js-comment-container">"#
                    + #"<div class="timeline-comment-header"><a class="author Link--primary text-bold" data-hovercard-type="user" href="/dana">dana</a>"#
                    + ##"<span><a href="#c" class="js-timestamp"><relative-time datetime="\##(date.ISO8601Format())">Nov 12</relative-time></a></span></div>"##
                    + #"<div class="comment-body markdown-body js-comment-body"><p>One more thing</p></div></div></div>"#
            } ?? ""
            let html = "<!doctype html><html><body><meta name=\"user-login\" content=\"pat-kit\">" + header + talk
                + "<div id=\"discussion-timeline-actions\"></div>"
                + "<script type=\"application/json\" data-target=\"react-app.embeddedData\">\(blob)</script></body></html>"
            return (Data(html.utf8), 200)
        }
    }

    private let live = LiveFolders.shared
    private let reader = LiveFolders.shared.reader
    private let pointReader = LiveFolders.shared.pointReader
    private let pageFetcher = LiveFolders.shared.pageFetcher
    private let looking = LiveFolders.shared.looking
    private let idleness = LiveFolders.shared.idleness
    private let signInGap = LiveFolders.shared.signInGap
    private let space = UUID()
    private let hub = Hub()
    private let updated = Date(timeIntervalSince1970: 1_793_400_000)
    private var listed: [Int] = []
    private var drafts: Set<Int> = []
    private var reads = 0

    init() async throws {
        _ = NSApplication.shared
        addTeardownBlock { await self.tearDown() }
        for folder in live.folders { live.remove(folder.id) }
        live.resetPace()
        LiveRefs.known = [:]
        let hub = hub
        let shown = space
        live.reader = { [weak self] folder in
            guard let self else { return .items([], nil) }
            self.reads += 1
            let items = await LiveRefs.filled(self.listed.map(self.pull), previous: folder.items, space: folder.space, host: "github.com",
                                              again: self.live.rereads, keep: self.live.keep(folder), fetch: { await hub.answer($0) })
            self.live.pagesRead()
            return .items(LiveStacks.arranged(items), nil)
        }
        live.pointReader = { _ in [] }
        live.pageFetcher = { _ in LiveReader.PageFetch(host: "github.com", also: nil, fetch: { await hub.answer($0) }) }
        live.looking = { [shown] }
        live.idleness = { 0 }
    }

    private func tearDown() async {
        live.reader = reader
        live.pointReader = pointReader
        live.pageFetcher = pageFetcher
        live.looking = looking
        live.idleness = idleness
        live.saidHold = LiveFolders.pageHold
        live.signInGap = signInGap
        live.resetPace()
        for folder in live.folders { live.remove(folder.id) }
        LiveRefs.known = [:]
    }

    private func pull(_ number: Int) -> LiveItem {
        LiveItem(key: "https://github.com/acme/rocket/pull/\(number)", title: "PR \(number)", updated: updated, draft: drafts.contains(number) ? true : nil)
    }

    private func url(_ number: Int) -> URL { URL(string: pull(number).key)! }

    private func chips(_ made: LiveFolder) -> [Int: String] {
        var out: [Int: String] = [:]
        for item in live.folder(made.id)?.items ?? [] { out[Int(URL(string: item.key)!.lastPathComponent)!] = item.stack?.said ?? "-" }
        return out
    }

    private func folder(_ numbers: [Int]) async -> LiveFolder {
        listed = numbers
        let made = live.add(name: "PRs", source: .pullRequests, space: space)
        await live.readNow(made.id)
        return made
    }

    private func reload(_ number: Int, at now: Date = Date()) async {
        live.touch(url(number), space: space, cause: .landed, now: now)
        await live.flush()
    }

    private func fill(_ numbers: [Int], previous: [LiveItem], at now: Date, again: Set<String> = [], keep: TimeInterval = LiveRefs.stale,
                      only: Bool = false) async -> [LiveItem] {
        let hub = hub
        return await LiveRefs.filled(numbers.map(pull), previous: previous, at: now, again: again, keep: keep, only: only,
                                     fetch: { await hub.answer($0) })
    }

    private func said(_ items: [LiveItem]) -> [Int: String] {
        var out: [Int: String] = [:]
        for item in LiveStacks.arranged(items) { out[Int(URL(string: item.key)!.lastPathComponent)!] = item.stack?.said ?? "-" }
        return out
    }

    @Test func twoRowsJoinedIntoAStackWithTheirTimeUnchangedFoldWithinSecondsOfAReload() async throws {
        await hub.set(1, base: "main", head: "wing")
        await hub.set(2, base: "main", head: "tail")
        let made = await folder([1, 2])
        let before = chips(made)
        await hub.set(1, base: "main", head: "wing", stack: (7, 1))
        await hub.set(2, base: "wing", head: "tail", stack: (7, 2))

        await reload(2)

        #expect(before == [1: "-", 2: "-"])
        #expect(chips(made) == [1: "1/2", 2: "2/2"])
        #expect(await hub.count(2) == 2)
        #expect(await hub.count(1) == 2)
        #expect(reads == 1)
    }

    @Test func aPageAskedForAFolderReadBringsTheNewStacksOtherMemberWithIt() async throws {
        live.signInGap = 0
        await hub.set(1, base: "main", head: "wing")
        await hub.set(2, base: "main", head: "tail")
        let made = await folder([1, 2])
        await hub.set(1, base: "main", head: "wing", stack: (7, 1))
        await hub.set(2, base: "wing", head: "tail", stack: (7, 2))

        live.pageShown(url(2), space: space)
        try await Task.sleep(for: .milliseconds(500))

        #expect(await hub.count(2) == 2)
        #expect(await hub.count(1) == 2)
        #expect(chips(made) == [1: "1/2", 2: "2/2"])
    }

    @Test func aSecondReloadWithinTenMinutesReadsThePageAgain() async throws {
        await hub.set(1, base: "main", head: "wing", stack: (7, 1))
        await hub.set(2, base: "wing", head: "tail", stack: (7, 2))
        let made = await folder([1, 2])
        let now = Date()
        await reload(2, at: now)
        await hub.set(1, base: "main", head: "wing")
        await hub.set(2, base: "main", head: "tail")

        await reload(2, at: now.addingTimeInterval(120))

        #expect(chips(made) == [1: "-", 2: "-"])
        #expect(await hub.count(2) == 3)
        #expect(await hub.count(1) == 2)
    }

    @Test func aBurstOfReloadsMakesOneRead() async throws {
        await hub.set(1, base: "main", head: "wing")
        await hub.set(2, base: "main", head: "tail")
        _ = await folder([1, 2])
        let now = Date()

        live.touch(url(2), space: space, cause: .landed, now: now)
        live.touch(url(2), space: space, cause: .landed, now: now.addingTimeInterval(1))
        live.touch(url(2), space: space, cause: .landed, now: now.addingTimeInterval(2))
        await live.flush()
        live.touch(url(2), space: space, cause: .landed, now: now.addingTimeInterval(3))
        await live.flush()

        #expect(await hub.count(2) == 2)
        #expect(await hub.count(1) == 1)
    }

    @Test func anActOnThePageReadsItsStack() async throws {
        await hub.set(1, base: "main", head: "wing")
        await hub.set(2, base: "main", head: "tail")
        let made = await folder([1, 2])
        await hub.set(1, base: "main", head: "wing", stack: (7, 1))
        await hub.set(2, base: "wing", head: "tail", stack: (7, 2))

        live.touch(url(1), space: space, cause: .acted)
        await live.flush()

        #expect(chips(made) == [1: "1/2", 2: "2/2"])
    }

    @Test func aReadThatDisagreesWithThePageWins() async throws {
        await hub.set(1, base: "main", head: "wing")
        let made = await folder([1])
        live.pageSays(.draft, at: url(1), space: space)
        let told = live.folder(made.id)?.items.first?.draft

        await reload(1)

        #expect(told == true)
        #expect(live.folder(made.id)?.items.first?.draft == nil)
        #expect(LiveFolders.shows(live.folder(made.id)!.items[0]) == .open)
    }

    @Test func anOpenStateFromThePagesDataAloneDoesNotClearADraft() async throws {
        drafts = [1]
        await hub.set(1, base: "main", head: "wing")
        let made = await folder([1])
        await hub.heading(false)

        await reload(1)

        #expect(await hub.count(1) == 2)
        #expect(live.folder(made.id)?.items.first?.draft == true)
    }

    @Test func aDraftMadeReadyIsShownReadyOnReload() async throws {
        drafts = [1]
        await hub.set(1, base: "main", head: "wing")
        let made = await folder([1])

        await reload(1)

        #expect(live.folder(made.id)?.items.first?.draft == nil)
    }

    @Test func aChangedBaseBranchIsShownOnReload() async throws {
        await hub.set(1, base: "main", head: "wing")
        let made = await folder([1])
        await hub.set(1, base: "release", head: "wing")

        await reload(1)

        #expect(live.folder(made.id)?.items.first?.branch?.base == "release")
    }

    @Test func aNewCommentOnThePageInFrontIsCountedAndSeenAndOneOnAMemberStaysNew() async throws {
        await hub.set(1, base: "main", head: "wing")
        await hub.set(2, base: "main", head: "tail")
        let made = await folder([1, 2])
        let said = Date(timeIntervalSince1970: 1_793_450_000)
        await hub.set(1, base: "main", head: "wing", stack: (7, 1))
        await hub.set(2, base: "wing", head: "tail", stack: (7, 2))
        await hub.comment(on: 1, at: said)
        await hub.comment(on: 2, at: said)

        await reload(2)

        let rows = Dictionary(uniqueKeysWithValues: (live.folder(made.id)?.items ?? []).map { (Int(URL(string: $0.key)!.lastPathComponent)!, $0) })
        #expect(rows[2]?.activity == said)
        #expect(rows[2]?.fresh == false)
        #expect(rows[1]?.activity == said)
        #expect(rows[1]?.fresh == true)
        #expect(chips(made) == [1: "1/2", 2: "2/2"])
    }

    @Test func anAgentsTabOnAPullRequestMakesNoPageRead() async throws {
        await hub.set(1, base: "main", head: "wing")
        _ = await folder([1])

        live.touch(url(1), space: space, cause: .landed, agent: true)
        await live.flush()

        #expect(await hub.count(1) == 1)
    }

    @Test func aPageReadFindingDraftTellsTheRow() async throws {
        await hub.set(1, base: "main", head: "wing")
        let made = await folder([1])
        await hub.set(1, base: "main", head: "wing", draft: true)

        await reload(1)

        #expect(live.folder(made.id)?.items.first?.draft == true)
    }

    @Test func aFolderReadThatStartedBeforeAPageReadDoesNotUndoIt() async throws {
        await hub.set(1, base: "main", head: "wing")
        await hub.set(2, base: "main", head: "tail")
        let made = await folder([1, 2])
        let stale = live.folder(made.id)!.items
        await hub.set(1, base: "main", head: "wing", stack: (7, 1))
        await hub.set(2, base: "wing", head: "tail", stack: (7, 2))
        await reload(2)

        live.apply(.items(stale, nil), to: made.id)

        #expect(chips(made) == [1: "1/2", 2: "2/2"])
    }

    @Test func landingOnAPullRequestNoFolderListsReadsTheFolderOnce() async throws {
        await hub.set(1, base: "main", head: "wing")
        let made = await folder([1])
        let now = Date()
        live.signInGap = 0

        live.pageShown(url(9), space: space, person: true, now: now)
        live.pageShown(url(9), space: space, person: true, now: now.addingTimeInterval(30))
        live.pageShown(URL(string: "https://github.com/acme/rocket/issues/9")!, space: space, person: true, now: now)
        try await Task.sleep(for: .milliseconds(200))

        #expect(reads == 2)
        #expect(live.folder(made.id) != nil)
        #expect(!live.rereads.contains(LiveIdentity.of(pull(9).key)))
    }

    @Test func aRowsOwnLoadSkipsTheTenMinuteHoldButAShownTabKeepsIt() async throws {
        await hub.set(1, base: "main", head: "wing")
        _ = await folder([1])
        let now = Date()
        let identity = LiveIdentity.of(pull(1).key)

        live.pageShown(url(1), space: space, now: now)
        LiveRefs.known[LiveRefs.slot(pull(1).key, space: space)]?.read = now.addingTimeInterval(1)
        live.pagesRead()
        live.pageShown(url(1), space: space, now: now.addingTimeInterval(120))
        let shown = live.rereads.contains(identity)
        live.pageShown(url(1), space: space, person: true, now: now.addingTimeInterval(121))
        let loaded = live.rereads.contains(identity)

        #expect(!shown)
        #expect(loaded)
    }

    @Test func twoLoneRowsThatBecomeAStackAreBothReadWhenOneIsAsked() async throws {
        await hub.set(11, base: "main", head: "reef")
        await hub.set(12, base: "main", head: "kelp")
        await hub.set(13, base: "main", head: "apart")
        let first = await fill([11, 12, 13], previous: [], at: Date(timeIntervalSince1970: 1_793_500_000))
        await hub.set(11, base: "main", head: "reef", stack: (5, 1))
        await hub.set(12, base: "main", head: "kelp", stack: (5, 2))

        let next = await fill([11, 12, 13], previous: first, at: Date(timeIntervalSince1970: 1_793_500_060), again: [LiveIdentity.of(pull(12).key)])

        #expect(said(next) == [11: "1/2", 12: "2/2", 13: "-"])
        #expect(await hub.count(11) == 2)
        #expect(await hub.count(13) == 1)
    }

    @Test func aNewStackOfThreeWithNoMembersNamedIsFoundThroughItsBranches() async throws {
        await hub.naming(false)
        await hub.set(21, base: "main", head: "one")
        await hub.set(22, base: "main", head: "two")
        await hub.set(23, base: "main", head: "three")
        await hub.set(24, base: "main", head: "apart")
        let start = Date(timeIntervalSince1970: 1_793_500_000)
        let first = await fill([21, 22, 23, 24], previous: [], at: start)
        await hub.set(21, base: "main", head: "one", stack: (6, 1))
        await hub.set(22, base: "one", head: "two", stack: (6, 2))
        await hub.set(23, base: "two", head: "three", stack: (6, 3))

        let next = await fill([21, 22, 23, 24], previous: first, at: start.addingTimeInterval(60), again: [LiveIdentity.of(pull(23).key)],
                              only: true)

        #expect(said(next) == [21: "1/3", 22: "2/3", 23: "3/3", 24: "-"])
        #expect(await hub.count(24) == 1)
    }

    @Test func aKeptReadingIsUsedForAtMostTheKeepTimeEvenWithTheTimeUnchanged() async throws {
        await hub.set(31, base: "main", head: "mast")
        let start = Date(timeIntervalSince1970: 1_793_500_000)
        let first = await fill([31], previous: [], at: start, keep: 240)
        let soon = await fill([31], previous: first, at: start.addingTimeInterval(120), keep: 240)
        await hub.set(31, base: "main", head: "mast", stack: (8, 1))
        await hub.set(32, base: "mast", head: "sail", stack: (8, 2))
        let round = await fill([31, 32], previous: soon, at: start.addingTimeInterval(300), keep: 240)

        #expect(await hub.count(31) == 2)
        #expect(said(round) == [31: "1/2", 32: "2/2"])
    }

    @Test func onlyReadsTheAskedRowAndNoAgedOnes() async throws {
        await hub.set(41, base: "main", head: "oar")
        await hub.set(42, base: "main", head: "keel")
        let start = Date(timeIntervalSince1970: 1_793_500_000)
        let first = await fill([41, 42], previous: [], at: start)

        _ = await fill([41, 42], previous: first, at: start.addingTimeInterval(3600), again: [LiveIdentity.of(pull(41).key)], only: true)

        #expect(await hub.count(41) == 2)
        #expect(await hub.count(42) == 1)
    }

    @Test func theKeepTimeIsTheFolderIntervalWithAFloorOfFiveMinutes() async throws {
        let made = live.add(name: "PRs", source: .pullRequests, space: space)
        let every = live.every
        defer { live.every = every }

        live.every = { LiveEvery.minute.interval }
        let minute = live.keep(made)
        live.every = { LiveEvery.quarter.interval }
        let quarter = live.keep(made)

        #expect(minute == 240)
        #expect(quarter == 840)
    }
}
