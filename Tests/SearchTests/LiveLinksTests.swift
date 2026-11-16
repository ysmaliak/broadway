import Foundation
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5)))
@MainActor
struct LiveLinksTests {
    private let home = UUID()
    private let work = UUID()
    private let prs = UUID()
    private let workPRs = UUID()
    private let reviews = UUID()

    private func url(_ text: String) -> URL { URL(string: text)! }

    private func same(_ asked: String, _ key: String, _ kind: LiveSource.Kind) -> Bool {
        LiveLinks.same(url(asked), as: key, in: kind)
    }

    private func row(_ key: String, in folder: UUID, _ name: String = "PRs", space: UUID, kind: LiveSource.Kind = .pullRequests) -> LinkWorld.Row {
        LinkWorld.Row(folder: folder, name: name, space: space, kind: kind, key: key)
    }

    private func world(_ rows: [LinkWorld.Row], front: UUID? = nil) -> LinkWorld {
        var world = LinkWorld()
        world.spaces = [LinkWorld.Space(id: home, name: "Home"), LinkWorld.Space(id: work, name: "Work")]
        world.front = front ?? home
        world.apps = ["com.google.Chrome"]
        world.broadway = "com.officecommun.search"
        world.rows = rows
        return world
    }

    private func decide(_ text: String, _ rules: [LinkRule] = [], settings: LinkSettings = LinkSettings(), world: LinkWorld,
                        source: IncomingLink.Source = .unknownApp, chooses: Bool = false, behind: Bool = false,
                        seats: [IncomingLink.Seat] = []) -> LinkDecision {
        LinkRouter.decide(IncomingLink(url: url(text), source: source, chooses: chooses, behind: behind, seats: seats),
                          rules: rules, settings: settings, world: world)
    }

    private var page: IncomingLink.Source { .page(space: home, site: "example.com") }

    private let pull = "https://github.com/acme/rocket/pull/123"

