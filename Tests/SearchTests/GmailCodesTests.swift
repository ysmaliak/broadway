import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
struct GmailAccountTests {
    @Test @MainActor func theAccountComesFromTheGmailTab() {
        let pages = [URL(string: "https://example.com/mail/u/7/"), nil, URL(string: "https://mail.google.com/mail/u/2/#inbox")]

        #expect(GmailAccount.index(among: pages) == 2)
    }

    @Test @MainActor func withNoGmailTabItIsTheFirstAccount() {
        #expect(GmailAccount.index(among: []) == 0)
        #expect(GmailAccount.index(among: [URL(string: "https://mail.google.com/mail/?ui=2")]) == 0)
    }

    @Test @MainActor func theFeedAddressIsGooglesOwn() {
        #expect(GmailAccount.feed(account: 3)?.absoluteString == "https://mail.google.com/mail/u/3/feed/atom")
    }

    @MainActor
    @Test func aSessionIsSeenOnlyFromGooglesSignInCookie() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let other = try #require(HTTPCookie(properties: [.domain: ".example.com", .path: "/", .name: "SID", .value: "x"]))
        await store.httpCookieStore.setCookie(other)
        let before = await GmailAccount.signedIn(store)
        let google = try #require(HTTPCookie(properties: [.domain: ".google.com", .path: "/", .name: "SID", .value: "x"]))

        await store.httpCookieStore.setCookie(google)
        let after = await GmailAccount.signedIn(store)

        #expect(!before)
        #expect(after)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct GmailAtomTests {
    private let since = ISO8601DateFormatter().date(from: "2026-11-02T10:00:00Z")!

    private func entry(_ title: String, _ summary: String, _ stamp: String, from name: String = "Acme") -> String {
        """
        <entry><title>\(title)</title><summary>\(summary)</summary><link rel="alternate" href="https://mail.google.com/x"/>
        <modified>\(stamp)</modified><issued>\(stamp)</issued><id>tag:gmail.google.com,2004:1</id>
        <author><name>\(name)</name><email>no-reply@acme.example</email></author></entry>
        """
    }

