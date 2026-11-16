import AppKit
import QuartzCore
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct KitGradientTests {
    @Test func aSquareKeepsItsCornerToCornerAxis() {
        let layer = CAGradientLayer()

        layer.kitAxis(in: CGSize(width: 50, height: 50))

        #expect(layer.startPoint == .zero)
        #expect(abs(layer.endPoint.x - 1) < 0.0001)
        #expect(abs(layer.endPoint.y - 1) < 0.0001)
    }

    @Test func aWideLayerRunsItsLinesAcrossTheDiagonalInPoints() {
        let size = CGSize(width: 560, height: 230)
        let layer = CAGradientLayer()

        layer.kitAxis(in: size)

        let axis = CGPoint(x: layer.endPoint.x, y: layer.endPoint.y)
        #expect(abs(axis.x / axis.y - pow(size.width / size.height, 2)) < 0.0001)
        let far = (axis.x * 1 + axis.y * 1) / (axis.x * axis.x + axis.y * axis.y)
        #expect(abs(far - 1) < 0.0001)
    }

    @Test func aFlatLineKeepsItsEnds() {
        let layer = CAGradientLayer()

        layer.kitAxis(from: CGPoint(x: 0, y: 0.5), to: CGPoint(x: 1, y: 0.5), in: CGSize(width: 300, height: 40))

        #expect(layer.startPoint == CGPoint(x: 0, y: 0.5))
        #expect(abs(layer.endPoint.x - 1) < 0.0001)
        #expect(abs(layer.endPoint.y - 0.5) < 0.0001)
    }

    @Test func aBoxsDiagonalGradientFollowsItsShape() throws {
        let box = KitBox(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        box.gradient = [.black, .white]
        box.gradientAxis = (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1))
        let expected = CAGradientLayer()
        expected.kitAxis(in: CGSize(width: 200, height: 50))

        box.layout()
        box.updateLayer()
        let layer = try #require(box.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first)

        #expect(abs(layer.endPoint.x - expected.endPoint.x) < 0.0001)
        #expect(abs(layer.endPoint.y - expected.endPoint.y) < 0.0001)
        #expect(layer.endPoint.y < 0.2)
    }
}
