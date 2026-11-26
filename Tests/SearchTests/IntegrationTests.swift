import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class IntegrationTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("IntegrationFixtures")

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).json"))
    }

    private var asked: [URLRequest] = []
    private let session = LinearSessionFake()

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        asked = []
    }

    private func tearDown() async {
        IntegrationReader.cookies = { await Spaces.store(for: $0).httpCookieStore.allCookies() }
    }

    private func integrations(answering answers: [String: (String, Int)]) -> Integrations {
        let made = Integrations()
        made.transport = { [weak self] request in
            guard let self else { return nil }
            asked.append(request)
            let answered: (URLRequest) -> (Data, Int)? = { request in
                let path = request.url?.path() ?? ""
                guard let (name, status) = answers.first(where: { path.hasSuffix($0.key) })?.value,
                      let data = try? self.fixture(name) else { return nil }
                return (data, status)
            }
            return LinearSessionFake.handles(request) ? session.answer(request, answered) : answered(request)
        }
        return made
    }

    private func folder(_ source: LiveSource) -> LiveFolder {
        LiveFolder(space: UUID(), name: "Folder", source: source)
    }

    @Test func checksFollowTheRollup() {
        #expect(GitHubAPI.checks("SUCCESS") == .passing)
        #expect(GitHubAPI.checks("ERROR") == .failing)
        #expect(GitHubAPI.checks("EXPECTED") == .pending)
        #expect(GitHubAPI.checks(nil) == nil)
    }

    @Test func aGitHubPageBecomesTheSameSearch() {
        #expect(GitHubAPI.search(for: URL(string: LiveSource.issues.address)) == "is:open is:issue involves:@me archived:false sort:updated-desc")
        #expect(GitHubAPI.search(for: URL(string: "https://github.com/acme/rocket/pulls")) == "is:pr is:open repo:acme/rocket sort:updated-desc")
        #expect(GitHubAPI.search(for: URL(string: "https://github.com/acme/rocket/issues?q=is%3Aissue+label%3Abug")) == "is:issue label:bug repo:acme/rocket sort:updated-desc")
        #expect(GitHubAPI.search(for: URL(string: "https://github.com/pulls?q=is%3Apr+sort%3Acreated-asc")) == "is:pr sort:created-asc")
        #expect(GitHubAPI.search(for: URL(string: "https://github.com/acme")) == nil)
        #expect(GitHubAPI.search(for: URL(string: "https://example.com/pulls")) == nil)
    }

    @Test func theSameStackNumberInAnotherRepositoryIsNotAStack() {
        let items = [
            LiveItem(key: "a", title: "A", branch: LiveBranch(repository: "acme/rocket", base: "main", head: "feature", stack: 7, position: 1)),
            LiveItem(key: "b", title: "B", branch: LiveBranch(repository: "acme/site", base: "feature", head: "feature-2", stack: 7, position: 2)),
        ]

        let arranged = LiveStacks.arranged(items)

        #expect(arranged.map(\.key) == ["a", "b"])
        #expect(arranged.map(\.stack) == [nil, nil])
    }

    @Test func everyListIsASearchOnGitHub() {
        #expect(PullList.reviewRequests.page(hidingDrafts: false).absoluteString == "https://github.com/pulls?q=is%3Aopen+is%3Apr+archived%3Afalse+review-requested%3A%40me")
        #expect(PullList.allCases.first == .reviewRequests)
        #expect(Set(PullList.allCases.map { $0.query(hidingDrafts: false) }).count == PullList.allCases.count)
        #expect(PullList.named("ready to merge") == .ready)
        #expect(PullList.named("teamReviews") == .teamReviews)
        #expect(PullList.ordered([.assigned, .reviewRequests]) == [.reviewRequests, .assigned])
    }

    @Test func thePullRequestsFolderSplitsAndOthersDoNot() {
        var chosen = LiveSource.pullRequests
        chosen.lists = [.drafts, .ready]

        #expect(LiveSource.pullRequests.pullLists == PullList.standard)
        #expect(PullList.standard.first == .reviewRequests)
        #expect(chosen.pullLists == [.ready, .drafts])
        #expect(LiveSource.reviewRequests.pullLists == nil)
        #expect(LiveSource.issues.pullLists == nil)
        #expect(LiveSource.pullRequests.asksForReview)
        #expect(!chosen.asksForReview)
        #expect(LiveSource.reviewRequests.asksForReview)
        #expect(!LiveSource.myPullRequests.asksForReview)
    }

    @Test func aFolderSavedBeforeListsStillReads() throws {
        let old = #"{"kind":"pullRequests","address":"https://github.com/pulls?q=is%3Aopen"}"#

        let source = try JSONDecoder().decode(LiveSource.self, from: Data(old.utf8))
        let item = try JSONDecoder().decode(LiveItem.self, from: Data(#"{"key":"k","title":"t"}"#.utf8))

        #expect(source.lists == nil)
        #expect(source.pullLists == nil)
        #expect(item.arrived == nil)
    }

    @Test func linearAddressesNameTheirList() {
        #expect(LinearAPI.List(address: "https://linear.app/acme/my-issues/assigned") == .assigned)
        #expect(LinearAPI.List(address: "https://linear.app/acme/my-issues/created") == .created)
        #expect(LinearAPI.List(address: "https://linear.app/acme/inbox") == .inbox)
        #expect(LinearAPI.List(address: "https://linear.app/acme/inbox/mentions") == .mentions)
        #expect(LinearAPI.List(address: "https://linear.app/acme/team/eng/cycle/current") == .cycle("ENG"))
        #expect(LinearAPI.List(address: "https://linear.app/acme/settings") == nil)
        #expect(LinearAPI.List(address: "https://example.com/acme/inbox") == nil)
        #expect(LinearAPI.address(for: .mentions, workspace: "acme") == "https://linear.app/acme/inbox/mentions")
        #expect(LinearAPI.address(for: .assigned, workspace: nil) == "https://linear.app/my-issues/assigned")
    }

    @Test func linearIssuesShowTheirKeyAndState() throws {
        let items = try #require(LinearAPI.items(from: try fixture("linear-assigned"), list: .assigned))

        #expect(items.map(\.title) == ["Rate limit the export endpoint", "Flaky login test on CI"])
        #expect(items.map(\.byline) == ["ENG-231 • In Progress", "ENG-198 • Todo"])
        #expect(items[0].checks == nil)
    }

    @Test func linearIssuesAreSortedByStatus() throws {
        func issue(_ key: String, _ name: String, _ type: String, _ position: Double) -> [String: Any] {
            ["identifier": key, "title": key, "url": "https://linear.app/acme/issue/\(key)", "updatedAt": "2026-11-03T22:01:10.511Z",
             "state": ["name": name, "type": type, "position": position]]
        }
        let issues = [issue("A-1", "Backlog", "backlog", 0), issue("A-2", "In Progress", "started", 2), issue("A-3", "Todo", "unstarted", 1),
                      issue("A-4", "In Review", "started", 3), issue("A-5", "In Progress", "started", 2), issue("A-6", "Triage", "triage", 0),
                      issue("A-7", "Done", "completed", 4)]
        let data = try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["id": "me", "assignedIssues": ["nodes": issues]]]])

        let items = try #require(LinearAPI.items(from: data, list: .assigned))

        #expect(items.map(\.author) == ["A-6", "A-4", "A-2", "A-5", "A-3", "A-1", "A-7"])
        #expect(String(decoding: LinearAPI.body(for: .assigned), as: UTF8.self).contains("state { name type position }"))
    }

    @Test func theInboxKeepsUnreadIssuesOnceAndMentionsKeepMentions() throws {
        let data = try fixture("linear-inbox")

        let inbox = try #require(LinearAPI.items(from: data, list: .inbox))
        let mentions = try #require(LinearAPI.items(from: data, list: .mentions))

        #expect(inbox.map(\.byline) == ["DES-12 • Mention", "ENG-231 • Assigned"])
        #expect(mentions.map(\.byline) == ["DES-12 • Mention", "ENG-231 • Mention"])
    }

    @Test func aCycleListsItsIssues() throws {
        let items = try #require(LinearAPI.items(from: try fixture("linear-cycle"), list: .cycle("ENG")))
        let body = String(decoding: LinearAPI.body(for: .cycle("ENG")), as: UTF8.self)

        #expect(items.map(\.byline) == ["ENG-231 • In Progress", "ENG-150 • Done"])
        #expect(body.contains(#""key":"ENG""#))
    }

    @Test func onlyATestRunMayPointTheServicesAtThisMac() throws {
        let settings = try #require(UserDefaults(suiteName: "integration-tests-\(getpid())"))
        defer { settings.removePersistentDomain(forName: "integration-tests-\(getpid())") }
        settings.set("http://127.0.0.1:8123", forKey: Integrations.rootKey)

        let testing = Integrations.fixture(.gitHub, settings: settings, testing: true)
        let real = Integrations.fixture(.gitHub, settings: settings, testing: false)
        let session = Integrations.sessionEndpoint(settings: settings, testing: true)
        settings.set("https://evil.example/", forKey: Integrations.rootKey)
        let elsewhere = Integrations.fixture(.linear, settings: settings, testing: true)

        #expect(testing?.absoluteString == "http://127.0.0.1:8123/github")
        #expect(real == nil)
        #expect(session.absoluteString == "http://127.0.0.1:8123/linear-session/graphql")
        #expect(elsewhere == nil)
        #expect(Integrations.sessionEndpoint(settings: settings, testing: true).absoluteString == "https://client-api.linear.app/graphql")
        #expect(Integrations.sessionEndpoint(settings: settings, testing: false).absoluteString == "https://client-api.linear.app/graphql")
    }

    @Test func aRefusedLinearAnswerIsRecognised() throws {
        #expect(LinearAPI.refused(try fixture("linear-unauthenticated")))
        #expect(!LinearAPI.refused(try fixture("linear-assigned")))
    }

    @Test func gitHubFoldersStayWithThePage() async {
        let made = integrations(answering: ["/graphql": ("linear-assigned", 200)])

        let issues = await IntegrationReader.read(folder(.issues), with: made)
        let pulls = await IntegrationReader.read(folder(.pullRequests), with: made)
        let notices = await IntegrationReader.read(folder(.gitHubNotifications), with: made)

        #expect(issues == nil)
        #expect(pulls == nil)
        #expect(notices == nil)
        #expect(asked.isEmpty)
    }

    @Test func linearAsksWhoIsSignedInThenSendsThemAlong() async throws {
        let made = integrations(answering: ["/graphql": ("linear-inbox", 200)])
        let cookie = try #require(HTTPCookie(properties: [.domain: ".linear.app", .path: "/", .name: "session", .value: "s3cr3t", .secure: "TRUE"]))
        let other = try #require(HTTPCookie(properties: [.domain: "github.com", .path: "/", .name: "user_session", .value: "nope"]))
        IntegrationReader.cookies = { _ in [cookie, other] }

        let answer = await IntegrationReader.read(folder(.linear(.inbox, workspace: "acme")), with: made)

        guard let items = answer?.found else { Issue.record("\(String(describing: answer))"); return }
        #expect(items.count == 2)
        #expect(asked.count == 2)
        let lookup = try #require(session.lookups.first)
        #expect(lookup.url?.absoluteString == "https://client-api.linear.app/graphql")
        #expect(lookup.value(forHTTPHeaderField: "Cookie") == "session=s3cr3t")
        #expect(lookup.value(forHTTPHeaderField: "user") == nil)
        #expect(lookup.value(forHTTPHeaderField: "organization") == nil)
        let request = try #require(session.real.first)
        #expect(request.url?.absoluteString == "https://client-api.linear.app/graphql")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "session=s3cr3t")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://linear.app")
        #expect(request.value(forHTTPHeaderField: "user") == "u-acme")
        #expect(request.value(forHTTPHeaderField: "organization") == "o-acme")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aLinearFolderAsksOnlyForTheStatusesItShows() async throws {
        let made = integrations(answering: ["/graphql": ("linear-assigned", 200)])
        IntegrationReader.cookies = { _ in [HTTPCookie(properties: [.domain: ".linear.app", .path: "/", .name: "session", .value: "fixture"])!] }
        var everything = LiveSource.linear(.assigned, workspace: "acme")
        everything.statuses = LinearStatus.allCases.map(\.rawValue)

        _ = await IntegrationReader.read(folder(.linear(.assigned, workspace: "acme")), with: made)
        _ = await IntegrationReader.read(folder(everything), with: made)
        _ = await IntegrationReader.read(folder(.linear(.inbox, workspace: "acme")), with: made)

        let sent = session.real.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
        #expect(sent.count == 3)
        #expect(sent.first?.contains(#"nin: [\"completed\", \"canceled\", \"backlog\"]"#) == true)
        #expect(sent.dropFirst().first?.contains(#"nin: [\"completed\", \"canceled\"]"#) == true)
        #expect(sent.last?.contains("backlog") == false)
    }

    @Test func linearSignedOutAsksToSignIn() async throws {
        let made = integrations(answering: ["/graphql": ("linear-assigned", 200)])
        IntegrationReader.cookies = { _ in [] }
        let unauthenticated = try fixture("linear-unauthenticated")
        let refusing = Integrations()
        refusing.transport = { [weak self] request in
            self?.asked.append(request)
            return (unauthenticated, 401)
        }

        let nothing = await IntegrationReader.read(folder(.linear(.assigned)), with: made)
        let noRequest = asked.isEmpty
        IntegrationReader.cookies = { _ in [HTTPCookie(properties: [.domain: "linear.app", .path: "/", .name: "s", .value: "old"])!] }
        session.users = []
        let nobody = await IntegrationReader.read(folder(.linear(.assigned)), with: made)
        let refused = await IntegrationReader.read(folder(.linear(.assigned)), with: refusing)

        #expect(nothing == .signIn)
        #expect(noRequest)
        #expect(nobody == .signIn)
        #expect(refused == .signIn)
        #expect(session.lookups.count == 1)
        #expect(session.real.isEmpty)
        #expect(asked.count == 2)
    }

    @Test func linearSessionReadsOnlyTheFolderWorkspace() async throws {
        let made = integrations(answering: ["/graphql": ("linear-assigned", 200)])
        IntegrationReader.cookies = { _ in [HTTPCookie(properties: [.domain: ".linear.app", .path: "/", .name: "session", .value: "fixture"])!] }

        let acme = await IntegrationReader.read(folder(.linear(.assigned, workspace: "Acme")), with: made)
        let plain = await IntegrationReader.read(folder(.linear(.assigned, workspace: nil)), with: made)
        let gone = await IntegrationReader.read(folder(.linear(.assigned, workspace: "gone")), with: made)
        let typed = await IntegrationReader.read(folder(LiveSource(kind: .linear, address: "https://linear.app/acme/team/ENG/active")), with: made)

        for answer in [acme, plain] {
            guard answer?.found != nil else { Issue.record("\(String(describing: answer))"); return }
        }
        #expect(gone == .signIn)
        #expect(typed != .signIn)
        #expect(session.real.map { $0.value(forHTTPHeaderField: "user") } == ["u-acme", "u-north", "u-acme"])
        #expect(session.real.map { $0.value(forHTTPHeaderField: "organization") } == ["o-acme", "o-north", "o-acme"])
    }

    @Test func linearWorkspaceComesFromTheAddressWhenItHasOne() {
        #expect(LinearAPI.workspace(in: "https://linear.app/Acme/my-issues/assigned") == "acme")
        #expect(LinearAPI.workspace(in: "https://linear.app/acme/team/ENG/cycle/current") == "acme")
        #expect(LinearAPI.workspace(in: "https://linear.app/my-issues/assigned") == nil)
        #expect(LinearAPI.workspace(in: "https://linear.app/inbox") == nil)
        #expect(LinearAPI.workspace(in: "https://linear.app/team/ENG/cycle/current") == nil)
        #expect(LinearAPI.workspace(in: "https://example.com/acme/inbox") == nil)
    }

    @Test func aSecondLinearRefreshSendsOneRequest() async throws {
        let made = integrations(answering: ["/graphql": ("linear-assigned", 200)])
        IntegrationReader.cookies = { _ in [HTTPCookie(properties: [.domain: ".linear.app", .path: "/", .name: "session", .value: "fixture"])!] }
        let mine = folder(.linear(.assigned, workspace: "acme"))

        _ = await IntegrationReader.read(mine, with: made)
        let first = asked.count
        let again = await IntegrationReader.read(mine, with: made)

        guard again?.found != nil else { Issue.record("\(String(describing: again))"); return }
        #expect(first == 2)
        #expect(asked.count == 3)
        #expect(session.lookups.count == 1)
    }

    @Test func aLinearFolderPinnedToItsWorkspaceAfterTheFirstReadSendsOneRequestOnTheNext() async throws {
        let made = integrations(answering: ["/graphql": ("linear-assigned", 200)])
        IntegrationReader.cookies = { _ in [HTTPCookie(properties: [.domain: ".linear.app", .path: "/", .name: "session", .value: "fixture"])!] }
        var mine = folder(.linear(.assigned, workspace: nil))

        let first = await IntegrationReader.read(mine, with: made)
        guard case .read(let read) = first, let pinned = read.source else { Issue.record("\(String(describing: first))"); return }
        mine.source = pinned
        let again = await IntegrationReader.read(mine, with: made)

        guard again?.found != nil else { Issue.record("\(String(describing: again))"); return }
        #expect(LinearAPI.workspace(in: pinned.address) == "north")
        #expect(asked.count == 3)
        #expect(session.lookups.count == 1)
    }

    @Test func aRefusedLinearSessionAsksAgainOnceThenSaysSignIn() async throws {
        let made = integrations(answering: ["/graphql": ("linear-assigned", 200)])
        IntegrationReader.cookies = { _ in [HTTPCookie(properties: [.domain: ".linear.app", .path: "/", .name: "session", .value: "fixture"])!] }
        let mine = folder(.linear(.assigned, workspace: "acme"))
        _ = await IntegrationReader.read(mine, with: made)
        session.refuseReal = true

        let refused = await IntegrationReader.read(mine, with: made)
        let afterRefusal = asked.count
        session.refuseReal = false
        let back = await IntegrationReader.read(mine, with: made)

        #expect(refused == .signIn)
        #expect(afterRefusal == 5)
        #expect(session.lookups.count == 3)
        guard back?.found != nil else { Issue.record("\(String(describing: back))"); return }
        #expect(asked.count == 7)
    }

    @Test func aLinearWorkspaceSignedOutAsksToSignInRatherThanReadAnother() async throws {
        let made = integrations(answering: ["/graphql": ("linear-assigned", 200)])
        IntegrationReader.cookies = { _ in [HTTPCookie(properties: [.domain: ".linear.app", .path: "/", .name: "session", .value: "fixture"])!] }
        let mine = folder(.linear(.assigned, workspace: "acme"))
        _ = await IntegrationReader.read(mine, with: made)
        session.users = [LinearSessionFake.north]

        let answer = await IntegrationReader.read(mine, with: made)

        #expect(answer == .signIn)
        #expect(session.real.map { $0.value(forHTTPHeaderField: "user") } == ["u-acme", "u-acme"])
    }

    @Test func unreadNotificationsAreFoundPastTheFirstPage() async throws {
        let made = Integrations()
        var pages = 0
        made.transport = { [weak self] request in
            guard let self else { return nil }
            return session.answer(request) { asked in
                let body = (try? JSONSerialization.jsonObject(with: asked.httpBody ?? Data()) as? [String: Any]) ?? [:]
                pages += 1
                let after = (body["variables"] as? [String: Any])?["after"] as? String
                let id = after == nil ? "p1" : after!
                let node: [String: Any] = ["id": "n-\(id)", "type": "issueMention", "createdAt": "2027-01-15T08:00:00.000Z", "readAt": NSNull(),
                                           "archivedAt": NSNull(),
                                           "issue": ["identifier": "ENG-\(pages)", "title": "Issue \(pages)", "url": "https://linear.app/acme/issue/ENG-\(pages)/x",
                                                     "updatedAt": "2027-01-15T08:00:00.000Z", "state": ["name": "Todo", "type": "unstarted", "position": 1]]]
                let info: [String: Any] = ["hasNextPage": true, "endCursor": "p\(pages + 1)"]
                let data = try? JSONSerialization.data(withJSONObject: ["data": ["viewer": ["id": "me"], "notifications": ["nodes": [node], "pageInfo": info]]])
                return (data ?? Data(), 200)
            }
        }
        IntegrationReader.cookies = { _ in [HTTPCookie(properties: [.domain: ".linear.app", .path: "/", .name: "session", .value: "fixture"])!] }

        let answer = await IntegrationReader.read(folder(.linear(.inbox, workspace: "acme")), with: made)

        #expect(pages == LinearAPI.pages)
        #expect(answer?.found?.count == LinearAPI.pages)
        guard case .read(let read)? = answer else { Issue.record("\(String(describing: answer))"); return }
        #expect(read.more == "https://linear.app/acme/inbox")
    }

    @Test func shorthandsMakeTheRightFolders() {
        #expect(LiveSource.from("github:reviews") == .reviewRequests)
        #expect(LiveSource.from("GH:Notifications") == .gitHubNotifications)
        #expect(LiveSource.from("https://github.com/notifications") == .gitHubNotifications)
        #expect(LiveSource.from("linear:assigned")?.kind == .linear)
        #expect(LiveSource.from("linear:cycle/eng").map { LinearAPI.List(address: $0.address) } == .cycle("ENG"))
        #expect(LiveSource.from("linear:cycle/") == nil)
        #expect(LiveSource.from("gitlab:mrs") == nil)
        #expect(LiveSource.from("vercel:deployments") == nil)
        #expect(LiveSource.from("github:actions/acme/rocket") == nil)
        #expect(LiveSource.from("https://linear.app/acme/inbox")?.kind == .linear)
        #expect(LiveSource.from("https://linear.app/pricing")?.kind == .feed)
        #expect(LiveSource.linear(.inbox, workspace: "acme").siteName == "Linear")
        #expect(LiveSource.gitHubNotifications.pattern.map { "/acme/rocket/pull/3".range(of: $0, options: .regularExpression) != nil } == true)
    }

    @Test func aNewItemArrivesOnlyAfterTheFirstRead() {
        let first = [LiveItem(key: "a", title: "A")]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var made = folder(.linear(.assigned, workspace: "acme"))

        made = LiveMerge.merged(made, fetched: first, now: now)
        made = LiveMerge.merged(made, fetched: [LiveItem(key: "b", title: "B")] + first, now: now.addingTimeInterval(300))
        made = LiveMerge.merged(made, fetched: [LiveItem(key: "b", title: "B")] + first, now: now.addingTimeInterval(600))

        #expect(made.items.map(\.key) == ["b", "a"])
        #expect(made.items.map(\.arrived) == [now.addingTimeInterval(300), nil])
    }

    @Test func aReadThatOnlyAskedToSignInIsNotTheFirstRead() {
        var made = folder(.linear(.assigned, workspace: "acme"))
        made.state = .signIn
        made.read = Date()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        made = LiveMerge.merged(made, fetched: [LiveItem(key: "a", title: "Backlog")], now: now)

        #expect(made.items.map(\.arrived) == [nil])
    }

    @Test func reviewRequestsComeBeforeAssignmentsInNow() {
        var issues = folder(.linear(.assigned, workspace: "acme"))
        issues.state = .fine
        issues.items = [LiveItem(key: "https://linear.app/acme/issue/ENG-1", title: "One", arrived: Date()),
                        LiveItem(key: "https://linear.app/acme/issue/ENG-2", title: "Two", arrived: Date())]
        var reviews = folder(.reviewRequests)
        reviews.state = .fine
        reviews.items = [LiveItem(key: "https://github.com/a/b/pull/1", title: "Review me")]

        let rows = IntegrationNow.rows(from: [issues, reviews], on: true)

        #expect(rows.map(\.title) == ["Review me", "One"])
    }

    @Test func nowShowsReviewRequestsAndNewAssignments() {
        var pulls = folder(.pullRequests)
        pulls.state = .fine
        pulls.items = [LiveItem(key: "https://github.com/acme/rocket/pull/412", title: "Retry uploads", label: "To review", author: "dana", list: .reviewRequests),
                       LiveItem(key: "https://github.com/acme/rocket/pull/409", title: "Mine", label: "Ready", author: "rocket", list: .created)]
        var issues = folder(.linear(.assigned, workspace: "acme"))
        issues.state = .fine
        issues.items = [LiveItem(key: "https://linear.app/acme/issue/ENG-240", title: "CSV download", author: "ENG-240", arrived: Date()),
                        LiveItem(key: "https://linear.app/acme/issue/ENG-198", title: "Backlog", author: "ENG-198")]

        let rows = IntegrationNow.rows(from: [pulls, issues], on: true)
        let off = IntegrationNow.rows(from: [pulls, issues], on: false)

        #expect(rows.map(\.title) == ["Retry uploads", "CSV download"])
        #expect(rows.map(\.detail) == ["Review requested · dana", "Assigned to you · ENG-240"])
        #expect(rows.first?.id == "integration:https://github.com/acme/rocket/pull/412")
        #expect(off.isEmpty)
    }

    @Test func nowLeavesOutWhatWasOpenedPausedOrUnread() {
        var reviews = folder(.reviewRequests)
        reviews.state = .fine
        reviews.items = (1...4).map { LiveItem(key: "https://github.com/a/b/pull/\($0)", title: "PR \($0)") }
        reviews.items[0].opened = Date()
        var paused = reviews
        paused.id = UUID()
        paused.paused = true
        var waiting = folder(.reviewRequests)
        waiting.items = [LiveItem(key: "https://github.com/a/b/pull/9", title: "Not read yet")]

        let rows = IntegrationNow.rows(from: [paused, waiting, reviews], on: true)

        #expect(rows.map(\.title) == ["PR 2", "PR 3"])
    }

    @Test func aRowMarkedDoneMakesRoomForTheNext() {
        var reviews = folder(.reviewRequests)
        reviews.state = .fine
        reviews.items = (1...3).map { LiveItem(key: "https://github.com/a/b/pull/\($0)", title: "PR \($0)") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("now-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let memory = NowMemory(file: file)
        let now = Date()

        memory.done("integration:https://github.com/a/b/pull/1", at: now)
        let rows = IntegrationNow.rows(from: [reviews], on: true, at: now, memory: memory)

        #expect(rows.map(\.title) == ["PR 2", "PR 3"])
    }

    @Test func issueNamesOpenWhereTheyLive() throws {
        let repository = URL(string: "https://github.com/acme/rocket/pull/3/files")

        #expect(IssueRefs.match("acme/rocket#412")?.url.absoluteString == "https://github.com/acme/rocket/issues/412")
        #expect(IssueRefs.match(" acme/rocket.js#7 ")?.said == "acme/rocket.js#7")
        #expect(IssueRefs.match("#12", page: repository)?.url.absoluteString == "https://github.com/acme/rocket/issues/12")
        #expect(IssueRefs.match("#12", page: URL(string: "https://github.com/settings/profile")) == nil)
        #expect(IssueRefs.match("#12", page: URL(string: "https://example.com/acme/rocket")) == nil)
        #expect(IssueRefs.match("#12") == nil)
        #expect(IssueRefs.match("ENG-231") == nil)
        #expect(IssueRefs.match("acme/rocket #412") == nil)
        #expect(Address.url(from: "acme/rocket#412") == nil)
        #expect(Address.url(from: "ENG-231") == nil)
    }

    @Test func aLimitedLinearFolderWaitsAsLongAsLinearSays() async {
        let made = Integrations()
        made.exchange = { [weak self] request in
            guard let self, let (data, status) = session.answer(request, { _ in (Data(), 429) }) else { return nil }
            return (data, status, status == 429 ? ["Retry-After": "120"] : [:])
        }
        session.users = [LinearSessionFake.north]
        IntegrationReader.cookies = { _ in [HTTPCookie(properties: [.domain: "linear.app", .path: "/", .name: "s", .value: "fixture"])!] }

        let answer = await IntegrationReader.read(folder(.linear(.assigned)), with: made)

        #expect(answer == .missed(LiveMiss(cause: .limited, wait: 120)))
    }
}
