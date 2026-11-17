import Foundation
import Testing
import WebKit
@testable import Search

@Suite("Certificate trust", .sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class CertificateTrustTests {
    let folder: URL
    let kept: CertificateExceptions
    let chain = ["aa11", "bb22"]
    var asked = 0

    init() {
        folder = Store.file("certificate-trust-\(UUID().uuidString.prefix(8))")
        kept = CertificateTrust.book
        CertificateTrust.book = CertificateExceptions(folder: folder)
        addTeardownBlock { [kept, folder] in
            CertificateTrust.book = kept
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func answer(
        _ store: WKWebsiteDataStore,
        host: String = "router.example.org",
        port: Int = 443,
        chain: [String]? = nil,
        trusted: Bool = false,
        isPage: Bool = true,
        reply: Bool = true
    ) -> CertificateTrust.Outcome? {
        var outcome: CertificateTrust.Outcome?
        CertificateTrust.answer(
            store: store, host: host, port: port, chain: chain ?? self.chain, trusted: trusted, isPage: isPage,
            ask: { [self] respond in
                asked += 1
                respond(reply)
            },
            done: { outcome = $0 }
        )
        return outcome
    }

    @Test func aTrustedCertificateIsLeftToTheSystemWithoutAQuestion() {
        let store = WKWebsiteDataStore.nonPersistent()

        #expect(answer(store, trusted: true) == .system)
        #expect(asked == 0)
    }

    @Test func thisMacGoesThroughWithoutAQuestion() {
        let store = WKWebsiteDataStore.nonPersistent()

        #expect(answer(store, host: "localhost") == .pass)
        #expect(answer(store, host: "127.0.0.1", isPage: false) == .pass)
        #expect(asked == 0)
    }

    @Test func continueAnywayLetsTheSameChainThroughWithoutAskingAgain() {
        let store = WKWebsiteDataStore.nonPersistent()

        #expect(answer(store) == .pass)
        #expect(asked == 1)
        #expect(answer(store, reply: false) == .pass)
        #expect(asked == 1)
    }

    @Test func aNewChainOnTheSameHostAsksAgain() {
        let store = WKWebsiteDataStore.nonPersistent()
        _ = answer(store)

        #expect(answer(store, chain: ["cc33", "bb22"], reply: false) == .refuse)
        #expect(asked == 2)
    }

    @Test func anotherPortOnTheSameHostAsksAgain() {
        let store = WKWebsiteDataStore.nonPersistent()
        _ = answer(store)

        #expect(answer(store, port: 8443, reply: false) == .refuse)
        #expect(asked == 2)
    }

    @Test func goBackRefusesAndRecordsNothing() {
        let store = WKWebsiteDataStore.nonPersistent()

        #expect(answer(store, reply: false) == .refuse)
        #expect(answer(store, reply: false) == .refuse)
        #expect(asked == 2)
    }

    @Test func somethingThePageLoadsIsNotAskedAbout() {
        let store = WKWebsiteDataStore.nonPersistent()

        #expect(answer(store, isPage: false) == .system)
        #expect(asked == 0)
    }

    @Test func somethingThePageLoadsFromTheExcusedEndpointGoesThrough() {
        let store = WKWebsiteDataStore.nonPersistent()
        _ = answer(store)

        #expect(answer(store, isPage: false) == .pass)
        #expect(answer(store, chain: ["cc33"], isPage: false) == .system)
        #expect(asked == 1)
    }

    @Test func aPageThatShowsNoChainIsNotAskedAbout() {
        let store = WKWebsiteDataStore.nonPersistent()

        #expect(answer(store, chain: []) == .system)
        #expect(asked == 0)
    }

    @Test func twoPrivateWindowsDoNotShareAnException() {
        let one = WKWebsiteDataStore.nonPersistent()
        let two = WKWebsiteDataStore.nonPersistent()
        _ = answer(one)

        #expect(answer(two, reply: false) == .refuse)
        #expect(asked == 2)
    }

    @Test func aPrivateStoreKeepsOneHolderForItsLife() {
        let store = WKWebsiteDataStore.nonPersistent()

        let first = CertificateTrust.holder(for: store)
        #expect(CertificateTrust.holder(for: store) == first)
        guard case .passing = first else {
            Issue.record("a private store is held in memory")
            return
        }
    }

    @Test func theSharedStoreBelongsToTheFirstSpace() {
        #expect(CertificateTrust.holder(for: Store.websites) == .space(Space.firstID))
    }

    @Test func aSpacesOwnStoreIsHeldUnderItsSpace() async throws {
        let id = UUID()
        let store = WKWebsiteDataStore(forIdentifier: id)

        #expect(CertificateTrust.holder(for: store) == .space(id))
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    @Test func anExceptionInAPrivateWindowIsNeverWrittenToDisk() {
        let store = WKWebsiteDataStore.nonPersistent()
        _ = answer(store)

        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(names.isEmpty)
    }

    @Test func clearingCookiesForASiteDropsItsExceptionInThatStore() async {
        let store = WKWebsiteDataStore.nonPersistent()
        let other = WKWebsiteDataStore.nonPersistent()
        _ = answer(store)
        _ = answer(store, host: "nas.example.net")
        _ = answer(other)

        await SiteClearing.clear("example.org", in: store)

        #expect(answer(store, reply: false) == .refuse)
        #expect(answer(store, host: "nas.example.net", reply: false) == .pass)
        #expect(answer(other, reply: false) == .pass)
    }

    @Test func clearingBrowsingDataDropsEveryException() {
        let store = WKWebsiteDataStore.nonPersistent()
        _ = answer(store)

        CertificateTrust.clearEverything()

        #expect(answer(store, reply: false) == .refuse)
    }

    private func until(_ seconds: Double = 5, _ check: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if check() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return check()
    }

    @Test func aPrivateStoresExceptionsGoWhenTheStoreIsFreed() async {
        var holder: CertificateHolder?
        do {
            let store = WKWebsiteDataStore.nonPersistent()
            _ = answer(store)
            holder = CertificateTrust.holder(for: store)
        }
        let held = try? #require(holder)

        #expect(await until { held.map { CertificateTrust.book.exceptions($0).isEmpty } ?? false })
    }

    @Test func signingOutOfEverySiteDropsTheFirstSpacesExceptions() {
        CertificateTrust.book.excuse(.space(Space.firstID), host: "router.example.org", port: 443, chain: chain)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }

        browser.clearSites()

        #expect(!CertificateTrust.book.covers(.space(Space.firstID), host: "router.example.org", port: 443, chain: chain))
    }

    @Test func erasingASpaceDropsItsExceptionsAndItsFile() {
        let id = UUID()
        let store = Spaces.store(for: id)
        #expect(CertificateTrust.holder(for: store) == .space(id))
        CertificateTrust.book.excuse(.space(id), host: "router.example.org", port: 443, chain: chain)
        #expect(FileManager.default.fileExists(atPath: CertificateTrust.book.file(for: id).path))
        addTeardownBlock {
            let left = (Store.settings.stringArray(forKey: "spaces.erasing") ?? []).filter { $0 != id.uuidString }
            Store.settings.set(left, forKey: "spaces.erasing")
        }

        Spaces.erase(id)

        #expect(!CertificateTrust.book.covers(.space(id), host: "router.example.org", port: 443, chain: chain))
        #expect(!FileManager.default.fileExists(atPath: CertificateTrust.book.file(for: id).path))
    }

    @Test func removingASpaceDropsItsExceptions() {
        let id = UUID()
        CertificateTrust.book.excuse(.space(id), host: "router.example.org", port: 443, chain: chain)

        CertificateTrust.forget(space: id)

        #expect(!CertificateTrust.book.covers(.space(id), host: "router.example.org", port: 443, chain: chain))
    }
}
