import AppKit
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5)))
@MainActor
struct OfferedColourTests {
    @Test(arguments: SpaceLook.offered)
    func everyOfferedLookReadsBackAsItselfAndHasAName(_ id: String) throws {
        let look = try #require(SpaceLook.offered(id))

        #expect(SpaceLook.offeredID(of: look) == id)
        #expect(SpaceLook.offeredName(id) != id)
        #expect(SpaceLook.offeredName(id).count <= 10)
    }

    @Test func theOfferIsAFewLooksStartingWithTheHouseLookThenThePlainOne() {
        let offers = SpaceLook.offers

        #expect(offers.count >= 4 && offers.count <= 6)
        #expect(Set(offers.map(\.id)).count == offers.count)
        #expect(Set(offers.map(\.name)).count == offers.count)
        #expect(SpaceLook.offered.prefix(2) == ["noir", "gray"])
        #expect(SpaceLook.offered("gray") == SpaceLook())
    }

    @Test(arguments: [true, false])
    func noirIsBlackWithATraceOfGrainAndNothingShowingThrough(_ dark: Bool) throws {
        let noir = try #require(SpaceLook.offered("noir"))
        let ground = noir.ground(dark: dark)

        #expect(ground.stops.map(\.hex) == ["000000"])
        #expect(noir.grain > 0 && noir.grain <= 0.3)
        #expect(noir.grain * GrainView.strength * 255 / 4 <= 4)
        #expect(noir.transparency == 0 && !noir.glass && !noir.showsThrough)
        #expect(SpaceGroundView.shown(transparency: noir.transparency, glass: 0, vivid: noir.vivid(dark: true), blurred: true) == 1)
        #expect(ground.lightInk)
        #expect(Paint.reads(ground.stops[0], light: true, lift: ground.lift))
    }

    @Test func noirOnAGroundDrawsNoMaterialOfTheDesktopBehindIt() throws {
        let noir = try #require(SpaceLook.offered("noir"))
        let ground = SpaceGroundView(look: noir)
        ground.frame = NSRect(x: 0, y: 0, width: 260, height: 400)

        ground.layoutSubtreeIfNeeded()

        #expect(ground.kitSubviews(of: NSVisualEffectView.self).isEmpty)
        #expect(ground.kitSubviews(of: NSGlassEffectView.self).isEmpty)
        #expect(ground.kitSubviews(of: GrainView.self).count == 1)
    }

    @Test(arguments: [
        (#"{"colour":"custom","custom":"000000","intensity":1,"transparency":0.12,"grain":0.45,"glass":false,"v":3}"#, "noir"),
        (#"{"colour":"custom","custom":"2B1A7A","colours":["2B1A7A","F0508C","FFB05C"],"intensity":1.4,"transparency":0,"grain":0.4,"glass":false,"v":3}"#, "dusk"),
    ])
    func aSpaceSavedInAnOfferThatChangedWakesInTheOfferAsItIsNow(_ saved: String, _ id: String) throws {
        let woken = try JSONDecoder().decode(SpaceLook.self, from: Data(saved.utf8))
        let again = try JSONDecoder().decode(SpaceLook.self, from: JSONEncoder().encode(woken))

        #expect(woken == SpaceLook.offered(id))
        #expect(SpaceLook.offeredID(of: woken) == id)
        #expect(again == woken)
    }

    @Test func aLookSavedByThisVersionIsLeftAsItIs() throws {
        let old = SpaceLook.retired[0].was
        let written = try JSONEncoder().encode(old)

        let read = try JSONDecoder().decode(SpaceLook.self, from: written)

        #expect(String(decoding: written, as: UTF8.self).contains("\"v\":\(SpaceLook.version)"))
        #expect(read == old)
        #expect(SpaceLook.offeredID(of: read) == "custom")
    }

    @Test func everyRetiredLookLeadsToAnOfferAndIsNoOfferItself() {
        for retired in SpaceLook.retired {
            #expect(SpaceLook.offered(retired.id) != nil)
            #expect(SpaceLook.offeredID(of: retired.was) == "custom")
            #expect(SpaceLook.renewed(retired.was) == SpaceLook.offered(retired.id))
        }
        #expect(SpaceLook.renewed(SpaceLook()) == nil)
        #expect(SpaceLook.renewed(SpaceLook.onyx) == nil)
    }

    @Test(arguments: SpaceLook.offers.map(\.id), [true, false])
    func everyOfferedGroundKeepsTheSidebarsWritingReadable(_ id: String, _ dark: Bool) throws {
        let look = try #require(SpaceLook.offered(id))
        let ground = look.ground(dark: dark)

        for stop in ground.stops {
            #expect(Paint.reads(stop, light: ground.lightInk, lift: ground.lift), "\(id) \(stop.hex)")
        }
    }

    @Test func everyOfferedNameIsOneWord() {
        for offer in SpaceLook.offers {
            #expect(offer.name.allSatisfy { $0.isLetter })
            #expect(offer.name.first?.isUppercase == true)
            #expect(offer.id == offer.name.lowercased())
        }
    }

    @Test(arguments: [true, false])
    func noTwoOfferedLooksPaintTheSameGround(_ dark: Bool) {
        let painted = SpaceLook.offers.map { "\($0.look.ground(dark: dark).stops.map(\.hex)) \($0.look.glass)" }

        #expect(Set(painted).count == painted.count)
    }

    @Test func aSpaceWithNoLookOfItsOwnOpensOnTheFirstOfferAndAnyOtherOnItsOwn() {
        let worn = SpaceLook(colours: ["123456"], intensity: 0.5)

        #expect(SpaceLook.opening(for: nil) == "noir")
        #expect(SpaceLook.opening(for: SpaceLook()) == "gray")
        #expect(SpaceLook.opening(for: SpaceLook.offered("dusk")) == "dusk")
        #expect(SpaceLook.opening(for: worn) == "custom")
    }

    @Test func theOfferShowsWhatASpaceCanBe() {
        let looks = SpaceLook.offers.map(\.look)

        #expect(looks.filter(\.glass).count == 1)
        #expect(looks.contains { $0.showsThrough })
        #expect(looks.filter { $0.picked.count == 3 && $0.grain > 0 }.count == 2)
        #expect(looks.contains { !$0.inkLight(dark: true) && $0.grain > 0 })
        #expect(looks.contains { $0.picked == ["000000"] })
        #expect(looks.contains { $0 == SpaceLook() })
        #expect(looks.filter { $0.grain > 0 }.count >= 3)
    }

    @Test func aNamedColourKeepsTheSpacesTransparencyGrainAndGlass() throws {
        let now = SpaceLook(colour: "sky", transparency: 0.4, grain: 0.3, glass: true)

        let look = try #require(SpaceLook.named("cobalt", over: now))

        #expect(look.picked == ["3139FB"])
        #expect(look.intensity == 1)
        #expect(look.transparency == 0.4)
        #expect(look.grain == 0.3)
        #expect(look.glass)
    }

    @Test func anUnknownLookPaintsNothing() {
        #expect(SpaceLook.offered("plaid") == nil)
        #expect(SpaceLook.named("plaid") == nil)
        #expect(SpaceLook.offeredID(of: nil) == "gray")
        #expect(SpaceLook.offeredID(of: SpaceLook(colours: ["123456"], intensity: 0.5)) == "custom")
        #expect(SpaceLook.offeredID(of: SpaceLook.onyx) == "custom")
    }
}
