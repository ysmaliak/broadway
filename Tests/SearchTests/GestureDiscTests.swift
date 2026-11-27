import AppKit
import Testing
@testable import Search


private enum RingFit {
    typealias Ink = [(x: Double, y: Double, alpha: Double)]

    static func centre(_ ink: Ink) -> CGPoint? {
        guard var found = fit(ink) else { return nil }
        for _ in 0..<5 {
            let near = ink.filter { abs(hypot($0.x - found.x, $0.y - found.y) - found.r) < 1.2 }
            let kept = ring(near, around: found)
            guard kept.count > 8, let next = fit(kept) else { break }
            found = refine(kept, from: next)
        }
        return CGPoint(x: found.x, y: found.y)
    }

    private static func ring(_ ink: Ink, around found: (x: Double, y: Double, r: Double)) -> Ink {
        let bins = 36
        var mass = [Double](repeating: 0, count: bins), first = mass, second = mass
        var placed: [(Int, (x: Double, y: Double, alpha: Double))] = []
        for point in ink {
            let angle = atan2(point.y - found.y, point.x - found.x)
            let bin = min(bins - 1, Int((angle + .pi) / (2 * .pi) * Double(bins)))
            let d = hypot(point.x - found.x, point.y - found.y)
            mass[bin] += point.alpha
            first[bin] += point.alpha * d
            second[bin] += point.alpha * d * d
            placed.append((bin, point))
        }
        let spread = (0..<bins).map { bin -> Double? in
            guard mass[bin] > 0 else { return nil }
            let mean = first[bin] / mass[bin]
            return max(0, second[bin] / mass[bin] - mean * mean).squareRoot()
        }
        let seen = spread.compactMap { $0 }.sorted()
        guard !seen.isEmpty else { return ink }
        let typical = seen[seen.count / 2]
        let heavy = mass.filter { $0 > 0 }.sorted()
        let usual = heavy[heavy.count / 2]
        var drop = Set<Int>()
        for bin in 0..<bins {
            guard let s = spread[bin] else { continue }
            if s > typical * 1.25 || mass[bin] > usual * 1.6 {
                drop.formUnion((-2...2).map { (bin + bins + $0) % bins })
            }
        }
        for bin in 0..<bins where mass[bin] == 0 {
            drop.formUnion((-2...2).map { (bin + bins + $0) % bins })
        }
        return placed.filter { !drop.contains($0.0) }.map(\.1)
    }

    private static func refine(_ ink: Ink, from start: (x: Double, y: Double, r: Double)) -> (x: Double, y: Double, r: Double) {
        var (x, y, r) = start
        for _ in 0..<20 {
            var m = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
            var v = [Double](repeating: 0, count: 3)
            for p in ink {
                let d = max(1e-9, hypot(p.x - x, p.y - y))
                let j = [-(p.x - x) / d, -(p.y - y) / d, -1.0], e = d - r
                for i in 0..<3 {
                    v[i] -= p.alpha * j[i] * e
                    for k in 0..<3 { m[i][k] += p.alpha * j[i] * j[k] }
                }
            }
            guard let step = solve(m, v) else { break }
            x += step[0]
            y += step[1]
            r += step[2]
            if abs(step[0]) + abs(step[1]) < 1e-7 { break }
        }
        return (x, y, r)
    }

    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a, v = b
        for c in 0..<3 {
            guard let p = (c..<3).max(by: { abs(m[$0][c]) < abs(m[$1][c]) }), abs(m[p][c]) > 1e-12 else { return nil }
            m.swapAt(c, p)
            v.swapAt(c, p)
            for r in 0..<3 where r != c {
                let f = m[r][c] / m[c][c]
                for k in 0..<3 { m[r][k] -= f * m[c][k] }
                v[r] -= f * v[c]
            }
        }
        return (0..<3).map { v[$0] / m[$0][$0] }
    }

    private static func fit(_ ink: Ink) -> (x: Double, y: Double, r: Double)? {
        var m = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        var v = [Double](repeating: 0, count: 3)
        for p in ink {
            let row = [p.x, p.y, 1.0], z = -(p.x * p.x + p.y * p.y)
            for i in 0..<3 {
                v[i] += p.alpha * row[i] * z
                for j in 0..<3 { m[i][j] += p.alpha * row[i] * row[j] }
            }
        }
        for c in 0..<3 {
            guard let p = (c..<3).max(by: { abs(m[$0][c]) < abs(m[$1][c]) }), abs(m[p][c]) > 1e-12 else { return nil }
            m.swapAt(c, p)
            v.swapAt(c, p)
            for r in 0..<3 where r != c {
                let f = m[r][c] / m[c][c]
                for k in 0..<3 { m[r][k] -= f * m[c][k] }
                v[r] -= f * v[c]
            }
        }
        let s = (0..<3).map { v[$0] / m[$0][$0] }
        let x = -s[0] / 2, y = -s[1] / 2
        return (x, y, (x * x + y * y - s[2]).squareRoot())
    }
}

