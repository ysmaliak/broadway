import AppKit
import Testing
@testable import Search

@MainActor
struct CardRimTests {
    private let size = CGSize(width: 120, height: 90)
    private let corner = Metrics.pageRadius

    private func drawn(scale: CGFloat, card: CGRect? = nil, cut: CGRect? = nil) throws -> [[Double]] {
        let wide = Int(size.width * scale), high = Int(size.height * scale)
        var data = [UInt8](repeating: 0, count: wide * high * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: &data, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: wide * 4,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(high))
        context.scaleBy(x: scale, y: -scale)
        let bounds = CGRect(origin: .zero, size: size)
        CardRim.fill(card ?? bounds, in: bounds, cut: cut, corner: corner, line: PaneEdge.width, colour: .white, on: context)
        return (0..<high).map { y in (0..<wide).map { x in Double(data[(y * wide + x) * 4 + 3]) / 255 } }
    }

    @Test func theEdgeKeepsItsWeightRoundACornerAtOneAndTwoTimes() throws {
        for scale in [1, 2] as [CGFloat] {
            let full = Double(PaneEdge.width * scale)
            let reach = Int(corner * 2 * scale)

            let ink = try drawn(scale: scale)

            let straight = ink[Int(size.height / 2 * scale)][0..<reach].reduce(0, +)
            #expect(abs(straight - full) < 0.01)
            let gentle = Int((size.height - 1.52866483 * corner) * scale)...Int((size.height - 0.63149399 * corner) * scale)
            for row in gentle {
                let across = ink[row][0..<reach].reduce(0, +)
                #expect(across > full * 0.98 && across < full * 1.3)
            }
            let turning = Int((size.height - 1.52866483 * corner) * scale)..<Int((size.height - PaneEdge.width) * scale) - 1
            for row in turning {
                let peak = ink[row][0..<reach].max() ?? 0
                #expect(peak >= (scale >= 2 ? 0.98 : 0.5))
            }
            let foot = (0..<Int(size.height * scale)).map { ink[$0][Int(size.width / 2 * scale)] }.reduce(0, +)
            #expect(abs(foot - 2 * full) < 0.02)
        }
    }

    @Test func whereItsHostClipsTheCardTheEdgeRunsOutToItsOwnBoundsAndLeavesTheCurveToThatClip() throws {
        let bounds = CGRect(origin: .zero, size: size)
        let card = CGRect(x: 0.27, y: 0, width: size.width - 0.27, height: size.height)

        let own = try drawn(scale: 2, card: card)
        let hosted = try drawn(scale: 2, card: card, cut: card)
        let shape = CardRim.shape(card, in: bounds, cut: card, corner: corner, line: PaneEdge.width)

        #expect(own[0][0] == 0)
        #expect(hosted[0][0] == 1)
        #expect(hosted[Int(size.height * 2) - 1][0] == 1)
        #expect(hosted[0][Int(size.width * 2) - 1] == 1)
        let middle = Int(size.height)
        #expect(abs(own[middle][0..<20].reduce(0, +) - 2) < 0.01)
        #expect(abs(hosted[middle][0..<20].reduce(0, +) - 2.54) < 0.01)
        #expect(hosted[middle][0] == 1)
        #expect(shape.outer.boundingBoxOfPath == bounds)
        #expect(shape.inner.boundingBoxOfPath == card.insetBy(dx: PaneEdge.width, dy: PaneEdge.width))
    }

    @Test func aCurveCutFinerKeepsItsShape() {
        let rect = CGRect(x: 3, y: 5, width: 200, height: 120)
        let path = KitPath.continuous(rect, radius: corner)
        func curves(_ path: CGPath) -> Int {
            var count = 0
            path.applyWithBlock { if $0.pointee.type == .addCurveToPoint { count += 1 } }
            return count
        }

        let fine = KitPath.fine(path)

        #expect(curves(path) == 12)
        #expect(curves(fine) == 48)
        #expect(fine.boundingBoxOfPath == path.boundingBoxOfPath)
        for step in 0..<40 {
            let point = CGPoint(x: rect.minX + CGFloat(step) * 0.5, y: rect.minY + CGFloat(step) * 0.45)
            #expect(fine.contains(point) == path.contains(point))
        }
    }
}
