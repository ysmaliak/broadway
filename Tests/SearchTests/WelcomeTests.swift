import Foundation
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5))) struct TroubleTests {
    @Test(arguments: [
        (NSURLErrorCannotFindHost, TroubleKind.notFound),
        (NSURLErrorDNSLookupFailed, .notFound),
        (NSURLErrorNotConnectedToInternet, .offline),
        (NSURLErrorNetworkConnectionLost, .offline),
        (NSURLErrorTimedOut, .slow),
        (NSURLErrorCannotConnectToHost, .refused),
        (NSURLErrorServerCertificateUntrusted, .insecure),
        (NSURLErrorServerCertificateHasBadDate, .insecure),
        (NSURLErrorBadServerResponse, .other),
    ])
    func eachLoadErrorHasItsKind(code: Int, kind: TroubleKind) {
        let found = TroubleKind(code: code)

        #expect(found == kind)
    }

    @Test(arguments: TroubleKind.allCases)
    func theMessageLeadsBackToItsKind(_ kind: TroubleKind) {
        let read = TroubleKind(message: kind.message)

        #expect(read == kind)
    }

    @Test func messagesAreShortAndDistinct() {
        let messages = TroubleKind.allCases.map(\.message)

        #expect(Set(messages).count == messages.count)
        #expect(messages.allSatisfy { $0.count <= 40 && !$0.hasSuffix(".") })
    }

    @Test func theLineNamesTheSite() {
        let named = TroubleKind.notFound.line(host: "example.test")
        let unnamed = TroubleKind.refused.line(host: nil)

        #expect(named.contains("\u{201C}example.test\u{201D}"))
        #expect(unnamed.hasPrefix("This site"))
    }

    @Test func anUnknownMessageIsTheGeneralKind() {
        let read = TroubleKind(message: "Something new.")

        #expect(read == .other)
    }
}

@Suite(.timeLimit(.minutes(5))) struct DelightTests {
    @Test func aMomentIsCelebratedOnce() {
        let first = Delight.due(.firstPin, testing: false, forced: false, done: false)
        let again = Delight.due(.firstPin, testing: false, forced: false, done: true)

        #expect(first)
        #expect(!again)
    }

    @Test func testRunsStayQuietUnlessAsked() {
        let quiet = Delight.due(.firstSpace, testing: true, forced: false, done: false)
        let asked = Delight.due(.firstSpace, testing: true, forced: true, done: false)

        #expect(!quiet)
        #expect(asked)
    }

    @Test(arguments: Delight.Moment.allCases)
    func eachMomentHasItsOwnKeyAndLine(_ moment: Delight.Moment) {
        let others = Delight.Moment.allCases.filter { $0 != moment }

        #expect(moment.rawValue.hasPrefix("delight."))
        #expect(!moment.line.isEmpty)
        #expect(others.allSatisfy { $0.rawValue != moment.rawValue && $0.line != moment.line })
    }
}

@Suite(.timeLimit(.minutes(5))) struct TroubleErrorTests {
    @Test func aRefusedSocketIsRefused() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))

        let kind = TroubleKind(error: error)

        #expect(kind == .refused)
    }

    @Test func theUnderlyingErrorIsReadWhenTheOuterOneSaysLittle() {
        let under = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let error = NSError(domain: "WebKitErrorDomain", code: 999, userInfo: [NSUnderlyingErrorKey: under])

        let kind = TroubleKind(error: error)

        #expect(kind == .offline)
    }

    @Test func aURLErrorIsReadByItsCode() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)

        let kind = TroubleKind(error: error)

        #expect(kind == .notFound)
    }
}