@Suite(.sharedWorld)
@MainActor
struct GestureDiscTests {
    private struct Ink {
        var points: [(x: Double, y: Double, alpha: Double)] = []
    }

    private final class Screen: NSWindow {
        var scale: CGFloat = 2
        override var backingScaleFactor: CGFloat { scale }
    }

    private let fine = 8
    private let slack: CGFloat = 0.15

    private func staged(_ edge: GestureDisc.Edge, dark: Bool, screen: CGFloat? = nil) -> (NSWindow, GestureDisc) {
        let side = GestureDisc.size * 4
        let frame = NSRect(x: 0, y: 0, width: side, height: side)
        let window: NSWindow
        if let screen {
            let scaled = Screen(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
            scaled.scale = screen
            window = scaled
        } else {
            window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        }
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = KitFlippedView(frame: frame)
        window.contentView = host
        let disc = GestureDisc(edge)
        host.addSubview(disc)
        disc.settle(in: host)
        disc.commit()
        hideGlass(in: disc)
        disc.layoutSubtreeIfNeeded()
        if let screen { backed(disc, at: screen) }
        disc.displayIfNeeded()
        return (window, disc)
    }

    private func backed(_ view: NSView, at scale: CGFloat) {
        view.layer?.contentsScale = scale
        view.needsDisplay = true
        view.subviews.forEach { backed($0, at: scale) }
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

    private func shot(_ disc: GestureDisc, scale: Int, least: Double = 0.05) -> Ink {
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
                guard alpha > least, hypot(x - middle, y - middle) < 16 else { continue }
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

    private func round(_ disc: GestureDisc) -> CGPoint? {
        RingFit.centre(shot(disc, scale: fine, least: 0.02).points)
    }

    private func box(_ ink: Ink, scale: Int) -> CGPoint? {
        guard let across = span(ink, scale: scale, across: true), let down = span(ink, scale: scale, across: false) else { return nil }
        return CGPoint(x: (across.lowerBound + across.upperBound) / 2, y: (down.lowerBound + down.upperBound) / 2)
    }

    private func slack(_ scale: Int) -> CGFloat {
        scale >= 2 ? 0.3 : 0.5
    }

    private func arc(around centre: CGPoint, turned: CGFloat, drawnAt scale: Int) -> RingFit.Ink {
        let side = 24
        let space = CGColorSpaceCreateDeviceRGB(), info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let small = CGContext(data: nil, width: side * scale, height: side * scale, bitsPerComponent: 8, bytesPerRow: side * scale * 4,
                                    space: space, bitmapInfo: info),
              let large = CGContext(data: nil, width: side * fine, height: side * fine, bitsPerComponent: 8, bytesPerRow: side * fine * 4,
                                    space: space, bitmapInfo: info)
        else { return [] }
        small.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        let radius: CGFloat = 5.3, end = turned + 2 * .pi - 0.85
        small.setLineWidth(1.5)
        small.setLineCap(.round)
        small.addArc(center: centre, radius: radius, startAngle: turned + 0.35, endAngle: end, clockwise: false)
        small.strokePath()
        let tip = CGPoint(x: centre.x + radius * cos(end), y: centre.y + radius * sin(end))
        let along = CGVector(dx: -sin(end), dy: cos(end)), out = CGVector(dx: cos(end), dy: sin(end))
        small.move(to: CGPoint(x: tip.x + along.dx * 2.6, y: tip.y + along.dy * 2.6))
        small.addLine(to: CGPoint(x: tip.x + out.dx * 2.2, y: tip.y + out.dy * 2.2))
        small.addLine(to: CGPoint(x: tip.x - out.dx * 2.2, y: tip.y - out.dy * 2.2))
        small.closePath()
        small.fillPath()
        guard let picture = small.makeImage(), let data = large.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        large.interpolationQuality = .low
        large.draw(picture, in: CGRect(x: 0, y: 0, width: side * fine, height: side * fine))
        var ink: RingFit.Ink = []
        for row in 0..<side * fine {
            for column in 0..<side * fine {
                let alpha = Double(data[(row * side * fine + column) * 4 + 3]) / 255
                guard alpha > 0.02 else { continue }
                ink.append(((Double(column) + 0.5) / Double(fine), Double(side) - (Double(row) + 0.5) / Double(fine), alpha))
            }
        }
        return ink
    }

    private func bare(_ image: NSImage, scale: Int) -> RingFit.Ink {
        let wide = Int(image.size.width) * scale, high = Int(image.size.height) * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: wide * 4, bitsPerPixel: 32)
        else { return [] }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return [] }
        var ink: RingFit.Ink = []
        for row in 0..<high {
            for column in 0..<wide {
                let alpha = Double(data[(row * wide + column) * 4 + 3]) / 255
                guard alpha > 0.02 else { continue }
                ink.append(((Double(column) + 0.5) / Double(scale), (Double(row) + 0.5) / Double(scale), alpha))
            }
        }
        return ink
    }

    @Test func theRingFitFindsAKnownCentreFromAFineRender() throws {
        for (scale, within) in [(1, 0.2), (2, 0.02), (8, 0.02)] {
            for offset in [0.0, 0.13, 0.25, 0.37, 0.5] {
                for step in 0..<16 {
                    let truth = CGPoint(x: 12 + offset, y: 11.7 + offset * 0.6)
                    let found = try #require(RingFit.centre(arc(around: truth, turned: CGFloat(step) * .pi / 8, drawnAt: scale)))
                    #expect(hypot(found.x - truth.x, found.y - truth.y) <= within, "\(scale)x, \(offset), step \(step): \(found)")
                }
            }
        }
    }

    @Test func theArrowsCircleSitsOnTheRingsCentreAtEveryAngleOfTheTurn() throws {
        for dark in [false, true] {
            for screen in [CGFloat(1), 2] {
                let (window, disc) = staged(.top, dark: dark, screen: screen)
                defer { window.contentView = nil }
                let turn = try #require(turner(in: disc)?.layer)
                for step in 0..<16 {
                    let angle = CGFloat(step) * .pi / 8
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    turn.sublayerTransform = disc.turned(angle)
                    CATransaction.commit()
                    let found = try #require(round(disc))
                    #expect(hypot(found.x - disc.pivot.x, found.y - disc.pivot.y) <= slack, "\(screen)x, step \(step): \(found) for \(disc.pivot)")
                }
            }
        }
    }

    @Test func theMeasuredMiddleOfTheArrowsCircleIsTheOneTheDiscKeeps() throws {
        for dark in [false, true] {
            for screen in [CGFloat(1), 2] {
                let (window, disc) = staged(.top, dark: dark, screen: screen)
                defer { window.contentView = nil }
                let holder = try #require(turner(in: disc))
                let found = try #require(round(disc))
                let drawn = CGPoint(x: found.x - holder.frame.midX, y: found.y - holder.frame.midY)
                #expect(hypot(drawn.x - disc.hub.x, drawn.y - disc.hub.y) <= slack, "\(screen)x: \(drawn) for \(disc.hub)")
            }
        }
    }

    @Test func theTurningArrowIsAFineRenderPlacedOnTheScreensPixels() throws {
        let style = KitSymbol.Style(size: GestureDisc.glyph, weight: .semibold)
        let symbol = try #require(KitGlyph.image("arrow.clockwise", style))
        let image = try #require(KitGlyph.fine("arrow.clockwise", style))
        let ring = try #require(GestureDisc.Edge.top.ring)
        let centre = try #require(RingFit.centre(bare(symbol, scale: 16)))
        #expect(abs(centre.x / image.size.width - ring.x) <= 0.004 && abs(centre.y / image.size.height - ring.y) <= 0.004, "\(centre) in \(image.size)")
        for screen in [CGFloat(1), 2] {
            let (window, disc) = staged(.top, dark: false, screen: screen)
            defer { window.contentView = nil }
            let holder = try #require(turner(in: disc))
            let arrow = try #require(holder.content as? KitSymbol)
            #expect(arrow.image === image)
            #expect(holder.frame.size == image.size)
            #expect((holder.frame.minX * screen).rounded() == holder.frame.minX * screen)
            #expect((holder.frame.minY * screen).rounded() == holder.frame.minY * screen)
            #expect(abs(disc.pivot.x - GestureDisc.size / 2) <= 0.5 / screen && abs(disc.pivot.y - GestureDisc.size / 2) <= 0.5 / screen)
        }
    }

    @Test func theTurnsCentreIsWhereTheArrowIsPlaced() throws {
        let (window, disc) = staged(.top, dark: false)
        let turn = try #require(turner(in: disc))
        let middle = GestureDisc.size / 2
        let hub = disc.hub
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
