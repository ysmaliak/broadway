import Foundation
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5)))
@MainActor
struct LinkRouterTests {
    private let work = UUID()
    private let home = UUID()
    private let reviews = UUID()
    private let window = UUID()
    private let page = UUID()

    private var world: LinkWorld {
        var world = LinkWorld()
        world.spaces = [
            LinkWorld.Space(id: home, name: "Home"),
            LinkWorld.Space(id: work, name: "Work", folders: [LinkWorld.Folder(id: reviews, name: "Reviews")]),
        ]
        world.front = home
        world.windows = [window]
        world.apps = ["us.zoom.xos"]
        world.broadway = "com.officecommun.search"
        return world
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    private func outside(_ text: String, from source: IncomingLink.Source = .unknownApp, chooses: Bool = false) -> IncomingLink {
        IncomingLink(url: url(text), source: source, chooses: chooses)
    }

    private func decide(_ link: IncomingLink, _ rules: [LinkRule], settings: LinkSettings = LinkSettings(), world: LinkWorld? = nil) -> LinkDecision {
        LinkRouter.decide(link, rules: rules, settings: settings, world: world ?? self.world)
    }

    private func toWork(_ match: LinkRule.Match, from: LinkRule.From = .anywhere) -> LinkRule {
        LinkRule(match: match, from: from, target: .space(work, folder: nil))
    }

    @Test func aSiteRuleTakesTheSiteAndEverySubdomainOnly() {
        let rule = toWork(.site("notion.so"))

        let sub = decide(outside("https://team.notion.so/x"), [rule])
        let bare = decide(outside("https://www.notion.so/"), [rule])
        let other = decide(outside("https://notnotion.so/"), [rule])

        #expect(sub.place == .space(work, folder: nil))
        #expect(bare.place == .space(work, folder: nil))
        #expect(other.place == .here)
        #expect(other.rule == nil)
    }

    @Test func aHostRuleTakesExactlyThatHost() {
        let rule = toWork(.host("docs.google.com"))

        #expect(decide(outside("https://docs.google.com/document/d/1"), [rule]).rule == rule.id)
        #expect(decide(outside("https://DOCS.google.com/"), [rule]).rule == rule.id)
        #expect(decide(outside("https://mail.google.com/"), [rule]).rule == nil)
        #expect(decide(outside("https://google.com/"), [rule]).rule == nil)
    }

    @Test func startsAndContainsReadTheAddressWithoutSchemeOrWWW() {
        let starts = toWork(.starts("https://www.GitHub.com/apple"))
        let contains = toWork(.contains("/pull/"))

        #expect(decide(outside("http://github.com/apple/swift"), [starts]).rule == starts.id)
        #expect(decide(outside("https://github.com/google/x"), [starts]).rule == nil)
        #expect(decide(outside("https://gitlab.com/a/pull/3"), [contains]).rule == contains.id)
        #expect(decide(outside("https://gitlab.com/a/PULL/3"), [contains]).rule == nil)
        #expect(LinkRouter.bare(url("https://WWW.Example.com:8080/A/b?q=1#top")) == "example.com:8080/A/b?q=1#top")
    }

    @Test func aPatternIsAnchoredAndStarCoversAnyRun() {
        let rule = toWork(.pattern("github.com/*/pull/*"))

        #expect(decide(outside("https://github.com/apple/swift/pull/12"), [rule]).rule == rule.id)
        #expect(decide(outside("https://www.github.com/a/pull/"), [rule]).rule == rule.id)
        #expect(decide(outside("https://github.com/apple/swift/issues/12"), [rule]).rule == nil)
        #expect(decide(outside("https://gist.github.com/a/pull/1"), [rule]).rule == nil)
    }

    @Test func aRegexReadsTheWholeAddressIgnoringCase() {
        let rule = toWork(.regex("^HTTPS://[a-z]+\\.zoom\\.us/j/\\d+"))

        #expect(decide(outside("https://acme.zoom.us/j/123?pwd=x"), [rule]).rule == rule.id)
        #expect(decide(outside("http://acme.zoom.us/j/123"), [rule]).rule == nil)
    }

    @Test func anExpressionThatDoesNotReadNeverMatchesAndSaysSo() {
        let rule = toWork(.regex("(unclosed"))
        let fine = toWork(.regex("zoom"))

        let decision = decide(outside("https://zoom.us/(unclosed"), [rule])

        #expect(decision.rule == nil)
        #expect(LinkRouter.broken(rule) == "The expression doesn't read")
        #expect(LinkRouter.broken(fine) == nil)
        #expect(LinkRouter.broken(toWork(.site(" "))) == "Nothing to match yet")
    }

    @Test func whereALinkCameFromDecidesWhichRulesApply() {
        let slack = IncomingLink.Source.app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        let mail = IncomingLink.Source.app(bundleID: "com.apple.mail", name: "Mail")
        let inside = IncomingLink.Source.page(space: home, site: "example.com")
        let anywhere = toWork(.site("a.com"), from: .anywhere)
        let others = toWork(.site("a.com"), from: .otherApps)
        let fromSlack = toWork(.site("a.com"), from: .app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"))
        let insideBroadway = toWork(.site("a.com"), from: .insideBroadway)
        let address = "https://a.com/"

        for source in [slack, mail, .unknownApp, inside] {
            #expect(decide(IncomingLink(url: url(address), source: source), [anywhere]).rule == anywhere.id)
        }
        #expect(decide(IncomingLink(url: url(address), source: slack), [others]).rule == others.id)
        #expect(decide(IncomingLink(url: url(address), source: .unknownApp), [others]).rule == others.id)
        #expect(decide(IncomingLink(url: url(address), source: inside), [others]).rule == nil)
        #expect(decide(IncomingLink(url: url(address), source: slack), [fromSlack]).rule == fromSlack.id)
        #expect(decide(IncomingLink(url: url(address), source: mail), [fromSlack]).rule == nil)
        #expect(decide(IncomingLink(url: url(address), source: .unknownApp), [fromSlack]).rule == nil)
        #expect(decide(IncomingLink(url: url(address), source: inside), [insideBroadway]).rule == insideBroadway.id)
        #expect(decide(IncomingLink(url: url(address), source: slack), [insideBroadway]).rule == nil)
    }

    @Test func theFirstMatchingRuleWinsAndOffRulesAreSkipped() {
        var off = LinkRule(match: .site("github.com"), target: .peek)
        off.on = false
        let narrow = LinkRule(match: .pattern("github.com/*/pull/*"), target: .space(work, folder: reviews))
        let broad = LinkRule(match: .site("github.com"), target: .window(nil))

        let pull = decide(outside("https://github.com/a/b/pull/1"), [off, narrow, broad])
        let other = decide(outside("https://github.com/a/b"), [off, narrow, broad])

        #expect(pull.rule == narrow.id)
        #expect(pull.place == .space(work, folder: reviews))
        #expect(pull.steps.contains("Matched rule 2: github.com/*/pull/*"))
        #expect(pull.steps.last == "Opens in Work › Reviews")
        #expect(other.rule == broad.id)
        #expect(other.place == .window(nil))
    }

    @Test func aRuleWhoseTargetIsGoneIsSkippedAndTheNextOneTried() {
        let gone = LinkRule(match: .site("a.com"), target: .space(UUID(), folder: nil))
        let closed = LinkRule(match: .site("a.com"), target: .window(UUID()))
        let missing = LinkRule(match: .site("a.com"), target: .app(bundleID: "com.figma.Desktop", name: "Figma"))
        let broadway = LinkRule(match: .site("a.com"), target: .app(bundleID: "com.officecommun.search", name: "Broadway"))
        let last = LinkRule(match: .site("a.com"), target: .peek)

        let decision = decide(outside("https://a.com"), [gone, closed, missing, broadway, last])

        #expect(decision.rule == last.id)
        #expect(decision.place == .peek)
        #expect(decision.steps.contains("Its space no longer exists. Trying the next rule."))
        #expect(decision.steps.contains("Its window is closed. Trying the next rule."))
        #expect(decision.steps.contains("Figma isn't installed. Trying the next rule."))
        #expect(decision.steps.contains("A rule can't send links to Broadway itself. Trying the next rule."))
    }

    @Test func anInstalledAppAndAnOpenWindowAreTargets() {
        let zoom = LinkRule(match: .site("zoom.us"), target: .app(bundleID: "us.zoom.xos", name: "Zoom"))
        let there = LinkRule(match: .site("a.com"), target: .window(window))

        #expect(decide(outside("https://acme.zoom.us/j/1"), [zoom]).place == .app(bundleID: "us.zoom.xos", name: "Zoom"))
        #expect(decide(outside("https://a.com"), [there]).place == .window(window))
    }

    @Test func aRuleForWhereTheLinkIsGoingAnywayStopsAndDoesNothingVisible() {
        let same = LinkRule(match: .site("a.com"), target: .space(home, folder: nil))
        let front = LinkRule(match: .site("a.com"), target: .frontSpace)
        let later = LinkRule(match: .site("a.com"), target: .window(nil))

        let here = decide(outside("https://a.com"), [same, later])
        let exception = decide(outside("https://a.com"), [front, later])

        #expect(here.rule == same.id)
        #expect(here.place == .here)
        #expect(exception.rule == front.id)
        #expect(exception.place == .here)
    }

    @Test func aFolderThatIsGoneOpensLoose() {
        let rule = LinkRule(match: .site("a.com"), target: .space(work, folder: UUID()))

        let decision = decide(outside("https://a.com"), [rule])

        #expect(decision.place == .space(work, folder: nil))
        #expect(decision.steps.contains("Its folder is gone, so it opened loose in Work"))
    }

    @Test func spacesTurnedOffSkipSpaceRules() {
        var flat = world
        flat.usesSpaces = false
        let rule = LinkRule(match: .site("a.com"), target: .space(work, folder: nil))

        let decision = decide(outside("https://a.com"), [rule], world: flat)

        #expect(decision.rule == nil)
        #expect(decision.place == .here)
    }

    @Test func whereItIsAlreadyOpenPicksTheMostRecentSpace() {
        var seen = world
        seen.open = ["linear.app": [work, home]]
        let rule = LinkRule(match: .site("linear.app"), target: .whereOpen)

        let open = decide(outside("https://linear.app/x"), [rule], world: seen)
        let notOpen = decide(outside("https://linear.app/x"), [rule])

        #expect(open.place == .space(work, folder: nil))
        #expect(notOpen.place == .here)
        #expect(notOpen.steps.contains("Not open in any space, so it opened where you are"))
    }

    @Test func aRewriteChangesTheAddressAndOneThatIsNotAWebAddressIsIgnored() {
        var rule = LinkRule(match: .site("twitter.com"), target: .frontSpace)
        rule.rewrite = LinkRule.Rewrite(find: "^https://(www\\.)?twitter\\.com/(.*)$", replace: "https://x.com/$2")
        var bad = LinkRule(match: .site("zoom.us"), target: .frontSpace)
        bad.rewrite = LinkRule.Rewrite(find: "^https://zoom\\.us/j/(\\d+)", replace: "zoommtg://zoom.us/join?confno=$1")

        let changed = decide(outside("https://twitter.com/apple/status/1"), [rule])
        let kept = decide(outside("https://zoom.us/j/42"), [bad])

        #expect(changed.url.absoluteString == "https://x.com/apple/status/1")
        #expect(kept.url.absoluteString == "https://zoom.us/j/42")
        #expect(kept.steps.contains("The address change gave no web address, so the address stays"))
    }

    @Test(arguments: [
        ("https://www.google.com/url?q=https://a.com/x&sa=D", "a Google"),
        ("https://www.google.co.uk/url?url=https%3A%2F%2Fa.com%2Fx", "a Google"),
        ("https://l.facebook.com/l.php?u=https%3A%2F%2Fa.com%2Fx&h=AT", "a Facebook"),
        ("https://slack-redir.net/link?url=https%3A%2F%2Fa.com%2Fx", "a Slack"),
        ("https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fa.com%2Fx&data=05", "an Outlook Safe Links"),
        ("https://l.instagram.com/?u=https%3A%2F%2Fa.com%2Fx&e=AT", "an Instagram"),
        ("https://t.umblr.com/redirect?z=https%3A%2F%2Fa.com%2Fx&t=1", "a Tumblr"),
        ("https://link.zhihu.com/?target=https%3A%2F%2Fa.com%2Fx", "a Zhihu"),
        ("https://www.youtube.com/redirect?q=https%3A%2F%2Fa.com%2Fx&v=1", "a YouTube"),
        ("https://away.vk.com/away.php?to=https%3A%2F%2Fa.com%2Fx", "a VK"),
    ])
    func eachKnownWrapperIsUnwrapped(wrapped: String, name: String) {
        let rule = toWork(.site("a.com"))

        let decision = decide(outside(wrapped), [rule])

        #expect(decision.url.absoluteString == "https://a.com/x")
        #expect(decision.rule == rule.id)
        #expect(decision.steps.first == "Unwrapped \(name) redirect")
    }

    @Test func unwrappingLeavesAnythingElseAlone() {
        var off = LinkSettings()
        off.unwrapsLinks = false
        let wrapped = "https://www.google.com/url?q=https://a.com/x"

        #expect(decide(outside(wrapped), [], settings: off).url.absoluteString == wrapped)
        #expect(LinkUnwrap.unwrap(url("https://www.google.com/url?q=javascript:alert(1)")) == nil)
        #expect(LinkUnwrap.unwrap(url("https://www.google.com/search?q=https://a.com")) == nil)
        #expect(LinkUnwrap.unwrap(url("https://google.evil.example.com/url?q=https://a.com")) == nil)
        #expect(decide(IncomingLink(url: url(wrapped), source: .page(space: home, site: nil)), []).url.absoluteString == wrapped)
    }

    @Test func trackingIsTakenOffLinksFromOtherAppsOnly() {
        var off = LinkSettings()
        off.cleansLinks = false
        let tracked = "https://a.com/x?id=3&utm_source=mail&fbclid=abc"

        let cleaned = decide(outside(tracked), [])
        let kept = decide(outside(tracked), [], settings: off)
        let inside = decide(IncomingLink(url: url(tracked), source: .page(space: home, site: nil)), [])

        #expect(cleaned.url.absoluteString == "https://a.com/x?id=3")
        #expect(cleaned.steps.contains("Took the tracking parameters off"))
        #expect(kept.url.absoluteString == tracked)
        #expect(inside.url.absoluteString == tracked)
    }

    @Test func holdingOptionAsksBeforeAnyRule() {
        let rule = toWork(.site("a.com"))
        var off = LinkSettings()
        off.chooseKey = false

        let asked = decide(outside("https://a.com", chooses: true), [rule])
        let ignored = decide(outside("https://a.com", chooses: true), [rule], settings: off)
        let inside = decide(IncomingLink(url: url("https://a.com"), source: .page(space: home, site: nil), chooses: true), [rule])

        #expect(asked.place == .ask)
        #expect(asked.rule == nil)
        #expect(ignored.rule == rule.id)
        #expect(inside.rule == rule.id)
    }

    @Test func whenNoRuleMatchesAnOutsideLinkGoesWhereTheSettingSays() {
        var toWork = LinkSettings()
        toWork.outsideDefault = .space(work)
        var asks = LinkSettings()
        asks.outsideDefault = .ask
        var gone = LinkSettings()
        gone.outsideDefault = .space(UUID())

        #expect(decide(outside("https://a.com"), []).place == .here)
        #expect(decide(outside("https://a.com"), [], settings: toWork).place == .space(work, folder: nil))
        #expect(decide(outside("https://a.com"), [], settings: asks).place == .ask)
        #expect(decide(outside("https://a.com"), [], settings: gone).place == .here)
        #expect(decide(IncomingLink(url: url("https://a.com"), source: .page(space: home, site: nil)), [], settings: asks).place == .here)
    }

    @Test func anAddressAlreadyOpenInTheTargetSpaceGoesToItsTab() {
        let tab = UUID()
        var open = world
        open.tabs = [work: [LinkRouter.key(of: url("https://a.com/x?y=1")): tab]]
        var settings = LinkSettings()
        settings.goesToOpenTab = true
        let rule = toWork(.site("a.com"))

        let found = decide(outside("https://a.com/x?y=1#part"), [rule], settings: settings, world: open)
        let other = decide(outside("https://a.com/x?y=2"), [rule], settings: settings, world: open)
        let off = decide(outside("https://a.com/x?y=1"), [rule], world: open)

        #expect(found.place == .tab(tab, space: work))
        #expect(other.place == .space(work, folder: nil))
        #expect(off.place == .space(work, folder: nil))
    }

    @Test func aBackgroundRuleSaysSo() {
        var rule = toWork(.site("a.com"))
        rule.background = true

        #expect(decide(outside("https://a.com"), [rule]).background)
    }

    @Test func aRuleMadeInTheFlowGoesAboveTheFirstBroaderRule() {
        let pattern = LinkRule(match: .pattern("docs.google.com/*/edit"), target: .peek)
        let google = LinkRule(match: .site("google.com"), target: .peek)
        let contains = LinkRule(match: .contains("docs"), target: .peek)

        #expect(LinkRules.place(forSite: "docs.google.com", in: [pattern, google]) == 1)
        #expect(LinkRules.place(forSite: "docs.google.com", in: [contains, google]) == 0)
        #expect(LinkRules.place(forSite: "figma.com", in: [pattern, google]) == 2)
    }
}
