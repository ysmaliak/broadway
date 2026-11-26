import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PullSignsTests {
    private var browser: Browser!
    private let pull = "https://github.com/acme/rocket/pull/412"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.liveFolders = true
        LiveRefs.known = [:]
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
    }

    private func tearDown() async {
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        LiveRefs.known = [:]
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    private func said(_ who: String, _ minutes: Double, bot: Bool = false, asks: Bool = false) -> PullSigns.Said {
        PullSigns.Said(at: at(minutes), who: who, bot: bot, asks: asks)
    }

    private static func stamp(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format.string(from: date)
    }

    private func author(_ who: String, _ minutes: Double) -> String {
        let href = who.hasPrefix("bot:") ? "/apps/\(who.dropFirst(4))" : "/\(who)"
        return """
        <a class="author Link--primary text-bold css-overflow-wrap-anywhere " show_full_name="false" data-hovercard-type="user" href="\(href)">\(who)</a>
        <span class="color-fg-muted"><a href="#c" class="js-timestamp Link--secondary"><relative-time datetime="\(Self.stamp(at(minutes)))" class="no-wrap">Nov 12</relative-time></a></span>
        """
    }

    private func comment(_ who: String, _ minutes: Double) -> String {
        """
        <div class="js-timeline-item js-timeline-progressive-focus-container" data-gid="IC_kwDO\(Int(minutes))">
        <div class="TimelineItem js-comment-container"><div class="timeline-comment-header">\(author(who, minutes))</div>
        <div class="comment-body markdown-body js-comment-body"><p>Looks off by one, <a class="user-mention" href="/octo-sam">@octo-sam</a></p></div></div></div>
        """
    }

    private func thread(resolved: Bool, _ comments: [(String, Double)]) -> String {
        """
        <turbo-frame id="review-thread-or-comment-id-\(comments.first.map { Int($0.1) } ?? 0)" target="_top">
        <review-thread-collapsible
              class="review-thread-component js-comment-container js-resolvable-timeline-thread-container"
              data-resolved="\(resolved)"
            >
        <a href="/acme/rocket/pull/412/files#diff-1" class="text-mono text-small Link--primary">Sources/Feed.swift</a>
        <div class="js-comments-holder">\(comments.map { author($0.0, $0.1) + "<div class=\"comment-body\">Why?</div>" }.joined())</div>
        </review-thread-collapsible></turbo-frame>
        """
    }

    private func review(_ who: String, _ minutes: Double, changes: Bool = false, threads: [String]) -> String {
        """
        <div class="js-timeline-item js-timeline-progressive-focus-container" data-gid="PRR_kwDO\(Int(minutes))">
        <div class="TimelineItem"><div class="TimelineItem-body">\(author(who, minutes)) \(changes ? "requested changes" : "reviewed")</div></div>
        <div class="TimelineItem"><div class="TimelineItem-body">\(threads.joined())</div></div></div>
        """
    }

    private func commit(_ who: String) -> String {
        """
        <div class="js-timeline-item js-timeline-progressive-focus-container" data-gid="C_kwDOcommit">
        <a class="avatar avatar-user" data-test-selector="commits-avatar-stack-avatar-link" data-hovercard-type="user" href="/\(who)"><img alt="@\(who)"></a>
        <a title="Fix the feed" class="Link--secondary markdown-title" href="/acme/rocket/pull/412/commits/abc">Fix the feed</a></div>
        """
    }

    private func page(viewer: String = "octo-sam", opener: String = "octo-sam", _ items: [String]) -> String {
        """
        <!doctype html><html><head><meta name="user-login" content="\(viewer)"></head><body>
        <div class="timeline-comment"><div class="timeline-comment-header">\(author(opener, 0))</div></div>
        <div id="partial-timeline">\(items.joined(separator: "\n"))</div>
        <div id="discussion-timeline-actions"><a class="author" href="/sidebar-person">sidebar</a><relative-time datetime="\(Self.stamp(at(999)))"></relative-time></div>
        </body></html>
        """
    }

    @Test func theNewestChangeBySomeoneElseIsActivityAndYoursOrABotsIsNot() {
        let theirs = PullSigns.read([said("octo-sam", 1), said("dana", 5)], threads: [], viewer: "Octo-Sam")
        let yours = PullSigns.read([said("dana", 5), said("octo-sam", 6)], threads: [], viewer: "octo-sam")
        let botAfter = PullSigns.read([said("dana", 5), said("octo-sam", 6), said("cursor", 9, bot: true)], threads: [], viewer: "octo-sam")
        let reply = PullSigns.read([said("octo-sam", 6)], threads: [PullSigns.Thread(resolved: true, said: [said("lee", 8)])], viewer: "octo-sam")

        #expect(theirs.activity == at(5))
        #expect(yours.activity == nil)
        #expect(botAfter.activity == nil)
        #expect(reply.activity == at(8))
    }

    @Test func anOpenThreadWaitsUntilYouReplyOrResolveIt() {
        let open = PullSigns.Thread(resolved: false, said: [said("octo-sam", 1), said("dana", 4)])
        let answered = PullSigns.Thread(resolved: false, said: [said("dana", 2), said("octo-sam", 3)])
        let resolved = PullSigns.Thread(resolved: true, said: [said("lee", 5)])
        let botOnly = PullSigns.Thread(resolved: false, said: [said("copilot-pull-request-reviewer", 6, bot: true)])
        let botAfterYou = PullSigns.Thread(resolved: false, said: [said("dana", 2), said("octo-sam", 3), said("cursor", 7, bot: true)])

        let read = PullSigns.read([said("octo-sam", 10)], threads: [open, answered, resolved, botOnly, botAfterYou], viewer: "octo-sam")

        #expect(read.unanswered == 1)
    }

    @Test func aCommentWaitsUntilYouCommentReviewOrPushAfterIt() {
        let comments = [said("dana", 2, asks: true), said("lee", 6, asks: true), said("codecov", 7, bot: true, asks: true)]

        let before = PullSigns.read(comments, threads: [], viewer: "octo-sam")
        let between = PullSigns.read(comments + [said("octo-sam", 4)], threads: [], viewer: "octo-sam")
        let after = PullSigns.read(comments + [said("octo-sam", 8)], threads: [], viewer: "octo-sam")

        #expect(before.unanswered == 2)
        #expect(between.unanswered == 1)
        #expect(after.unanswered == 0)
    }

    @Test func onSomeoneElsesPullRequestOnlyTalkYouAreInWaitsOnYou() {
        let theirs = PullSigns.Thread(resolved: false, said: [said("lee", 1), said("dana", 2)])
        let yours = PullSigns.Thread(resolved: false, said: [said("octo-sam", 3), said("dana", 4)])

        let joined = PullSigns.read([said("dana", 5, asks: true)], threads: [theirs, yours], viewer: "octo-sam", author: "dana")
        let never = PullSigns.read([said("dana", 5, asks: true)], threads: [theirs], viewer: "octo-sam", author: "dana")

        #expect(joined.unanswered == 2)
        #expect(never.unanswered == 0)
    }

    @Test func thePullRequestPageGivesActivityAndOpenThreads() throws {
        let html = page([
            comment("dana", 2),
            review("lee", 3, changes: true, threads: [
                thread(resolved: false, [("lee", 3), ("octo-sam", 4)]),
                thread(resolved: false, [("lee", 3.5), ("octo-sam", 4.5), ("lee", 9)]),
                thread(resolved: true, [("lee", 3.6)]),
            ]),
            review("bot:copilot-pull-request-reviewer", 5, threads: [thread(resolved: false, [("bot:copilot-pull-request-reviewer", 5)])]),
            commit("octo-sam"),
            comment("bot:codecov", 7),
        ])

        let talk = try #require(PullSigns.page(html))
        let read = PullSigns.read(talk)

        #expect(talk.viewer == "octo-sam")
        #expect(talk.author == "octo-sam")
        #expect(talk.threads.map(\.resolved) == [false, false, true, false])
        #expect(talk.said.contains { $0.who == "copilot-pull-request-reviewer" && $0.bot })
        #expect(talk.said.contains { $0.who == "octo-sam" && $0.at == at(5).addingTimeInterval(1) })
        #expect(!talk.said.contains { $0.who == "sidebar-person" })
        #expect(read.activity == at(9))
        #expect(read.unanswered == 1)
    }

    private func spoke(_ who: String, _ minutes: Double, _ kind: PullSigns.Kind = .word, bot: Bool = false) -> PullSigns.Said {
        PullSigns.Said(at: at(minutes), who: who, bot: bot, kind: kind)
    }

    private func reviewed(_ said: [PullSigns.Said], threads: [PullSigns.Thread] = []) -> PullSigns.Talk {
        PullSigns.Talk(said: [spoke("octo-sam", 1, .review)] + said, threads: threads, viewer: "octo-sam", author: "dana")
    }

    @Test func aReviewThenAnAuthorPushIsBack() {
        #expect(PullSigns.read(reviewed([spoke("dana", 2, .push)])).back)
    }

    @Test func aReviewThenAnAuthorReplyIsBack() {
        let reply = PullSigns.Thread(resolved: false, said: [spoke("octo-sam", 1), spoke("dana", 3)])

        #expect(PullSigns.read(reviewed([], threads: [reply])).back)
    }

    @Test func aReviewThenAThirdPersonsCommentIsNotBack() {
        #expect(!PullSigns.read(reviewed([spoke("lee", 2)])).back)
    }

    @Test func aPushBySomeoneOtherThanTheAuthorIsBack() {
        #expect(PullSigns.read(reviewed([spoke("lee", 2, .push)])).back)
    }

    @Test func anApprovalThenAPushIsNotBack() {
        let talk = PullSigns.Talk(said: [spoke("octo-sam", 1, .approval), spoke("dana", 2, .push)], viewer: "octo-sam", author: "dana")

        #expect(!PullSigns.read(talk).back)
    }

    @Test func requestedChangesThenTheReviewersThreadsResolvedIsBack() {
        let open = PullSigns.Thread(resolved: false, said: [spoke("octo-sam", 1)], id: "41")
        let closed = PullSigns.Thread(resolved: true, said: [], id: "41")
        let before = reviewed([], threads: [open])
        let after = reviewed([], threads: [closed])

        let first = PullSigns.seen(before, before: nil, at: at(2))
        let second = PullSigns.seen(after, before: first, at: at(9))
        let read = PullSigns.read(after, seen: second)

        #expect(!PullSigns.read(before, seen: first).back)
        #expect(read.back)
        #expect(read.activity == at(9))
    }

    @Test func aThreadAlreadyResolvedAtTheFirstReadIsNotBack() {
        let talk = reviewed([], threads: [PullSigns.Thread(resolved: true, said: [spoke("octo-sam", 1)], id: "41")])

        #expect(!PullSigns.read(talk, seen: PullSigns.seen(talk, before: nil, at: at(9))).back)
    }

    @Test func aResolvedThreadWhereTheReviewerDidNotSpeakLastIsNotBack() {
        let open = PullSigns.Thread(resolved: false, said: [spoke("octo-sam", 1), spoke("lee", 1.5)], id: "41")
        let first = PullSigns.seen(reviewed([spoke("octo-sam", 1.8)], threads: [open]), before: nil, at: at(2))
        let after = reviewed([spoke("octo-sam", 1.8)], threads: [PullSigns.Thread(resolved: true, said: [], id: "41")])

        #expect(!PullSigns.read(after, seen: PullSigns.seen(after, before: first, at: at(9))).back)
    }

    @Test func aBotAloneIsNotBack() {
        let bot = PullSigns.Thread(resolved: false, said: [spoke("octo-sam", 1), spoke("copilot", 3, bot: true)])

        #expect(!PullSigns.read(reviewed([spoke("dependabot", 2, .push, bot: true), spoke("codecov", 3, bot: true)], threads: [bot])).back)
    }

    @Test func theReviewersReplyEndsIt() {
        #expect(!PullSigns.read(reviewed([spoke("dana", 2, .push), spoke("dana", 3), spoke("octo-sam", 4)])).back)
    }

    @Test func yourOwnPullRequestIsNeverBack() {
        let talk = PullSigns.Talk(said: [spoke("octo-sam", 1, .review), spoke("dana", 2, .push)], viewer: "octo-sam", author: "octo-sam")

        #expect(!PullSigns.read(talk).back)
    }

    @Test func thePageTellsReviewsApprovalsPushesAndThreads() throws {
        let approval = """
        <div class="js-timeline-item js-timeline-progressive-focus-container" data-gid="PRR_kwDOapproved">
        <div class="TimelineItem"><div class="TimelineItem-body"><strong>\(author("lee", 3))</strong> approved these changes</div></div></div>
        """
        let pushed = """
        <div class="js-timeline-item js-timeline-progressive-focus-container" data-gid="C_kwDOpushed">
        <div class="TimelineItem-body"><a class="author Link--primary text-bold" data-hovercard-type="user" href="/dana">dana</a> added <span>2</span> commits
        <a href="#commits-pushed-1"><relative-time tense="past" datetime="\(Self.stamp(at(8)))">Nov 12</relative-time></a></div></div>
        """
        let folded = """
        <turbo-frame id="review-thread-or-comment-id-777" target="_top">
        <review-thread-collapsible class="review-thread-component js-comment-container" data-resolved="true"
            data-deferred-content-url="/acme/rocket/pull/412/threads/777?rendering_on_files_tab=false"></review-thread-collapsible></turbo-frame>
        """
        let html = page(opener: "dana", [review("octo-sam", 2, changes: true, threads: [thread(resolved: false, [("octo-sam", 2)]), folded]),
                                         approval, pushed])

        let talk = try #require(PullSigns.page(html))

        #expect(talk.said.map(\.kind) == [.review, .approval, .push])
        #expect(talk.said.last?.at == at(8))
        #expect(talk.threads.map(\.id) == ["2", "777"])
        #expect(talk.threads.last?.said.isEmpty == true)
        #expect(PullSigns.read(talk).back)
    }

    private func forcePushed(_ who: String, _ minutes: Double) -> String {
        """
        <div id="event-\(Int(minutes))" class="TimelineItem js-targetable-element"><div class="TimelineItem-body"><div class="d-flex">
        <a class="d-inline-block" data-test-selector="pr-timeline-events-actor-avatar" data-hovercard-type="user" href="/\(who)"><img class="avatar avatar-user" alt="@\(who)"></a>
        <div class="flex-auto"><a class="author Link--primary text-bold" data-test-selector="pr-timeline-events-actor-profile-link" data-hovercard-type="user" href="/\(who)">\(who)</a>
        <a href="/acme/rocket/compare/1a2b3c4..5d6e7f8" class="Link--inTextBlock Link--secondary Link">force-pushed</a> the <span class="commit-ref"><span class="css-truncate-target">retry-uploads</span></span>
        branch from <a href="/acme/rocket/commit/1a2b3c4" class="Link--primary Link text-bold"><code>1a2b3c4</code></a> to <a href="/acme/rocket/commit/5d6e7f8" class="Link--primary Link text-bold"><code>5d6e7f8</code></a>
        <a href="#event-\(Int(minutes))" class="Link--secondary Link"><relative-time tense="past" datetime="\(Self.stamp(at(minutes)))">Nov 12</relative-time></a></div></div></div></div>
        """
    }

    private func forcePush(_ who: String, _ minutes: Double) -> String {
        """
        <div class="js-timeline-item js-timeline-progressive-focus-container" data-gid="HRFPE_kwDO\(Int(minutes))">
        \(forcePushed(who, minutes))</div>
        """
    }

    private func movedThenForcePushed(_ who: String, _ minutes: Double) -> String {
        """
        <div class="js-timeline-item js-timeline-progressive-focus-container" data-gid="PVTISC_kwDO\(Int(minutes))">
        <div class="TimelineItem js-targetable-element"><div class="TimelineItem-body">\(author(who, minutes - 1)) moved this from <strong>New</strong> to <strong>In review</strong></div></div>
        \(forcePushed(who, minutes))</div>
        """
    }

    @Test func aReviewThenAForcePushByTheAuthorAndNothingElseIsBack() throws {
        let talk = try #require(PullSigns.page(page(opener: "dana", [review("octo-sam", 2, changes: true, threads: []), forcePush("dana", 5)])))

        #expect(talk.said.map(\.kind) == [.review, .push])
        #expect(talk.said.last?.at == at(5))
        #expect(PullSigns.read(talk).back)
    }

    @Test func aForcePushGroupedAfterAnotherEventStillCountsAsAPush() throws {
        let talk = try #require(PullSigns.page(page(opener: "dana", [review("octo-sam", 2, changes: true, threads: []), movedThenForcePushed("dana", 5)])))

        #expect(talk.said.map(\.kind) == [.review, .event, .push])
        #expect(PullSigns.read(talk).back)
    }

    @Test func aForcePushByTheReviewerThemselfIsNotBack() throws {
        let talk = try #require(PullSigns.page(page(opener: "dana", [review("octo-sam", 2, changes: true, threads: []), forcePush("octo-sam", 5)])))

        #expect(!PullSigns.read(talk).back)
    }

    @Test func aBotsForcePushIsNotBack() throws {
        let talk = try #require(PullSigns.page(page(opener: "dana", [review("octo-sam", 2, changes: true, threads: []), forcePush("apps/renovate", 5)])))

        #expect(talk.said.last?.bot == true)
        #expect(!PullSigns.read(talk).back)
    }

    @Test func aPageWithNoViewerOrNoTimelineGivesNoSigns() {
        #expect(PullSigns.page(page(viewer: "", [comment("dana", 2)])) == nil)
        #expect(PullSigns.page("<html><meta name=\"user-login\" content=\"octo-sam\"><body>Sign in to GitHub</body></html>") == nil)
        let quiet = PullSigns.page("<meta name=\"user-login\" content=\"octo-sam\"><div id=\"discussion-timeline-actions\"></div>")
        #expect(quiet.map(PullSigns.read) == PullSigns.Read(activity: nil, unanswered: 0))
    }

    private func served(_ html: String, counter: Hits) -> @Sendable (URL) async -> (Data, Int)? {
        { url in
            await counter.add(url)
            return (Data(html.utf8), 200)
        }
    }

    private actor Hits {
        var count = 0
        func add(_ url: URL) { count += 1 }
    }

    private func open(_ updated: Date) -> LiveItem {
        LiveItem(key: pull, title: "Retry", updated: updated)
    }

    @Test func thePagesSignsRideAlongWithItsBranchAndAreKept() async {
        let html = page([comment("dana", 2)]).replacingOccurrences(of: "<body>",
            with: #"<body><script type="application/json">{"baseBranch":"main","headBranch":"retry"}</script>"#)
        let hits = Hits()

        let first = await LiveRefs.filled([open(at(3))], previous: [], at: at(3), fetch: served(html, counter: hits))
        let again = await LiveRefs.filled([open(at(3))], previous: first, at: at(4), fetch: served(html, counter: hits))
        LiveRefs.known = [:]
        let launched = await LiveRefs.filled([open(at(3))], previous: first, at: at(5), fetch: served(html, counter: hits))

        #expect(await hits.count == 1)
        for read in [first, again, launched] {
            #expect(read.first?.activity == at(2))
            #expect(read.first?.unanswered == 1)
            #expect(read.first?.signsRead == true)
            #expect(read.first?.branch?.head == "retry")
        }
    }

    @Test func aRowReadBeforeSignsIsReadOnceMoreAndOpenTalkIsCheckedAgainLater() async {
        let html = page([comment("dana", 2)]).replacingOccurrences(of: "<body>",
            with: #"<body><script type="application/json">{"baseBranch":"main","headBranch":"retry"}</script>"#)
        var old = open(at(3))
        old.branch = LiveBranch(repository: "acme/rocket", base: "main", head: "retry", stackRead: true)
        let hits = Hits()

        let upgraded = await LiveRefs.filled([open(at(3))], previous: [old], at: at(3), fetch: served(html, counter: hits))
        _ = await LiveRefs.filled([open(at(3))], previous: upgraded, at: at(5), fetch: served(html, counter: hits))
        _ = await LiveRefs.filled([open(at(3))], previous: upgraded, at: at(14), fetch: served(html, counter: hits))

        #expect(upgraded.first?.signsRead == true)
        #expect(await hits.count == 2)
    }

    @Test func theFirstSignsOfARowYouOpenedAfterThemStayQuiet() {
        var folder = LiveFolder(space: UUID(), name: "PRs", source: .pullRequests)
        folder.state = .fine
        folder.noticing = true
        let seen = "https://github.com/acme/rocket/pull/1"
        folder.items = [LiveItem(key: pull, title: "Retry", opened: at(1)), LiveItem(key: seen, title: "Seen", opened: at(10))]
        func signed(_ key: String, _ minutes: Double) -> LiveItem {
            LiveItem(key: key, title: key, activity: at(minutes), signsRead: true)
        }

        let next = LiveMerge.merged(folder, fetched: [signed(pull, 5), signed(seen, 5)], now: at(20))
        let later = LiveMerge.merged(next, fetched: [signed(pull, 5), signed(seen, 30)], now: at(40))

        #expect(next.items.map(\.fresh) == [true, false])
        #expect(later.items.map(\.fresh) == [true, true])
    }

    @Test func onlyTheTabInFrontOfAWindowOnScreenSeesThePage() throws {
        let made = LiveFolders.shared.add(name: "PRs", source: .reviewRequests, space: browser.spaceID)
        LiveFolders.shared.apply(.items([LiveItem(key: pull, title: "Retry", activity: at(1))], nil), to: made.id, now: at(1))
        LiveFolders.shared.apply(.items([LiveItem(key: pull, title: "Retry", activity: at(2))], nil), to: made.id, now: at(3))
        let url = try #require(URL(string: pull + "/files"))
        browser.sightForBench = true
        let front = browser.open(try #require(URL(string: "https://example.com/")), foreground: true)
        let behind = browser.open(url, foreground: false)

        browser.liveTabLanded(behind, at: url)
        let afterBehind = LiveFolders.shared.folder(made.id)?.items.first?.fresh
        browser.sightForBench = false
        browser.liveMoved(front, at: url)
        let afterHidden = LiveFolders.shared.folder(made.id)?.items.first?.fresh
        browser.sightForBench = true
        browser.liveMoved(front, at: url)

        #expect(afterBehind == true)
        #expect(afterHidden == true)
        #expect(LiveFolders.shared.folder(made.id)?.items.first?.fresh == false)
    }

    @Test func theRowShowsTheBubbleWithItsCountBesideTheDot() throws {
        let made = LiveFolders.shared.add(name: "PRs", source: .reviewRequests, space: browser.spaceID)
        let two = "https://github.com/acme/rocket/pull/2"
        LiveFolders.shared.apply(.items([LiveItem(key: pull, title: "One", unanswered: 1), LiveItem(key: two, title: "Two", unanswered: 3),
                                         LiveItem(key: "https://github.com/acme/rocket/pull/3", title: "Three")], nil), to: made.id, now: at(1))
        browser.syncLive()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: 600), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        browser.sightForBench = true
        browser.unfoldFolder(made.id)
        let column = SideColumnView(browser: browser)
        window.contentView = column
        column.layoutSubtreeIfNeeded()

        let marks = column.kitSubviews(of: TalkMarkView.self).filter { $0.window != nil }

        #expect(marks.compactMap { $0.accessibilityLabel() }.sorted() == ["1 unanswered comment", "3 unanswered comments"])
        let rows = column.kitSubviews(of: TabRowView.self).filter { $0.window != nil }
        for mark in marks {
            let row = try #require(rows.first { mark.isDescendant(of: $0) })
            let frame = mark.convert(mark.bounds, to: row)
            #expect(abs(frame.maxX - TalkPlace.crossRight(width: row.bounds.width, height: row.bounds.height)) <= 0.5)
            #expect(abs(frame.midY - row.bounds.midY) <= 1)
        }
        window.close()
    }
}
