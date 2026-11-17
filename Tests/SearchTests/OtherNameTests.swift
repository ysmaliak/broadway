import Foundation
import Testing
@testable import Search

struct OtherNameTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func other(_ text: String) -> String? {
        OtherName.of(URL(string: text)!)?.absoluteString
    }

    private func sent(_ text: String, ago seconds: TimeInterval = 1) -> SentAddress {
        SentAddress(url: URL(string: text)!, at: start.addingTimeInterval(-seconds))
    }

    private func typedLoad(_ text: String, ago seconds: TimeInterval = 1) -> LoadRetry {
        var retry = LoadRetry()
        retry.heads(URLRequest(url: URL(string: text)!), redirect: false, returns: 0, sent: sent(text, ago: seconds))
        return retry
    }

    @Test func aBareNameGetsWwwAndAWwwNameLosesIt() {
        let found = [other("https://example.com/a?b=1"), other("https://www.example.com/"), other("http://shop.example.org/"),
                     other("https://www.shop.example.org/x")]

        #expect(found == ["https://www.example.com/a?b=1", "https://example.com/", "http://www.shop.example.org/",
                          "https://shop.example.org/x"])
    }

    @Test func someNamesHaveNoOtherName() {
        let found = ["https://www.com/", "https://192.0.2.10/", "http://printer.local/", "http://localhost/",
                     "https://example.com:8443/", "https://[2001:db8::1]/", "https://nas/", "https://example.123/",
                     "https://app.test/", "file:///tmp/a.html", "http://10.0.0.1/"].map(other)

        #expect(found.allSatisfy { $0 == nil })
    }

    @Test func theFailuresThatCountAreNoSuchNameNoAnswerAndTheWrongCertificate() {
        let counted: [Int] = [NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost,
                              NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot]
        let not: [Int] = [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                          NSURLErrorBadServerResponse, NSURLErrorServerCertificateHasBadDate, NSURLErrorCancelled]

        #expect(counted.allSatisfy { OtherName.counts(LoadFault(code: $0)) })
        #expect(not.allSatisfy { !OtherName.counts(LoadFault(code: $0)) })
    }

    @Test func aTypedAddressThatFailsGoesToTheOtherName() {
        var retry = typedLoad("https://example.com/")

        let step = retry.failed(.cannotFindHost, at: URL(string: "https://example.com/"), failure: "not found",
                                agent: false, returns: 0, available: true, onScreen: true, now: start)

        #expect(step == .go(URL(string: "https://www.example.com/")!))
    }

    @Test func ninetySecondsAfterSendingItIsTooLate() {
        var inTime = typedLoad("https://example.com/", ago: 90)
        var late = typedLoad("https://example.com/", ago: 91)

        let first = inTime.failed(.cannotFindHost, at: URL(string: "https://example.com/"), failure: nil,
                                  agent: false, returns: 0, available: true, onScreen: true, now: start)
        let second = late.failed(.cannotFindHost, at: URL(string: "https://example.com/"), failure: nil,
                                 agent: false, returns: 0, available: true, onScreen: true, now: start)

        #expect(first == .go(URL(string: "https://www.example.com/")!))
        #expect(second == .nothing)
    }

    @Test func aLoadThatWasNotTypedIsNeverRewritten() {
        var retry = LoadRetry()
        retry.heads(URLRequest(url: URL(string: "https://example.com/")!), redirect: false, returns: 0)

        let step = retry.failed(.cannotFindHost, at: URL(string: "https://example.com/"), failure: nil,
                                agent: false, returns: 0, available: true, onScreen: true, now: start)

        #expect(step == .nothing)
    }

    @Test func aFailureAtAnotherHostIsNotTheTypedOne() {
        var retry = typedLoad("https://example.com/")

        let step = retry.failed(.cannotFindHost, at: URL(string: "https://login.example.net/"), failure: nil,
                                agent: false, returns: 0, available: true, onScreen: true, now: start)

        #expect(step == .nothing)
    }

    @Test func theOtherNameIsTriedOnceAndThenTheTypedFailureShows() {
        var retry = typedLoad("https://example.com/")
        _ = retry.failed(.cannotFindHost, at: URL(string: "https://example.com/"), failure: "not found",
                         agent: false, returns: 0, available: true, onScreen: true, now: start)
        retry.loadsOwn()
        retry.heads(URLRequest(url: URL(string: "https://www.example.com/")!), redirect: false, returns: 0)

        let step = retry.failed(.cannotFindHost, at: URL(string: "https://www.example.com/"), failure: "other",
                                agent: false, returns: 0, available: true, onScreen: true, now: start)
        let again = retry.tryAgain()

        guard case .showFirst(let detour) = step else {
            Issue.record("expected the typed failure, got \(step)")
            return
        }
        #expect(detour.from.absoluteString == "https://example.com/")
        #expect(detour.failure == "not found")
        #expect(again?.absoluteString == "https://example.com/")
    }

    @Test func aCertificateProblemAtTheOtherNameIsShownThere() {
        var retry = typedLoad("https://example.com/")
        _ = retry.failed(.cannotConnect, at: URL(string: "https://example.com/"), failure: "refused",
                         agent: false, returns: 0, available: true, onScreen: true, now: start)
        retry.loadsOwn()
        retry.heads(URLRequest(url: URL(string: "https://www.example.com/")!), redirect: false, returns: 0)

        let step = retry.failed(.untrusted, at: URL(string: "https://www.example.com/"), failure: "insecure",
                                agent: false, returns: 0, available: true, onScreen: true, now: start)

        #expect(step == .showAt(URL(string: "https://www.example.com/")!))
    }

    @Test func onlyAnUntrustedOrMisnamedCertificateSkipsTheQuestion() {
        let found = [errSecHostNameMismatch, errSecNotTrusted, errSecCertificateExpired, errSecCertificateNotValidYet]
            .map { OtherName.countsTrust(Int($0)) }

        #expect(found == [true, true, false, false])
        #expect(!OtherName.countsTrust(nil))
    }

    @Test func theCertificateQuestionWaitsWhileTheOtherNameIsDue() {
        let fresh = typedLoad("https://example.com/")
        let stale = typedLoad("https://example.com/", ago: 120)
        let bare = typedLoad("https://www.com/")

        #expect(fresh.otherNameDue(for: "example.com", now: start))
        #expect(!fresh.otherNameDue(for: "cdn.example.net", now: start))
        #expect(!stale.otherNameDue(for: "example.com", now: start))
        #expect(!bare.otherNameDue(for: "www.com", now: start))
    }

    @Test func aWorkingNameIsRememberedForTheTypedOne() {
        let list = SiteNames.remembered([], typed: "example.com", named: "www.example.com", at: start)

        let going = SiteNames.sent(URL(string: "https://example.com/news?x=1")!, by: list)
        let other = SiteNames.sent(URL(string: "https://example.org/")!, by: list)
        let ported = SiteNames.sent(URL(string: "https://example.com:8443/")!, by: list)

        #expect(going.absoluteString == "https://www.example.com/news?x=1")
        #expect(other.absoluteString == "https://example.org/")
        #expect(ported.absoluteString == "https://example.com:8443/")
    }

    @Test func aSiteAnsweringAtTheFirstNameAgainIsForgotten() {
        let list = SiteNames.remembered([], typed: "example.com", named: "www.example.com", at: start)

        let answered = SiteNames.answered(list, host: "example.com")
        let elsewhere = SiteNames.answered(list, host: "www.example.com")

        #expect(answered.isEmpty)
        #expect(elsewhere == list)
    }

    @Test func rememberingTheReverseNameReplacesThePairSoNothingGoesInACircle() {
        let first = SiteNames.remembered([], typed: "example.com", named: "www.example.com", at: start)

        let turned = SiteNames.remembered(first, typed: "www.example.com", named: "example.com", at: start)

        #expect(turned == [SiteName(typed: "www.example.com", named: "example.com", at: start)])
    }

    @Test func atMostFiveHundredAreKeptAndTheOldestGoFirst() {
        var list: [SiteName] = []
        for n in 0..<502 {
            list = SiteNames.remembered(list, typed: "site\(n).example", named: "www.site\(n).example", at: start.addingTimeInterval(Double(n)))
        }

        #expect(list.count == 500)
        #expect(list.first?.typed == "site2.example")
        #expect(list.last?.typed == "site501.example")
    }

    @Test func aCommitAtTheOtherNameRemembersItAndAPrivateOneWritesNothing() {
        let detour = Detour(kind: .otherName, from: URL(string: "https://example.com/")!, to: URL(string: "https://www.example.com/")!,
                            failure: nil, waits: nil)
        let old = SiteNames.remembered([], typed: "www.example.com", named: "example.com", at: start)

        let kept = SiteNames.committed(old, at: "www.example.com", after: detour, privately: false, now: start)
        let privately = SiteNames.committed(old, at: "www.example.com", after: detour, privately: true, now: start)
        let plain = SiteNames.committed(old, at: "www.example.com", after: nil, privately: false, now: start)

        #expect(kept == [SiteName(typed: "example.com", named: "www.example.com", at: start)])
        #expect(privately == old)
        #expect(plain.isEmpty)
    }

    @Test func forgettingASiteOrALatePeriodTakesItsNames() {
        let list = SiteNames.remembered(SiteNames.remembered([], typed: "example.com", named: "www.example.com", at: start),
                                        typed: "shop.example.org", named: "www.shop.example.org", at: start.addingTimeInterval(60))

        let site = SiteNames.forgotten(list, site: "example.com")
        let since = SiteNames.forgotten(list, since: start.addingTimeInterval(30))

        #expect(site.map(\.typed) == ["shop.example.org"])
        #expect(since.map(\.typed) == ["example.com"])
    }
}