    @Test func aPullRequestIsItsRepositoryAndNumberWhateverPageOfIt() {
        let asked = [
            "https://github.com/acme/rocket/pull/123",
            "https://github.com/acme/rocket/pull/123/",
            "https://github.com/acme/rocket/pull/123/files",
            "https://github.com/acme/rocket/pull/123/changes",
            "https://github.com/acme/rocket/pull/123/commits/0a1b2c3",
            "https://github.com/acme/rocket/pull/123/checks?check_run_id=9",
            "https://github.com/acme/rocket/pull/123#issuecomment-4411",
            "https://github.com/acme/rocket/pull/123/files?diff=split&w=1#diff-abc",
            "https://www.github.com/Acme/Rocket/pull/123",
            "http://github.com/acme/rocket/pull/123",
            "https://github.com/acme/rocket/issues/123",
        ]
        let others = [
            "https://github.com/acme/rocket/pull/1234",
            "https://github.com/acme/rocket/pull/12",
            "https://github.com/acme/other/pull/123",
            "https://github.com/acme/rocket/pulls",
            "https://github.com/acme/rocket",
            "https://gitlab.com/acme/rocket/pull/123",
            "https://github.com.evil.example/acme/rocket/pull/123",
            "mailto:acme/rocket/pull/123",
        ]

        for kind in [LiveSource.Kind.pullRequests, .repository, .notifications] {
            for text in asked { #expect(same(text, pull, kind), "\(text) in \(kind)") }
            for text in others { #expect(!same(text, pull, kind), "\(text) in \(kind)") }
        }
        #expect(same("https://github.com/acme/rocket/issues/7#issuecomment-1", "https://github.com/acme/rocket/issues/7", .issues))
        #expect(!same("https://github.com/acme/rocket/issues/8", "https://github.com/acme/rocket/issues/7", .issues))
    }

    @Test func aNotificationThatIsNotNumberedIsOnlyItsOwnPage() {
        let repository = "https://github.com/acme/rocket"
        let commit = "https://github.com/acme/rocket/commit/0a1b2c3"

        #expect(same("https://github.com/acme/rocket/", repository, .notifications))
        #expect(!same("https://github.com/acme/rocket/pull/5", repository, .notifications))
        #expect(!same("https://github.com/acme/rocket/releases", repository, .notifications))
        #expect(same("https://github.com/acme/rocket/commit/0a1b2c3#diff-1", commit, .notifications))
        #expect(!same("https://github.com/acme/rocket/commit/ffff", commit, .notifications))
    }

    @Test func aLinearIssueIsItsIdentifierWithAnyTitleOrNone() {
        let issue = "https://linear.app/acme/issue/ENG-212/fix-the-upload-retry"

        #expect(same("https://linear.app/acme/issue/ENG-212", issue, .linear))
        #expect(same("https://linear.app/acme/issue/eng-212/renamed-since#comment-9f", issue, .linear))
        #expect(same("https://linear.app/acme/issue/ENG-212/fix-the-upload-retry?noRedirect=1", issue, .linear))
        #expect(!same("https://linear.app/acme/issue/ENG-21", issue, .linear))
        #expect(!same("https://linear.app/acme/project/ENG-212", issue, .linear))
    }

    @Test func aVideoIsItsIdOnAnyOfYouTubesAddresses() {
        let video = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

        #expect(same("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s&list=PL1", video, .subscriptions))
        #expect(same("https://youtu.be/dQw4w9WgXcQ?t=42", video, .subscriptions))
        #expect(same("https://m.youtube.com/watch?v=dQw4w9WgXcQ", video, .subscriptions))
        #expect(same("https://www.youtube.com/shorts/dQw4w9WgXcQ", video, .subscriptions))
        #expect(same("https://www.youtube.com/live/dQw4w9WgXcQ?feature=share", video, .subscriptions))
        #expect(!same("https://www.youtube.com/watch?v=other", video, .subscriptions))
        #expect(!same("https://www.youtube.com/watch", video, .subscriptions))
        #expect(!same("https://vimeo.com/watch?v=dQw4w9WgXcQ", video, .subscriptions))
    }

    @Test func aFeedEntryIsItsAddressWithoutTrackingOrAFragment() {
        let entry = "https://blog.example.com/2026/routing/?utm_source=rss&id=7"

        for kind in [LiveSource.Kind.feed, .page] {
            #expect(same("https://blog.example.com/2026/routing?id=7", entry, kind))
            #expect(same("https://www.blog.example.com/2026/routing/?id=7&utm_medium=email#comments", entry, kind))
            #expect(!same("https://blog.example.com/2026/routing?id=8", entry, kind))
            #expect(!same("https://blog.example.com/2026/routing/more?id=7", entry, kind))
            #expect(!same("https://blog.example.com/2026?id=7", entry, kind))
        }
        #expect(!same("https://github.com/acme/rocket/pull/123/files", pull, .feed))
    }

    @Test func theSameThingToALinkIsTheSameThingToAFolder() {
        let keys: [(String, LiveSource.Kind)] = [
            ("https://github.com/acme/rocket/pull/123", .pullRequests),
            ("https://github.com/Acme/Rocket/pull/123/files", .pullRequests),
            ("https://github.com/acme/rocket/issues/123", .issues),
            ("https://github.com/acme/rocket/pull/124", .repository),
            ("https://github.com/acme/other/pull/123", .notifications),
            ("https://linear.app/acme/issue/ENG-212/fix-the-upload-retry", .linear),
            ("https://linear.app/acme/issue/eng-212", .linear),
            ("https://linear.app/acme/issue/ENG-213/another", .linear),
        ]

        for (first, kind) in keys {
            for (second, other) in keys where LiveSource(kind: kind, address: first).service == LiveSource(kind: other, address: second).service {
                let folder = LiveIdentity.of(first) == LiveIdentity.of(second)
                let link = LiveLinks.thing(url(first), in: kind) == LiveLinks.thing(url(second), in: kind)
                #expect(folder == link, "\(first) and \(second)")
            }
        }
    }

    @Test func theRowsPageShowsTheAddressOnlyWhenNothingWouldBeLost() {
        let files = url("https://github.com/acme/rocket/pull/123/files")
        let comment = url("https://github.com/acme/rocket/pull/123#issuecomment-4411")

        #expect(LiveLinks.shows(files, files))
        #expect(LiveLinks.shows(comment, url(pull)))
        #expect(LiveLinks.shows(comment, comment))
        #expect(!LiveLinks.shows(url(pull), comment))
        #expect(!LiveLinks.shows(url(pull), files))
        #expect(!LiveLinks.shows(url("https://github.com/acme/rocket/pull/123/files?w=1"), files))
        #expect(!LiveLinks.shows(nil, files))
    }

    @Test func aLinkToARowGoesToItsRowAndSaysSo() {
        let world = world([row(pull, in: prs, space: home)])

        let decision = decide("https://github.com/acme/rocket/pull/123/files?utm_source=slack#diff-1", world: world)

        #expect(decision.place == .row(pull, folder: prs, space: home))
        #expect(decision.url == url("https://github.com/acme/rocket/pull/123/files#diff-1"))
        #expect(decision.steps == ["Took the tracking parameters off", "Already in PRs", "Shown there"])
        #expect(decision.rule == nil)
        #expect(!decision.background)
    }

    @Test func aWrappedLinkIsReadBeforeItsRowIsLookedFor() {
        let world = world([row(pull, in: prs, space: home)])
        let wrapped = "https://slack-redir.net/link?url=https%3A%2F%2Fgithub.com%2Facme%2Frocket%2Fpull%2F123%2Fcommits%2Fabc"

        let decision = decide(wrapped, world: world)

        #expect(decision.place == .row(pull, folder: prs, space: home))
        #expect(decision.url == url("https://github.com/acme/rocket/pull/123/commits/abc"))
    }

    @Test func aLinkToSomethingNoFolderListsOpensTheOrdinaryWay() {
        let world = world([row(pull, in: prs, space: home)])
        let rule = LinkRule(match: .site("github.com"), target: .space(work, folder: nil))

        let gone = decide("https://github.com/acme/rocket/pull/99", world: world)
        let ruled = decide("https://github.com/acme/rocket/pull/99", [rule], world: world)
        let empty = decide(pull, world: self.world([]))

        #expect(gone.place == .here)
        #expect(gone.steps == ["Opens where you are"])
        #expect(ruled.place == .space(work, folder: nil))
        #expect(empty.place == .here)
    }

    @Test func theRowWinsOverARuleForAnotherSpace() {
        let world = world([row(pull, in: prs, space: home)])
        let rule = LinkRule(match: .site("github.com"), target: .space(work, folder: nil))

        let decision = decide(pull, [rule], world: world)

        #expect(decision.place == .row(pull, folder: prs, space: home))
        #expect(decision.rule == nil)
        #expect(decision.steps == ["Matched rule 1: github.com", "Already in PRs, so the rule doesn't move it", "Shown there"])
    }

    @Test func aRowInAnotherSpaceIsNamedWithItsSpace() {
        let world = world([row(pull, in: workPRs, space: work)])

        let decision = decide(pull, world: world)

        #expect(decision.place == .row(pull, folder: workPRs, space: work))
        #expect(decision.steps == ["Already in PRs in Work", "Shown there"])
    }

    @Test func ofTwoRowsTheSpaceInFrontWinsThenTheOneARuleNamesThenTheFirst() {
        let both = [row(pull, in: prs, space: home), row(pull, in: workPRs, space: work), row(pull, in: reviews, "Reviews", space: work)]
        let away = [row(pull, in: prs, space: home), row(pull, in: workPRs, space: work)]
        let elsewhere = UUID()
        let toWork = LinkRule(match: .site("github.com"), target: .space(work, folder: nil))

        let front = decide(pull, [toWork], world: world(both, front: work))
        let named = decide(pull, [toWork], world: world(away, front: elsewhere))
        let first = decide(pull, world: world(away, front: elsewhere))

        #expect(front.place == .row(pull, folder: workPRs, space: work))
        #expect(named.place == .row(pull, folder: workPRs, space: work))
        #expect(first.place == .row(pull, folder: prs, space: home))
    }

    @Test func aRuleForAnotherAppStillSendsTheLinkAway() {
        let world = world([row(pull, in: prs, space: home)])
        let rule = LinkRule(match: .site("github.com"), target: .app(bundleID: "com.google.Chrome", name: "Chrome"))

        let decision = decide(pull, [rule], world: world)

        #expect(decision.place == .app(bundleID: "com.google.Chrome", name: "Chrome"))
        #expect(decision.rule == rule.id)
    }

    @Test func aRuleThatAsksOrADefaultThatAsksDoesNotAskForARow() {
        let world = world([row(pull, in: prs, space: home)])
        let rule = LinkRule(match: .site("github.com"), target: .ask)
        var asking = LinkSettings()
        asking.outsideDefault = .ask

        let ruled = decide(pull, [rule], world: world)
        let byDefault = decide(pull, settings: asking, world: world)
        let other = decide("https://github.com/acme/rocket/pull/99", settings: asking, world: world)

        #expect(ruled.place == .row(pull, folder: prs, space: home))
        #expect(byDefault.place == .row(pull, folder: prs, space: home))
        #expect(other.place == .ask)
    }

    @Test func holdingOptionGoesToTheRowWithoutAsking() {
        let world = world([row(pull, in: prs, space: home)])
        let toWork = LinkRule(match: .site("github.com"), target: .space(work, folder: nil))

        let held = decide(pull + "/files?utm_source=slack", world: world, chooses: true)
        let ruled = decide(pull, [toWork], world: world, chooses: true)
        let unheld = decide(pull + "/files?utm_source=slack", world: world)

        #expect(held.place == .row(pull, folder: prs, space: home))
        #expect(held.url == url(pull + "/files"))
        #expect(held.steps == ["Took the tracking parameters off", "Already in PRs",
                               "⌥ was held, but a live folder has it, so you aren't asked", "Shown there"])
        #expect(ruled.place == .row(pull, folder: prs, space: home))
        #expect(ruled.rule == nil)
        #expect(unheld.place == held.place)
        #expect(unheld.steps == ["Took the tracking parameters off", "Already in PRs", "Shown there"])
    }

