import AppKit
import Foundation
import Testing
import WebKit
@testable import Search

@Suite("Client certificate answers", .sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class ClientCertificateAskTests {
    let folder: URL
    let keptBook: CertificateExceptions
    let keptAnswers: ClientCertificates
    let chain = ["aa11", "bb22"]

    init() {
        folder = Store.file("client-certificates-\(UUID().uuidString.prefix(8))")
        keptBook = CertificateTrust.book
        keptAnswers = ClientCertificateAsk.answers
        CertificateTrust.book = CertificateExceptions(folder: folder)
        ClientCertificateAsk.answers = ClientCertificates()
        addTeardownBlock { [keptBook, keptAnswers, folder] in
            CertificateTrust.book = keptBook
            ClientCertificateAsk.answers = keptAnswers
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func refuse(_ holder: CertificateHolder, _ host: String = "portal.example.org") -> ClientEndpoint {
        let endpoint = ClientEndpoint(holder: holder, host: host, port: 443)
        let candidate = ClientCandidate(id: "one", name: "Pat Example", issuer: Data(), issuerName: "", notBefore: nil,
                                        notAfter: .distantFuture, canSign: true)
        _ = ClientCertificateAsk.answers.request(
            ClientCertificates.Request(endpoint: endpoint, isPage: true, onScreen: true, agent: false, fitting: [candidate])
        ) { _ in }
        ClientCertificateAsk.answers.answer(endpoint, with: .refused)
        return endpoint
    }

    private func until(_ seconds: Double = 5, _ check: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if check() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return check()
    }

    @Test func aTestWorldNeverListsTheKeychain() {
        #expect(ClientCertificateAsk.source is HeldIdentities)
        #expect(ClientCertificateAsk.source.identities().isEmpty)
    }

    @Test func theWordsBesideTheListNameTheSite() {
        #expect(ClientCertificateAsk.message("example.com") == "\u{201C}example.com\u{201D} asks for a certificate that identifies you")
    }

    @Test func signingOutOfEverySiteForgetsEveryAnswer() {
        let endpoint = refuse(.space(Space.firstID))
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }

        browser.clearSites()

        #expect(ClientCertificateAsk.answers.kept[endpoint] == nil)
    }

    @Test func clearingCookiesForASiteForgetsItsAnswerInThatStore() async {
        let store = WKWebsiteDataStore.nonPersistent()
        let holder = CertificateTrust.holder(for: store)
        let mine = refuse(holder)
        let theirs = refuse(holder, "files.example.net")
        let elsewhere = refuse(.space(Space.firstID))

        await SiteClearing.clear("example.org", in: store)

        #expect(ClientCertificateAsk.answers.kept[mine] == nil)
        #expect(ClientCertificateAsk.answers.kept[theirs] == .refused)
        #expect(ClientCertificateAsk.answers.kept[elsewhere] == .refused)
    }

    @Test func erasingASpaceForgetsItsAnswers() {
        let id = UUID()
        _ = Spaces.store(for: id)
        let endpoint = refuse(.space(id))
        addTeardownBlock {
            let left = (Store.settings.stringArray(forKey: "spaces.erasing") ?? []).filter { $0 != id.uuidString }
            Store.settings.set(left, forKey: "spaces.erasing")
        }

        Spaces.erase(id)

        #expect(ClientCertificateAsk.answers.kept[endpoint] == nil)
    }

    @Test func aPrivateStoresAnswersGoWhenTheStoreIsFreed() async {
        var endpoint: ClientEndpoint?
        do {
            let store = WKWebsiteDataStore.nonPersistent()
            endpoint = refuse(CertificateTrust.holder(for: store))
        }
        let held = try? #require(endpoint)

        #expect(await until { held.map { ClientCertificateAsk.answers.kept[$0] == nil } ?? false })
    }

    @Test func anExtensionClearingCookiesForAnOriginForgetsThatSitesExceptions() async throws {
        let site = "k\(UUID().uuidString.prefix(6).lowercased()).test"
        CertificateTrust.book.excuse(.space(Space.firstID), host: "shop.\(site)", port: 443, chain: chain)
        CertificateTrust.book.excuse(.space(Space.firstID), host: "cdn.\(site)", port: 443, chain: chain)
        CertificateTrust.book.excuse(.space(Space.firstID), host: "news.example.org", port: 443, chain: chain)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }

        try await ExtensionShims.clear(["cookies": true], options: ["origins": ["https://shop.\(site)"]], browser: browser)

        #expect(!CertificateTrust.book.covers(.space(Space.firstID), host: "shop.\(site)", port: 443, chain: chain))
        #expect(!CertificateTrust.book.covers(.space(Space.firstID), host: "cdn.\(site)", port: 443, chain: chain))
        #expect(CertificateTrust.book.covers(.space(Space.firstID), host: "news.example.org", port: 443, chain: chain))
    }

    @Test func anExtensionClearingEveryCookieForgetsEveryException() async throws {
        CertificateTrust.book.excuse(.space(Space.firstID), host: "news.example.org", port: 443, chain: chain)
        let endpoint = refuse(.space(Space.firstID))
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }

        try await ExtensionShims.clear(["cookies": true], options: [:], browser: browser)

        #expect(!CertificateTrust.book.covers(.space(Space.firstID), host: "news.example.org", port: 443, chain: chain))
        #expect(ClientCertificateAsk.answers.kept[endpoint] == nil)
    }

    @Test func anExtensionClearingOnlyTheCacheKeepsEveryException() async throws {
        CertificateTrust.book.excuse(.space(Space.firstID), host: "news.example.org", port: 443, chain: chain)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }

        try await ExtensionShims.clear(["cache": true], options: [:], browser: browser)

        #expect(CertificateTrust.book.covers(.space(Space.firstID), host: "news.example.org", port: 443, chain: chain))
    }
}
