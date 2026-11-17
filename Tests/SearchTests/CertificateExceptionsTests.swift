import Foundation
import Testing
@testable import Search

@Suite("Certificate exceptions")
struct CertificateExceptionsTests {
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_900_000_000)
    }

    let clock = Clock()
    let folder: URL
    let space = UUID()
    let chain = ["aa11", "bb22"]

    init() {
        folder = Store.file("certificate-exceptions-\(UUID().uuidString.prefix(8))")
    }

    private func book() -> CertificateExceptions {
        CertificateExceptions(folder: folder, now: { [clock] in clock.now })
    }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func clean() {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func anExceptionCoversTheSameStoreHostPortAndChain() {
        defer { clean() }
        let book = book()
        book.excuse(.space(space), host: "router.example.org", port: 443, chain: chain)

        #expect(book.covers(.space(space), host: "router.example.org", port: 443, chain: chain))
    }

    @Test func aChangedChainIsNotCovered() {
        defer { clean() }
        let book = book()
        book.excuse(.space(space), host: "router.example.org", port: 443, chain: chain)

        #expect(!book.covers(.space(space), host: "router.example.org", port: 443, chain: ["cc33", "bb22"]))
        #expect(!book.covers(.space(space), host: "router.example.org", port: 443, chain: ["aa11"]))
    }

    @Test func anotherPortIsNotCovered() {
        defer { clean() }
        let book = book()
        book.excuse(.space(space), host: "router.example.org", port: 443, chain: chain)

        #expect(!book.covers(.space(space), host: "router.example.org", port: 8443, chain: chain))
    }

    @Test func anotherHostIsNotCovered() {
        defer { clean() }
        let book = book()
        book.excuse(.space(space), host: "router.example.org", port: 443, chain: chain)

        #expect(!book.covers(.space(space), host: "other.example.org", port: 443, chain: chain))
    }

    @Test func anotherStoreIsNotCovered() {
        defer { clean() }
        let book = book()
        let window = UUID()
        book.excuse(.space(space), host: "router.example.org", port: 443, chain: chain)
        book.excuse(.passing(window), host: "nas.example.org", port: 443, chain: chain)

        #expect(!book.covers(.space(UUID()), host: "router.example.org", port: 443, chain: chain))
        #expect(!book.covers(.passing(window), host: "router.example.org", port: 443, chain: chain))
        #expect(!book.covers(.passing(UUID()), host: "nas.example.org", port: 443, chain: chain))
        #expect(!book.covers(.space(space), host: "nas.example.org", port: 443, chain: chain))
    }

    @Test func theHostIsMatchedWithoutRegardToCaseOrATrailingDot() {
        defer { clean() }
        let book = book()
        book.excuse(.space(space), host: "Router.Example.org.", port: 443, chain: chain)

        #expect(book.covers(.space(space), host: "router.example.org", port: 443, chain: chain))
    }

    @Test func aPublicNameIsExcusedForSevenDays() {
        defer { clean() }
        let book = book()
        let start = clock.now
        book.excuse(.space(space), host: "router.example.org", port: 443, chain: chain)

        clock.now = start.addingTimeInterval(7 * 24 * 60 * 60 - 1)
        #expect(book.covers(.space(space), host: "router.example.org", port: 443, chain: chain))
        clock.now = start.addingTimeInterval(7 * 24 * 60 * 60)
        #expect(!book.covers(.space(space), host: "router.example.org", port: 443, chain: chain))
    }

    @Test func anAddressOnTheLocalNetworkIsExcusedForThirtyDays() {
        defer { clean() }
        let book = book()
        let start = clock.now
        let hosts = ["192.168.1.20", "10.0.0.4", "172.20.0.9", "printer.local"]
        for host in hosts { book.excuse(.space(space), host: host, port: 443, chain: chain) }

        clock.now = start.addingTimeInterval(30 * 24 * 60 * 60 - 1)
        for host in hosts { #expect(book.covers(.space(space), host: host, port: 443, chain: chain), "\(host)") }
        clock.now = start.addingTimeInterval(30 * 24 * 60 * 60)
        for host in hosts { #expect(!book.covers(.space(space), host: host, port: 443, chain: chain), "\(host)") }
    }

    @Test func theLifetimeFollowsWhatAddressCallsLocal() {
        #expect(CertificateExceptions.lifetime(for: "router.example.org") == 7 * 24 * 60 * 60)
        #expect(CertificateExceptions.lifetime(for: "172.32.0.1") == 7 * 24 * 60 * 60)
        #expect(CertificateExceptions.lifetime(for: "10.io") == 7 * 24 * 60 * 60)
        #expect(CertificateExceptions.lifetime(for: "192.168.0.1") == 30 * 24 * 60 * 60)
        #expect(CertificateExceptions.lifetime(for: "camera.local") == 30 * 24 * 60 * 60)
        #expect(CertificateExceptions.lifetime(for: "cert.localhost") == 30 * 24 * 60 * 60)
    }

    @Test func anExceptionWhoseEndIsFurtherOffThanItsLifetimeIsNotTrusted() {
        defer { clean() }
        let book = book()
        let start = clock.now
        book.excuse(.space(space), host: "router.example.org", port: 443, chain: chain)

        clock.now = start.addingTimeInterval(-60 * 60)
        #expect(book.covers(.space(space), host: "router.example.org", port: 443, chain: chain))
        clock.now = start.addingTimeInterval(-2 * 24 * 60 * 60)
        #expect(!book.covers(.space(space), host: "router.example.org", port: 443, chain: chain))
    }

    @Test func aSpacesExceptionsAreKeptAcrossLaunches() {
        defer { clean() }
        book().excuse(.space(space), host: "router.example.org", port: 443, chain: chain)

        let next = book()
        #expect(next.covers(.space(space), host: "router.example.org", port: 443, chain: chain))
        #expect(files() == ["certificates-\(space.uuidString).json"])
    }

    @Test func theFirstSpaceKeepsItsExceptionsBesideItsSession() {
        defer { clean() }
        book().excuse(.space(Space.firstID), host: "router.example.org", port: 443, chain: chain)

        #expect(files() == ["certificates.json"])
    }

    @Test func aPrivateStoreNeverWritesToDisk() {
        defer { clean() }
        let book = book()
        let window = UUID()
        book.excuse(.passing(window), host: "router.example.org", port: 443, chain: chain)

        #expect(book.covers(.passing(window), host: "router.example.org", port: 443, chain: chain))
        #expect(files().isEmpty)
        #expect(!self.book().covers(.passing(window), host: "router.example.org", port: 443, chain: chain))
    }

    @Test func aPrivateStoresExceptionsGoWithIt() {
        defer { clean() }
        let book = book()
        let window = UUID()
        book.excuse(.passing(window), host: "router.example.org", port: 443, chain: chain)

        book.drop(passing: window)

        #expect(!book.covers(.passing(window), host: "router.example.org", port: 443, chain: chain))
    }

    @Test func anExpiredExceptionIsRemovedFromItsFile() {
        defer { clean() }
        let book = book()
        let start = clock.now
        book.excuse(.space(space), host: "router.example.org", port: 443, chain: chain)

        clock.now = start.addingTimeInterval(8 * 24 * 60 * 60)
        #expect(self.book().exceptions(.space(space)).isEmpty)
        #expect(files().isEmpty)
    }

    @Test func clearingEverythingEmptiesEveryStoreAndItsFile() throws {
        defer { clean() }
        let book = book()
        let window = UUID()
        let unread = UUID()
        self.book().excuse(.space(unread), host: "nas.example.org", port: 443, chain: chain)
        book.excuse(.space(space), host: "router.example.org", port: 443, chain: chain)
        book.excuse(.space(Space.firstID), host: "router.example.org", port: 443, chain: chain)
        book.excuse(.passing(window), host: "router.example.org", port: 443, chain: chain)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("session.json"))

        book.clearEverything()

        #expect(!book.covers(.space(space), host: "router.example.org", port: 443, chain: chain))
        #expect(!book.covers(.space(Space.firstID), host: "router.example.org", port: 443, chain: chain))
        #expect(!book.covers(.passing(window), host: "router.example.org", port: 443, chain: chain))
        #expect(!book.covers(.space(unread), host: "nas.example.org", port: 443, chain: chain))
        #expect(files() == ["session.json"])
    }

    @Test func clearingOneSiteLeavesOtherSitesAndOtherStores() {
        defer { clean() }
        let book = book()
        let other = UUID()
        book.excuse(.space(space), host: "router.example.org", port: 443, chain: chain)
        book.excuse(.space(space), host: "admin.example.org", port: 8443, chain: chain)
        book.excuse(.space(space), host: "nas.example.net", port: 443, chain: chain)
        book.excuse(.space(other), host: "router.example.org", port: 443, chain: chain)

        book.clear(.space(space)) { $0.hasSuffix("example.org") }

        #expect(!book.covers(.space(space), host: "router.example.org", port: 443, chain: chain))
        #expect(!book.covers(.space(space), host: "admin.example.org", port: 8443, chain: chain))
        #expect(book.covers(.space(space), host: "nas.example.net", port: 443, chain: chain))
        #expect(book.covers(.space(other), host: "router.example.org", port: 443, chain: chain))
        #expect(self.book().covers(.space(space), host: "nas.example.net", port: 443, chain: chain))
        #expect(!self.book().covers(.space(space), host: "router.example.org", port: 443, chain: chain))
    }

    @Test func forgettingASpaceRemovesItsExceptionsAndItsFile() {
        defer { clean() }
        let book = book()
        let other = UUID()
        book.excuse(.space(space), host: "router.example.org", port: 443, chain: chain)
        book.excuse(.space(other), host: "router.example.org", port: 443, chain: chain)

        book.forget(space: space)

        #expect(!book.covers(.space(space), host: "router.example.org", port: 443, chain: chain))
        #expect(book.covers(.space(other), host: "router.example.org", port: 443, chain: chain))
        #expect(files() == ["certificates-\(other.uuidString).json"])
    }

    @Test func anUnreadableFileIsSetAsideAndReadAsEmpty() throws {
        defer { clean() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("certificates-\(space.uuidString).json"))
        let book = book()

        #expect(book.exceptions(.space(space)).isEmpty)
        let names = files()
        #expect(names.count == 1)
        #expect(names.first?.hasPrefix("certificates-\(space.uuidString).unreadable-") == true)

        book.excuse(.space(space), host: "router.example.org", port: 443, chain: chain)
        #expect(self.book().covers(.space(space), host: "router.example.org", port: 443, chain: chain))
    }

    @Test func anEmptyChainIsNeverRecordedOrCovered() {
        defer { clean() }
        let book = book()
        book.excuse(.space(space), host: "router.example.org", port: 443, chain: [])

        #expect(book.exceptions(.space(space)).isEmpty)
        #expect(!book.covers(.space(space), host: "router.example.org", port: 443, chain: []))
        #expect(files().isEmpty)
    }

    @Test func theSameHostCanHoldTwoChainsAtOnce() {
        defer { clean() }
        let book = book()
        let second = ["dd44", "bb22"]
        book.excuse(.space(space), host: "router.example.org", port: 443, chain: chain)
        book.excuse(.space(space), host: "router.example.org", port: 443, chain: second)

        #expect(book.covers(.space(space), host: "router.example.org", port: 443, chain: chain))
        #expect(book.covers(.space(space), host: "router.example.org", port: 443, chain: second))
    }
}
