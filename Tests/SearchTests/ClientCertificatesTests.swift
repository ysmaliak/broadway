import Foundation
import Testing
@testable import Search

@Suite("Client certificates")
struct ClientCertificatesTests {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let space = CertificateHolder.space(UUID())
    let issuerA = ClientCertificateFixtures.subject(of: ClientCertificateFixtures.authority)

    private func candidate(_ id: String, issuer: Data? = nil, sign: Bool = true, until: TimeInterval = 86_400, from: TimeInterval? = nil) -> ClientCandidate {
        ClientCandidate(id: id, name: "Pat Example", issuer: issuer ?? issuerA, issuerName: "Example Test CA",
                        notBefore: from.map { now.addingTimeInterval($0) }, notAfter: now.addingTimeInterval(until), canSign: sign)
    }

    private func endpoint(_ host: String = "portal.example.org", port: Int = 443, holder: CertificateHolder? = nil) -> ClientEndpoint {
        ClientEndpoint(holder: holder ?? space, host: host, port: port)
    }

    private func request(_ endpoint: ClientEndpoint, page: Bool = true, onScreen: Bool = true, agent: Bool = false,
                         fitting: [ClientCandidate]? = nil) -> ClientCertificates.Request {
        ClientCertificates.Request(endpoint: endpoint, isPage: page, onScreen: onScreen, agent: agent, fitting: fitting ?? [candidate("one")])
    }

    final class Replies {
        var got: [ClientReply] = []
    }

    @Test func aCertificateIsReadFromItsOwnBytes() throws {
        let read = try #require(ClientCandidate(der: ClientCertificateFixtures.signing, id: "a"))

        #expect(read.name == "Pat Example sign")
        #expect(read.issuerName == "Example Test CA")
        #expect(read.canSign)
        #expect(read.notAfter > read.notBefore ?? .distantFuture)
        #expect(DistinguishedName(der: read.issuer) == DistinguishedName(der: issuerA))
    }

    @Test func aCertificateWhoseKeyCannotSignIsReadAsSuch() throws {
        let read = try #require(ClientCandidate(der: ClientCertificateFixtures.notSigning, id: "b"))

        #expect(!read.canSign)
    }

    @Test func aCertificateFitsWhenItsIssuerIsOneTheServerNamed() throws {
        let read = try #require(ClientCandidate(der: ClientCertificateFixtures.signing, id: "a"))
        let other = ClientCertificateFixtures.subject(of: ClientCertificateFixtures.signing)

        #expect(ClientCertificates.fitting([read], asked: [other, issuerA], at: read.notAfter.addingTimeInterval(-60)) == [read])
        #expect(ClientCertificates.fitting([read], asked: [other], at: read.notAfter.addingTimeInterval(-60)).isEmpty)
    }

    @Test func anyCertificateFitsWhenTheServerNamedNoIssuer() {
        let mine = candidate("one", issuer: ClientCertificateFixtures.subject(of: ClientCertificateFixtures.signing))

        #expect(ClientCertificates.fitting([mine], asked: [], at: now) == [mine])
    }

    @Test func aCertificateThatCannotSignDoesNotFit() {
        #expect(ClientCertificates.fitting([candidate("one", sign: false)], asked: [], at: now).isEmpty)
    }

    @Test func anExpiredCertificateDoesNotFit() {
        #expect(ClientCertificates.fitting([candidate("one", until: -1)], asked: [], at: now).isEmpty)
        #expect(ClientCertificates.fitting([candidate("one", until: 0)], asked: [], at: now).isEmpty)
    }

    @Test func aCertificateNotYetValidDoesNotFit() {
        #expect(ClientCertificates.fitting([candidate("one", from: 60)], asked: [], at: now).isEmpty)
    }

