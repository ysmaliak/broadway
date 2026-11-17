import Foundation
import Testing
@testable import Search

struct NetworkReturnTests {
    private let page = URL(string: "https://example.com/news")!

    private func request(_ url: URL? = URL(string: "https://example.com/news"), method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url ?? URL(string: "about:blank")!)
        request.httpMethod = method
        request.httpBody = body
        return request
    }

    @Test func onlyAPlainGetToTheWebIsRemembered() {
        let cases: [(String?, Bool, String, Bool)] = [
            ("GET", false, "https://example.com/", true),
            (nil, false, "http://example.com/", true),
            ("get", false, "https://example.com/", true),
            ("POST", false, "https://example.com/", false),
            ("GET", true, "https://example.com/", false),
            ("GET", false, "file:///tmp/a.html", false),
            ("GET", false, "about:blank", false),
            ("GET", false, "data:text/plain,hi", false),
        ]

        let found = cases.map { NetworkReturn.remembers(method: $0.0, hasBody: $0.1, url: URL(string: $0.2)) }

        #expect(found == cases.map(\.3))
    }

    @Test func theFailuresThatWaitAreTheNetworkOnes() {
        let waits: [Int] = [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
                            NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed]
        let others: [Int] = [NSURLErrorBadServerResponse, NSURLErrorCannotParseResponse, NSURLErrorServerCertificateUntrusted,
                             NSURLErrorSecureConnectionFailed, NSURLErrorCancelled, NSURLErrorBadURL, NSURLErrorUnsupportedURL]

        let waiting = waits.map { NetworkReturn.waits(LoadFault(code: $0)) }
        let notWaiting = others.map { NetworkReturn.waits(LoadFault(code: $0)) }

        #expect(waiting.allSatisfy { $0 })
        #expect(notWaiting.allSatisfy { !$0 })
    }

    @Test func aWrappedOrPosixFailureIsReadToo() {
        let wrapped = NSError(domain: "WebKitErrorDomain", code: 1,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)])
        let refused = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
        let down = NSError(domain: NSPOSIXErrorDomain, code: Int(ENETDOWN))

        let faults = [LoadFault(error: wrapped), LoadFault(error: refused), LoadFault(error: down)]

        #expect(faults == [.cannotFindHost, .cannotConnect, .offline])
    }

    @Test func aFailedLoadWaitsUntilTheNetworkComesBack() {
        var wait = NetworkWait()
        wait.began(request(), returns: 3)

        let now = wait.failed(.offline, agent: false, returns: 3, available: false, onScreen: true)
        let waiting = wait.isWaiting
        let back = wait.returned(onScreen: true)

        #expect(now == nil)
        #expect(waiting)
        #expect(back?.url == page)
        #expect(!wait.isWaiting)
    }

    @Test func theNetworksWordBeforeTheFailureLoadsAtOnce() {
        var wait = NetworkWait()
        wait.began(request(), returns: 3)

        let now = wait.failed(.offline, agent: false, returns: 4, available: true, onScreen: true)

        #expect(now?.url == page)
        #expect(!wait.isWaiting)
    }

    @Test func theNetworksWordBeforeTheFailureIsOwedToATabOffScreen() {
        var wait = NetworkWait()
        wait.began(request(), returns: 3)

        let now = wait.failed(.offline, agent: false, returns: 4, available: true, onScreen: false)
        let owed = wait.owed
        let forward = wait.cameForward()

        #expect(now == nil)
        #expect(owed)
        #expect(forward?.url == page)
    }

    @Test func aReturnThatWentAwayAgainIsNotALoad() {
        var wait = NetworkWait()
        wait.began(request(), returns: 3)

        let now = wait.failed(.offline, agent: false, returns: 4, available: false, onScreen: true)

        #expect(now == nil)
        #expect(wait.isWaiting)
    }

    @Test func aTabOffScreenLoadsWhenItComesForwardOnce() {
        var wait = NetworkWait()
        wait.began(request(), returns: 0)
        _ = wait.failed(.cannotConnect, agent: false, returns: 0, available: false, onScreen: false)

        let away = wait.returned(onScreen: false)
        let first = wait.cameForward()
        let second = wait.cameForward()

        #expect(away == nil)
        #expect(first?.url == page)
        #expect(second == nil)
    }

    @Test func comingForwardBeforeTheNetworkReturnsLoadsNothing() {
        var wait = NetworkWait()
        wait.began(request(), returns: 0)
        _ = wait.failed(.cannotConnect, agent: false, returns: 0, available: false, onScreen: false)

        let forward = wait.cameForward()

        #expect(forward == nil)
        #expect(wait.isWaiting)
    }

    @Test func eachReturnLoadsOnce() {
        var wait = NetworkWait()
        wait.began(request(), returns: 0)
        _ = wait.failed(.timedOut, agent: false, returns: 0, available: false, onScreen: true)

        let first = wait.returned(onScreen: true)
        let second = wait.returned(onScreen: true)

        #expect(first != nil)
        #expect(second == nil)
    }

    @Test func anAgentsTabNeverWaits() {
        var wait = NetworkWait()
        wait.began(request(), returns: 0)

        let now = wait.failed(.offline, agent: true, returns: 1, available: true, onScreen: true)

        #expect(now == nil)
        #expect(!wait.isWaiting)
    }

    @Test func aPostThatFailsDoesNotWait() {
        var wait = NetworkWait()
        wait.began(request(method: "POST", body: Data("a=1".utf8)), returns: 0)

        _ = wait.failed(.offline, agent: false, returns: 0, available: false, onScreen: true)

        #expect(!wait.isWaiting)
    }

    @Test func aFailureThatIsNotTheNetworksDoesNotWait() {
        var wait = NetworkWait()
        wait.began(request(), returns: 0)

        _ = wait.failed(.badResponse, agent: false, returns: 0, available: false, onScreen: true)

        #expect(!wait.isWaiting)
    }

    @Test func loadingSomethingElseOrTryAgainEndsTheWaiting() {
        var other = LoadRetry()
        other.heads(request(), redirect: false, returns: 0)
        _ = other.network.failed(.offline, agent: false, returns: 0, available: false, onScreen: true)
        var again = other
        var committed = other

        other.heads(request(URL(string: "https://example.org/")), redirect: false, returns: 0)
        again.tryAgain()
        committed.committed()

        #expect(!other.network.isWaiting)
        #expect(!again.network.isWaiting)
        #expect(!committed.network.isWaiting)
    }

    @Test func theTabsOwnLoadAgainKeepsNothingButItsRequest() {
        var retry = LoadRetry()
        retry.heads(request(), redirect: false, returns: 0)
        _ = retry.network.failed(.offline, agent: false, returns: 0, available: false, onScreen: true)
        let taken = retry.network.returned(onScreen: true)
        retry.loadsOwn()

        retry.heads(taken!, redirect: false, returns: 1)

        #expect(retry.network.request?.url == page)
        #expect(retry.network.began == 1)
    }

    @Test func aRedirectKeepsTheWaitAndTakesTheNewRequest() {
        var retry = LoadRetry()
        retry.heads(request(), redirect: false, returns: 0)

        retry.heads(request(URL(string: "https://example.com/news/")), redirect: true, returns: 0)

        #expect(retry.network.request?.url?.absoluteString == "https://example.com/news/")
    }

    @Test func onlyAWayBackFromNoNetworkIsAReturn() {
        let first = NetworkPath.word(before: nil, now: true)
        let firstDown = NetworkPath.word(before: nil, now: false)
        let same = NetworkPath.word(before: true, now: true)
        let down = NetworkPath.word(before: true, now: false)
        let back = NetworkPath.word(before: false, now: true)

        #expect(first == .init(changed: true, returned: false))
        #expect(firstDown == .init(changed: true, returned: false))
        #expect(same == .init(changed: false, returned: false))
        #expect(down == .init(changed: true, returned: false))
        #expect(back == .init(changed: true, returned: true))
    }
}
