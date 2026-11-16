import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct FolderGlyphTests {
    private func placed() -> (NSWindow, FolderGlyphView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: true)
        let glyph = FolderGlyphView(frame: NSRect(origin: .zero, size: FolderGlyphView.size))
        window.contentView?.addSubview(glyph)
        glyph.layoutSubtreeIfNeeded()
        return (window, glyph)
    }

    private func shape(_ glyph: FolderGlyphView) -> CAShapeLayer? {
        glyph.layer?.sublayers?.first as? CAShapeLayer
    }

    private func flap(_ glyph: FolderGlyphView) -> CAShapeLayer? {
        glyph.layer?.sublayers?.dropFirst().first as? CAShapeLayer
    }

    @Test func shuttingWithACurveAddsAPathMorph() throws {
        let (window, glyph) = placed()
        glyph.curve = .spring(.settle)

        glyph.open = 0

        let morph = try #require(shape(glyph)?.animation(forKey: "path") as? CAKeyframeAnimation)
        let values = try #require(morph.values as? [CGPath])
        let box = CGRect(origin: .zero, size: FolderGlyphView.size)
        #expect(values.first == FolderGlyphView.ring(open: 1, in: box))
        #expect(values.last == FolderGlyphView.ring(open: 0, in: box))
        #expect(shape(glyph)?.path == FolderGlyphView.ring(open: 0, in: box))
        let bar = try #require(flap(glyph)?.animation(forKey: "path") as? CAKeyframeAnimation)
        #expect((bar.values as? [CGPath])?.first == FolderGlyphView.flap(open: 1, in: box))
        #expect((bar.values as? [CGPath])?.last == FolderGlyphView.flap(open: 0, in: box))
        let width = try #require(flap(glyph)?.animation(forKey: "lineWidth") as? CAKeyframeAnimation)
        #expect((width.values as? [CGFloat])?.first == FolderGlyphView.stroke)
        #expect((width.values as? [CGFloat])?.last == FolderGlyphView.barWidth)
        #expect(flap(glyph)?.lineWidth == FolderGlyphView.barWidth)
        withExtendedLifetime(window) {}
    }

    @Test func everyFrameOfTheMorphIsTheFolderAtThatOpenness() throws {
        let (window, glyph) = placed()
        glyph.open = 0
        glyph.curve = .spring(.settle)

        glyph.open = 1

        let morph = try #require(shape(glyph)?.animation(forKey: "path") as? CAKeyframeAnimation)
        let values = try #require(morph.values as? [CGPath])
        let box = CGRect(origin: .zero, size: FolderGlyphView.size)
        let steps = values.count - 1
        for (step, value) in values.enumerated() {
            let amount = FolderGlyphView.progress(morph.duration * Double(step) / Double(steps), curve: .spring(.settle))
            #expect(value == FolderGlyphView.ring(open: amount, in: box))
        }
        withExtendedLifetime(window) {}
    }

    @Test func everyFrameOfTheMorphHasTheSameShapeSoNoneIsDrawnBetweenTwo() throws {
        let (window, glyph) = placed()
        glyph.curve = .spring(.settle)
        func kinds(_ path: CGPath) -> [Int32] {
            var kinds: [Int32] = []
            path.applyWithBlock { kinds.append($0.pointee.type.rawValue) }
            return kinds
        }

        glyph.open = 0

        let morph = try #require(shape(glyph)?.animation(forKey: "path") as? CAKeyframeAnimation)
        let values = try #require(morph.values as? [CGPath])
        let first = kinds(try #require(values.first))
        #expect(values.allSatisfy { kinds($0) == first })
        withExtendedLifetime(window) {}
    }

    @Test func withoutACurveTheFolderChangesAtOnce() {
        let (window, glyph) = placed()
        glyph.curve = .none

        glyph.open = 0

        #expect(shape(glyph)?.animation(forKey: "path") == nil)
        #expect(flap(glyph)?.animation(forKey: "path") == nil)
        #expect(shape(glyph)?.path == FolderGlyphView.ring(open: 0, in: CGRect(origin: .zero, size: FolderGlyphView.size)))
        #expect(flap(glyph)?.path == FolderGlyphView.flap(open: 0, in: CGRect(origin: .zero, size: FolderGlyphView.size)))
        withExtendedLifetime(window) {}
    }

    @Test func theOpenFlapsEdgeEndsFreeClearOfTheBacksWallAndBottom() {
        let box = CGRect(origin: .zero, size: FolderGlyphView.size)

        let open = FolderGlyphView.outline(open: 1, in: box)

        #expect(abs(open.flapFoot.x - open.backBottomLeft.x - FolderGlyphView.footOut) < 1e-9)
        #expect(abs(open.flapFoot.y - open.lipLeft.y - FolderGlyphView.footDrop) < 1e-9)
        #expect(open.flapEnd == open.wallEnd)
        #expect(open.flapFoot.x - open.backBottomLeft.x - FolderGlyphView.stroke >= 1)
        #expect(open.backBottomLeft.y - open.flapFoot.y - FolderGlyphView.stroke >= 1)
        #expect(open.wallEnd.x == open.backTopRight.x && open.wallEnd.y == open.lipRight.y)
        #expect(abs(open.lipRight.x - open.wallEnd.x - FolderGlyphView.reach) < 1e-9)
        #expect(open.toe.y == open.backBottomLeft.y && abs(open.backTopRight.x - open.toe.x - FolderGlyphView.toeIn) < 1e-9)
    }

    @Test func theOpenFrontPanelIsNearlyHalfTheBody() {
        let box = CGRect(origin: .zero, size: FolderGlyphView.size)

        let open = FolderGlyphView.outline(open: 1, in: box)

        let body = open.backBottomLeft.y - open.backTopLeft.y
        let front = open.backBottomLeft.y - open.lipLeft.y
        #expect(front / body > 0.45, "\(front) of \(body)")
    }

    @Test func shutTheFrontIsSFsFloatingBarClearOfBothWalls() {
        let box = CGRect(origin: .zero, size: FolderGlyphView.size)

        let shut = FolderGlyphView.outline(open: 0, in: box)

        #expect(shut.wallEnd == shut.lipRight)
        #expect(shut.toe.x == shut.backTopRight.x)
        #expect(shut.lipLeft == shut.flapFoot)
        #expect(shut.lipLeft.y == shut.flapEnd.y)
        let inner = (left: shut.backTopLeft.x + FolderGlyphView.stroke / 2, right: shut.backTopRight.x - FolderGlyphView.stroke / 2)
        let bar = (left: shut.lipLeft.x - FolderGlyphView.barWidth / 2, right: shut.flapEnd.x + FolderGlyphView.barWidth / 2)
        #expect(bar.left - inner.left > 0.6 && bar.left - inner.left < 0.9, "\(bar.left - inner.left)")
        #expect(inner.right - bar.right > 0.6 && inner.right - bar.right < 0.9, "\(inner.right - bar.right)")
    }

    @Test(arguments: [CGFloat(0), 0.5, 1])
    func theStrokeStaysInsideTheBox(open: CGFloat) {
        let box = CGRect(origin: .zero, size: FolderGlyphView.size)

        let drawn = FolderGlyphView.path(open: open, in: box).boundingBoxOfPath.insetBy(dx: -FolderGlyphView.stroke / 2, dy: -FolderGlyphView.stroke / 2)

        #expect(box.contains(drawn), "\(drawn)")
    }

    @Test(arguments: [CGFloat(0), 0.25, 0.5, 0.75, 1])
    func theFlapsEdgeLeansOneAcrossForTwoDownSoItGrowsOutOfTheWallsCorner(open: CGFloat) {
        let box = CGRect(origin: .zero, size: FolderGlyphView.size)

        let o = FolderGlyphView.outline(open: open, in: box)

        #expect(abs(2 * (o.lipLeft.x - o.flapFoot.x) - (o.flapFoot.y - o.lipLeft.y)) < 1e-6)
        #expect(o.flapFoot.y >= o.lipLeft.y)
        #expect(o.flapFoot.x >= o.backBottomLeft.x)
    }

    @Test func openTheFlapsEdgesAreParallelSoThePanelIsAParallelogram() {
        let box = CGRect(origin: .zero, size: FolderGlyphView.size)

        let o = FolderGlyphView.outline(open: 1, in: box)

        let left = (o.flapFoot.x - o.lipLeft.x) / (o.flapFoot.y - o.lipLeft.y)
        let right = (o.toe.x - o.lipRight.x) / (o.toe.y - o.lipRight.y)
        #expect(abs(left - right) < 1e-6, "\(left) \(right)")
    }

    @Test func theOpenFlapsTopStaysInsideTheBack() {
        let box = CGRect(origin: .zero, size: FolderGlyphView.size)
        let stroke: CGFloat = 1.3

        let open = FolderGlyphView.outline(open: 1, in: box)

        #expect(open.lipRight.x <= open.backTopRight.x + stroke)
        #expect(open.lipLeft.x >= open.backTopLeft.x)
        #expect(open.lipLeft.y > open.backTopRight.y)
        #expect(open.lipRight.y > open.backTopRight.y)
    }

    @Test(arguments: [NSFont.Weight.semibold])
    func shutItIsSFsFolderAtTheHeadingsWeight(weight: NSFont.Weight) throws {
        let box = CGRect(origin: .zero, size: FolderGlyphView.size)
        let scale = 8
        let symbol = try #require(NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: weight)))

        let reference = coverage(scale) { _ in
            symbol.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let drawn = coverage(scale) { context in
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(FolderGlyphView.stroke)
            context.addPath(FolderGlyphView.ring(open: 0, in: box))
            context.strokePath()
            context.setLineWidth(FolderGlyphView.flapWidth(open: 0))
            context.addPath(FolderGlyphView.flap(open: 0, in: box))
            context.strokePath()
        }

        let pixel = 1 / (NSScreen.main?.backingScaleFactor ?? 2)
        #expect(abs(symbol.size.width - box.width) <= pixel && abs(symbol.size.height - box.height) <= pixel,
                "SF's folder is \(symbol.size) against a box of \(box.size) at \(pixel) pt a pixel")
        let total = reference.reduce(0) { $0 + Int($1) }, ours = drawn.reduce(0) { $0 + Int($1) }
        let apart = zip(reference, drawn).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        #expect(Double(abs(total - ours)) / Double(total) < 0.03, "ink \(ours) against SF's \(total)")
        #expect(Double(apart) / Double(total) < 0.08, "\(Double(apart) / Double(total)) of SF's ink lies apart")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOLDER_GLYPH_SHOTS"] != nil))
    func shotsBesideSFsFolder() throws {
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FOLDER_GLYPH_SHOTS"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let cells: [CGFloat?] = [nil, 0, 0.25, 0.5, 0.75, 1]

        for dark in [true, false] {
            for scale in [2, 8] {
                let cell = CGSize(width: 34, height: 26)
                let width = Int(cell.width) * cells.count * scale, height = Int(cell.height) * scale
                let space = CGColorSpace(name: CGColorSpace.sRGB)!
                let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(dark ? CGColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1) : CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
                for (index, open) in cells.enumerated() {
                    let origin = CGPoint(x: CGFloat(index) * cell.width + (cell.width - 19) / 2, y: (cell.height - 15) / 2)
                    let glyph = FolderGlyphView(frame: NSRect(origin: .zero, size: FolderGlyphView.size))
                    glyph.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    glyph.open = open ?? 0
                    glyph.layoutSubtreeIfNeeded()
                    glyph.updateLayer()
                    let ink = (glyph.layer?.sublayers?.first as? CAShapeLayer)?.strokeColor ?? .black
                    context.saveGState()
                    context.translateBy(x: origin.x, y: origin.y)
                    if open == nil {
                        let tinted = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                            .applying(.init(paletteColors: [NSColor(cgColor: ink) ?? .black]))
                        let symbol = try #require(NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?.withSymbolConfiguration(tinted))
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                        symbol.draw(in: CGRect(origin: .zero, size: FolderGlyphView.size), from: .zero, operation: .sourceOver, fraction: 1,
                                    respectFlipped: true, hints: nil)
                        NSGraphicsContext.restoreGraphicsState()
                    } else {
                        glyph.layer?.render(in: context)
                    }
                    context.restoreGState()
                }
                let image = try #require(context.makeImage())
                let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: out.appendingPathComponent("glyph-\(dark ? "dark" : "light")-\(scale)x.png"))
            }
        }

        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("glyph-dark-2x.png").path))
    }

    private func coverage(_ scale: Int, _ draw: (CGContext) -> Void) -> [UInt8] {
        let width = Int(FolderGlyphView.size.width) * scale, height = Int(FolderGlyphView.size.height) * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return [] }
        rep.size = FolderGlyphView.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        draw(context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return [] }
        return (0..<(width * height)).map { data[$0 * 4 + 3] }
    }

    @Test func theLowerHalfIsDrawnOnceSoNoWallIsStrokedTwice() {
        let box = CGRect(origin: .zero, size: FolderGlyphView.size)

        let path = FolderGlyphView.path(open: 1, in: box)

        let lines = segments(path)
        #expect(!lines.isEmpty)
        let doubled = lines.indices.contains { i in
            lines.indices.contains { j in
                j > i && overlap(lines[i], lines[j]) > 0.25
            }
        }
        #expect(!doubled)
    }

    @Test func everyFrameOfTheMorphIsOneCleanFolder() throws {
        let (window, glyph) = placed()
        glyph.open = 0
        glyph.curve = .spring(.settle)

        glyph.open = 1

        let morph = try #require(shape(glyph)?.animation(forKey: "path") as? CAKeyframeAnimation)
        let values = try #require(morph.values as? [CGPath])
        let bars = try #require(flap(glyph)?.animation(forKey: "path") as? CAKeyframeAnimation)
        let fronts = try #require(bars.values as? [CGPath])
        #expect(fronts.count == values.count)
        let count = elements(try #require(values.first))
        for (step, (value, front)) in zip(values, fronts).enumerated() {
            #expect(elements(value) == count, "frame \(step)")
            let both = CGMutablePath()
            both.addPath(value)
            both.addPath(front)
            #expect(crossings(both) == 0, "frame \(step)")
        }
        withExtendedLifetime(window) {}
    }

    @Test func aReversalMidFoldStartsFromTheShapeShownAndKeepsItsWay() throws {
        let (window, glyph) = placed()
        glyph.curve = .spring(.settle)
        glyph.open = 0
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        glyph.open = 1

        let morph = try #require(shape(glyph)?.animation(forKey: "path") as? CAKeyframeAnimation)
        let values = try #require(morph.values as? [CGPath])
        let box = CGRect(origin: .zero, size: FolderGlyphView.size)
        func reach(_ path: CGPath) -> CGFloat { path.boundingBoxOfPath.maxX }
        let shut = reach(FolderGlyphView.ring(open: 0, in: box)), open = reach(FolderGlyphView.ring(open: 1, in: box))
        let first = reach(try #require(values.first))
        #expect(first > shut + 0.01 && first < open - 0.01, "the morph starts where the fold is, not at an end: \(first)")
        #expect(reach(values[1]) <= first, "it keeps shutting for a moment before it opens: \(values.prefix(4).map(reach))")
        #expect(reach(try #require(values.last)) == open)
        let count = elements(try #require(values.first))
        for (step, value) in values.enumerated() {
            #expect(elements(value) == count, "frame \(step)")
            #expect(crossings(value) == 0, "frame \(step)")
        }
        withExtendedLifetime(window) {}
    }

    @Test func theSpringWithASpeedStartsAtThatSpeed() {
        let spring = KitSpring.settle

        let early = spring.progress(0.000001, velocity: -6) / 0.000001
        let rest = spring.progress(0.000001) / 0.000001

        #expect(abs(early - -6) < 0.1)
        #expect(abs(rest) < 0.1)
        #expect(abs(spring.rate(0.05, velocity: -6) - (spring.progress(0.0501, velocity: -6) - spring.progress(0.0499, velocity: -6)) / 0.0002) < 0.01)
        #expect(abs(spring.progress(spring.time(toReach: 0.5)) - 0.5) < 0.001)
    }

    @Test func theCrossingCheckSeesACrossing() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 10, y: 10))
        path.move(to: CGPoint(x: 0, y: 10))
        path.addLine(to: CGPoint(x: 10, y: 0))

        let found = crossings(path)

        #expect(found == 1)
    }

    private func elements(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { _ in count += 1 }
        return count
    }

    private func segments(_ path: CGPath) -> [(CGPoint, CGPoint)] {
        var out: [(CGPoint, CGPoint)] = []
        var last = CGPoint.zero
        var first = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                last = element.points[0]
                first = last
            case .addLineToPoint:
                out.append((last, element.points[0]))
                last = element.points[0]
            case .addQuadCurveToPoint:
                let control = element.points[0], end = element.points[1]
                var previous = last
                for step in 1...12 {
                    let t = CGFloat(step) / 12, u = 1 - t
                    let point = CGPoint(x: u * u * last.x + 2 * u * t * control.x + t * t * end.x,
                                        y: u * u * last.y + 2 * u * t * control.y + t * t * end.y)
                    out.append((previous, point))
                    previous = point
                }
                last = end
            case .addCurveToPoint:
                let one = element.points[0], two = element.points[1], end = element.points[2]
                var previous = last
                for step in 1...12 {
                    let t = CGFloat(step) / 12, u = 1 - t
                    let point = CGPoint(x: u * u * u * last.x + 3 * u * u * t * one.x + 3 * u * t * t * two.x + t * t * t * end.x,
                                        y: u * u * u * last.y + 3 * u * u * t * one.y + 3 * u * t * t * two.y + t * t * t * end.y)
                    out.append((previous, point))
                    previous = point
                }
                last = end
            case .closeSubpath:
                out.append((last, first))
                last = first
            @unknown default:
                break
            }
        }
        return out.filter { hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) > 1e-6 }
    }

    private func overlap(_ one: (CGPoint, CGPoint), _ two: (CGPoint, CGPoint)) -> CGFloat {
        let (a, b) = one, (c, d) = two
        let length = hypot(b.x - a.x, b.y - a.y)
        let u = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
        func off(_ p: CGPoint) -> CGFloat { abs((p.x - a.x) * u.y - (p.y - a.y) * u.x) }
        guard off(c) < 0.05, off(d) < 0.05 else { return 0 }
        func along(_ p: CGPoint) -> CGFloat { (p.x - a.x) * u.x + (p.y - a.y) * u.y }
        let low = max(0, min(along(c), along(d)))
        let high = min(length, max(along(c), along(d)))
        return max(0, high - low)
    }

    private func crossings(_ path: CGPath) -> Int {
        let lines = segments(path)
        func side(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        func apart(_ one: CGFloat, _ two: CGFloat) -> Bool { (one > 1e-4 && two < -1e-4) || (one < -1e-4 && two > 1e-4) }
        var found = 0
        for i in lines.indices {
            for j in lines.indices where j > i {
                let (a, b) = lines[i], (c, d) = lines[j]
                if apart(side(a, b, c), side(a, b, d)), apart(side(c, d, a), side(c, d, b)) { found += 1 }
            }
        }
        return found
    }

    @Test func theSettleSpringRunsFromNothingToAll() {
        let curve = KitCurve.spring(.settle)

        let start = FolderGlyphView.progress(0, curve: curve)
        let middle = FolderGlyphView.progress(0.05, curve: curve)
        let end = FolderGlyphView.progress(FolderGlyphView.duration(of: curve), curve: curve)

        #expect(start == 0)
        #expect(middle > 0 && middle < 1)
        #expect(end == 1)
    }
}
