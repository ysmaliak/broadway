import Testing
import AppKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SpaceIconTests {
    private func decoded(_ fields: String) throws -> Space {
        let id = UUID().uuidString
        let json = #"{"id":"\#(id)","name":"Work","colour":2\#(fields)}"#
        return try JSONDecoder().decode(Space.self, from: Data(json.utf8))
    }

    @Test func anOldSymbolBecomesTheIcon() throws {
        let fields = #","icon":"briefcase""#

        let space = try decoded(fields)

        #expect(space.icon == TabIcon(symbol: "briefcase"))
    }

    @Test func anOldEmojiWinsOverTheSymbolBesideIt() throws {
        let fields = #","icon":"briefcase","emoji":"🦊""#

        let space = try decoded(fields)

        #expect(space.icon == TabIcon(emoji: "🦊"))
    }

    @Test func anOldSpaceWithNoIconStaysWithout() throws {
        let fields = ""

        let space = try decoded(fields)

        #expect(space.icon == nil)
    }

    @Test func anIconIsWrittenAsOneField() throws {
        var space = try decoded("")
        space.icon = TabIcon(emoji: "🌊")

        let data = try JSONEncoder().encode(space)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let back = try JSONDecoder().decode(Space.self, from: data)

        #expect(fields["emoji"] == nil)
        #expect(back.icon == TabIcon(emoji: "🌊"))
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SpaceMotionTests {
    @Test func theSpringEndsExactlyOnItsTargetAndSaysSo() async {
        let motion = SpaceMotion()
        motion.follow(-40, width: 240)
        let landed = Expectation(description: "landed")

        motion.carry(to: -240, width: 240, velocity: -300) { landed.fulfill() }
        await fulfillment(of: [landed], timeout: 3)

        #expect(motion.offset == -240)
        #expect(!motion.moving)
    }

    @Test func turningBackLandsWhereItWasSentLast() async {
        let motion = SpaceMotion()
        motion.follow(-120, width: 240)
        let first = Expectation(description: "first")
        first.isInverted = true
        let second = Expectation(description: "second")
        motion.carry(to: -240, width: 240, velocity: -500) { first.fulfill() }

        motion.carry(to: 0, width: 240, velocity: 200) { second.fulfill() }
        await fulfillment(of: [second], timeout: 3)
        await fulfillment(of: [first], timeout: 0.05)

        #expect(motion.offset == 0)
    }

    @Test func fingersTakeItFromTheSpring() {
        let motion = SpaceMotion()
        motion.carry(to: -240, width: 240) {}

        motion.follow(-30, width: 240)

        #expect(!motion.moving)
        #expect(motion.offset == -30)
        #expect(motion.progress == 0.125)
    }

    @Test func holdingAShortSwipeDiscardsItsOldFlickVelocity() {
        let trail: [(time: CFTimeInterval, travel: CGFloat)] = [(1, 0), (1.04, -35)]

        let speed = SpaceSwipe.releaseSpeed(trail, at: 1.2)

        #expect(speed == 0)
    }

    @Test func aFreshFlickKeepsItsReleaseVelocity() {
        let trail: [(time: CFTimeInterval, travel: CGFloat)] = [(1, 0), (1.04, -35)]

        let speed = SpaceSwipe.releaseSpeed(trail, at: 1.05)

        #expect(abs(speed - -875) <= 0.001)
    }

    @Test func atRestItIsNowhere() {
        let motion = SpaceMotion()
        motion.follow(-90, width: 240)

        motion.rest()

        #expect(motion.offset == 0)
        #expect(motion.progress == 0)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct LookBlendTests {
    @Test func halfWayIsHalfWayInEveryNumber() {
        let from = SpaceLook(colour: "gray", transparency: 0.2, grain: 0, glass: false)
        let to = SpaceLook(colour: "coral", transparency: 0.6, grain: 0.4, glass: true)

        let blend = LookBlend(from: from, to: to, share: 0.5)

        #expect(abs(blend.transparency - 0.4) <= 0.0001)
        #expect(abs(blend.grain - 0.2) <= 0.0001)
        #expect(abs(blend.glass - 0.5) <= 0.0001)
    }

    @Test func atNoneItIsTheLookItLeft() {
        let from = SpaceLook(colour: "sage", transparency: 0.1, grain: 0.1, glass: false)
        let to = SpaceLook(colour: "coral", transparency: 0.9, grain: 0.9, glass: true)

        let blend = LookBlend(from: from, to: to, share: 0)

        #expect(abs(blend.transparency - 0.1) <= 0.0001)
        #expect(abs(blend.glass - 0) <= 0.0001)
        let dark = NSAppearance(named: .darkAqua)!
        var shown = "", left = ""
        dark.performAsCurrentDrawingAppearance {
            shown = blend.tint.hexString
            left = from.tint.hexString
        }
        #expect(shown == left)
    }

    @Test func eachChoiceTintsTheWindowItsOwnWay() {
        let dark = NSAppearance(named: .darkAqua)!

        let tints = SpaceLook.presets.map { preset -> String in
            var hex = ""
            dark.performAsCurrentDrawingAppearance { hex = SpaceLook.tint(hex: preset.hex).hexString }
            return hex
        }

        #expect(Set(tints).count == SpaceLook.presets.count)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
struct VaultQueueTests {
    @Test func aReadRunsOffTheMainThread() async {
        let onMain = await MainActor.run { Thread.isMainThread }

        let read = await Vault.off { Thread.isMainThread }

        #expect(onMain)
        #expect(!read)
    }
}
