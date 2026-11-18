import Foundation
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LiveReplayTests {
    private let source = LiveSource(kind: .pullRequests, address: "https://github.com/pulls?q=is%3Aopen+is%3Apr+author%3A%40me")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var server: LocalPageServer!

    init() throws {
        setenv("SEARCH_PROBE", "live-replay-\(getpid())", 1)
        addTeardownBlock { await self.tearDown() }
        let head = #"<!doctype html><meta name="user-login" content="octo-sam"><title>Pull requests</title>"#
        func rows(_ numbers: [Int], prefix: String = "/acme/rocket/pull/") -> String {
            "<ul>" + numbers.map { #"<li class="js-issue-row"><a href="\#(prefix)\#($0)">Teach the rocket to count stars \#($0)</a></li>"# }
                .joined() + "</ul>"
        }
        func html(_ body: String) -> LocalPageServer.Page { .init(type: "text/html", body: head + body) }
        server = try LocalPageServer([
            "/list": html(rows([1, 2, 3])),
            "/empty": html("<main><h3>No results matched your search.</h3></main>"),
            "/cut": html(rows([1])),
            "/limit": .init(status: "429 Too Many Requests", type: "text/html", body: "<!doctype html><p>Slow down</p>",
                            headers: ["Retry-After": "120"]),
            "/secondary": .init(status: "403 Forbidden", type: "text/html",
                                body: "<!doctype html><h1>Access to this site has been restricted.</h1><p>You have exceeded a secondary rate limit.</p>"),
            "/forbidden": .init(status: "403 Forbidden", type: "text/html", body: "<!doctype html><p>Forbidden</p>"),
            "/slow": html("<main><h3>This search took too long to finish.</h3></main>"),
            "/login": .init(type: "text/html", body: #"<!doctype html><form action="/session"><input name="login"><input type="password" name="password"></form>"#),
            "/sso": .init(type: "text/html", body: try banner()),
            "/renamed": html(rows([7, 8], prefix: "/acme/rocket/merge-requests/")),
        ])
    }

    private func tearDown() async {
        server.stop()
        server = nil
    }

    private func banner() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("IntegrationFixtures/github-sso-banner.html"), encoding: .utf8)
    }

    private func read(_ path: String) async -> LiveReader.Answer {
        await LiveReader.readPage(server.url(path), source: source, store: .nonPersistent())
    }

    private func pull(_ number: Int) -> LiveItem {
        LiveItem(key: server.url("/acme/rocket/pull/\(number)").absoluteString, title: "Teach the rocket to count stars \(number)")
    }

    private func folder(_ numbers: [Int]) -> LiveFolder {
        var made = LiveFolder(space: UUID(), name: "PRs", source: source)
        made.items = numbers.map(pull)
        made.state = .fine
        made.noticing = true
        return made
    }

    @Test func aGoodListReadsWhole() async {
        let answer = await read("/list")

        #expect(answer.found?.count == 3)
        #expect(answer.whole)
    }

    @Test func theSitesNothingHereMarkerProvesAnEmptyList() async {
        let answer = await read("/empty")
        let after = LiveTrust.after(folder([1, 2]), answer, now: now)

        guard case .read(let read) = answer else { Issue.record("not a read: \(answer)"); return }
        #expect(read.marked)
        #expect(after.items.isEmpty && after.note == .empty)
    }

    @Test func aListCutShortOnceDoesNotTakeRows() async {
        var paths = ["/cut", "/list"]

        let answer = await LiveTrust.looked(folder([1, 2, 3]).items, known: [], pause: .zero) { await self.read(paths.removeFirst()) }
        let after = LiveTrust.after(folder([1, 2, 3]), answer, now: now)

        #expect(paths.isEmpty)
        #expect(after.items.count == 3)
    }

    @Test func tooManyRequestsWithRetryAfterIsALimit() async {
        let answer = await read("/limit")

        #expect(answer == .missed(LiveMiss(cause: .limited, wait: 120)))
    }

    @Test func theSitesOwnLimitPageIsALimitAndNotASignOut() async {
        let answer = await read("/secondary")
        let after = LiveTrust.after(folder([1]), answer, now: now)

        #expect(answer == .missed(LiveMiss(cause: .limited)))
        #expect(after.status == "Limited")
        #expect(after.items.count == 1)
    }

    @Test func aPlainForbiddenPageStillAsksToSignIn() async {
        #expect(await read("/forbidden") == .signIn)
    }

    @Test func aSearchThatTimedOutKeepsTheRows() async {
        let answer = await LiveTrust.looked(folder([1, 2]).items, known: [], pause: .zero) { await self.read("/slow") }
        let after = LiveTrust.after(folder([1, 2]), answer, now: now)

        #expect(after.items.count == 2)
        #expect(after.status == "Can't read")
    }

    @Test func aSignInPageAsksToSignIn() async {
        #expect(await read("/login") == .signIn)
    }

    @Test func aSingleSignOnPageAsksForSingleSignOn() async {
        guard case .sso(let sso, _) = await read("/sso") else { Issue.record("not single sign-on"); return }
        #expect(sso.org == "Octo Corp")
    }

    @Test func rowsUnderNamesTheReaderDoesNotKnowReadAsFailedAndNeverEmpty() async {
        let answer = await LiveTrust.looked(folder([1, 2]).items, known: [], pause: .zero) { await self.read("/renamed") }
        let after = LiveTrust.after(folder([1, 2]), answer, now: now)

        #expect(after.state == .failed)
        #expect(after.note == .failed)
        #expect(after.items.count == 2)
    }
}
