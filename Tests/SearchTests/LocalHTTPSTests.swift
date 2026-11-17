import Foundation
import Testing
@testable import Search

struct LocalHTTPSTests {
    private func candidate(_ text: String) -> String? {
        LocalHTTPS.candidate(for: URL(string: text)!)?.absoluteString
    }

    private func request(_ text: String) -> URLRequest {
        URLRequest(url: URL(string: text)!)
    }

    @Test func aLocalHttpAddressHasAnHttpsOneWithItsHostPortAndPath() {
        let found = [
            candidate("http://192.168.1.20/admin?tab=2#top"),
            candidate("http://printer.local/"),
            candidate("http://localhost:8443/app"),
            candidate("http://10.0.0.5:3000/"),
            candidate("http://dev.localhost:5173/x"),
            candidate("http://[::1]:3000/"),
        ]

        #expect(found == [
            "https://192.168.1.20/admin?tab=2#top",
            "https://printer.local/",
            "https://localhost:8443/app",
            "https://10.0.0.5:3000/",
            "https://dev.localhost:5173/x",
            "https://[::1]:3000/",
        ])
    }

    @Test func anExplicitPortEightyIsDropped() {
        let found = candidate("http://172.16.4.2:80/setup")

        #expect(found == "https://172.16.4.2/setup")
    }

    @Test func aPublicOrHttpsAddressHasNone() {
        let found = ["http://example.com/", "https://localhost:8443/", "http://8.8.8.8/", "ftp://printer.local/", "http://10.io/"]
            .map(candidate)

        #expect(found.allSatisfy { $0 == nil })
    }

    @Test func localIsWhatTheAddressFieldCallsLocal() {
        let hosts = ["localhost", "app.localhost", "printer.local", "127.0.0.1", "0.0.0.0", "10.1.2.3", "192.168.0.9",
                     "172.20.0.1", "::1", "example.com", "172.32.0.1", "nas", "10.io"]

        let local = hosts.map { Address.isLocal(host: $0) }

        #expect(local == [true, true, true, true, true, true, true, true, true, false, false, false, false])
    }

    @Test func theFailuresThatSayTryHttpsAreAnswersThatAreNotHttp() {
        let counted: [Int] = [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                              NSURLErrorCannotParseResponse, NSURLErrorBadServerResponse]
        let not: [Int] = [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                          NSURLErrorNotConnectedToInternet, NSURLErrorServerCertificateUntrusted]

        #expect(counted.allSatisfy { LocalHTTPS.counts(LoadFault(code: $0)) })
        #expect(not.allSatisfy { !LocalHTTPS.counts(LoadFault(code: $0)) })
    }

    @Test func aRefusedLocalLoadGoesToHttps() {
        var retry = LoadRetry()
        retry.heads(request("http://192.168.1.20/"), redirect: false, returns: 0)

        let step = retry.failed(.cannotConnect, at: URL(string: "http://192.168.1.20/"), failure: "refused",
                                agent: false, returns: 0, available: true, onScreen: true)

        #expect(step == .go(URL(string: "https://192.168.1.20/")!))
        #expect(!retry.network.isWaiting)
    }

    @Test func aFailedPostIsNotSentToHttps() {
        var retry = LoadRetry()
        var post = request("http://192.168.1.20/save")
        post.httpMethod = "POST"
        retry.heads(post, redirect: false, returns: 0)

        let step = retry.failed(.cannotConnect, at: URL(string: "http://192.168.1.20/save"), failure: "refused",
                                agent: false, returns: 0, available: true, onScreen: true)

        #expect(step == .nothing)
    }

    @Test func aTimeoutDoesNotTryHttps() {
        var retry = LoadRetry()
        retry.heads(request("http://192.168.1.20/"), redirect: false, returns: 0)

        let step = retry.failed(.timedOut, at: URL(string: "http://192.168.1.20/"), failure: "slow",
                                agent: false, returns: 0, available: false, onScreen: true)

        #expect(step == .nothing)
        #expect(retry.network.isWaiting)
    }

    @Test func nothingAtHttpsShowsTheHttpFailureAndTryAgainTriesHttp() {
        var retry = LoadRetry()
        let http = URL(string: "http://192.168.1.20/")!
        retry.heads(request(http.absoluteString), redirect: false, returns: 0)
        _ = retry.failed(.cannotConnect, at: http, failure: "refused", agent: false, returns: 0, available: false, onScreen: true)
        retry.loadsOwn()
        retry.heads(request("https://192.168.1.20/"), redirect: false, returns: 0)

        let step = retry.failed(.cannotConnect, at: URL(string: "https://192.168.1.20/"), failure: "other",
                                agent: false, returns: 0, available: false, onScreen: true)
        let waiting = retry.network.waiting?.url
        let again = retry.tryAgain()

        guard case .showFirst(let detour) = step else {
            Issue.record("expected the first failure, got \(step)")
            return
        }
        #expect(detour.from == http)
        #expect(detour.failure == "refused")
        #expect(waiting == http)
        #expect(again == http)
        #expect(!retry.network.isWaiting)
    }

    @Test func aCertificateAtHttpsMeansSomethingAnsweredThere() {
        var retry = LoadRetry()
        let http = URL(string: "http://printer.local/")!
        retry.heads(request(http.absoluteString), redirect: false, returns: 0)
        _ = retry.failed(.cannotParse, at: http, failure: "other", agent: false, returns: 0, available: true, onScreen: true)
        retry.loadsOwn()
        retry.heads(request("https://printer.local/"), redirect: false, returns: 0)

        let step = retry.failed(.untrusted, at: URL(string: "https://printer.local/"), failure: "insecure",
                                agent: false, returns: 0, available: true, onScreen: true)

        #expect(step == .showAt(URL(string: "https://printer.local/")!))
        #expect(retry.tryAgain() == nil)
    }

    @Test func anAgentsTabIsNotSentToHttps() {
        var retry = LoadRetry()
        retry.heads(request("http://localhost:3000/"), redirect: false, returns: 0)

        let step = retry.failed(.cannotConnect, at: URL(string: "http://localhost:3000/"), failure: "refused",
                                agent: true, returns: 0, available: true, onScreen: true)

        #expect(step == .nothing)
    }

    @Test func aCommitAtHttpsEndsTheDetour() {
        var retry = LoadRetry()
        let http = URL(string: "http://localhost:3000/")!
        retry.heads(request(http.absoluteString), redirect: false, returns: 0)
        _ = retry.failed(.cannotConnect, at: http, failure: "refused", agent: false, returns: 0, available: true, onScreen: true)
        retry.loadsOwn()
        retry.heads(request("https://localhost:3000/"), redirect: false, returns: 0)

        let ended = retry.committed()

        #expect(ended?.kind == .https)
        #expect(retry.detour == nil)
        #expect(retry.tryAgain() == nil)
    }
}
