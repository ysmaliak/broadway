import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct GestureDiscTests {
    private struct Ink {
        var points: [(x: Double, y: Double, alpha: Double)] = []
    }

    private func staged(_ edge: GestureDisc.Edge, dark: Bool) -> (NSWindow, GestureDisc) {
        let side = GestureDisc.size * 4
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: side, height: side), styleMask: .borderless, backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = KitFlippedView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        window.contentView = host
        let disc = GestureDisc(edge)
        host.addSubview(disc)
        disc.settle(in: host)
        disc.commit()
        hideGlass(in: disc)
        disc.layoutSubtreeIfNeeded()
        return (window, disc)
    }

    private func hideGlass(in view: NSView) {
        for child in view.subviews {
            if child is KitGlass { child.isHidden = true } else { hideGlass(in: child) }
        }
    }

    private func turner(in view: NSView) -> KitTurnView? {
        for child in view.subviews {
            if let turn = child as? KitTurnView { return turn }
            if let found = turner(in: child) { return found }
        }
        return nil
    }

    private func shot(_ disc: GestureDisc, scale: Int) -> Ink {
        CATransaction.flush()
        let side = Int(GestureDisc.size) * scale
        guard let layer = disc.layer,
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Ink() }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        layer.render(in: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return Ink() }
        let middle = GestureDisc.size / 2
        var glyph = Ink()
        for row in 0..<side {
            for column in 0..<side {
                let alpha = Double(data[row * side * 4 + column * 4 + 3]) / 255
                let x = (Double(column) + 0.5) / Double(scale), y = Double(GestureDisc.size) - (Double(row) + 0.5) / Double(scale)
                guard alpha > 0.05, hypot(x - middle, y - middle) < 16 else { continue }
                glyph.points.append((x, y, alpha))
            }
        }
        return glyph
    }

    private func span(_ ink: Ink, scale: Int, across: Bool) -> ClosedRange<CGFloat>? {
        let side = Int(GestureDisc.size) * scale
        var line = [Int](repeating: 0, count: side)
        for point in ink.points {
            let index = Int(((across ? point.x : point.y) * Double(scale)).rounded(.down))
            guard line.indices.contains(index) else { continue }
            line[index] = max(line[index], Int(point.alpha * 255))
        }
        return KitGlyph.inkSpan(line).map { ($0.lowerBound / CGFloat(scale))...($0.upperBound / CGFloat(scale)) }
    }

    private func unturned(_ ink: Ink, by angle: CGFloat) -> Ink {
        let middle = Double(GestureDisc.size / 2), turn = -Double(angle)
        var back = Ink()
        back.points = ink.points.map { point in
            let x = point.x - middle, y = point.y - middle
            return (middle + x * cos(turn) - y * sin(turn), middle + x * sin(turn) + y * cos(turn), point.alpha)
        }
        return back
    }

    private func round(_ ink: Ink, scale: Int) -> CGPoint? {
        guard let across = span(ink, scale: scale, across: true), let down = span(ink, scale: scale, across: false) else { return nil }
        let radius = (across.upperBound - across.lowerBound) / 2
        return CGPoint(x: (across.lowerBound + across.upperBound) / 2, y: down.upperBound - radius)
    }

    private func box(_ ink: Ink, scale: Int) -> CGPoint? {
        guard let across = span(ink, scale: scale, across: true), let down = span(ink, scale: scale, across: false) else { return nil }
        return CGPoint(x: (across.lowerBound + across.upperBound) / 2, y: (down.lowerBound + down.upperBound) / 2)
    }

    private func slack(_ scale: Int) -> CGFloat {
        scale >= 2 ? 0.3 : 0.5
    }

    private func unturned(_ point: CGPoint, by angle: CGFloat) -> CGPoint {
        let middle = GestureDisc.size / 2, turn = -angle
        let x = point.x - middle, y = point.y - middle
        return CGPoint(x: middle + x * cos(turn) - y * sin(turn), y: middle + x * sin(turn) + y * cos(turn))
    }

    @Test func theArrowsCircleSitsOnTheRingsCentreAtEveryAngleOfTheTurn() throws {
        for dark in [false, true] {
            for scale in [1, 2] {
                let (_, disc) = staged(.top, dark: dark)
                let turn = try #require(turner(in: disc)?.layer)
                for quarter in 0..<4 {
                    let angle = CGFloat(quarter) * .pi / 2
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    turn.sublayerTransform = disc.turned(angle)
                    CATransaction.commit()
                    let found = try #require(round(unturned(shot(disc, scale: scale), by: angle), scale: scale))
                    let pivot = unturned(disc.pivot, by: angle)
                    #expect(hypot(found.x - pivot.x, found.y - pivot.y) <= slack(scale))
                }
            }
        }
    }

    @Test func theMeasuredMiddleOfTheArrowsCircleIsTheOneTheDiscKeeps() throws {
        for dark in [false, true] {
            for scale in [1, 2] {
                let (_, disc) = staged(.top, dark: dark)
                let holder = try #require(turner(in: disc))
                let found = try #require(round(shot(disc, scale: scale), scale: scale))
                let drawn = CGPoint(x: found.x - holder.frame.midX, y: found.y - holder.frame.midY)
                let hub = GestureDisc.Edge.top.hub
                #expect(hypot(drawn.x - hub.x, drawn.y - hub.y) <= slack(scale))
            }
        }
    }

    @Test func theTurnsCentreIsWhereTheArrowIsPlaced() throws {
        let (window, disc) = staged(.top, dark: false)
        let turn = try #require(turner(in: disc))
        let middle = GestureDisc.size / 2
        let hub = GestureDisc.Edge.top.hub
        let pixel = 1 / window.backingScaleFactor
        #expect(abs(disc.pivot.x - middle) <= pixel / 2 && abs(disc.pivot.y - middle) <= pixel / 2)
        #expect(disc.pivot == CGPoint(x: turn.frame.midX + hub.x, y: turn.frame.midY + hub.y))
        let inside = CGPoint(x: disc.pivot.x - turn.frame.minX, y: disc.pivot.y - turn.frame.minY)
        for step in 0...32 {
            let moved = inside.applying(CATransform3DGetAffineTransform(disc.turned(CGFloat(step) * .pi / 16)))
            #expect(hypot(moved.x - inside.x, moved.y - inside.y) < 0.0001)
        }
        disc.spin()
        let spin = try #require(turn.layer?.animation(forKey: "turn") as? CAKeyframeAnimation)
        let values = try #require(spin.values as? [NSValue])
        #expect(values.count == 33)
        for (step, value) in values.enumerated() {
            #expect(CATransform3DEqualToTransform(value.caTransform3DValue, disc.turned(CGFloat(step) * .pi / 16)))
        }
    }

    @Test func theSideArrowsSitInTheMiddleOfTheirDiscs() throws {
        for edge in [GestureDisc.Edge.left, .right] {
            for dark in [false, true] {
                for scale in [1, 2] {
                    let (window, disc) = staged(edge, dark: dark)
                    let holder = try #require(turner(in: disc))
                    let found = try #require(box(shot(disc, scale: scale), scale: scale))
                    let placed = CGPoint(x: holder.frame.midX + edge.hub.x, y: holder.frame.midY + edge.hub.y)
                    let pixel = 1 / window.backingScaleFactor
                    #expect(hypot(found.x - placed.x, found.y - placed.y) <= slack(scale))
                    #expect(abs(placed.x - GestureDisc.size / 2) <= pixel / 2 && abs(placed.y - GestureDisc.size / 2) <= pixel / 2)
                }
            }
        }
    }
}