    @Test func holdingOptionStillChoosesForALinkWithNoRowOrOneThatLeavesBroadway() {
        let world = world([row(pull, in: prs, space: home)])
        let toChrome = LinkRule(match: .site("github.com"), target: .app(bundleID: "com.google.Chrome", name: "Chrome"))
        var rowless = LinkSettings()
        rowless.goesToLiveRow = false
        var keyless = LinkSettings()
        keyless.chooseKey = false

        let other = decide("https://github.com/acme/rocket/pull/99", world: world, chooses: true)
        let leaving = decide(pull, [toChrome], world: world, chooses: true)
        let switchedOff = decide(pull, settings: rowless, world: world, chooses: true)
        let keyOff = decide(pull, settings: keyless, world: world, chooses: true)

        #expect(other.place == .ask)
        #expect(other.steps == ["⌥ was held, so you choose", "Ask every time"])
        #expect(leaving.place == .ask)
        #expect(leaving.rule == nil)
        #expect(switchedOff.place == .ask)
        #expect(keyOff.place == .row(pull, folder: prs, space: home))
        #expect(keyOff.steps == ["Already in PRs", "Shown there"])
    }

    @Test func aBackgroundRuleKeepsTheRowBehind() {
        let world = world([row(pull, in: prs, space: home)])
        let rule = LinkRule(match: .site("github.com"), target: .frontSpace, background: true)

        let decision = decide(pull, [rule], world: world)

        #expect(decision.place == .row(pull, folder: prs, space: home))
        #expect(decision.background)
        #expect(decision.steps.last == "Its row goes there in the background")
    }

