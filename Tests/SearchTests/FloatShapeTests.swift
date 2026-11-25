import AppKit
import Testing
@testable import Search

@Suite
struct FloatShapeTests {
    @Test func aWindowTakesTheVideosShapeAndKeepsItsArea() {
        let frame = NSRect(x: 100, y: 100, width: 440, height: 247)

        let shaped = Float.shaped(frame, to: NSSize(width: 4, height: 3), in: nil)

        #expect(abs(shaped.width / shaped.height - 4.0 / 3.0) < 0.0001)
        #expect(abs(shaped.width * shaped.height - 440 * 247) < 1)
        #expect(shaped.minX == frame.minX)
        #expect(shaped.maxY == frame.maxY)
    }

    @Test func aWindowAtTheBottomRightStaysInThatCorner() {
        let area = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 976, y: 24, width: 440, height: 247)

        let shaped = Float.shaped(frame, to: NSSize(width: 1920, height: 1080), in: area)

        #expect(abs(shaped.maxX - frame.maxX) < 0.0001)
        #expect(abs(shaped.minY - frame.minY) < 0.0001)
        #expect(abs(shaped.width / shaped.height - 16.0 / 9.0) < 0.0001)
    }

    @Test func aTallVideoGetsATallWindowThatStaysOnScreen() {
        let area = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 976, y: 24, width: 1000, height: 562)

        let shaped = Float.shaped(frame, to: NSSize(width: 9, height: 16), in: area)

        #expect(shaped.height > shaped.width)
        #expect(abs(shaped.width / shaped.height - 9.0 / 16.0) < 0.0001)
        #expect(area.contains(shaped))
    }

    @Test func aSmallWindowIsNeverSmallerThanTheLeast() {
        let frame = NSRect(x: 0, y: 0, width: 100, height: 56)
        let shape = NSSize(width: 21, height: 9)

        let shaped = Float.shaped(frame, to: shape, in: nil)

        #expect(shaped.width >= Float.least(for: shape).width)
        #expect(abs(shaped.width / shaped.height - 21.0 / 9.0) < 0.0001)
    }

    @Test func noShapeOrAnEmptyOneIsNotUsed() {
        #expect(Float.usable(nil) == nil)
        #expect(Float.usable(NSSize(width: 0, height: 720)) == nil)
        #expect(Float.usable(NSSize(width: 1280, height: CGFloat.nan)) == nil)
    }

    @Test func anExtremeShapeIsHeldToAWindowThatStillMakesSense() {
        let wide = Float.usable(NSSize(width: 10000, height: 100))
        let tall = Float.usable(NSSize(width: 100, height: 10000))

        #expect(wide.map { $0.width / $0.height } == 4)
        #expect(tall.map { $0.width / $0.height } == 0.25)
    }

    @Test func thePollCarriesTheVideosShape() {
        let state = FloatMediaState(["current": 1.0, "shape": [1920.0, 804.0]])

        #expect(state.shape == NSSize(width: 1920, height: 804))
        #expect(FloatMediaState(["current": 1.0]).shape == nil)
    }
}
