import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LiveSignInOverTests {
    private var browsers: [Browser] = []
    private let space = UUID()
    private let signOnPage = URL(string: "https://github.com/orgs/octocorp/sso?return_to=%2Fpulls")!
    private let provider = URL(string: "https://octocorp.okta.com/app/github/sso/saml")!
    private let consume = URL(string: "https://github.com/orgs/octocorp/saml/consume")!
    private let listPage = URL(string: "https://github.com/pulls?q=is%3Aopen+is%3Apr+author%3A%40me")!
    private let pullPage = URL(string: "https://github.com/octocorp/notes-api/pull/753")!
    private let sso = LiveSSO(org: "Octo Corp", url: "https://github.com/orgs/octocorp/sso?return_to=%2Fpulls")
    private let kept = (1...3).map { LiveItem(key: "https://github.com/octocorp/ios/pull/\($0)", title: "Kept \($0)") }
    private let fresh = LiveItem(key: "https://github.com/octocorp/ios/pull/9", title: "Fresh")
    private var signedOn: LiveArrival { LiveArrival(from: provider, type: .formSubmitted, redirected: true) }

    init() {
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "live-sign-in-over-\(getpid())", 1)
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
    }

    private func tearDown() async {
        LiveFolders.shared.reader = { await LiveReader.read($0) }
        LiveFolders.shared.signInGap = 15
        LiveFolders.shared.signOnLasts = LiveSignOn.lasts
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        for browser in browsers { browser.closeAll() }
        browsers = []
    }

    private func asking(_ source: LiveSource = .pullRequests, single: Bool = true, items: Bool = true) -> UUID {
        let live = LiveFolders.shared
        let made = live.add(name: "PRs", source: source, space: space)
        let long = Date().addingTimeInterval(-60)
        if items { live.apply(.items(kept, nil), to: made.id, now: long) }
        live.apply(single ? .sso(sso, []) : .signIn, to: made.id, now: long)
        return made.id
    }

    private final class Reads {
        var starts: [Date] = []
        var waiting: [CheckedContinuation<LiveReader.Answer, Never>] = []
        var count: Int { starts.count }

        func answer(_ answer: LiveReader.Answer) {
            guard !waiting.isEmpty else { return }
            waiting.removeFirst().resume(returning: answer)
        }
    }

    private func held() -> Reads {
        let reads = Reads()
        LiveFolders.shared.reader = { _ in
            reads.starts.append(Date())
            return await withCheckedContinuation { reads.waiting.append($0) }
        }
        return reads
    }

    private func until(_ timeout: TimeInterval = 3, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func folder(_ id: UUID) -> LiveFolder? { LiveFolders.shared.folder(id) }

    @Test func leavingTheSignOnPageLoadsAtOnceAndFillsWhenTheReadAnswers() async throws {
        let id = asking()
        let reads = held()
        let tab = UUID()
        let live = LiveFolders.shared

        live.signInPressed(id)
        live.signOnTab(tab, for: id, at: signOnPage)
        live.signOnTab(tab, at: provider)
        live.signOnTab(tab, at: consume)
        let before = folder(id)
        let left = Date()
        live.signOnTab(tab, at: listPage)
        let after = try #require(folder(id))
        await until { reads.count == 1 }
        let started = reads.starts.first.map { $0.timeIntervalSince(left) } ?? 99

        #expect(before?.state == .signIn)
        #expect(after.state == .waiting)
        #expect(after.note == nil)
        #expect(after.status == nil)
        #expect(after.sso == nil)
        #expect(after.items.map(\.title) == kept.map(\.title))
        #expect(reads.count == 1)
        #expect(started < 0.5)

        reads.answer(.items([fresh], nil))
        await until { self.folder(id)?.state == .fine }

        #expect(folder(id)?.state == .fine)
        #expect(folder(id)?.items.map(\.title) == ["Fresh"])
        #expect(folder(id)?.note == nil)
    }

    @Test func aSiteThatStillAsksBringsTheNoteBack() async {
        let id = asking()
        let reads = held()
        let tab = UUID()

        LiveFolders.shared.signOnTab(tab, for: id, at: signOnPage)
        LiveFolders.shared.signOnTab(tab, at: listPage)
        await until { reads.count == 1 }
        let loading = folder(id)?.state
        reads.answer(.sso(sso, []))
        await until { self.folder(id)?.state == .signIn }

        #expect(loading == .waiting)
        #expect(folder(id)?.state == .signIn)
        #expect(folder(id)?.note == .sso(sso))
        #expect(folder(id)?.items.map(\.title) == kept.map(\.title))
    }

    @Test func aReadThatFailsLandsInFailedNotWaiting() async {
        let id = asking(single: false)
        let reads = held()

        LiveFolders.shared.cameBack(to: listPage, space: space, through: signedOn)
        await until { reads.count == 1 }
        reads.answer(.failed)
        await until { self.folder(id)?.state == .failed }

        #expect(folder(id)?.state == .failed)
    }

    @Test func aBurstOfSignalsMakesOneRead() async throws {
        let id = asking()
        let reads = held()
        let tab = UUID()
        let live = LiveFolders.shared

        live.signInPressed(id)
        live.signOnTab(tab, for: id, at: signOnPage)
        live.signOnTab(tab, at: listPage)
        live.cameBack(to: listPage, space: space)
        live.cameBack(to: pullPage, space: space)
        live.signOnTabClosed(tab)
        live.cameBack(to: listPage, space: space)
        try await Task.sleep(for: .milliseconds(300))

        #expect(reads.count == 1)
        #expect(folder(id)?.state == .waiting)

        reads.answer(.items([fresh], nil))
        await until { self.folder(id)?.state == .fine }
        try await Task.sleep(for: .milliseconds(200))

        #expect(reads.count == 1)
    }

    @Test func closingTheSignOnTabLoadsAndReads() async {
        let id = asking()
        let reads = held()
        let tab = UUID()

        LiveFolders.shared.signOnTab(tab, for: id, at: signOnPage)
        LiveFolders.shared.signOnTabClosed(tab)
        await until { reads.count == 1 }

        #expect(folder(id)?.state == .waiting)
        #expect(reads.count == 1)
    }

    @Test func theOpenedTabCountsOnlyOnceItLeavesASignInPage() async throws {
        let page = LiveSource(kind: .page, address: "https://example.com/news")
        let id = asking(page, single: false)
        let reads = held()
        let tab = UUID()
        let live = LiveFolders.shared
        let news = URL(string: page.address)!

        live.signOnTab(tab, for: id, at: news)
        live.signOnTab(tab, at: news)
        try await Task.sleep(for: .milliseconds(150))
        let onItsPage = (folder(id)?.state, reads.count)
        live.signOnTab(tab, at: URL(string: "https://example.com/login")!)
        try await Task.sleep(for: .milliseconds(150))
        let onTheLogin = (folder(id)?.state, reads.count)
        live.signOnTab(tab, at: news)
        await until { reads.count == 1 }

        #expect(onItsPage.0 == .signIn && onItsPage.1 == 0)
        #expect(onTheLogin.0 == .signIn && onTheLogin.1 == 0)
        #expect(folder(id)?.state == .waiting)
        #expect(reads.count == 1)
    }

    @Test func aTabOfAnotherSpaceOrAnotherSiteChangesNothing() async throws {
        let id = asking()
        let reads = held()

        LiveFolders.shared.cameBack(to: listPage, space: UUID())
        LiveFolders.shared.cameBack(to: URL(string: "https://example.com/")!, space: space)
        LiveFolders.shared.cameBack(to: signOnPage, space: space)
        try await Task.sleep(for: .milliseconds(200))

        #expect(folder(id)?.state == .signIn)
        #expect(reads.count == 0)
    }

    @Test func aPausedFolderKeepsAsking() async throws {
        let id = asking()
        LiveFolders.shared.pause(id, true)
        let reads = held()

        LiveFolders.shared.cameBack(to: listPage, space: space)
        try await Task.sleep(for: .milliseconds(200))

        #expect(folder(id)?.state == .signIn)
        #expect(reads.count == 0)
    }

    @Test func everyKindOfLiveFolderLoadsTheSameWay() async {
        let sources: [(LiveSource, URL)] = [
            (.subscriptions, URL(string: "https://www.youtube.com/feed/subscriptions")!),
            (.linear(.assigned), URL(string: "https://linear.app/acme/my-issues")!),
            (LiveSource(kind: .feed, address: "https://example.com/feed.xml"), URL(string: "https://example.com/")!),
            (.gitHubNotifications, URL(string: "https://github.com/notifications")!),
        ]
        let ids = sources.map { asking($0.0, single: false, items: false) }
        let reads = held()

        for (_, page) in sources { LiveFolders.shared.cameBack(to: page, space: space, through: signedOn) }
        await until { reads.count == sources.count }

        #expect(ids.map { folder($0)?.state } == ids.map { _ in .waiting })
        #expect(ids.map { folder($0)?.note } == ids.map { _ in .loading })
        #expect(reads.count == sources.count)
    }

    @Test func anAnswerFromBeforeTheSignOnIsNotShown() async {
        LiveFolders.shared.signInGap = 0.2
        let id = asking()
        let reads = held()
        var states: [LiveFolder.State] = []

        LiveFolders.shared.update(id)
        await until { reads.count == 1 }
        LiveFolders.shared.cameBack(to: listPage, space: space, through: signedOn)
        states.append(folder(id)?.state ?? .fine)
        reads.answer(.sso(sso, []))
        try? await Task.sleep(for: .milliseconds(60))
        states.append(folder(id)?.state ?? .fine)
        await until { reads.count == 2 }
        states.append(folder(id)?.state ?? .fine)
        reads.answer(.items([fresh], nil))
        await until { self.folder(id)?.state == .fine }

        #expect(states == [.waiting, .waiting, .waiting])
        #expect(reads.count == 2)
        #expect((reads.starts.last ?? .distantPast).timeIntervalSince(reads.starts.first ?? .distantFuture) >= 0.2)
        #expect(folder(id)?.items.map(\.title) == ["Fresh"])
    }

    @Test func insideTheGapItLoadsAtOnceAndReadsWhenTheGapEnds() async {
        LiveFolders.shared.signInGap = 0.5
        let live = LiveFolders.shared
        let made = live.add(name: "PRs", source: .pullRequests, space: space)
        live.apply(.sso(sso, kept), to: made.id, now: Date())
        let reads = held()
        let landed = Date()

        live.cameBack(to: listPage, space: space, through: signedOn)
        let loading = folder(made.id)?.state
        await until { reads.count == 1 }

        #expect(loading == .waiting)
        #expect(reads.count == 1)
        #expect((reads.starts.first?.timeIntervalSince(landed) ?? 0) >= 0.4)
        reads.answer(.items(kept, nil))
        await until { self.folder(made.id)?.state == .fine }
    }

    @Test func aFolderSavedWhileLoadingIsReadOnTheFirstTick() {
        var folder = LiveFolder(space: space, name: "PRs", source: .pullRequests)
        folder.items = kept
        folder.read = Date()
        folder.state = .waiting
        var settled = folder
        settled.id = UUID()
        settled.state = .fine
        let moment = LiveMoment(active: true, away: 0)

        let woken = LiveFolders.woken([folder, settled])
        let wanted = LivePace.wanted(woken, moment: moment, looked: nil, returned: false, now: Date())

        #expect(wanted == [folder.id])
        #expect(woken.map(\.items.count) == [3, 3])
    }

    @Test func theLoadingBarShowsOnlyWhileAKeptOrFoldedFolderLoads() {
        var folder = LiveFolder(space: space, name: "PRs", source: .pullRequests)
        let emptyOpen = LiveLoading.shows(folder, collapsed: false)
        let emptyFolded = LiveLoading.shows(folder, collapsed: true)
        folder.items = kept
        let keptOpen = LiveLoading.shows(folder, collapsed: false)
        folder.paused = true
        let paused = LiveLoading.shows(folder, collapsed: true)
        folder.paused = false
        let shown = [LiveFolder.State.fine, .signIn, .failed].map { state -> Bool in
            var other = folder
            other.state = state
            return LiveLoading.shows(other, collapsed: true)
        }

        #expect(!emptyOpen)
        #expect(emptyFolded)
        #expect(keptOpen)
        #expect(!paused)
        #expect(shown == [false, false, false])
        #expect(LiveLoading.width == 32)
        #expect(GroupNameReveal.barHeight == 9)
        #expect(LiveLoading.spoken(folder) == "Loading PRs")
    }

    private func heading(_ id: UUID, collapsed: Bool) async throws -> GroupHeadingView {
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let view = GroupHeadingView(frame: NSRect(x: 0, y: 0, width: 240, height: GroupHeadingView.height))
        view.count = 3
        view.show(TabGroup(id: id, name: "PRs", collapsed: collapsed, live: true), in: browser)
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
            view.layoutSubtreeIfNeeded()
        }
        return view
    }

    @Test func theHeadingSwapsTheSignInButtonForTheLoadingBarOpenAndFolded() async throws {
        let id = asking()
        let reads = held()
        let folded = try await heading(id, collapsed: true)
        let open = try await heading(id, collapsed: false)
        let asked = (folded.status as? LiveStatusView)?.pill != nil

        LiveFolders.shared.cameBack(to: listPage, space: space, through: signedOn)
        await until { reads.count == 1 }
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
            folded.layoutSubtreeIfNeeded()
            open.layoutSubtreeIfNeeded()
        }
        let views = [folded, open].map { $0.status as? LiveStatusView }
        let bars = views.map { $0?.loading }
        let frames = zip([folded, open], bars).map { heading, bar in bar.map { heading.convert($0.bounds, from: $0) } ?? .zero }

        #expect(asked)
        #expect(views.map { $0?.pill == nil } == [true, true])
        #expect(bars.map { $0 != nil && !$0!.isHidden } == [true, true])
        #expect(frames.map(\.width) == [32, 32])
        #expect(frames.map(\.height) == [9, 9])
        #expect(frames.allSatisfy { $0.minX >= folded.nameHost.frame.maxX && $0.maxX <= 240 })
        #expect(views.map { $0?.accessibilityLabel() } == ["Loading PRs", "Loading PRs"])

        reads.answer(.items([fresh], nil))
        await until { self.folder(id)?.state == .fine }
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
            folded.layoutSubtreeIfNeeded()
        }

        #expect((folded.status as? LiveStatusView)?.loading == nil)
    }

    @Test func browsingTheSiteSignedOutKeepsTheNoteAndTheButtonThroughTheRead() async throws {
        LiveFolders.shared.signInGap = 0.5
        let id = asking(single: false)
        let reads = held()
        let folded = try await heading(id, collapsed: true)
        let live = LiveFolders.shared
        let repository = URL(string: "https://github.com/octocorp/ios")!
        let search = URL(string: "https://www.google.com/search?q=octocorp+ios")!
        let landings: [(URL, LiveArrival?)] = [
            (listPage, LiveArrival(from: provider, type: .other, asked: true)),
            (pullPage, LiveArrival(from: listPage, type: .linkActivated)),
            (repository, LiveArrival(from: search, type: .linkActivated, redirected: true)),
            (listPage, LiveArrival(from: repository, type: .formSubmitted, redirected: true)),
            (pullPage, LiveArrival(from: provider, type: .backForward)),
            (repository, nil),
        ]
        var seen: [(LiveFolder.State?, LiveFolder.Note?, Bool)] = []
        let look = {
            folded.layoutSubtreeIfNeeded()
            seen.append((self.folder(id)?.state, self.folder(id)?.note, (folded.status as? LiveStatusView)?.pill != nil))
        }

        for (page, arrival) in landings {
            live.cameBack(to: page, space: space, through: arrival)
            look()
        }
        await until { reads.count == 1 }
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
            look()
        }
        reads.answer(.signIn)
        try await Task.sleep(for: .milliseconds(60))
        for (page, arrival) in landings {
            live.cameBack(to: page, space: space, through: arrival)
            look()
        }
        try await Task.sleep(for: .milliseconds(150))
        let inTheGap = reads.count
        await until { reads.count == 2 }
        look()
        reads.answer(.signIn)
        try await Task.sleep(for: .milliseconds(60))
        look()

        #expect(seen.allSatisfy { $0.0 == .signIn && $0.1 == .signIn && $0.2 })
        #expect(inTheGap == 1)
        #expect(reads.count == 2)
        #expect((reads.starts.last ?? .distantPast).timeIntervalSince(reads.starts.first ?? .distantFuture) >= 0.45)
        #expect(folder(id)?.items.map(\.title) == kept.map(\.title))
    }

    @Test func anOrdinaryTabBackFromAnotherHostAfterASignOnLoadsAtOnce() async throws {
        let id = asking()
        let reads = held()
        let live = LiveFolders.shared

        live.cameBack(to: signOnPage, space: space, through: LiveArrival(from: listPage, type: .linkActivated))
        try await Task.sleep(for: .milliseconds(100))
        let onTheSignOn = (folder(id)?.state, reads.count)
        let left = Date()
        live.cameBack(to: listPage, space: space, through: LiveArrival(from: provider, type: .formSubmitted, redirected: true))
        let after = try #require(folder(id))
        await until { reads.count == 1 }
        let started = reads.starts.first.map { $0.timeIntervalSince(left) } ?? 99

        #expect(onTheSignOn.0 == .signIn && onTheSignOn.1 == 0)
        #expect(after.state == .waiting)
        #expect(after.note == nil)
        #expect(after.sso == nil)
        #expect(after.items.map(\.title) == kept.map(\.title))
        #expect(started < 0.5)

        reads.answer(.items([fresh], nil))
        await until { self.folder(id)?.state == .fine }

        #expect(folder(id)?.items.map(\.title) == ["Fresh"])
    }

    @Test func whatCountsAsComingThroughASignIn() {
        let login = URL(string: "https://github.com/login?return_to=%2Fpulls")!
        let search = URL(string: "https://www.google.com/search?q=github")!
        let through: [LiveArrival] = [
            LiveArrival(from: provider, type: .formSubmitted, redirected: true),
            LiveArrival(from: provider, type: .formSubmitted),
            LiveArrival(from: provider, type: .other),
            LiveArrival(from: signOnPage, type: .linkActivated, redirected: true),
            LiveArrival(from: login, type: .formSubmitted, redirected: true),
            LiveArrival(from: consume, type: .other),
            .signOnTab,
        ]
        let ordinary: [LiveArrival] = [
            LiveArrival(),
            LiveArrival(from: provider, type: .other, asked: true),
            LiveArrival(from: provider, type: .other, asked: true, redirected: true),
            LiveArrival(from: provider, type: .linkActivated),
            LiveArrival(from: search, type: .linkActivated, redirected: true),
            LiveArrival(from: login, type: .linkActivated),
            LiveArrival(from: pullPage, type: .formSubmitted, redirected: true),
            LiveArrival(from: listPage, type: .other),
            LiveArrival(from: provider, type: .backForward, redirected: true),
            LiveArrival(from: provider, type: .reload),
            LiveArrival(from: nil, type: .formSubmitted, redirected: true),
        ]

        #expect(through.map { $0.signsIn(to: .pullRequests) } == through.map { _ in true })
        #expect(ordinary.map { $0.signsIn(to: .pullRequests) } == ordinary.map { _ in false })
        #expect(LiveArrival(from: URL(string: "https://accounts.google.com/signin")!, type: .other)
            .signsIn(to: .subscriptions))
    }
}
