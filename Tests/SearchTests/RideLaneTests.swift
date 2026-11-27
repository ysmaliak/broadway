import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct RideLaneTests {
    func neighbour(width: CGFloat) -> CGFloat {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let motion = SpaceMotion()
        let rider = RideView(content: NSView(), motion: motion)
        rider.frame = NSRect(x: 0, y: 0, width: width, height: 688)
        window.contentView?.addSubview(rider)
        rider.set(RideLook(here: 0, span: 0, clip: .none, band: false, hits: false, lane: 1))
        return rider.content.layer?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? .nan
    }

    @Test func aNeighbourPageRidesExactlyOneStageWidthAwaySoNoGroundShowsBetweenThem() {
        #expect(neighbour(width: 815.73) == 815.73)
        #expect(neighbour(width: 836) == 836)
    }
}
