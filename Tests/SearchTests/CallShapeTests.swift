import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct CallShapeTests {
    private let screen = NSRect(x: 0, y: 0, width: 1600, height: 1000)
    private let room = NSRect(x: 0, y: 40, width: 1600, height: 930)

    private func store() -> UserDefaults {
        let name = "call-shape-tests-\(UUID().uuidString)"
        let made = UserDefaults(suiteName: name) ?? .standard
        made.removePersistentDomain(forName: name)
        return made
    }

    private func panel(_ frame: NSRect) -> NSPanel {
        let made = NSPanel(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        made.isReleasedWhenClosed = false
        return made
    }

    @Test func withNoSharedScreenTheWindowIsTodaysSizeAtItsSmallest() {
        let size = CallShape.size(width: CallShape.smallest, picture: nil, screen: screen)

        #expect(size == CallFloat.size)
        #expect(size == NSSize(width: 340, height: 214))
    }

    @Test func theStageTakesASharedScreensShapeAndTheBarKeepsItsHeight() {
        let wide = CallShape.size(width: 340, picture: 16.0 / 9.0, screen: screen)
        let tall = CallShape.size(width: 340, picture: 16.0 / 10.0, screen: screen)

        #expect(wide == NSSize(width: 340, height: 248))
        #expect(tall == NSSize(width: 340, height: 269))
        #expect(abs((wide.width - CallShape.sides) / (wide.height - CallShape.ends) - 16.0 / 9.0) < 0.01)
        #expect(CallShape.ends == 66)
    }

    @Test func aPictureNarrowerOrWiderThanTheWindowMayBeStopsAtTheLimit() {
        let narrow = CallShape.size(width: 340, picture: 0.3, screen: screen)
        let wide = CallShape.size(width: 340, picture: 9, screen: screen)

        #expect(narrow == NSSize(width: 340, height: 498))
        #expect(wide == NSSize(width: 340, height: 147))
        #expect(CallShape.shape(0) == CallShape.rest)
        #expect(CallShape.shape(nil) == CallShape.rest)
    }

    @Test func aChosenWidthIsKeptAndTheHeightFollowsThePicture() {
        let rest = CallShape.size(width: 600, picture: nil, screen: screen)
        let shared = CallShape.size(width: 600, picture: 16.0 / 10.0, screen: screen)

        #expect(rest.width == 600)
        #expect(shared.width == 600)
        #expect(rest.height == CallShape.height(width: 600, shape: CallShape.rest))
        #expect(shared.height == 431)
    }

    @Test func theWidthStaysBetweenTodaysSizeAndHalfTheScreen() {
        let small = CallShape.width(120, screen: screen)
        let large = CallShape.width(5000, screen: screen)
        let unknown = CallShape.width(5000, screen: nil)

        #expect(small == 340)
        #expect(large == 800)
        #expect(unknown == 680)
    }

    @Test func aWindowNeverGrowsTallerThanTheScreenHasRoomFor() {
        let size = CallShape.size(width: 800, picture: 0.75, screen: screen, room: room)

        #expect(size == NSSize(width: 800, height: 930))
    }

    @Test func draggingASideEdgeKeepsTheShape() {
        let was = NSSize(width: 340, height: 214)

        let wider = CallShape.dragged(from: was, to: NSSize(width: 500, height: 214), picture: nil, screen: screen)
        let taller = CallShape.dragged(from: was, to: NSSize(width: 340, height: 300), picture: nil, screen: screen)
        let shared = CallShape.dragged(from: was, to: NSSize(width: 500, height: 214), picture: 16.0 / 9.0, screen: screen)
        let under = CallShape.dragged(from: was, to: NSSize(width: 200, height: 100), picture: nil, screen: screen)

        #expect(wider == NSSize(width: 500, height: CallShape.height(width: 500, shape: CallShape.rest)))
        #expect(taller.height == CallShape.height(width: taller.width, shape: CallShape.rest))
        #expect(abs(taller.height - 300) <= 1)
        #expect(shared == NSSize(width: 500, height: 338))
        #expect(under == was)
    }

    @Test func itGrowsFromTheCornerItSitsIn() {
        let grown = NSSize(width: 340, height: 269)

        let bottomRight = CallShape.frame(NSRect(x: 1236, y: 64, width: 340, height: 214), size: grown, in: room)
        let topLeft = CallShape.frame(NSRect(x: 24, y: 732, width: 340, height: 214), size: grown, in: room)
        let wider = CallShape.frame(NSRect(x: 1236, y: 64, width: 340, height: 214), size: NSSize(width: 600, height: 333), in: room)

        #expect(bottomRight == NSRect(x: 1236, y: 64, width: 340, height: 269))
        #expect(topLeft == NSRect(x: 24, y: 677, width: 340, height: 269))
        #expect(wider == NSRect(x: 976, y: 64, width: 600, height: 333))
    }

    @Test func itNeverLeavesTheScreenAndNeverMovesWhatWasAlreadyOutside() {
        let large = NSSize(width: 800, height: 930)

        let inside = CallShape.frame(NSRect(x: 100, y: 500, width: 340, height: 214), size: large, in: room)
        let partly = CallShape.frame(NSRect(x: 1400, y: 64, width: 340, height: 214), size: NSSize(width: 340, height: 269), in: room)
        let unseen = CallShape.frame(NSRect(x: -20000, y: -20000, width: 340, height: 214), size: large, in: nil)

        #expect(room.contains(inside))
        #expect(partly == NSRect(x: 1400, y: 64, width: 340, height: 269))
        #expect(unseen.origin == NSPoint(x: -20000, y: -20000))
    }

    @Test func withReduceMotionTheWindowChangesAtOnce() {
        #expect(CallShape.glide(reduced: true, seen: true) == nil)
        #expect(CallShape.glide(reduced: false, seen: false) == nil)
        #expect((CallShape.glide(reduced: false, seen: true) ?? 0) > 0)
    }

    @Test func thePageIsDrawnAtHalfSizeAtTheSmallestAndGrowsHalfAsFastAsTheWindowToFullSize() {
        #expect(CallShape.zoom(width: 340) == 0.5)
        #expect(abs(CallShape.zoom(width: 765) - 0.75) < 0.0001)
        #expect(CallShape.zoom(width: 1360) == 1)
        #expect(CallShape.zoom(width: 2000) == 1)
        #expect(CallShape.zoom(width: 200) == 0.5)
    }

    @Test func thePageGetsMoreRoomAsWellAsALargerDrawingWhenTheWindowGrows() {
        let small = 340 / CallShape.zoom(width: 340)
        let middle = 810 / CallShape.zoom(width: 810)
        let large = 1280 / CallShape.zoom(width: 1280)

        #expect(small == 680)
        #expect(middle > small)
        #expect(large > middle)
    }

    @Test func withTilesThePageIsLaidOutAsLargeAsALaptopsWindowWhateverTheWindowsSize() {
        let sizes = [NSSize(width: 340, height: 214), NSSize(width: 471, height: 274), NSSize(width: 800, height: 386),
                     NSSize(width: 340, height: 498)]

        let laid = sizes.map { size in NSSize(width: size.width / CallShape.zoom(tiles: size), height: size.height / CallShape.zoom(tiles: size)) }

        for page in laid {
            #expect(page.width >= 1280 - 0.01 && page.height >= 800 - 0.01)
            #expect(abs(page.width - 1280) < 0.01 || abs(page.height - 800) < 0.01)
        }
        #expect(abs(CallShape.zoom(tiles: NSSize(width: 340, height: 214)) - 340.0 / 1280) < 0.0001)
    }

    @Test func aResizeTellsWhoeverScalesThePage() {
        let sizing = CallSizing(store: store())
        let window = panel(NSRect(x: -20000, y: -20000, width: 340, height: 214))
        defer { window.close() }
        sizing.attach(window)
        var told: [CGFloat] = []
        sizing.resized = { told.append($0) }

        sizing.choose(width: 480)
        sizing.detach()

        #expect(told == [480])
    }

    @Test func onlyTheBandAtTheEdgeCountsAsTheEdge() {
        let bounds = NSRect(x: 0, y: 0, width: 340, height: 214)

        #expect(CallShape.onEdge(NSPoint(x: 2, y: 100), of: bounds))
        #expect(CallShape.onEdge(NSPoint(x: 342, y: 100), of: bounds))
        #expect(CallShape.onEdge(NSPoint(x: 170, y: 211), of: bounds))
        #expect(!CallShape.onEdge(NSPoint(x: 170, y: 100), of: bounds))
        #expect(!CallShape.onEdge(NSPoint(x: 10, y: 10), of: bounds))
    }

    @Test func aSharedScreenShapesTheWindowAndItGoesBackWhenThePresentationEnds() {
        let sizing = CallSizing(store: store())
        let window = panel(NSRect(x: -20000, y: -20000, width: 340, height: 214))
        defer { window.close() }
        sizing.attach(window)

        sizing.heard(16.0 / 9.0)
        let shared = window.frame
        sizing.heard(0)
        let loading = window.frame
        sizing.heard(-1)
        let onceMissed = window.frame
        sizing.heard(-1)
        let ended = window.frame
        sizing.detach()

        #expect(shared == NSRect(x: -20000, y: -20000, width: 340, height: 248))
        #expect(loading == shared)
        #expect(onceMissed == shared)
        #expect(ended == NSRect(x: -20000, y: -20000, width: 340, height: 214))
    }

    @Test func aChosenSizeIsRememberedForTheNextCall() {
        let kept = store()
        let first = CallSizing(store: kept)
        let window = panel(NSRect(x: -20000, y: -20000, width: 340, height: 214))
        defer { window.close() }
        first.attach(window)

        first.choose(width: 480)
        let chosen = window.frame.size
        first.heard(16.0 / 10.0)
        let shared = window.frame.size
        first.detach()
        let next = CallSizing(store: kept).opening(on: nil)

        #expect(chosen == NSSize(width: 480, height: CallShape.height(width: 480, shape: CallShape.rest)))
        #expect(shared == NSSize(width: 480, height: 356))
        #expect(next.width == 480)
        #expect(next.height == CallShape.height(width: 480, shape: CallShape.rest))
        #expect(window.frame.size == chosen)
    }

    @Test func goingBackToTheSmallestIsRememberedToo() {
        let kept = store()
        let sizing = CallSizing(store: kept)
        let window = panel(NSRect(x: -20000, y: -20000, width: 340, height: 214))
        defer { window.close() }
        sizing.attach(window)
        sizing.choose(width: 500)

        sizing.shrink()
        let next = CallSizing(store: kept).opening(on: nil)
        sizing.detach()

        #expect(window.frame.size == NSSize(width: 340, height: 214))
        #expect(next == NSSize(width: 340, height: 214))
    }

    @Test func aDragOfTheEdgeIsHeldToTheShapeByTheWindowItself() {
        let sizing = CallSizing(store: store())
        let window = panel(NSRect(x: -20000, y: -20000, width: 340, height: 214))
        defer { window.close() }
        sizing.attach(window)
        sizing.heard(16.0 / 9.0)

        let asked = sizing.windowWillResize(window, to: NSSize(width: 480, height: 248))
        sizing.detach()

        #expect(asked == NSSize(width: 480, height: 327))
    }
}