    @Test func aRulesChangedAddressIsWhatIsLookedForAndShown() {
        let world = world([row(pull, in: prs, space: home)])
        let split = LinkRule(match: .site("github.com"), target: .frontSpace, rewrite: LinkRule.Rewrite(find: "/files$", replace: "/files?w=1"))
        let away = LinkRule(match: .site("github.com"), target: .frontSpace,
                            rewrite: LinkRule.Rewrite(find: "^https://github\\.com/", replace: "https://mirror.example.com/"))

        let kept = decide(pull + "/files", [split], world: world)
        let left = decide(pull + "/files", [away], world: world)

        #expect(kept.place == .row(pull, folder: prs, space: home))
        #expect(kept.url == url(pull + "/files?w=1"))
        #expect(left.place == .here)
        #expect(left.url == url("https://mirror.example.com/acme/rocket/pull/123/files"))
    }

    @Test func aLinkOpenedInANewTabInsideBroadwayGoesToItsRowInFront() {
        let world = world([row(pull, in: prs, space: home)])
        let rule = LinkRule(match: .site("github.com"), target: .space(work, folder: nil))

        let plain = decide(pull + "/files?utm_source=slack#diff-1", world: world, source: page)
        let ruled = decide(pull, [rule], world: world, source: page)
        let other = decide("https://github.com/acme/rocket/pull/99", world: world, source: page)

        #expect(plain.place == .row(pull, folder: prs, space: home))
        #expect(plain.url == url(pull + "/files?utm_source=slack#diff-1"))
        #expect(!plain.background)
        #expect(plain.steps == ["Already in PRs", "Shown there"])
        #expect(ruled.place == .row(pull, folder: prs, space: home))
        #expect(ruled.rule == nil)
        #expect(ruled.steps == ["Matched rule 1: github.com", "Already in PRs, so the rule doesn't move it", "Shown there"])
        #expect(other.place == .here)
        #expect(other.steps == ["Opens as usual"])
    }

