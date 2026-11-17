import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PullStackTests {
    private actor Counter {
        var asked: [URL] = []
        var now = 0
        var most = 0

        func begin(_ url: URL) {
            asked.append(url)
            now += 1
            most = max(most, now)
        }

        func end() { now -= 1 }
    }

    private static let host = "https://github.com"

    nonisolated private static func page(base: String, head: String, owner: String = "acme", repository: String = "rocket",
                                         stack: String = "null") -> String {
        let blob = #"{"payload":{"pullRequestsLayoutRoute":{"pullRequest":{"author":{"login":"octo-sam"},"baseBranch":"\#(base)","#
            + #""commitsCount":1,"headBranch":"\#(head)","headRepositoryName":"\#(repository)","headRepositoryOwnerLogin":"\#(owner)","#
            + #""number":37,"state":"OPEN","title":"Audio: record"},"stack":\#(stack)}}}"#
        return "<!doctype html><html><head><meta name=\"user-login\" content=\"octo-sam\"></head><body>"
            + "<script type=\"application/json\" data-target=\"react-app.embeddedData\">\(blob)</script></body></html>"
    }

    private func pull(_ number: Int, updated: Date? = nil, label: String? = nil, host: String = host) -> LiveItem {
        LiveItem(key: "\(host)/acme/rocket/pull/\(number)", title: "PR \(number)", label: label, updated: updated)
    }

    private func served(_ heads: [Int: (String, String)], counter: Counter, delay: Duration = .zero) -> @Sendable (URL) async -> (Data, Int)? {
        { url in
            await counter.begin(url)
            if delay > .zero { try? await Task.sleep(for: delay) }
            await counter.end()
            guard let number = Int(url.lastPathComponent), let (base, head) = heads[number] else { return (Data(), 404) }
            return (Data(Self.page(base: base, head: head).utf8), 200)
        }
    }

    @Test func thePullRequestPageGivesBothBranches() {
        let html = Self.page(base: "audio-model", head: "users/sam/audio-recorder")

        let branch = LiveRefs.branch(in: html, repository: "acme/rocket")

        #expect(branch == LiveBranch(repository: "acme/rocket", base: "audio-model", head: "users/sam/audio-recorder", stackRead: true))
    }

    @Test func thePullRequestPageGivesGitHubsStack() {
        let stack = #"{"id":2436699,"baseBranch":"main {x}","number":577,"position":2,"size":3,"#
            + #""pulls":[{"number":576,"title":"Top \"}\" here","headBranch":"c"},{"number":575,"headBranch":"b"}]}"#
        let html = Self.page(base: "audio-model", head: "audio-record", stack: stack)

        let branch = LiveRefs.branch(in: html, repository: "acme/rocket")

        #expect(branch?.stack == 577)
        #expect(branch?.position == 2)
        #expect(LiveRefs.branch(in: Self.page(base: "main", head: "x"), repository: "acme/rocket")?.stack == nil)
    }

    @Test func aHeadFromAForkNeverCarriesAPullRequestHere() {
        let html = Self.page(base: "main", head: "audio-model", owner: "someone")

        let branch = LiveRefs.branch(in: html, repository: "acme/rocket")

        #expect(branch == LiveBranch(repository: "acme/rocket", base: "main", head: "someone/rocket:audio-model", stackRead: true))
        #expect(LiveStacks.arranged([
            LiveItem(key: "a", title: "A", branch: LiveBranch(repository: "acme/rocket", base: "main", head: "audio-model")),
            LiveItem(key: "b", title: "B", branch: branch),
        ]).map(\.stack) == [nil, nil])
    }

    @Test func theMergeLineIsReadWhenThereIsNoEmbeddedData() {
        let html = """
        <div>octo-sam wants to merge 2 commits into<div class="d-flex"><a href="/acme/rocket/tree/audio-model" data-component="BranchName">acme:audio-model</a>
        <span>from </span><div><a href="/acme/rocket/tree/users/sam/audio%20record" data-component="BranchName">acme:users/sam/audio record</a></div></div></div>
        """

        let branch = LiveRefs.branch(in: html, repository: "acme/rocket")

        #expect(branch == LiveBranch(repository: "acme/rocket", base: "audio-model", head: "users/sam/audio record", stackRead: true))
    }

    @Test func aPageWithoutBranchesGivesNone() {
        #expect(LiveRefs.branch(in: "<html><body>Sign in to GitHub</body></html>", repository: "acme/rocket") == nil)
        #expect(LiveRefs.place(of: "https://github.com/acme/rocket/pull/37")?.repository == "acme/rocket")
        #expect(LiveRefs.place(of: "https://github.com/acme/rocket/issues/37") == nil)
    }

    @Test func aStackReadsTopFirstAtItsFirstMembersPlace() {
        func item(_ key: String, _ base: String, _ head: String, _ position: Int? = nil) -> LiveItem {
            LiveItem(key: key, title: key, branch: LiveBranch(repository: "acme/rocket", base: base, head: head,
                                                              stack: position == nil ? nil : 8, position: position))
        }
        let items = [item("other", "main", "tidy"), item("model", "main", "audio-model", 1), item("upload", "audio-record", "audio-upload", 3),
                     item("lone", "lone-base", "lone"), item("record", "audio-model", "audio-record", 2)]

        let arranged = LiveStacks.arranged(items)

        #expect(arranged.map(\.key) == ["other", "upload", "record", "model", "lone"])
        #expect(arranged.map(\.stack) == [nil, LiveStack(position: 3, count: 3), LiveStack(position: 2, count: 3),
                                          LiveStack(position: 1, count: 3), nil])
        #expect(arranged.map(\.who) == [nil, "3/3", "2/3", "1/3", nil])
        #expect(LiveStackRuns.tops(arranged) == [nil, 1, 1, 1, nil])
    }

    @Test func onlyOpenPullRequestsOnTheListsHostAreRead() async {
        LiveRefs.known = [:]
        let counter = Counter()
        let items = [pull(36), pull(37, label: PullState.merged), pull(38, label: PullState.closed), pull(39, host: "https://elsewhere.example")]

        let filled = await LiveRefs.filled(items, previous: [], host: "github.com",
                                           fetch: served([36: ("main", "audio-model"), 37: ("main", "x")], counter: counter))

        #expect(await counter.asked.map(\.lastPathComponent) == ["36"])
        #expect(filled.map(\.branch) == [LiveBranch(repository: "acme/rocket", base: "main", head: "audio-model", stackRead: true), nil, nil, nil])
    }

    @Test func refsAreKeptByNumberAndUpdatedTime() async {
        LiveRefs.known = [:]
        let monday = Date(timeIntervalSince1970: 1_793_000_000)
        let tuesday = monday.addingTimeInterval(86_400)
        let heads = [36: ("main", "audio-model"), 37: ("audio-model", "audio-record")]
        let counter = Counter()

        _ = await LiveRefs.filled([pull(36, updated: monday), pull(37, updated: monday)], previous: [], fetch: served(heads, counter: counter))
        let again = await LiveRefs.filled([pull(36, updated: monday), pull(37, updated: tuesday)], previous: [], fetch: served(heads, counter: counter))

        #expect(await counter.asked.map(\.lastPathComponent).sorted() == ["36", "37", "37"])
        #expect(again.map(\.branch?.base) == ["main", "audio-model"])
    }

    @Test func theFoldersLastReadSeedsTheRefsAfterALaunch() async {
        LiveRefs.known = [:]
        let monday = Date(timeIntervalSince1970: 1_793_000_000)
        var kept = pull(36, updated: monday)
        kept.branch = LiveBranch(repository: "acme/rocket", base: "main", head: "audio-model", stackRead: true)
        kept.signsRead = true
        kept.pageRead = Date()
        let counter = Counter()

        let filled = await LiveRefs.filled([pull(36, updated: monday)], previous: [kept], fetch: served([:], counter: counter))

        #expect(await counter.asked.isEmpty)
        #expect(filled.first?.branch == kept.branch)
    }

    @Test func aBranchKeptFromBeforeStacksWereReadIsReadAgain() async {
        LiveRefs.known = [:]
        let monday = Date(timeIntervalSince1970: 1_793_000_000)
        var kept = pull(36, updated: monday)
        kept.branch = LiveBranch(repository: "acme/rocket", base: "main", head: "audio-model")
        let counter = Counter()

        let filled = await LiveRefs.filled([pull(36, updated: monday)], previous: [kept], fetch: served([36: ("main", "audio-model")], counter: counter))

        #expect(await counter.asked.map(\.lastPathComponent) == ["36"])
        #expect(filled.first?.branch?.stackRead == true)
    }

    @Test func aSlowSiteRunsOutOfTimeIntoNoStackFourAtATime() async {
        LiveRefs.known = [:]
        let counter = Counter()
        let items = (1...10).map { pull($0) }
        let heads = Dictionary(uniqueKeysWithValues: (1...10).map { ($0, ("main", "b\($0)")) })

        let began = Date()
        let filled = await LiveRefs.filled(items, previous: [], width: 4, budget: 0.3,
                                           fetch: served(heads, counter: counter, delay: .seconds(2)))

        #expect(Date().timeIntervalSince(began) < 1.5)
        #expect(filled.allSatisfy { $0.branch == nil })
        #expect(await counter.most <= 4)
    }

    @Test func theFetchLimitStopsAtTheFoldersCap() async {
        LiveRefs.known = [:]
        let counter = Counter()
        let heads = Dictionary(uniqueKeysWithValues: (1...5).map { ($0, ("main", "b\($0)")) })

        _ = await LiveRefs.filled((1...5).map { pull($0) }, previous: [], limit: 2, fetch: served(heads, counter: counter))

        #expect(await counter.asked.count == 2)
    }

    @Test func everyChecksMarkKeepsThreeToOneOnEveryGround() {
        var looks: [(String, SpaceLook)] = SpaceLook.themes.map { ($0.name, $0.look) }
        looks += SpaceLook.palette.map { ($0.name, SpaceLook(colour: $0.id)) }
        looks += ["000000", "000354", "3139FB", "FB3A4D", "39FF14", "FFFFFF", "E8FF1A", "FFD3E0"].flatMap { hex in
            [0.8, 2.0].map { strength -> (String, SpaceLook) in
                var look = SpaceLook(colour: "custom", custom: hex)
                look.intensity = strength
                return ("\(hex) \(strength)", look)
            }
        }

        var failing: [String] = []
        for (name, look) in looks {
            for dark in [false, true] {
                let ground = look.ground(dark: dark)
                for checks in [LiveChecks.passing, .failing, .pending] {
                    let mark = ChecksTint.colour(checks, dark: ground.lightInk, stops: ground.stops, frame: true, lift: ground.lift)
                    let all = ChecksTint.grounds(ground.stops, frame: true, dark: ground.lightInk, lift: ground.lift)
                    if ChecksTint.worst(mark, on: all) < ChecksTint.minimum { failing.append("\(name) \(dark) \(checks)") }
                }
            }
        }

        #expect(failing.isEmpty)
    }

    @Test func plainGroundsKeepPrimersColoursUnlessTheyFallUnderThreeToOne() {
        let made = [false, true].flatMap { dark in
            [LiveChecks.passing, .failing, .pending].map { ChecksTint.colour($0, dark: dark, stops: nil, frame: false, lift: 0).hex }
        }

        #expect(made == ["1A7F37", "D1242F", "9A6700", "3FB950", "FF6F63", "D29922"])
    }
}
