import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class EdgeCloseTests {
    private var browser: Browser!

    init() {
        keepSetting(Shared.prefs, \.sideWidth, "sidebar.width")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.prefs.sideWidth = 260
    }

    private func tearDown() {
        if browser.folded { browser.toggleFold() }
        browser.closeAll()
        browser = nil
    }

    private func grip(canClose: Bool = true) -> (ColumnEdgeGrip, () -> [CGFloat]) {
        let grip = ColumnEdgeGrip()
        grip.prefs = browser.prefs
        grip.canClose = { canClose }
        var closed: [CGFloat] = []
        grip.onClose = { closed.append($0) }
        return (grip, { closed })
    }

    @Test func draggingInsideTheNarrowestWidthStillStopsThere() {
        let line = Metrics.sideMin - ColumnEdgeGrip.closeZone

        let step = ColumnEdgeGrip.step(from: 260, pulled: line - 260 + 1, canClose: true)

        #expect(step.width == Metrics.sideMin)
        #expect(!step.closes)
    }

    @Test func pastTheLineTheColumnFollowsAtHalfStrength() {
        let line = Metrics.sideMin - ColumnEdgeGrip.closeZone

        let step = ColumnEdgeGrip.step(from: 260, pulled: line - 260 - 40, canClose: true)

        #expect(step.width == Metrics.sideMin - 20)
        #expect(step.closes)
    }

    @Test func farPastTheLineTheColumnStopsShrinking() {
        let grabbed: CGFloat = 260

        let step = ColumnEdgeGrip.step(from: grabbed, pulled: -2000, canClose: true)

        #expect(step.width == ColumnEdgeGrip.closeFloor)
        #expect(step.closes)
    }

    @Test func aColumnThatCannotCloseClampsAsBefore() {
        let grabbed: CGFloat = 260

        let step = ColumnEdgeGrip.step(from: grabbed, pulled: -400, canClose: false)

        #expect(step.width == Metrics.sideMin)
        #expect(!step.closes)
    }

    @Test func lettingGoPastTheLineClosesWithTheWidthFromBeforeTheDrag() {
        let (grip, closed) = grip()
        grip.begin(at: NSPoint(x: 500, y: 0))

        grip.pull(to: NSPoint(x: 500 - 200, y: 0))
        let shown = browser.prefs.sideWidth
        grip.letGo()

        #expect(shown < Metrics.sideMin)
        #expect(closed() == [260])
    }

    @Test func comingBackOutBeforeLettingGoCancels() {
        let (grip, closed) = grip()
        grip.begin(at: NSPoint(x: 500, y: 0))
        grip.pull(to: NSPoint(x: 500 - 200, y: 0))

        grip.pull(to: NSPoint(x: 500 - 100, y: 0))
        grip.letGo()

        #expect(closed().isEmpty)
        #expect(browser.prefs.sideWidth == Metrics.sideMin)
    }

    @Test func onTheRightTheDragRunsTheOtherWay() {
        let (grip, closed) = grip()
        grip.onRight = true
        grip.begin(at: NSPoint(x: 500, y: 0))

        grip.pull(to: NSPoint(x: 500 + 200, y: 0))
        grip.letGo()

        #expect(closed() == [260])
    }

    @Test func closingFromTheEdgeHidesTheColumnAndKeepsItsWidth() async {
        #expect(!browser.folded)
        browser.prefs.sideWidth = 170

        browser.closeColumnFromEdge(restoring: 260)
        for _ in 0..<40 where browser.prefs.sideWidth != 260 {
            try? await Task.sleep(for: .milliseconds(50))
        }

        #expect(browser.folded)
        #expect(browser.prefs.sideWidth == 260)
    }
}
