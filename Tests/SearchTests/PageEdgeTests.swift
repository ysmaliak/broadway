import AppKit
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PageEdgeTests {
    @Test func aPageClipsToItsOwnFrame() {
        _ = NSApplication.shared

        let page = PageView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())

        #expect(page.clipsToBounds)
    }

    @Test func aPairArrivesWithItsHairlinesAndFocusRingAlreadyOn() throws {
        _ = NSApplication.shared
        let left = Tab(bench: true)
        let right = Tab(bench: true)
        let stage = PaneStage(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        stage.corner = Metrics.pageRadius
        let window = makeWindow(stage)
        defer { window.close() }
        stage.show([left], split: nil, focused: left.id)
        stage.layoutSubtreeIfNeeded()

        stage.show([left, right], split: TabSplit(left: left.id, right: right.id), focused: right.id)
        stage.layoutSubtreeIfNeeded()

        let slots = stage.subviews.compactMap { $0 as? PageFrame }.first?.subviews.compactMap { $0 as? StageView }.filter { !$0.isHidden } ?? []
        #expect(slots.count == 2)
        #expect(stage.edgeWidth > 0)
        for slot in slots {
            let layer = try #require(slot.layer)
            #expect(layer.borderWidth == 0)
        }
        let cues = stage.rims.subviews.compactMap { $0 as? FocusCue }
        #expect(cues.map(\.alphaValue).sorted() == [0, 1])
        #expect(cues.allSatisfy { ($0.layer?.animationKeys() ?? []).isEmpty })
        let edges = stage.rims.subviews.compactMap { $0 as? PaneEdge }
        #expect(edges.map(\.alphaValue) == cues.map { 1 - $0.alphaValue })
        #expect(edges.allSatisfy { $0.line == stage.edgeWidth && ($0.layer?.animationKeys() ?? []).isEmpty })
    }

    @Test func aRestingNeighbourLeftOfTheCardEndsOnAWholePixelBeforeIt() {
        let edge: CGFloat = 278.26953125

        let shift = StagePicturesView.clearing(edge: edge, lane: -1, scale: 2)

        #expect(shift < 0)
        #expect(edge + shift == 278)
    }

    @Test func aRestingNeighbourRightOfTheCardStartsOnAWholePixelAfterIt() {
        let edge: CGFloat = 1274.3

        let shift = StagePicturesView.clearing(edge: edge, lane: 1, scale: 2)

        #expect(shift > 0)
        #expect(abs(edge + shift - 1274.5) < 0.0001)
    }

    @Test func aNeighbourAlreadyOnAPixelEdgeOrTheCardItselfStays() {
        #expect(StagePicturesView.clearing(edge: 278.5, lane: -1, scale: 2) == 0)
        #expect(StagePicturesView.clearing(edge: 278.27, lane: 0, scale: 2) == 0)
    }

    private func makeWindow(_ stage: PaneStage) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: stage.frame.width, height: stage.frame.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = stage
        window.orderFrontRegardless()
        return window
    }
}