    @Test func issuerNamesMatchWithoutRegardToCaseOrSpacing() {
        let plain = Data([0x30, 0x14, 0x31, 0x12, 0x30, 0x10, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0C, 0x09] + Array("Office CA".utf8))
        let loud = Data([0x30, 0x15, 0x31, 0x13, 0x30, 0x11, 0x06, 0x03, 0x55, 0x04, 0x03, 0x13, 0x0A] + Array("OFFICE  CA".utf8))

        #expect(DistinguishedName(der: plain) == DistinguishedName(der: loud))
        #expect(DistinguishedName(der: plain)?.common == "Office CA")
    }

    @Test func noQuestionWhenNoCertificateFits() {
        let book = ClientCertificates()
        let replies = Replies()

        let step = book.request(request(endpoint(), fitting: [])) { replies.got.append($0) }

        #expect(step == .answered)
        #expect(replies.got == [.none])
        #expect(book.kept.isEmpty)
        #expect(book.showing == nil)
    }

    @Test func oneQuestionPerEndpointAndLaterChallengesJoinIt() {
        let book = ClientCertificates()
        let replies = Replies()

        #expect(book.request(request(endpoint())) { replies.got.append($0) } == .queued(showNow: true))
        #expect(book.request(request(endpoint())) { replies.got.append($0) } == .joined)
        #expect(book.request(request(endpoint(), onScreen: false)) { replies.got.append($0) } == .joined)
        #expect(replies.got.isEmpty)

        book.answer(endpoint(), with: .identity("one"))

        #expect(replies.got == [.use("one"), .use("one"), .use("one")])
    }

    @Test func aKeptChoiceAnswersTheNextChallengeWithoutAQuestion() {
        let book = ClientCertificates()
        let replies = Replies()
        _ = book.request(request(endpoint())) { _ in }
        book.answer(endpoint(), with: .identity("one"))

        #expect(book.request(request(endpoint())) { replies.got.append($0) } == .answered)
        #expect(replies.got == [.use("one")])
    }

    @Test func aKeptRefusalAnswersWithNoCertificate() {
        let book = ClientCertificates()
        let replies = Replies()
        _ = book.request(request(endpoint())) { replies.got.append($0) }
        book.answer(endpoint(), with: .refused)

        #expect(book.request(request(endpoint())) { replies.got.append($0) } == .answered)
        #expect(replies.got == [.none, .none])
    }

    @Test func aKeptChoiceThatNoLongerFitsSendsNoCertificate() {
        let book = ClientCertificates()
        let replies = Replies()
        _ = book.request(request(endpoint())) { _ in }
        book.answer(endpoint(), with: .identity("one"))

        _ = book.request(request(endpoint(), fitting: [candidate("two")])) { replies.got.append($0) }

        #expect(replies.got == [.none])
    }

    @Test func anotherPortOrHostIsAnotherQuestion() {
        let book = ClientCertificates()
        _ = book.request(request(endpoint())) { _ in }
        book.answer(endpoint(), with: .refused)

        #expect(book.request(request(endpoint(port: 8443))) { _ in } == .queued(showNow: true))
        book.answer(endpoint(port: 8443), with: .refused)
        #expect(book.request(request(endpoint("other.example.org"))) { _ in } == .queued(showNow: true))
    }

    @Test func anAgentsTabIsNeverAskedAndGetsNoCertificate() {
        let book = ClientCertificates()
        let replies = Replies()
        _ = book.request(request(endpoint())) { _ in }
        book.answer(endpoint(), with: .identity("one"))

        #expect(book.request(request(endpoint("new.example.org"), agent: true)) { replies.got.append($0) } == .answered)
        #expect(book.request(request(endpoint(), agent: true)) { replies.got.append($0) } == .answered)
        #expect(replies.got == [.none, .none])
        #expect(book.kept[endpoint("new.example.org")] == nil)
    }

    @Test func aTabOutOfSightIsNeverAskedAndNothingIsKept() {
        let book = ClientCertificates()
        let replies = Replies()

        #expect(book.request(request(endpoint(), onScreen: false)) { replies.got.append($0) } == .answered)
        #expect(replies.got == [.none])
        #expect(book.kept.isEmpty)
        #expect(book.request(request(endpoint())) { _ in } == .queued(showNow: true))
    }

