import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SlideSettleTests {
    let rate = CGFloat(2 * Double.pi / 0.22)

    func left(_ distance: CGFloat, rate: CGFloat, at t: CGFloat) -> CGFloat {
        distance * (1 + rate * t) * exp(-rate * t)
    }

    @Test(arguments: [(CGFloat(262), CGFloat(1155)), (278, 1018), (240, 1600), (300, 500)])
    func thePageIsHomeWhenTheColumnIs(column: CGFloat, stage: CGFloat) {
        let reach = stage / column
        let home = RideSpring.settles(column) / rate

        let hurried = left(stage, rate: rate * RideSpring.hurry(column, reach: reach), at: home)
        let shared = left(stage, rate: rate, at: home)

        #expect(abs(left(column, rate: rate, at: home) - RideSpring.within) < 0.01)
        #expect(hurried <= RideSpring.within + 0.01)
        #expect(shared > RideSpring.within * reach * 0.9)
    }

    @Test func onlyWhatTravelsFurtherThanTheColumnIsHurried() {
        let column: CGFloat = 262

        let same = RideSpring.hurry(column, reach: 1)
        let shorter = RideSpring.hurry(column, reach: 0.4)
        let still = RideSpring.hurry(0.3, reach: 4)
        let stage = RideSpring.hurry(column, reach: 1155 / column)

        #expect(same == 1)
        #expect(shorter == 1)
        #expect(still == 1)
        #expect(stage > 1.1 && stage < 1.4)
    }

    struct Scene {
        let window: NSWindow
        let motion: SpaceMotion
        let stage: RideView
        let column: RideView
    }

    func scene() -> Scene {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1417, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let motion = SpaceMotion()
        motion.alone = false
        motion.follow(0, width: 262)
        let stage = RideView(content: NSView(), motion: motion)
        stage.frame = NSRect(x: 262, y: 0, width: 1155, height: 700)
        let column = RideView(content: NSView(), motion: motion)
        column.frame = NSRect(x: 0, y: 0, width: 262, height: 700)
        window.contentView?.addSubview(stage)
        window.contentView?.addSubview(column)
        stage.set(RideLook(here: 0, clip: .none, band: false, own: true))
        column.set(RideLook(here: 0))
        stage.layoutSubtreeIfNeeded()
        column.layoutSubtreeIfNeeded()
        return Scene(window: window, motion: motion, stage: stage, column: column)
    }

    @Test func theStageRidesTheSameSpringShapeOnlyQuicker() throws {
        let scene = scene()
        let spring = RideSpring(from: 0, to: -262, velocity: -400, rate: rate, began: CACurrentMediaTime(), width: 262, base: 0)

        scene.stage.spring(spring)
        scene.column.spring(spring)

        let stage = try #require(scene.stage.content.layer?.animation(forKey: "space") as? CASpringAnimation)
        let column = try #require(scene.column.content.layer?.animation(forKey: "space") as? CASpringAnimation)
        let quicker = rate * RideSpring.hurry(262, reach: 1155 / 262)
        #expect(abs(column.stiffness - rate * rate) < 0.01)
        #expect(abs(stage.stiffness - quicker * quicker) < 0.01)
        #expect(abs(stage.damping - 2 * quicker) < 0.01)
        #expect(stage.initialVelocity == column.initialVelocity)
        #expect(stage.toValue as? CGFloat == -1155)
        #expect(column.toValue as? CGFloat == -262)
    }

    @Test func aCaughtStageEasesOntoTheFingersInsteadOfJumping() throws {
        let scene = scene()
        let spring = RideSpring(from: 0, to: -262, velocity: 0, rate: rate, began: CACurrentMediaTime(), width: 262, base: 0)
        scene.stage.spring(spring)
        scene.column.spring(spring)

        scene.stage.ride(-131, width: 262)
        scene.column.ride(-131, width: 262)

        let eased = try #require(scene.stage.content.layer?.animation(forKey: "spaceCatch") as? CASpringAnimation)
        #expect(eased.isAdditive)
        #expect(eased.toValue as? CGFloat == 0)
        #expect(abs((eased.fromValue as? CGFloat ?? 0) - (-1155 + 577.5)) < 1)
        #expect(scene.column.content.layer?.animation(forKey: "spaceCatch") == nil)
        #expect(scene.stage.shown == nil)
        #expect(scene.column.shown != nil)
    }

    @Test func aRetakeReplacesOnlyAPictureAlreadyKept() {
        _ = NSApplication.shared
        var sizes = [NSSize(width: 1012, height: 788), NSSize(width: 954, height: 788)]
        var asked = 0
        let pictures = SpacePictures(presentation: { _, done in done() }, preview: { _, reply in
            asked += 1
            reply(NSImage(size: sizes.removeFirst()))
        })
        let tab = Search.Tab(configuration: Web.configuration(space: Space.firstID))
        tab.restore(url: URL(string: "http://127.0.0.1:9/wide")!, title: "Wide")
        let space = UUID(), elsewhere = UUID()
        pictures.capture(space, tabs: [tab])

        pictures.retake(tab, in: space)
        pictures.retake(tab, in: elsewhere)

        #expect(pictures.image(for: tab, in: space)?.size == NSSize(width: 954, height: 788))
        #expect(pictures.image(for: tab, in: elsewhere) == nil)
        #expect(asked == 2)
    }

    @Test func aPictureRidesOnlyAtTheSizeItWasTaken() {
        let picture = StagePicture(frame: NSRect(x: 0, y: 0, width: 954, height: 788))
        let stale = NSImage(size: NSSize(width: 1012, height: 788))
        let narrower = NSImage(size: NSSize(width: 473.5, height: 756))
        let taken = NSImage(size: NSSize(width: 954, height: 788))

        picture.show(stale, corner: 10)
        let afterStale = picture.image
        picture.show(narrower, corner: 10)
        let afterNarrower = picture.image
        picture.show(taken, corner: 10)

        #expect(afterStale == nil)
        #expect(afterNarrower == nil)
        #expect(picture.image === taken)
        #expect(picture.layer?.sublayers?.first?.frame == CGRect(x: 0, y: 0, width: 954, height: 788))
    }
}
