import Foundation
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PopupGuardTests {
    let page = URL(string: "https://videos.example/watch")
    let ad = URL(string: "https://ads.test/landing")
    let own = URL(string: "https://www.videos.example/next")

    @Test func aClickOnSomethingInvisibleIsUnseen() {
        let faded = PopupHit(fade: 0.02, over: "media", cover: 1)
        let hidden = PopupHit(hidden: true)
        let overMedia = PopupHit(over: "media", cover: 0.2)
        let overButton = PopupHit(over: "control", cover: 0.05)
        let overPage = PopupHit(over: "content", cover: 0.8)
        let overNothing = PopupHit(over: "nothing", cover: 1)

        for hit in [faded, hidden, overMedia, overButton, overPage, overNothing] {
            #expect(hit.unseen)
            #expect(PopupGuard.refusal([hit], url: ad, page: page, sized: false, wary: false) == .unseen)
        }
    }

    @Test func whatYouSawIsNotUnseen() {
        let button = PopupHit()
        let stretchedLink = PopupHit(over: "content", cover: 0.1)
        let smallBareSpot = PopupHit(over: "nothing", cover: 0.3)

        #expect(!button.unseen)
        #expect(!stretchedLink.unseen)
        #expect(!smallBareSpot.unseen)
        #expect(PopupGuard.refusal([stretchedLink], url: ad, page: page, sized: false, wary: false) == nil)
    }

    @Test func theSameSiteIsNeverRefused() {
        let hit = PopupHit(fade: 0, active: false)

        let refusal = PopupGuard.refusal([hit], url: own, page: page, sized: false, wary: true)

        #expect(refusal == nil)
    }

    @Test func aBlankWindowFromAnUnseenClickIsRefused() {
        let hit = PopupHit(fade: 0)

        let refusal = PopupGuard.refusal([hit], url: URL(string: "about:blank"), page: page, sized: true, wary: false)

        #expect(refusal == .unseen)
    }

    @Test func aClickOnNothingInteractiveIsInert() {
        let text = PopupHit(active: false)
        let thenButton = PopupHit(active: true)

        #expect(PopupGuard.refusal([text], url: ad, page: page, sized: false, wary: false) == .inert)
        #expect(PopupGuard.refusal([text], url: ad, page: page, sized: true, wary: false) == .inert)
        #expect(PopupGuard.refusal([text, thenButton], url: ad, page: page, sized: false, wary: false) == nil)
    }

    @Test func aWindowElsewhereThanTheClickedLinkIsAstray() {
        let link = PopupHit(link: URL(string: "https://news.test/story"))

        #expect(PopupGuard.refusal([link], url: ad, page: page, sized: false, wary: false) == .astray)
        #expect(PopupGuard.refusal([link], url: URL(string: "https://www.news.test/story"), page: page, sized: false, wary: false) == nil)
        #expect(PopupGuard.refusal([link], url: ad, page: page, sized: true, wary: false) == nil)
        #expect(PopupGuard.refusal([link], url: URL(string: "about:blank"), page: page, sized: false, wary: false) == nil)
    }

    @Test func visibleButtonsKeepSignInAndPaymentWindows() {
        let button = PopupHit()
        let google = URL(string: "https://accounts.google.com/o/oauth2/auth")

        #expect(PopupGuard.refusal([button], url: google, page: page, sized: true, wary: false) == nil)
        #expect(PopupGuard.refusal([button], url: google, page: page, sized: false, wary: false) == nil)
        #expect(PopupGuard.refusal([], url: google, page: page, sized: false, wary: false) == nil)
    }

    @Test func aWarySiteGetsNoWindowsToOtherSitesButSizedOnes() {
        let button = PopupHit()

        #expect(PopupGuard.refusal([button], url: ad, page: page, sized: false, wary: true) == .wary)
        #expect(PopupGuard.refusal([], url: ad, page: page, sized: false, wary: true) == .wary)
        #expect(PopupGuard.refusal([button], url: ad, page: page, sized: true, wary: true) == nil)
    }

    @Test func twoStrikesMakeASiteWaryUntilForgiven() {
        PopupGuard.forgive("videos.example")
        defer { PopupGuard.forgive("videos.example") }

        PopupGuard.strike(page, for: .unseen)
        let once = PopupGuard.wary(page)
        PopupGuard.strike(page, for: .wary)
        let stillOnce = PopupGuard.wary(page)
        PopupGuard.strike(own, for: .inert)

        #expect(!once)
        #expect(!stillOnce)
        #expect(PopupGuard.wary(page))
        PopupGuard.forgive("videos.example")
        #expect(!PopupGuard.wary(page))
    }

    @Test func hitsArriveFromTheScriptsMessage() {
        let body: [String: Any] = ["fade": 0.05, "hidden": false, "over": "media", "cover": 0.7, "active": true,
                                   "link": "https://news.test/a"]

        let hit = PopupHit(body)

        #expect(hit == PopupHit(fade: 0.05, over: "media", cover: 0.7, link: URL(string: "https://news.test/a")))
        #expect(PopupHit(NSNull()) == nil)
        #expect(PopupHit(["link": "javascript:void(0)"])?.link == nil)
    }

    @Test func theClickAddsToTheMousedownsFacts() {
        var gesture = PopupGesture()

        gesture.record(origin: "o", kind: "input", hit: PopupHit(), now: 10)
        gesture.record(origin: "o", kind: "click", hit: PopupHit(fade: 0), now: 10.1)

        #expect(gesture.hits.count == 2)
        #expect(PopupGuard.refusal(gesture.hits, url: ad, page: page, sized: false, wary: false) == .unseen)
        gesture.record(origin: "o", kind: "input", now: 11)
        #expect(gesture.hits.isEmpty)
    }

    @Test func aTabUnderIsTheOpenerLeavingRightAfterItsWindow() throws {
        var gesture = PopupGesture()
        gesture.record(origin: "o", kind: "input", now: 10)
        let took = gesture.take(origin: "o", now: 10.1)
        #expect(took)
        gesture.opened(UUID(), now: 10.1)
        gesture.clear()

        let spawn = try #require(gesture.tabUnder(now: 10.5))

        #expect(PopupGuard.tabUnder(spawn, navigation: .other, to: ad, page: page))
        #expect(PopupGuard.tabUnder(spawn, navigation: .linkActivated, to: ad, page: page))
        #expect(!PopupGuard.tabUnder(spawn, navigation: .other, to: own, page: page))
        #expect(!PopupGuard.tabUnder(spawn, navigation: .reload, to: ad, page: page))
        #expect(gesture.tabUnder(now: 13) == nil)
        gesture.record(origin: "o", kind: "input", now: 10.6)
        #expect(gesture.tabUnder(now: 10.7) == nil)
    }

    @Test func aRefusedOrSizedWindowLimitsTheTabUnder() throws {
        var refused = PopupGesture()
        refused.record(origin: "o", kind: "input", now: 10)
        refused.refused(sized: false, now: 10.1)
        var sized = PopupGesture()
        sized.record(origin: "o", kind: "input", now: 10)
        sized.opened(UUID(), sized: true, now: 10.1)

        let afterRefusal = try #require(refused.tabUnder(now: 10.2))
        let afterSized = try #require(sized.tabUnder(now: 10.2))

        #expect(PopupGuard.tabUnder(afterRefusal, navigation: .other, to: ad, page: page))
        #expect(!PopupGuard.tabUnder(afterRefusal, navigation: .linkActivated, to: ad, page: page))
        #expect(!PopupGuard.tabUnder(afterSized, navigation: .other, to: ad, page: page))
    }

    @Test func aSignInAddressIsTreatedAsASizedWindowIs() {
        let link = PopupHit(link: URL(string: "https://videos.example/auth/apple"))
        let button = PopupHit()
        let apple = URL(string: "https://appleid.apple.com/auth/authorize?client_id=x&redirect_uri=https%3A%2F%2Fvideos.example&response_type=code")
        let tenant = URL(string: "https://sso.company.example/oauth2/authorize?client_id=x&redirect_uri=https%3A%2F%2Fvideos.example%2Fcb")

        for url in [apple, tenant] {
            #expect(PopupGuard.refusal([link], url: url, page: page, sized: false, wary: false) == nil)
            #expect(PopupGuard.refusal([button], url: url, page: page, sized: false, wary: true) == nil)
        }
    }

    @Test func anUnseenClickOpensNoSignInWindowEither() {
        let overlay = PopupHit(fade: 0.01, cover: 1)
        let google = URL(string: "https://accounts.google.com/o/oauth2/v2/auth?client_id=x&redirect_uri=y&response_type=code")

        #expect(PopupGuard.refusal([overlay], url: google, page: page, sized: true, wary: false) == .unseen)
        #expect(PopupGuard.refusal([PopupHit(), overlay], url: google, page: page, sized: false, wary: false) == .unseen)
    }

    @Test func anUnseenButtonUnderAPaintedFaceOpensOnlyAListedProvidersWindow() {
        let masked = PopupHit(fade: 0, over: "nothing", cover: 0.02, masked: true)
        let overPlayer = PopupHit(fade: 0, over: "media", cover: 0.02, masked: true)
        let google = URL(string: "https://accounts.google.com/o/oauth2/v2/auth?client_id=x")
        let shaped = URL(string: "https://ads.test/landing?client_id=x&redirect_uri=y&response_type=code")

        #expect(masked.unseen)
        #expect(PopupGuard.refusal([masked], url: google, page: page, sized: true, wary: false) == nil)
        #expect(PopupGuard.refusal([PopupHit(), masked], url: google, page: page, sized: false, wary: true) == nil)
        #expect(PopupGuard.refusal([masked], url: shaped, page: page, sized: true, wary: false) == .unseen)
        #expect(PopupGuard.refusal([masked], url: ad, page: page, sized: true, wary: false) == .unseen)
        #expect(PopupGuard.refusal([overPlayer], url: google, page: page, sized: true, wary: false) == .unseen)
    }

    @Test func theRelaySaysWhenAnUnseenButtonSitsUnderAPaintedFace() {
        let body: [String: Any] = ["fade": 0, "hidden": false, "over": "nothing", "cover": 0.02, "active": true, "link": "", "masked": true]

        let hit = PopupHit(body)

        #expect(hit?.masked == true)
        #expect(PopupHit(["fade": 0])?.masked == false)
    }

    @Test func aPlainSpotOpensNoSignInWindowEither() {
        let text = PopupHit(active: false)
        let google = URL(string: "https://accounts.google.com/o/oauth2/v2/auth?client_id=x")
        let shaped = URL(string: "https://ads.test/landing?client_id=x&redirect_uri=y&response_type=code")

        #expect(PopupGuard.refusal([text], url: google, page: page, sized: true, wary: false) == .inert)
        #expect(PopupGuard.refusal([text], url: shaped, page: page, sized: true, wary: false) == .inert)
    }

    @Test func aRefusedSignInWindowIsNoStrike() {
        PopupGuard.forgive("videos.example")
        defer { PopupGuard.forgive("videos.example") }
        let apple = URL(string: "https://appleid.apple.com/auth/authorize?client_id=x")

        PopupGuard.strike(page, for: .unseen, to: apple)
        PopupGuard.strike(page, for: .unseen, to: apple)
        let afterSignIns = PopupGuard.wary(page)
        PopupGuard.strike(page, for: .unseen, to: ad)
        PopupGuard.strike(page, for: .unseen, to: ad)

        #expect(!afterSignIns)
        #expect(PopupGuard.wary(page))
    }

    @Test func aSeenClickWaitsLongerForAListedProvider() {
        func gesture(_ hits: [PopupHit]) -> PopupGesture {
            var gesture = PopupGesture()
            gesture.record(origin: "o", kind: "input", hit: hits.first, now: 10)
            for hit in hits.dropFirst() { gesture.record(origin: "o", kind: "click", hit: hit, now: 10.1) }
            return gesture
        }
        var seen = gesture([PopupHit(), PopupHit()])
        var impatient = seen
        var late = seen
        var other = seen
        var overlay = gesture([PopupHit(), PopupHit(fade: 0)])
        var text = gesture([PopupHit(active: false)])
        var key = PopupGesture()
        key.record(origin: "o", kind: "input", now: 10)
        var soon = key

        let withoutPatience = impatient.take(origin: "o", now: 18)
        let withPatience = seen.take(origin: "o", patient: true, now: 18)
        let again = seen.take(origin: "o", patient: true, now: 18.1)
        let tooLate = late.take(origin: "o", patient: true, now: 10 + PopupGuard.signInPatience + 1)
        let anotherFrame = other.take(origin: "elsewhere", patient: true, now: 18)
        let afterOverlay = overlay.take(origin: "o", patient: true, now: 18)
        let afterText = text.take(origin: "o", patient: true, now: 18)
        let afterKey = key.take(origin: "o", patient: true, now: 18)
        let keyInTime = soon.take(origin: "o", patient: true, now: 12)

        #expect(!withoutPatience)
        #expect(withPatience)
        #expect(!again)
        #expect(!tooLate)
        #expect(!anotherFrame)
        #expect(!afterOverlay)
        #expect(!afterText)
        #expect(!afterKey)
        #expect(keyInTime)
    }

    @Test func afterARefusalThePageMayGoToTheSignInAddressItself() throws {
        let apple = URL(string: "https://appleid.apple.com/auth/authorize?client_id=x")
        let shaped = URL(string: "https://ads.test/landing?client_id=x&redirect_uri=y&response_type=code")
        var inert = PopupGesture()
        inert.record(origin: "o", kind: "input", now: 10)
        inert.refused(sized: false, reason: .inert, now: 10.1)
        var unseen = PopupGesture()
        unseen.record(origin: "o", kind: "input", now: 10)
        unseen.refused(sized: false, reason: .unseen, now: 10.1)

        let afterInert = try #require(inert.tabUnder(now: 10.2))
        let afterUnseen = try #require(unseen.tabUnder(now: 10.2))

        #expect(!PopupGuard.tabUnder(afterInert, navigation: .other, to: apple, page: page))
        #expect(PopupGuard.tabUnder(afterInert, navigation: .other, to: ad, page: page))
        #expect(PopupGuard.tabUnder(afterInert, navigation: .other, to: shaped, page: page))
        #expect(PopupGuard.tabUnder(afterUnseen, navigation: .other, to: apple, page: page))
    }

    @Test func allowingASiteCoversAClickInAnyOfItsFrames() {
        let sites: Set<String> = ["videos.example"]

        #expect(BlockedPopups.allows(sites, top: own))
        #expect(!BlockedPopups.allows(sites, top: ad))
        #expect(!BlockedPopups.allows(sites, top: own, frameScheme: "https", frameHost: "accounts.google.com"))
    }

    @Test func refusalsAreKeptWithTheirReason() {
        let list = BlockedPopups.noting(ad, reason: .unseen, in: []) ?? []

        #expect(list.map(\.reason) == [.unseen])
        #expect(BlockedPopups.noting(ad, reason: .inert, in: list) == nil)
    }
}