    @Test func aLinkOpenedBehindInsideBroadwayPointsItsRowInTheBackground() {
        let near = world([row(pull, in: prs, space: home)])
        let far = world([row(pull, in: workPRs, space: work)])
        let rule = LinkRule(match: .site("github.com"), from: .insideBroadway, target: .space(work, folder: nil))

        let here = decide(pull + "/files", world: near, source: page, behind: true)
        let away = decide(pull + "/files", world: far, source: page, behind: true)
        let ruled = decide("https://github.com/acme/rocket/pull/99", [rule], world: near, source: page, behind: true)

        #expect(here.place == .row(pull, folder: prs, space: home))
        #expect(here.background)
        #expect(here.steps == ["Already in PRs", "Its row goes there in the background"])
        #expect(LinkRouter.pointed(here.place, here: home, world: near) == "Opened in its row in PRs")
        #expect(away.place == .row(pull, folder: workPRs, space: work))
        #expect(away.background)
        #expect(away.steps == ["Already in PRs in Work", "Its row goes there in the background"])
        #expect(LinkRouter.pointed(away.place, here: home, world: far) == "Opened in its row in PRs in Work")
        #expect(ruled.place == .space(work, folder: nil))
        #expect(ruled.background)
    }

    @Test func aLinkToTheRowYouAreOnGetsATabOfItsOwn() {
        let both = world([row(pull, in: prs, space: home), row(pull, in: workPRs, space: work),
                          row("https://github.com/acme/rocket/pull/7", in: prs, space: home)])
        let seat = IncomingLink.Seat(kind: .pullRequests, key: pull)
        let rule = LinkRule(match: .site("github.com"), from: .insideBroadway, target: .space(work, folder: nil))

        let own = decide(pull + "/files#diff-1", world: both, source: page, behind: true, seats: [seat])
        let ruled = decide(pull + "/files", [rule], world: both, source: page, seats: [seat])
        let another = decide("https://github.com/acme/rocket/pull/7", world: both, source: page, seats: [seat])

        #expect(own.place == .here)
        #expect(own.steps == ["You're on its row, so it gets a tab of its own", "Opens as usual"])
        #expect(ruled.place == .space(work, folder: nil))
        #expect(ruled.rule == rule.id)
        #expect(another.place == .row("https://github.com/acme/rocket/pull/7", folder: prs, space: home))
    }

    @Test func theSwitchTurnsItOff() {
        let world = world([row(pull, in: prs, space: home)])
        var settings = LinkSettings()
        settings.goesToLiveRow = false

        let decision = decide(pull, settings: settings, world: world)
        let inside = decide(pull, settings: settings, world: world, source: page, behind: true)
        let saved = try? JSONDecoder().decode(LinkSettings.self, from: JSONEncoder().encode(settings))
        let older = try? JSONDecoder().decode(LinkSettings.self, from: Data("{}".utf8))

        #expect(decision.place == .here)
        #expect(inside.place == .here)
        #expect(saved?.goesToLiveRow == false)
        #expect(older?.goesToLiveRow == true)
    }
}