    private func feed(_ entries: String...) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?><feed version="0.3" xmlns="http://purl.org/atom/ns#">
        <title>Gmail - Inbox for someone@example.com</title><tagline>New messages</tagline><fullcount>1</fullcount>
        <modified>2026-11-02T10:30:00Z</modified>\(entries.joined())</feed>
        """
    }

    @Test func aCodeInTheSubjectIsFoundWithItsSender() {
        let xml = feed(entry("Your verification code is 482913", "Thanks for signing in", "2026-11-02T10:20:00Z"))

        let codes = GmailAtom.codes(in: xml, since: since)

        #expect(codes.map(\.code) == ["482913"])
        #expect(codes.first?.sender == "Acme")
        #expect(codes.first?.detail == "Gmail · Acme")
    }

    @Test func aCodeInTheSnippetIsFound() {
        let xml = feed(entry("Sign in to Acme", "Use this code: 771204 to finish", "2026-11-02T10:20:00Z"))

        #expect(GmailAtom.codes(in: xml, since: since).map(\.code) == ["771204"])
    }

    @Test func oldMailAndOrdinaryMailAreLeftAlone() {
        let xml = feed(
            entry("Your verification code is 111111", "", "2026-11-02T09:00:00Z"),
            entry("Your order 482913 has shipped", "It arrives Friday", "2026-11-02T10:20:00Z"),
            entry("Your code is 222222", "", "not a date"))

        #expect(GmailAtom.codes(in: xml, since: since).isEmpty)
    }

    @Test func brokenXMLGivesNothing() {
        #expect(GmailAtom.codes(in: "<html><body>Sign in", since: since).isEmpty)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct GmailCodesTests {
    private final class Fake: GmailFeed {
        var answers: [GmailAnswer]
        var asked = 0

        init(_ answers: [GmailAnswer]) { self.answers = answers }

        func fetch() async -> GmailAnswer {
            asked += 1
            return answers.isEmpty ? .failed : answers.removeFirst()
        }
    }

    private let xml = """
    <feed><entry><title>Your code is 482913</title><summary></summary><modified>2999-01-01T00:00:00Z</modified>
    <author><name>Acme</name></author></entry></feed>
    """

    @Test func itSaysSoBeforeItLooksAndOnlyOnce() async {
        let feed = Fake([.xml("<feed/>"), .xml(xml)])
        var saidBeforeFetch: [Int] = []
        let source = GmailCodes(feed: feed, signedIn: { true }, told: { saidBeforeFetch.append(feed.asked) })

        let first = await source.read(since: Date())
        _ = await source.read(since: Date())
        let third = await source.read(since: Date())

        #expect(first == .nothing)
        #expect(saidBeforeFetch == [0])
        guard case .found(let codes) = third else { Issue.record("\(third)"); return }
        #expect(codes.map(\.code) == ["482913"])
    }

    @Test func itAsksGmailEveryOtherTurn() async {
        let feed = Fake([])
        let source = GmailCodes(feed: feed, signedIn: { true }, told: {})

        for _ in 0..<4 { _ = await source.read(since: Date()) }

        #expect(feed.asked == 2)
    }

    @Test func withNoSignInNothingIsAskedAndNothingIsSaid() async {
        let feed = Fake([.xml(xml)])
        var said = 0
        let source = GmailCodes(feed: feed, signedIn: { false }, told: { said += 1 })

        let read = await source.read(since: Date())

        #expect(read == .quiet)
        #expect(feed.asked == 0)
        #expect(said == 0)
    }

    @Test func aSignInThatTurnsOutOverStopsTheLooking() async {
        let feed = Fake([.signedOut, .xml(xml)])
        let source = GmailCodes(feed: feed, signedIn: { true }, told: {})

        let first = await source.read(since: Date())
        _ = await source.read(since: Date())
        let third = await source.read(since: Date())

        #expect(first == .quiet)
        #expect(third == .quiet)
        #expect(feed.asked == 1)
    }

    @Test func aFailureIsQuietAndTriedAgain() async {
        let feed = Fake([.failed, .failed])
        let source = GmailCodes(feed: feed, signedIn: { true }, told: {})

        let first = await source.read(since: Date())
        _ = await source.read(since: Date())
        let third = await source.read(since: Date())

        #expect(first == .quiet)
        #expect(third == .quiet)
        #expect(feed.asked == 2)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct WebGmailFeedTests {
    private func feed(_ server: LocalPageServer, _ path: String = "/mail/u/0/feed/atom") -> WebGmailFeed {
        WebGmailFeed(address: URL(string: "http://127.0.0.1:\(server.port)\(path)")!, store: .nonPersistent())
    }

    init() async throws {        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    @Test func theFeedComesBackAsXML() async throws {
        let server = try LocalPageServer(["/mail/u/0/feed/atom": .init(
            type: "application/atom+xml; charset=UTF-8",
            body: "<?xml version=\"1.0\"?><feed xmlns=\"http://purl.org/atom/ns#\"><entry><title>Your code is 482913</title></entry></feed>")])

        let answer = await feed(server).fetch()

        guard case .xml(let text) = answer else { Issue.record("\(answer)"); return }
        #expect(text.contains("482913"))
    }

    @Test func aRedirectToSignInIsSignedOutAndNotFollowed() async throws {
        let server = try LocalPageServer([
            "/mail/u/0/feed/atom": .init(status: "302 Found", type: "text/html\r\nLocation: /accounts/signin", body: ""),
            "/accounts/signin": .init(type: "text/html", body: "<title>Sign in</title>"),
        ])

        let answer = await feed(server).fetch()

        #expect(answer == .signedOut)
        #expect(!server.requests.contains("/accounts/signin"))
    }

    @Test func refusedIsSignedOut() async throws {
        let server = try LocalPageServer(["/mail/u/0/feed/atom": .init(status: "403 Forbidden", type: "text/html", body: "no")])

        let answer = await feed(server).fetch()

        #expect(answer == .signedOut)
    }

    @Test func aBrokenServerIsAFailure() async throws {
        let server = try LocalPageServer(["/mail/u/0/feed/atom": .init(status: "500 Oops", type: "text/html", body: "no")])

        let answer = await feed(server).fetch()

        #expect(answer == .failed)
    }

    @Test func itAlwaysAsksAfresh() async throws {
        let server = try LocalPageServer(["/mail/u/0/feed/atom": .init(type: "application/atom+xml", body: "<feed/>")])
        let feed = feed(server)

        _ = await feed.fetch()
        _ = await feed.fetch()

        #expect(server.requests.filter { $0 == "/mail/u/0/feed/atom" }.count == 2)
    }
}