    @Test func aTabOutOfSightUsesAnAnswerAlreadyGiven() {
        let book = ClientCertificates()
        let replies = Replies()
        _ = book.request(request(endpoint())) { _ in }
        book.answer(endpoint(), with: .identity("one"))

        _ = book.request(request(endpoint(), onScreen: false)) { replies.got.append($0) }

        #expect(replies.got == [.use("one")])
    }

    @Test func somethingThePageLoadsFromAnotherHostIsNeverAsked() {
        let book = ClientCertificates()
        let replies = Replies()

        #expect(book.request(request(endpoint(), page: false)) { replies.got.append($0) } == .answered)
        #expect(replies.got == [.none])
        #expect(book.kept.isEmpty)
    }

    @Test func onlyOneQuestionIsUpAtATimeAndTheNextFollows() {
        let book = ClientCertificates()
        let replies = Replies()
        _ = book.request(request(endpoint())) { _ in }

        #expect(book.request(request(endpoint("other.example.org"))) { replies.got.append($0) } == .queued(showNow: false))
        #expect(book.answer(endpoint(), with: .refused) == endpoint("other.example.org"))
        #expect(book.showing == endpoint("other.example.org"))
        book.answer(endpoint("other.example.org"), with: .identity("one"))
        #expect(replies.got == [.use("one")])
        #expect(book.showing == nil)
    }

    @Test func aQuestionAbandonedSendsNoCertificateAndKeepsNothing() {
        let book = ClientCertificates()
        let replies = Replies()
        _ = book.request(request(endpoint())) { replies.got.append($0) }
        _ = book.request(request(endpoint())) { replies.got.append($0) }

        book.abandon(endpoint())

        #expect(replies.got == [.none, .none])
        #expect(book.kept.isEmpty)
        #expect(book.request(request(endpoint())) { _ in } == .queued(showNow: true))
    }

    @Test func aPrivateStoreKeepsItsAnswersApart() {
        let book = ClientCertificates()
        let window = CertificateHolder.passing(UUID())
        _ = book.request(request(endpoint(holder: window))) { _ in }
        book.answer(endpoint(holder: window), with: .identity("one"))

        #expect(book.request(request(endpoint())) { _ in } == .queued(showNow: true))
        #expect(book.request(request(endpoint(holder: .passing(UUID())))) { _ in } == .queued(showNow: false))

        book.forget(window)
        #expect(book.kept[endpoint(holder: window)] == nil)
    }

    @Test func clearingEverythingForgetsEveryAnswer() {
        let book = ClientCertificates()
        let window = CertificateHolder.passing(UUID())
        for place in [endpoint(), endpoint(holder: window)] {
            _ = book.request(request(place)) { _ in }
            book.answer(place, with: .refused)
        }

        book.clearEverything()

        #expect(book.kept.isEmpty)
    }

    @Test func clearingOneSiteForgetsOnlyItsAnswersInThatStore() {
        let book = ClientCertificates()
        let other = CertificateHolder.space(UUID())
        for place in [endpoint(), endpoint("files.example.net"), endpoint(holder: other)] {
            _ = book.request(request(place)) { _ in }
            book.answer(place, with: .refused)
        }

        book.clear(space) { $0.hasSuffix("example.org") }

        #expect(book.kept[endpoint()] == nil)
        #expect(book.kept[endpoint("files.example.net")] == .refused)
        #expect(book.kept[endpoint(holder: other)] == .refused)
    }

    @Test func removingASpaceForgetsItsAnswers() {
        let book = ClientCertificates()
        _ = book.request(request(endpoint())) { _ in }
        book.answer(endpoint(), with: .refused)

        book.forget(space)

        #expect(book.kept.isEmpty)
    }
}
