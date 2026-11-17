import Foundation
import Testing
@testable import Search

@Suite("Kept sign-ins rules")
struct SignInKeepingTests {
    private typealias Crumb = SignInKeeping.Crumb

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func crumb(_ name: String, _ value: String = "one", domain: String = "shop.example.test", path: String = "/") -> Crumb {
        Crumb(name: name, value: value, domain: domain, path: path, secure: true, httpOnly: true, sameSite: "lax")
    }

    private func shelved(_ crumbs: [Crumb], written: Date) throws -> Data {
        try JSONEncoder().encode(SignInKeeping.Shelved(written: written, crumbs: crumbs))
    }

    @Test func onlyACookieWithNoExpiryDateIsKept() {
        let seen = [
            SignInKeeping.Seen(crumb: crumb("session"), sessionOnly: true),
            SignInKeeping.Seen(crumb: crumb("lasting"), sessionOnly: false),
        ]

        let kept = SignInKeeping.keepable(seen)

        #expect(kept == [crumb("session")])
    }

    @Test func anItemWrittenWithinAWeekIsPutBack() throws {
        let written = now.addingTimeInterval(-6 * day)
        let data = try shelved([crumb("session")], written: written)

        let reading = SignInKeeping.reading(data, now: now, fresh: false)

        #expect(reading == .putBack(written: written, crumbs: [crumb("session")]))
    }

    @Test func anItemWrittenMoreThanAWeekAgoIsRemovedNotPutBack() throws {
        let data = try shelved([crumb("session")], written: now.addingTimeInterval(-7 * day - 1))

        let reading = SignInKeeping.reading(data, now: now, fresh: false)

        #expect(reading == .discard)
    }

    @Test func anUnreadableItemIsRemoved() {
        let reading = SignInKeeping.reading(Data("not a kept item".utf8), now: now, fresh: false)

        #expect(reading == .discard)
    }

    @Test func noItemPutsNothingBack() {
        #expect(SignInKeeping.reading(nil, now: now, fresh: false) == .nothing)
    }

    @Test func startingWithAFreshWindowPutsNothingBackAndRemovesTheItem() throws {
        let data = try shelved([crumb("session")], written: now.addingTimeInterval(-60))

        let reading = SignInKeeping.reading(data, now: now, fresh: true)

        #expect(reading == .discard)
    }

    @Test func theStoresOwnCookieWinsOverTheKeptOne() {
        let kept = [crumb("session", "old"), crumb("other")]
        let present: Set<SignInKeeping.Place> = [crumb("session", "new").place]

        let back = SignInKeeping.toPutBack(kept, present: present)

        #expect(back == [crumb("other")])
    }

    @Test func aCookieOfTheSameNameOnAnotherPathIsStillPutBack() {
        let kept = [crumb("session", path: "/account")]
        let present: Set<SignInKeeping.Place> = [crumb("session", path: "/").place]

        let back = SignInKeeping.toPutBack(kept, present: present)

        #expect(back == kept)
    }

    @Test func theSameDomainInAnotherCaseIsTheSameCookie() {
        let kept = [crumb("session", domain: "Shop.Example.Test")]
        let present: Set<SignInKeeping.Place> = [crumb("session", domain: "shop.example.test").place]

        #expect(SignInKeeping.toPutBack(kept, present: present).isEmpty)
    }

    @Test func unchangedCookiesAreNotWrittenAgainWithinADay() {
        let kept: Set<Crumb> = [crumb("session")]

        let step = SignInKeeping.step(kept: kept, last: kept, written: now.addingTimeInterval(-day + 60), now: now, force: false, fresh: false)

        #expect(step == .nothing)
    }

    @Test func unchangedCookiesAreWrittenAgainOnceADayHasGoneBy() {
        let kept: Set<Crumb> = [crumb("session")]

        let step = SignInKeeping.step(kept: kept, last: kept, written: now.addingTimeInterval(-day), now: now, force: false, fresh: false)

        #expect(step == .write)
    }

    @Test func aChangedValueIsWritten() {
        let step = SignInKeeping.step(kept: [crumb("session", "two")], last: [crumb("session", "one")],
                                      written: now.addingTimeInterval(-60), now: now, force: false, fresh: false)

        #expect(step == .write)
    }

    @Test func theFirstKeptCookieIsWritten() {
        let step = SignInKeeping.step(kept: [crumb("session")], last: [], written: nil, now: now, force: false, fresh: false)

        #expect(step == .write)
    }

    @Test func theItemGoesWhenNothingIsLeftToKeep() {
        let step = SignInKeeping.step(kept: [], last: [crumb("session")], written: now.addingTimeInterval(-60),
                                      now: now, force: false, fresh: false)

        #expect(step == .remove)
    }

    @Test func nothingIsWrittenWhenNothingWasKeptAndNothingIsLeft() {
        let step = SignInKeeping.step(kept: [], last: [], written: nil, now: now, force: true, fresh: false)

        #expect(step == .nothing)
    }

    @Test func quittingWritesEvenWhenNothingChanged() {
        let kept: Set<Crumb> = [crumb("session")]

        let step = SignInKeeping.step(kept: kept, last: kept, written: now.addingTimeInterval(-60), now: now, force: true, fresh: false)

        #expect(step == .write)
    }

    @Test func withAFreshWindowAtLaunchTheItemIsRemovedInsteadOfWritten() {
        let kept: Set<Crumb> = [crumb("session")]

        let step = SignInKeeping.step(kept: kept, last: [], written: now.addingTimeInterval(-60), now: now, force: true, fresh: true)

        #expect(step == .remove)
    }

    @Test func whatIsWrittenReadsBackAsTheSameCookies() throws {
        let kept: Set<Crumb> = [crumb("b"), crumb("a", domain: ".example.test"), crumb("c", path: "/x")]

        let data = try #require(SignInKeeping.encode(kept, at: now))
        let reading = SignInKeeping.reading(data, now: now, fresh: false)

        guard case .putBack(let written, let crumbs) = reading else {
            Issue.record("nothing to put back")
            return
        }
        #expect(written == now)
        #expect(Set(crumbs) == kept)
    }
}
