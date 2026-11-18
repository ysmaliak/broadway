import AppKit
import QuartzCore
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct ReduceMotionTests {
    private func reduced<T>(_ body: () -> T) -> T {
        Store.settings.set(true, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        return body()
    }

    private func basic(_ path: String, _ seconds: Double) -> CABasicAnimation {
        let made = CABasicAnimation(keyPath: path)
        made.duration = seconds
        return made
    }

    @Test func underReduceMotionEveryCurveThatMovesAThingIsNone() {
        let curves = reduced {
            [Motion.kitGlide, Motion.kitSettle, Motion.kitRoll, Motion.kitCover, Motion.kitQuick, Motion.kitEdge, Motion.kitSlide,
             Motion.kitFold(out: true), Motion.kitFold(out: false)]
        }
        let pane = reduced { Motion.pane }
        let page = reduced { Motion.pageChange }

        #expect(curves.allSatisfy { $0 == .none })
        #expect(pane == 0)
        #expect(page == nil)
    }

    @Test func underReduceMotionAFadeOfUpToAFifthOfASecondMayStay() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        let group = CAAnimationGroup()
        group.animations = [basic("opacity", 0.1), basic("opacity", 0.2)]
        group.duration = 0.2

        #expect(Motion.reducedFade == 0.2)
        #expect(Motion.staysUnderReduce(basic("opacity", 0.2)))
        #expect(Motion.staysUnderReduce(basic("opacity", 0.12)))
        #expect(Motion.staysUnderReduce(fade))
        #expect(Motion.staysUnderReduce(group))
    }

    @Test func underReduceMotionALongerFadeDoesNotStay() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.3

        #expect(!Motion.staysUnderReduce(basic("opacity", 0.21)))
        #expect(!Motion.staysUnderReduce(fade))
    }

    @Test(arguments: ["position", "position.x", "transform", "transform.scale", "bounds", "bounds.size", "frame", "cornerRadius"])
    func underReduceMotionNoMovementStaysHoweverShort(path: String) {
        let push = CATransition()
        push.type = .push
        push.duration = 0.1
        let group = CAAnimationGroup()
        group.animations = [basic("opacity", 0.1), basic(path, 0.1)]
        group.duration = 0.1

        #expect(!Motion.staysUnderReduce(basic(path, 0.05)))
        #expect(!Motion.staysUnderReduce(KitSpring.glide.animation(path, from: 0, to: 1)))
        #expect(!Motion.staysUnderReduce(push))
        #expect(!Motion.staysUnderReduce(group))
    }

    @Test(arguments: [true, false])
    func underReduceMotionASurfaceArrivesAndLeavesInPlaceWithAtMostAFade(shown: Bool) {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 300, height: 200), styleMask: .borderless, backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let arrivals = [KitArrival.unfold(from: KitArrival.top), KitArrival.rise(by: 12), KitArrival.sheet]

        let found: [(moving: [String], placed: Bool)] = reduced {
            arrivals.map { arrival in
                let surface = KitFlippedView(frame: NSRect(x: 40, y: 40, width: 200, height: 60))
                window.contentView?.addSubview(surface)
                surface.kitArrive(shown, arrival)
                let layer = surface.layer
                let moving = (layer?.animationKeys() ?? []).filter { name in
                    layer?.animation(forKey: name).map { !Motion.staysUnderReduce($0) } ?? false
                }
                return (moving, layer.map { CATransform3DIsIdentity($0.transform) } ?? false)
            }
        }

        #expect(found.count == 3)
        #expect(found.allSatisfy { $0.moving.isEmpty })
        #expect(found.allSatisfy { $0.placed })
    }

    @Test func underReduceMotionAPressedKeyDoesNotMove() {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 80), styleMask: .borderless, backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let key = KitGlassKey(title: "Stop") {}
        key.frame = NSRect(x: 20, y: 20, width: 60, height: 22)
        window.contentView?.addSubview(key)
        key.layoutSubtreeIfNeeded()
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 30), modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)

        let moving: [String] = reduced {
            if let down { key.mouseDown(with: down) }
            var found: [String] = []
            func walk(_ layer: CALayer) {
                for name in layer.animationKeys() ?? [] {
                    if let animation = layer.animation(forKey: name), !Motion.staysUnderReduce(animation) { found.append(name) }
                }
                layer.sublayers?.forEach(walk)
            }
            if let layer = key.layer { walk(layer) }
            return found
        }

        #expect(down != nil)
        #expect(moving.isEmpty)
    }
}
