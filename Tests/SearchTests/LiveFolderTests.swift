import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LiveFolderTests {
    private var browser: Browser!

    init() async throws {
        keepSetting(Shared.prefs, \.liveFolders, "live.on")
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesTabGroups = true
        browser.prefs.liveFolders = true
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
    }

    private func tearDown() async {
        LiveFolders.shared.reader = { await LiveReader.read($0) }
        LiveFolders.shared.signInGap = 15
        LiveFolders.shared.signOnLasts = LiveSignOn.lasts
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    private let base = URL(string: "https://example.com/feed.xml")!

    private func folder(items: [LiveItem] = [], source: LiveSource = LiveSource(kind: .feed, address: "https://example.com/feed.xml")) -> LiveFolder {
        var folder = LiveFolder(space: UUID(), name: "News", source: source)
        folder.items = items
        return folder
    }

    private func fill(_ made: LiveFolder, _ pairs: [(String, String)]) {
        let items = pairs.map { LiveItem(key: $0.0, title: $0.1) }
        LiveFolders.shared.apply(.items(items, nil), to: made.id)
        browser.syncLive()
    }

    @Test func rssEntriesKeepTheirOrderAndCData() throws {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>Feed</title><link>https://example.com</link>
        <item><title><![CDATA[First & best]]></title><link>https://example.com/1</link></item>
        <item><title>Second</title><guid>https://example.com/2</guid></item>
        </channel></rss>
        """

        let entries = try #require(FeedParser.parse(Data(xml.utf8)))

        #expect(entries == [.init(title: "First & best", link: "https://example.com/1"),
                                 .init(title: "Second", link: "https://example.com/2")])
    }

    @Test func atomPrefersTheAlternateLink() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Feed</title>
        <entry><title>One</title><link rel="self" href="https://example.com/self"/><link rel="alternate" href="https://example.com/one"/></entry>
        </feed>
        """

        let entries = try #require(FeedParser.parse(Data(xml.utf8)))

        #expect(entries.first?.link == "https://example.com/one")
    }

    @Test func aPageIsNotAFeedAndItsFeedIsFound() {
        let html = #"<html><head><link rel="alternate" type="application/rss+xml" href="/rss.xml"></head></html>"#

        let parsed = FeedParser.parse(Data(html.utf8))
        let found = FeedParser.discover(html, base: URL(string: "https://example.com/blog/")!)

        #expect(parsed == nil)
        #expect(found?.absoluteString == "https://example.com/rss.xml")
    }

    @Test func aFeedCannotHandAScriptOrFileLink() {
        let entries: [FeedParser.Entry] = [
            .init(title: "Bad", link: "javascript:alert(1)"),
            .init(title: "Worse", link: "file:///etc/passwd"),
            .init(title: "Fine", link: "/post"),
        ]

        let items = LiveReader.items(entries, base: base)

        #expect(items.map(\.key) == ["https://example.com/post"])
    }

    @Test func cookiesOnlyGoWhereTheyBelong() throws {
        func cookie(_ name: String, domain: String, secure: Bool = false, path: String = "/") throws -> HTTPCookie {
            var fields: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "1", .domain: domain, .path: path]
            if secure { fields[.secure] = "TRUE" }
            return try #require(HTTPCookie(properties: fields))
        }
        let all = [try cookie("site", domain: ".example.com"), try cookie("other", domain: "notexample.com"),
                   try cookie("safe", domain: "feeds.example.com", secure: true), try cookie("deep", domain: "example.com", path: "/private")]

        let plain = LiveReader.cookies(all, for: URL(string: "http://feeds.example.com/rss")!)
        let safe = LiveReader.cookies(all, for: URL(string: "https://feeds.example.com/rss")!)

        #expect(plain.map(\.name) == ["site"])
        #expect(Set(safe.map { $0.name }) == ["site", "safe"])
    }

    @Test func aFeedKeepsTwelveAndForgetsWhatWasOpenedADayAgo() {
        let now = Date()
        var start = folder(items: [LiveItem(key: "old", title: "Old", opened: now.addingTimeInterval(-90_000)),
                                   LiveItem(key: "new", title: "New", opened: now.addingTimeInterval(-3_600))])
        start.hidden = ["gone"]
        let fetched = ["old", "gone", "new"].map { LiveItem(key: $0, title: $0) }
            + (0..<20).map { LiveItem(key: "more\($0)", title: "More") }

        let next = LiveMerge.merged(start, fetched: fetched, now: now)

        #expect(next.items.count == 12)
        #expect(next.items.first?.key == "new")
        #expect(next.items.first?.opened != nil)
        #expect(next.hidden.contains("old"))
    }

    @Test func aListStaysWhileItIsOnThePageEvenOnceOpened() {
        let now = Date()
        let start = folder(items: [LiveItem(key: "pull", title: "Pull", opened: now.addingTimeInterval(-900_000))],
                           source: .pullRequests)

        let next = LiveMerge.merged(start, fetched: [LiveItem(key: "pull", title: "Pull")], now: now)

        #expect(next.items.map(\.key) == ["pull"])
    }

    @Test func labelsTakeTheWorstState() {
        let row = "Fix it Review required Approved"

        #expect(LiveLabels.pullRequest(row: row) == "Approved")
        #expect(LiveLabels.pullRequest(row: "Draft Changes requested") == "Changes requested")
        #expect(LiveLabels.pullRequest(row: "This branch has conflicts: Merge conflict") == "Conflict")
        #expect(LiveLabels.pullRequest(row: "Fix it Draft") == "Draft")
        #expect(LiveLabels.pullRequest(row: "Just a title Review required") == nil)
    }

    @Test func signInIsOnlyAskedForWhenNothingWasFound() {
        let asked = URL(string: "https://github.com/pulls")!
        let login = URL(string: "https://github.com/login?return_to=x")

        #expect(LiveLabels.needsSignIn(asked: asked, landed: login, password: false, found: 0))
        #expect(LiveLabels.needsSignIn(asked: asked, landed: asked, password: true, found: 0))
        #expect(!LiveLabels.needsSignIn(asked: asked, landed: login, password: true, found: 3))
        #expect(!LiveLabels.needsSignIn(asked: asked, landed: asked, password: false, found: 0))
    }

    @Test func aSignedOutGitHubPageAsksToSignInEvenWithoutARedirect() {
        let issues = URL(string: "https://github.com/issues?q=is%3Aopen+involves%3A%40me")!
        let source = LiveSource.issues

        let plainNotFound = LiveLabels.needsSignIn(asked: issues, landed: issues, password: false, found: 0, status: 404,
                                                   personal: source.personal, hidesPrivate: source.hidesPrivate)
        let emptyLogin = LiveLabels.needsSignIn(asked: issues, landed: issues, password: false, found: 0, status: 200, user: "",
                                                personal: source.personal, hidesPrivate: source.hidesPrivate)

        #expect(plainNotFound)
        #expect(emptyLogin)
    }

    @Test func aPrivateRepositorySignedOutAsksToSignIn() {
        let source = LiveSource(kind: .repository, address: "https://github.com/acme/secret/pulls", range: .open)
        let page = URL(string: source.address)!

        let answer = LiveLabels.needsSignIn(asked: page, landed: page, password: false, found: 0, status: 404, user: "",
                                            personal: source.personal, hidesPrivate: source.hidesPrivate)

        #expect(!source.personal)
        #expect(answer)
    }

    @Test func aSignedInEmptyListIsFineNotSignIn() {
        let source = LiveSource.pullRequests
        let page = PullList.reviewRequests.page(hidingDrafts: false)

        let answer = LiveLabels.needsSignIn(asked: page, landed: page, password: false, found: 0, status: 200, user: "octo-sam",
                                            signInLink: true, personal: source.personal, hidesPrivate: source.hidesPrivate)

        #expect(!answer)
        #expect(!LiveLabels.broken(status: 200, found: 0))
    }

    @Test func aPublicRepositoryWithNoPullRequestsSignedOutIsFine() {
        let source = LiveSource(kind: .repository, address: "https://github.com/acme/rocket/pulls", range: .open)
        let page = URL(string: source.address)!

        let answer = LiveLabels.needsSignIn(asked: page, landed: page, password: false, found: 0, status: 200, user: "",
                                            signInLink: true, personal: source.personal, hidesPrivate: source.hidesPrivate)

        #expect(!answer)
    }

    @Test func signedOutYouTubeSubscriptionsAskToSignIn() {
        let source = LiveSource.subscriptions
        let page = URL(string: source.address)!

        let answer = LiveLabels.needsSignIn(asked: page, landed: page, password: false, found: 0, status: 200,
                                            signInLink: true, personal: source.personal, hidesPrivate: source.hidesPrivate)

        #expect(answer)
    }

    @Test func anErrorPageWithNothingOnItFailsInsteadOfLookingEmpty() {
        let feed = URL(string: "https://example.com/blog")!

        let signIn = LiveLabels.needsSignIn(asked: feed, landed: feed, password: false, found: 0, status: 500)

        #expect(!signIn)
        #expect(LiveLabels.broken(status: 500, found: 0))
        #expect(!LiveLabels.broken(status: 500, found: 2))
        #expect(!LiveLabels.needsSignIn(asked: feed, landed: feed, password: false, found: 0, status: 404))
    }

    @Test func theListsStopAtTheFirstSignIn() async {
        var asked: [URL] = []
        let folder = LiveFolder(space: UUID(), name: "PRs", source: .pullRequests)

        let answer = await LiveReader.readLists(folder.source) { url in
            asked.append(url)
            return .signIn
        }

        #expect(answer == .signIn)
        #expect(asked == [PullList.reviewRequests.page(hidingDrafts: false)])
    }

    @Test func oldPullRequestFolderNamesBecomePRsAndChosenNamesStay() {
        let space = UUID()
        let folders = [
            LiveFolder(space: space, name: "GitHub Pull Requests", source: .pullRequests),
            LiveFolder(space: space, name: "Pull Requests", source: .reviewRequests),
            LiveFolder(space: space, name: "Team PRs to look at", source: .pullRequests),
            LiveFolder(space: space, name: "Pull Requests", source: LiveSource(kind: .repository, address: "https://github.com/acme/rocket/pulls")),
        ]

        let renamed = LiveFolders.renamed(folders).map(\.name)

        #expect(renamed == ["PRs", "PRs", "Team PRs to look at", "Pull Requests"])
    }

    @Test func thePullRequestPresetIsCalledPRsEverywhere() {
        let menu = LiveMenu.menu(for: browser)

        let preset = LivePreset.all.first { $0.source == .pullRequests }

        #expect(preset?.name == "PRs")
        #expect(menu.items.map { $0.title }.contains("GitHub Pull Requests"))
    }

    @Test func everyStateOfAnOpenFolderHasSomethingToShow() {
        var folder = LiveFolder(space: UUID(), name: "PRs", source: .pullRequests)
        var notes: [LiveFolder.Note?] = []

        notes.append(folder.note)
        for state in [LiveFolder.State.fine, .signIn, .failed] {
            folder.state = state
            notes.append(folder.note)
        }
        folder.paused = true
        notes.append(folder.note)

        #expect(notes == [.loading, .empty, .signIn, .failed, .paused])
        #expect(folder.source.emptyWording == "No pull requests")
    }

    @Test func aFolderWithItemsOnlyNotesAProblem() {
        var folder = LiveFolder(space: UUID(), name: "PRs", source: .pullRequests)
        folder.items = [LiveItem(key: "https://github.com/acme/rocket/pull/1", title: "One")]

        folder.state = .fine
        let fine = folder.note
        folder.state = .waiting
        let waiting = folder.note
        folder.state = .signIn
        let signIn = folder.note

        #expect(fine == nil)
        #expect(waiting == nil)
        #expect(signIn == .signIn)
    }

    @Test func typedSourcesAreRecognised() {
        #expect(LiveSource.from("apple/swift")?.kind == .repository)
        #expect(LiveSource.from("https://github.com/apple/swift/pulls")?.address == "https://github.com/apple/swift/pulls")
        #expect(LiveSource.from("https://github.com/apple/swift/issues")?.kind == .issues)
        #expect(LiveSource.from("https://www.youtube.com/feed/subscriptions")?.kind == .subscriptions)
        #expect(LiveSource.from("example.com/feed.xml")?.kind == .feed)
        #expect(LiveSource.from("   ") == nil)
    }

    @Test func aRepositoryRangeBecomesTheQuery() {
        var source = LiveSource(kind: .repository, address: "https://github.com/a/b/pulls", range: .week)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let week = source.reading(at: now)
        source.range = .open
        let open = source.reading(at: now)

        #expect(week?.absoluteString.contains("updated%3A%3E%3D2027-01-") == true)
        #expect(open?.absoluteString == "https://github.com/a/b/pulls")
    }

    @Test func itemsBecomeSleepingTabsInAHeldFolder() {
        let made = LiveFolders.shared.add(name: "News", source: LiveSource(kind: .feed, address: "https://example.com/feed"), space: browser.spaceID)

        fill(made, [("https://example.com/1", "One"), ("https://example.com/2", "Two")])

        let group = browser.tabGroups.first { $0.id == made.id }
        #expect(group?.live == true)
        #expect(group?.held == true)
        #expect(group?.collapsed == true)
        #expect(browser.tabs(in: made.id).map(\.liveKey) == ["https://example.com/1", "https://example.com/2"])
        #expect(browser.tabs(in: made.id).allSatisfy { $0.asleep })
    }

    @Test func aSavedFolderOfARetiredKindIsSetAsideAndTheRestStillLoad() throws {
        func saved(_ name: String, kind: String, state: String) throws -> [String: Any] {
            var folder = LiveFolder(space: UUID(), name: name, source: .pullRequests)
            folder.items = [LiveItem(key: "https://example.com/\(name)", title: name)]
            var made = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(folder)) as? [String: Any])
            var source = try #require(made["source"] as? [String: Any])
            source["kind"] = kind
            made["source"] = source
            made["state"] = state
            return made
        }
        let all = [try saved("PRs", kind: "pullRequests", state: "connect"), try saved("MRs", kind: "mergeRequests", state: "fine"),
                   try saved("Deploys", kind: "deployments", state: "connect"), try saved("CI", kind: "actions", state: "failed")]
        let data = try JSONSerialization.data(withJSONObject: all)

        let sorted = try #require(LiveFolders.sorted(data))

        #expect(sorted.kept.map(\.name) == ["PRs"])
        #expect(sorted.kept.first?.state == .waiting)
        #expect(sorted.kept.first?.items.count == 1)
        #expect(sorted.retired.map(\.uuidString) == all.dropFirst().compactMap { $0["id"] as? String })
        #expect(LiveFolders.sorted(Data("not json".utf8)) == nil)
    }

    @Test func aRetiredLiveFolderBecomesAnOrdinaryFolderThatKeepsItsTabs() {
        let made = LiveFolders.shared.add(name: "Deployments", source: LiveSource(kind: .feed, address: "https://example.com/feed.xml"),
                                          space: browser.spaceID)
        browser.syncLive()
        fill(made, [("https://example.com/1", "One"), ("https://example.com/2", "Two")])
        browser.syncLive()
        let before = browser.tabs(in: made.id).map(\.id)

        let changed = browser.retireLive([made.id])
        LiveFolders.shared.remove(made.id)
        browser.syncLive()

        let group = browser.tabGroups.first { $0.id == made.id }
        #expect(changed)
        #expect(before.count == 2)
        #expect(group?.name == "Deployments")
        #expect(group?.live == false)
        #expect(group?.held == false)
        #expect(browser.tabs(in: made.id).map(\.id) == before)
        #expect(browser.tabs(in: made.id).allSatisfy { $0.liveKey == nil && $0.liveItem == nil })
        #expect(!browser.retireLive([made.id]))
    }

    @Test func aFolderAboveAnotherLiveFolderKeepsItsNewTabs() {
        let prs = LiveFolders.shared.add(name: "PRs", source: .pullRequests, space: browser.spaceID)
        let linearIssues = LiveFolders.shared.add(name: "Issues", source: .linear(.assigned), space: browser.spaceID)
        LiveFolders.shared.apply(.signIn, to: linearIssues.id)
        browser.syncLive()

        fill(prs, [("https://github.com/acme/rocket/pull/1", "One"), ("https://github.com/acme/rocket/pull/2", "Two")])
        browser.syncLive()

        #expect(browser.tabs(in: prs.id).map(\.liveKey) == ["https://github.com/acme/rocket/pull/1", "https://github.com/acme/rocket/pull/2"])
        #expect(browser.tabs(in: linearIssues.id).isEmpty)
    }

    @Test func anItemThatLeavesTakesItsTabWithoutHidingIt() {
        let made = LiveFolders.shared.add(name: "News", source: LiveSource(kind: .feed, address: "https://example.com/feed"), space: browser.spaceID)
        fill(made, [("https://example.com/1", "One"), ("https://example.com/2", "Two")])

        fill(made, [("https://example.com/2", "Two")])

        #expect(browser.tabs(in: made.id).map(\.liveKey) == ["https://example.com/2"])
        #expect(LiveFolders.shared.folder(made.id)?.hidden == [])
    }

    @Test func closingATabHidesItsItemForGood() {
        let made = LiveFolders.shared.add(name: "News", source: LiveSource(kind: .feed, address: "https://example.com/feed"), space: browser.spaceID)
        fill(made, [("https://example.com/1", "One"), ("https://example.com/2", "Two")])
        let first = browser.tabs(in: made.id)[0]

        browser.close(first)
        fill(made, [("https://example.com/1", "One"), ("https://example.com/2", "Two")])

        #expect(LiveFolders.shared.folder(made.id)?.hidden == ["https://example.com/1"])
        #expect(browser.tabs(in: made.id).map(\.liveKey) == ["https://example.com/2"])
    }

    @Test func movingATabOutKeepsItAndHidesItsItem() {
        let made = LiveFolders.shared.add(name: "News", source: LiveSource(kind: .feed, address: "https://example.com/feed"), space: browser.spaceID)
        fill(made, [("https://example.com/1", "One")])
        let tab = browser.tabs(in: made.id)[0]

        browser.move(tab, toGroup: nil)

        #expect(tab.groupID == nil)
        #expect(tab.liveKey == nil)
        #expect(browser.tabs.contains { $0 === tab })
        #expect(LiveFolders.shared.folder(made.id)?.hidden == ["https://example.com/1"])
    }

    @Test func nothingCanBeDroppedIntoALiveFolder() {
        let made = LiveFolders.shared.add(name: "News", source: LiveSource(kind: .feed, address: "https://example.com/feed"), space: browser.spaceID)
        browser.syncLive()
        browser.newTab()
        let tab = browser.tabs.last!

        browser.move(tab, toGroup: made.id)

        #expect(tab.groupID == nil)
    }

    @Test func aFailedReadLeavesTheTabs() {
        let made = LiveFolders.shared.add(name: "News", source: LiveSource(kind: .feed, address: "https://example.com/feed"), space: browser.spaceID)
        fill(made, [("https://example.com/1", "One")])

        LiveFolders.shared.apply(.failed, to: made.id)
        browser.syncLive()

        #expect(LiveFolders.shared.folder(made.id)?.status == "Can't read")
        #expect(browser.tabs(in: made.id).count == 1)
    }

    @Test func turningOffClearsTheColumnAndKeepsTheFolder() {
        let made = LiveFolders.shared.add(name: "News", source: LiveSource(kind: .feed, address: "https://example.com/feed"), space: browser.spaceID)
        fill(made, [("https://example.com/1", "One")])

        browser.prefs.liveFolders = false
        browser.syncLive()

        #expect(!browser.tabGroups.contains { $0.id == made.id })
        #expect(!browser.tabs.contains { $0.liveKey != nil })
        #expect(LiveFolders.shared.folder(made.id) != nil)
        #expect(LiveFolders.shared.folder(made.id)?.hidden == [])
    }

    @Test func theTimerStartsOnceHoweverManyWindowsAsk() {
        let live = LiveFolders.shared
        defer { live.run(false, testing: false) }

        live.run(true, testing: false)
        let first = live.running
        live.run(true, testing: false)
        let second = live.running
        live.run(false, testing: false)

        #expect(first)
        #expect(second)
        #expect(!live.running)
    }

    @Test func aTestRunNeverStartsTheTimer() {
        LiveFolders.shared.run(true)

        #expect(!LiveFolders.shared.running)
    }

    @Test func liveFoldersComeFirstInTheTree() {
        let plain = TabGroup(id: UUID(), name: "Plain", collapsed: false)
        let live = TabGroup(id: UUID(), name: "Live", collapsed: true, held: true, live: true)

        let ordered = FolderTree.ordered([plain, live])

        #expect(ordered.map(\.name) == ["Live", "Plain"])
    }

    @Test func theMasterSwitchLeftSettings() {
        let item = SettingsIndex.items.first { $0.id == "live.on" }

        #expect(item == nil)
        #expect(SettingsCut.fixed.contains("live.on"))
    }

    @Test func gitHubSignInReturnsToThePullRequests() {
        let page = LiveSource.pullRequests.signInPage()

        #expect(page?.absoluteString == "https://github.com/login?return_to=https%3A%2F%2Fgithub.com%2Fpulls%3Fq%3Dis%253Aopen%2Bis%253Apr%2Binvolves%253A%2540me%2Barchived%253Afalse")
    }

    @Test func gitHubSignInReturnsToTheIssues() {
        let page = LiveSource.issues.signInPage()

        #expect(page?.absoluteString == "https://github.com/login?return_to=https%3A%2F%2Fgithub.com%2Fissues%3Fq%3Dis%253Aopen%2Bis%253Aissue%2Binvolves%253A%2540me%2Barchived%253Afalse")
    }

    @Test func aRepositorySignsInBackToThePageItReads() throws {
        let source = try #require(LiveSource.from("apple/swift"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z"))
        var dated = source
        dated.range = .week

        let open = source.signInPage(at: now)
        let week = dated.signInPage(at: now)

        #expect(open?.absoluteString == "https://github.com/login?return_to=https%3A%2F%2Fgithub.com%2Fapple%2Fswift%2Fpulls")
        #expect(week?.absoluteString.hasPrefix("https://github.com/login?return_to=https%3A%2F%2Fgithub.com%2Fapple%2Fswift%2Fpulls%3Fq%3Dis%253Apr%2Bis%253Aopen%2Bupdated%253A%253E%253D2026-10-28T00%253A00%253A00") == true)
    }

    @Test func youTubeSignsInThroughGoogleBackToSubscriptions() {
        let page = LiveSource.subscriptions.signInPage()

        #expect(page?.absoluteString == "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26next%3D%252Ffeed%252Fsubscriptions")
    }

    @Test func aFeedOrPageSignsInOnItsOwnPage() {
        let feed = LiveSource(kind: .feed, address: "https://news.example.com/private.xml")
        let page = LiveSource(kind: .page, address: "http://127.0.0.1:8123/list")

        #expect(feed.signInPage()?.absoluteString == "https://news.example.com/private.xml")
        #expect(page.signInPage()?.absoluteString == "http://127.0.0.1:8123/list")
    }

    @Test func eachSourceNamesItsSite() {
        #expect(LiveSource.pullRequests.siteName == "GitHub")
        #expect(LiveSource.issues.siteName == "GitHub")
        #expect(LiveSource.from("apple/swift")?.siteName == "GitHub")
        #expect(LiveSource.subscriptions.siteName == "YouTube")
        #expect(LiveSource(kind: .feed, address: "https://www.example.com/feed.xml").siteName == "example.com")
    }

    @Test func aSourceOwnsItsOwnSiteOnly() throws {
        #expect(LiveSource.pullRequests.owns(try #require(URL(string: "https://github.com/pulls"))))
        #expect(LiveSource.pullRequests.owns(try #require(URL(string: "https://www.github.com/"))))
        #expect(!LiveSource.pullRequests.owns(try #require(URL(string: "https://notgithub.com/"))))
        #expect(LiveSource.subscriptions.owns(try #require(URL(string: "https://m.youtube.com/feed/subscriptions"))))
        #expect(!LiveSource.subscriptions.owns(try #require(URL(string: "https://accounts.google.com/ServiceLogin"))))
        #expect(LiveSource(kind: .feed, address: "https://example.com/feed").owns(try #require(URL(string: "https://blog.example.com/"))))
    }

    private func signedOut(_ source: LiveSource = .pullRequests, read: Date = Date().addingTimeInterval(-60)) -> LiveFolder {
        let made = LiveFolders.shared.add(name: "Pull Requests", source: source, space: browser.spaceID)
        LiveFolders.shared.apply(.signIn, to: made.id, now: read)
        return made
    }

    private func fake(_ answers: [LiveReader.Answer], reads: @escaping (Int) -> Void = { _ in }) {
        var left = answers
        var count = 0
        LiveFolders.shared.reader = { _ in
            count += 1
            reads(count)
            try? await Task.sleep(for: .milliseconds(50))
            return left.isEmpty ? .signIn : left.removeFirst()
        }
    }

    private func settle(_ id: UUID, timeout: TimeInterval = 3, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done(), !LiveFolders.shared.reading.contains(id) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func changingListsDuringAReadDiscardsAndReplacesTheOldAnswer() async throws {
        let live = LiveFolders.shared
        let made = live.add(name: "Pull Requests", source: .pullRequests, space: browser.spaceID)
        var pending: CheckedContinuation<LiveReader.Answer, Never>?
        var requested: [[PullList]] = []
        live.reader = { folder in
            requested.append(folder.source.pullLists ?? [])
            if requested.count == 1 {
                return await withCheckedContinuation { pending = $0 }
            }
            return .items([LiveItem(key: "https://github.com/a/b/pull/2", title: "New list")], nil)
        }
        live.update(made.id)
        let end = Date().addingTimeInterval(3)
        while pending == nil, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pending != nil)

        live.setLists(made.id, [.drafts])
        pending?.resume(returning: .items([LiveItem(key: "https://github.com/a/b/pull/1", title: "Old list")], nil))
        await settle(made.id) { requested.count == 2 }

        #expect(requested == [PullList.standard, [.drafts]])
        #expect(live.folder(made.id)?.items.map(\.title) == ["New list"])
        #expect(live.folder(made.id)?.source.pullLists == [.drafts])
    }

    @Test func landingBackOnTheSiteRefreshesAndFillsTheFolder() async {
        let made = signedOut()
        var reads = 0
        fake([.items([LiveItem(key: "https://github.com/a/b/pull/1", title: "Fix it")], nil)]) { reads = $0 }

        LiveFolders.shared.cameBack(to: URL(string: "https://github.com/pulls"))
        await settle(made.id) { LiveFolders.shared.folder(made.id)?.state == .fine }

        #expect(reads == 1)
        #expect(LiveFolders.shared.folder(made.id)?.state == .fine)
        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.title) == ["Fix it"])
    }

    @Test func theWindowComingBackRefreshesASignInFolder() async {
        let made = signedOut()
        fake([.items([LiveItem(key: "https://github.com/a/b/pull/2", title: "Two")], nil)])

        LiveFolders.shared.cameBack()
        await settle(made.id) { LiveFolders.shared.folder(made.id)?.state == .fine }

        #expect(LiveFolders.shared.folder(made.id)?.state == .fine)
    }

    @Test func landingOnAnotherSiteOrAFineFolderReadsNothing() async throws {
        let made = signedOut()
        let fine = LiveFolders.shared.add(name: "News", source: LiveSource(kind: .feed, address: "https://github.com/a.atom"), space: browser.spaceID)
        LiveFolders.shared.apply(.items([], nil), to: fine.id, now: Date().addingTimeInterval(-60))
        let paused = signedOut()
        LiveFolders.shared.pause(paused.id, true)
        var reads = 0
        fake([]) { reads = $0 }

        LiveFolders.shared.cameBack(to: URL(string: "https://example.com/"))
        try await Task.sleep(for: .milliseconds(200))

        #expect(reads == 0)
        #expect(LiveFolders.shared.folder(made.id)?.state == .signIn)
    }

    @Test func aRecheckSoonAfterAReadWaitsForTheGapThenRuns() async throws {
        LiveFolders.shared.signInGap = 0.4
        let made = signedOut(read: Date())
        var reads = 0
        fake([.items([], nil)]) { reads = $0 }

        LiveFolders.shared.cameBack(to: URL(string: "https://github.com/pulls"))
        LiveFolders.shared.cameBack()
        try await Task.sleep(for: .milliseconds(150))
        let early = reads
        await settle(made.id) { LiveFolders.shared.folder(made.id)?.state == .fine }

        #expect(early == 0)
        #expect(reads == 1)
        #expect(LiveFolders.shared.folder(made.id)?.state == .fine)
    }

    @Test func aLandingDuringAReadIsNotSwallowed() async {
        LiveFolders.shared.signInGap = 0.3
        let made = signedOut()
        var reads = 0
        fake([.signIn, .items([LiveItem(key: "https://github.com/a/b/pull/3", title: "Three")], nil)]) { reads = $0 }

        LiveFolders.shared.cameBack()
        LiveFolders.shared.cameBack(to: URL(string: "https://github.com/pulls"))
        await settle(made.id) { LiveFolders.shared.folder(made.id)?.state == .fine }

        #expect(reads == 2)
        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.title) == ["Three"])
    }

    private let signOnPage = URL(string: "https://github.com/orgs/octocorp/sso?return_to=%2Fpulls")!
    private let listPage = URL(string: "https://github.com/pulls?q=is%3Aopen+is%3Apr+author%3A%40me")!
    private let three = LiveItem(key: "https://github.com/octocorp/ios/pull/3", title: "Three")
    private let signedOn = LiveArrival(from: URL(string: "https://octocorp.okta.com/app/github/sso/saml"), type: .formSubmitted, redirected: true)

    private func timed(_ answers: [LiveReader.Answer], taking: Duration = .milliseconds(50)) -> () -> [Date] {
        var left = answers
        var starts: [Date] = []
        LiveFolders.shared.reader = { _ in
            starts.append(Date())
            try? await Task.sleep(for: taking)
            return left.isEmpty ? .signIn : left.removeFirst()
        }
        return { starts }
    }

    @Test func theStepsOfASignOnAreToldFromThePagesAfterIt() {
        let steps = ["https://github.com/login?return_to=%2Fpulls", "https://github.com/session", "https://github.com/sessions/two-factor/app",
                     "https://github.com/login/oauth/authorize", "https://github.com/orgs/octocorp/sso?return_to=%2Fpulls",
                     "https://github.com/orgs/octocorp/saml/consume", "https://github.com/enterprises/octocorp/sso",
                     "https://gitlab.com/users/sign_in", "https://example.com/signin"]
        let pages = ["https://github.com/pulls", "https://github.com/", "https://github.com/octocorp/session/pull/3",
                     "https://github.com/acme/login-service", "https://github.com/orgs/octocorp/repositories",
                     "https://github.com/orgs/octocorp", "https://github.com/users/sam"]

        let told = steps.map { LiveSignOn.step(URL(string: $0)!) }
        let passed = pages.map { LiveSignOn.step(URL(string: $0)!) }

        #expect(told == steps.map { _ in true })
        #expect(passed == pages.map { _ in false })
        #expect(LiveSource.pullRequests.signsIn(at: signOnPage))
        #expect(!LiveSource.pullRequests.signsIn(at: URL(string: "https://example.com/login")!))
        #expect(!LiveSource(kind: .page, address: "https://example.com/login").signsIn(at: URL(string: "https://example.com/login")!))
    }

    @Test func openingTheSignOnPageSpendsNoRead() async throws {
        let made = signedOut()
        let starts = timed([])
        let steps = [signOnPage, URL(string: "https://github.com/login?return_to=%2Fpulls")!, URL(string: "https://github.com/session")!,
                     URL(string: "https://github.com/sessions/two-factor/app")!]

        for step in steps { LiveFolders.shared.cameBack(to: step) }
        try await Task.sleep(for: .milliseconds(200))

        #expect(starts().isEmpty)
        #expect(LiveFolders.shared.signingOn(made.id))
        #expect(LiveFolders.shared.folder(made.id)?.state == .signIn)
    }

    @Test func landingBackAfterTheSignOnPageFillsTheFolderAtOnce() async {
        let made = signedOut()
        let starts = timed([.items([three], nil)])
        let pressed = Date()

        LiveFolders.shared.cameBack(to: signOnPage)
        LiveFolders.shared.cameBack(to: listPage, through: signedOn)
        await settle(made.id) { LiveFolders.shared.folder(made.id)?.state == .fine }

        #expect(starts().count == 1)
        #expect(starts().first.map { $0.timeIntervalSince(pressed) < 0.5 } == true)
        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.title) == ["Three"])
        #expect(!LiveFolders.shared.signingOn(made.id))
    }

    @Test func aSingleSignOnFolderFillsTheSameWay() async {
        let made = LiveFolders.shared.add(name: "PRs", source: .pullRequests, space: browser.spaceID)
        let sso = LiveSSO(org: "Octo Corp", url: signOnPage.absoluteString)
        LiveFolders.shared.apply(.sso(sso, []), to: made.id, now: Date().addingTimeInterval(-60))
        let starts = timed([.items([three], nil)])

        LiveFolders.shared.cameBack(to: signOnPage)
        LiveFolders.shared.cameBack(to: listPage, through: signedOn)
        await settle(made.id) { LiveFolders.shared.folder(made.id)?.state == .fine }

        #expect(starts().count == 1)
        #expect(LiveFolders.shared.folder(made.id)?.note == nil)
        #expect(LiveFolders.shared.folder(made.id)?.sso == nil)
    }

    @Test func comingBackToTheWindowDuringASignOnSpendsNoRead() async throws {
        let made = signedOut()
        let starts = timed([])
        let began = Date()

        LiveFolders.shared.signOnBegan(made.id, at: began)
        LiveFolders.shared.cameBack(at: began.addingTimeInterval(20))
        try await Task.sleep(for: .milliseconds(200))
        let during = starts().count
        LiveFolders.shared.cameBack(at: began.addingTimeInterval(LiveSignOn.lasts + 1))
        try await Task.sleep(for: .milliseconds(200))

        #expect(during == 0)
        #expect(starts().count == 1)
    }

    @Test func theTimerLeavesAFolderAloneDuringItsSignOn() {
        let live = LiveFolders.shared
        let (looking, idleness, frontmost) = (live.looking, live.idleness, live.frontmost)
        defer {
            live.looking = looking
            live.idleness = idleness
            live.frontmost = frontmost
            live.resetPace()
        }
        live.looking = { nil }
        live.idleness = { 0 }
        live.frontmost = { true }
        let made = signedOut(read: Date().addingTimeInterval(-3600))
        _ = timed([])
        let began = Date()

        live.signOnBegan(made.id, at: began)
        let during = live.tick(at: began.addingTimeInterval(20))
        let after = live.tick(at: began.addingTimeInterval(LiveSignOn.lasts + 1))

        #expect(!during.contains(made.id))
        #expect(after.contains(made.id))
    }

    @Test func pressingTheRowBeginsASignOnOnlyWhereItOpensASignInPage() async throws {
        LiveFolders.shared.signInGap = 0.1
        let page = LiveSource(kind: .page, address: "https://example.com/news")
        let own = signedOut(page)
        let hub = signedOut()
        let single = LiveFolders.shared.add(name: "PRs", source: .pullRequests, space: browser.spaceID)
        LiveFolders.shared.apply(.sso(LiveSSO(org: "Octo Corp", url: signOnPage.absoluteString), []), to: single.id,
                                 now: Date().addingTimeInterval(-60))
        let tube = signedOut(.subscriptions)
        let starts = timed([])

        for folder in [own, hub, single, tube] { LiveFolders.shared.signInPressed(folder.id) }
        let marked = [own, hub, single, tube].map { LiveFolders.shared.signingOn($0.id) }
        LiveFolders.shared.cameBack(to: URL(string: page.address))
        try await Task.sleep(for: .milliseconds(500))

        #expect(marked == [false, true, true, true])
        #expect(starts().count == 1)
        #expect(LiveFolders.shared.folder(own.id)?.state == .signIn)
    }

    @Test func aRefusalAfterASignOnTriesAgainAGapApart() async {
        LiveFolders.shared.signInGap = 0.3
        let made = signedOut()
        let starts = timed([.signIn, .signIn, .items([three], nil)])

        LiveFolders.shared.cameBack(to: signOnPage)
        LiveFolders.shared.cameBack(to: listPage, through: signedOn)
        await settle(made.id) { LiveFolders.shared.folder(made.id)?.state == .fine }

        let gaps = zip(starts(), starts().dropFirst()).map { $1.timeIntervalSince($0) }
        #expect(starts().count == 3)
        #expect(gaps.allSatisfy { $0 >= 0.3 })
        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.title) == ["Three"])
    }

    @Test func theTriesAfterASignOnAreBounded() async throws {
        LiveFolders.shared.signInGap = 0.1
        let made = signedOut()
        let starts = timed([])

        LiveFolders.shared.cameBack(to: signOnPage)
        LiveFolders.shared.cameBack(to: listPage, through: signedOn)
        try await Task.sleep(for: .milliseconds(1200))

        #expect(starts().count == 1 + LiveSignOn.retries)
        #expect(LiveFolders.shared.folder(made.id)?.state == .signIn)
    }

    @Test func aRefusalWithNoSignOnUnderWayIsNotTriedAgain() async throws {
        LiveFolders.shared.signInGap = 0.1
        let made = signedOut()
        let starts = timed([])

        LiveFolders.shared.cameBack(to: listPage)
        try await Task.sleep(for: .milliseconds(700))

        #expect(starts().count == 1)
        #expect(LiveFolders.shared.folder(made.id)?.state == .signIn)
    }

    @Test func theSignOnPageDropsARecheckKeptFromBefore() async throws {
        LiveFolders.shared.signInGap = 0.3
        let made = signedOut(read: Date())
        let starts = timed([])

        LiveFolders.shared.cameBack()
        LiveFolders.shared.cameBack(to: signOnPage)
        try await Task.sleep(for: .milliseconds(600))

        #expect(starts().isEmpty)
        #expect(LiveFolders.shared.folder(made.id)?.state == .signIn)
    }

    @Test func theGapCountsFromWhenTheLastReadBegan() async {
        LiveFolders.shared.signInGap = 0.8
        let made = signedOut()
        let starts = timed([.signIn, .items([three], nil)], taking: .milliseconds(500))

        LiveFolders.shared.cameBack(to: listPage)
        await settle(made.id) { LiveFolders.shared.folder(made.id)?.state == .signIn }
        LiveFolders.shared.cameBack(to: listPage)
        await settle(made.id) { LiveFolders.shared.folder(made.id)?.state == .fine }

        let apart = starts().count == 2 ? starts()[1].timeIntervalSince(starts()[0]) : 0
        #expect(starts().count == 2)
        #expect(apart >= 0.8)
        #expect(apart < 1.25)
    }

    @Test func aReadThatStraddlesTheSignOnIsStillSingleSignOn() async {
        let sso = LiveSSO(org: "Octo Corp", url: signOnPage.absoluteString)
        let created = LiveItem(key: "https://github.com/octocorp/ios/pull/3", title: "Three")
        let assigned = LiveItem(key: "https://github.com/octocorp/ios/pull/4", title: "Four")
        var answers: [LiveReader.Answer] = [.sso(sso, []), .items([created], nil), .items([assigned], nil), .items([], nil)]

        let answer = await LiveReader.readLists(.pullRequests) { _ in answers.removeFirst() }

        guard case .sso(let asked, let items) = answer else { Issue.record("not single sign-on: \(answer)"); return }
        #expect(asked == sso)
        #expect(items.map(\.title) == ["Three", "Four"])
    }

    @Test func deletingASpaceRemovesItsLiveFolders() throws {
        browser.addSpace(named: "Elsewhere")
        let other = try #require(browser.spaces.first { $0.name == "Elsewhere" }).id
        let gone = LiveFolders.shared.add(name: "News", source: LiveSource(kind: .feed, address: "https://example.com/feed"), space: other)
        let kept = LiveFolders.shared.add(name: "News", source: LiveSource(kind: .feed, address: "https://example.com/feed"), space: Space.firstID)

        browser.deleteSpace(other)

        #expect(LiveFolders.shared.folder(gone.id) == nil)
        #expect(LiveFolders.shared.folder(kept.id) != nil)
    }

    @Test func aSavedFolderWhoseSpaceIsGoneIsLeftOut() {
        let home = LiveFolder(space: Space.firstID, name: "News", source: LiveSource(kind: .feed, address: "https://example.com/feed"))
        let ghost = LiveFolder(space: UUID(), name: "News", source: LiveSource(kind: .feed, address: "https://example.com/feed"))

        let kept = LiveFolders.housed([home, ghost], in: [Space.firstID])

        #expect(kept.map(\.id) == [home.id])
    }

    @Test func goingToATabInAPrivateWindowLeavesTheLiveFolderItemUnopened() throws {
        let quiet = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { quiet.closeAll() }
        let made = LiveFolders.shared.add(name: "News", source: LiveSource(kind: .feed, address: "https://example.com/feed"), space: Space.firstID)
        LiveFolders.shared.apply(.items([LiveItem(key: "https://example.com/1", title: "One")], nil), to: made.id)
        _ = quiet.open(URL(string: "about:blank")!, foreground: true)
        let tab = quiet.open(URL(string: "about:blank")!, foreground: false)
        tab.liveKey = "https://example.com/1"

        quiet.select(tab)

        #expect(LiveFolders.shared.folder(made.id)?.items.first?.opened == nil)
    }

    @Test func theNewLiveFolderMenuOffersWhatSettingsOffersAndNothingTheSpaceHas() {
        _ = LiveFolders.shared.add(name: "PRs", source: .pullRequests, space: browser.spaceID)

        let titles = LiveMenu.menu(for: browser).items.map(\.title)

        #expect(!titles.contains("GitHub Pull Requests"))
        #expect(!titles.contains("GitHub Issues"))
        #expect(titles.contains("GitHub Assigned Issues"))
        #expect(titles.contains("Linear Inbox"))
        #expect(titles.contains("Google Drive"))
    }

    @Test func theNewLiveFolderMenuDrawsALineWhereTheServiceChanges() {
        _ = LiveFolders.shared.add(name: "PRs", source: .pullRequests, space: browser.spaceID)

        let rows = LiveMenu.menu(for: browser).items.drop { $0.title != "GitHub Assigned Issues" }
        let groups = rows.split { $0.isSeparatorItem }.map { $0.map(\.title) }

        #expect(groups == [
            ["GitHub Assigned Issues", "GitHub Notifications"],
            ["Linear My Issues", "Linear Mentions", "Linear Inbox", "Linear Created by Me"],
            ["YouTube Subscriptions", "Google Drive"],
        ])
    }

    @Test func followingASiteTheSpaceAlreadyFollowsAddsNoSecondFolder() throws {
        let tab = browser.makeTab()
        tab.restore(url: try #require(URL(string: "https://example.com/blog")), title: "Blog")
        browser.followSite(tab)
        let first = LiveFolders.shared.folders.filter { $0.space == browser.spaceID }

        browser.followSite(tab)

        #expect(first.count == 1)
        #expect(LiveFolders.shared.folders.filter { $0.space == browser.spaceID }.map(\.id) == first.map(\.id))
        #expect(browser.announcement == "Already following \(first.first?.name ?? "")")
    }

    @Test func everyDoorNamesAFolderTheSameWay() throws {
        let typed = try #require(LiveSource.from("acme/rocket"))
        let page = try #require(LiveSource.from("https://github.com/acme/rocket"))
        let feed = try #require(LiveSource.from("https://www.example.com/feed.xml"))

        #expect(LivePreset.name(for: .pullRequests) == LiveSource.pullRequestsName)
        #expect(LivePreset.name(for: .subscriptions) == "Subscriptions")
        #expect(LivePreset.name(for: typed) == "acme/rocket")
        #expect(LivePreset.name(for: page) == "acme/rocket")
        #expect(LivePreset.name(for: feed) == "example.com")
    }

    @Test func followingASiteSaysWhatSettingsSays() throws {
        let tab = browser.makeTab()
        tab.restore(url: try #require(URL(string: "https://github.com/acme/rocket")), title: "Rocket")

        browser.followSite(tab)

        #expect(LiveFolders.shared.folders.filter { $0.space == browser.spaceID }.map(\.name) == ["acme/rocket"])
        #expect(browser.announcement == "Added acme/rocket")
    }

    @Test func removingAFolderForgetsItsSignOnTab() {
        let made = LiveFolders.shared.add(name: "PRs", source: .pullRequests, space: browser.spaceID)
        let tab = UUID()
        LiveFolders.shared.signOnTab(tab, for: made.id, at: URL(string: "https://github.com/login")!)
        let watched = LiveFolders.shared.opened(tab)

        LiveFolders.shared.remove(made.id)

        #expect(watched)
        #expect(!LiveFolders.shared.opened(tab))
    }
}
