import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)), .serialized)
@MainActor
struct SplitDropPreviewTests {
    @Test(arguments: [TabDrag.Side.left, .right], [1000.0, 480.0])
    func thePreviewedFramesAreTheFramesAfterTheDrop(side: TabDrag.Side, width: Double) async throws {
        try await withStage(width: width) { browser, view, front, carried in
            let bars = width > 2 * PaneStage.narrowest + PaneStage.gutter

            TabDrag.shared.aim(browser: browser, source: carried, target: front, side: side)
            try await settle(view)
            let previewed = view.shownFrames
            let pane = try #require(view.landingPane)
            let placeholder = pane.frame

            if bars {
                #expect(previewed.count == 2)
                #expect(previewed[front.id]?.minY == Metrics.paneBar)
                #expect(pane.barHeight == Metrics.paneBar)
                #expect(pane.veil > 0.05 && pane.veil <= 0.2, "the stand-in is a see-through layer")
                #expect(pane.layer?.backgroundColor == nil)
                let left = try #require(previewed[side == .left ? carried.id : front.id])
                let right = try #require(previewed[side == .left ? front.id : carried.id])
                #expect(left.maxX + PaneStage.gutter == right.minX)
                #expect(abs(left.width - right.width) <= 1)
            } else {
                #expect(previewed.keys.sorted() == [carried.id])
                #expect(pane.barHeight == 0)
            }

            TabDrag.shared.aim(browser: browser, source: carried, target: nil, side: side)
            browser.pair(carried, with: front, onLeft: side == .left)
            try await settle(view)
            let dropped = view.shownFrames
            try await settle(view)

            #expect(dropped == previewed)
            #expect(view.shownFrames == dropped)
            let landed = try #require(dropped[carried.id])
            let bar = bars ? Metrics.paneBar : 0
            #expect(placeholder == CGRect(x: landed.minX, y: landed.minY - bar, width: landed.width, height: landed.height + bar))
        }
    }

    @Test func leavingTheBandGivesThePageItsFrameBack() async throws {
        try await withStage(width: 1000) { browser, view, front, carried in
            try await settle(view)
            let alone = view.shownFrames
            #expect(alone[front.id] == view.bounds)

            TabDrag.shared.aim(browser: browser, source: carried, target: front, side: .right)
            try await settle(view)
            let held = try #require(view.zoneFrame(of: front.id))
            TabDrag.shared.aim(browser: browser, source: carried, target: nil, side: .right)
            try await settle(view)

            #expect(held.width == view.bounds.width)
            #expect(view.shownFrames == alone)
            #expect(browser.splits.isEmpty)
            #expect(view.zoneFrame(of: front.id) == CGRect(origin: .zero, size: view.bounds.size))
        }
    }

    @Test func thePlaceholderHasThePanesCorners() async throws {
        try await withStage(width: 1000) { browser, view, front, carried in
            TabDrag.shared.aim(browser: browser, source: carried, target: front, side: .right)
            try await settle(view)
            let pane = try #require(view.landingPane)
            let previewed = pane.corners

            TabDrag.shared.aim(browser: browser, source: carried, target: nil, side: .right)
            browser.pair(carried, with: front, onLeft: false)
            try await settle(view)

            #expect(previewed == PaneLayersView.Corners(topLeft: 0, topRight: 0, bottomLeft: Metrics.pageRadius, bottomRight: Metrics.pageRadius))
            #expect(view.paneCorners(of: carried.id) == previewed)
            #expect(view.paneCorners(of: front.id) == previewed)
            #expect(pane.corner == Metrics.pageRadius)
        }
    }

    @Test func aDropOnAPaneOfAPairCoversThatPaneAndAddsNoThird() async throws {
        try await withStage(width: 1000) { browser, view, front, carried in
            browser.newTab()
            let partner = try #require(browser.tabs.last)
            partner.restore(url: URL(string: "about:blank#partner")!, title: "Partner")
            browser.pair(partner, with: front, onLeft: false)
            try await settle(view)
            let pair = view.shownFrames

            TabDrag.shared.aim(browser: browser, source: carried, target: partner, side: .centre)
            try await settle(view)
            let pane = try #require(view.landingPane)
            let previewed = view.shownFrames
            TabDrag.shared.aim(browser: browser, source: carried, target: nil, side: .centre)
            browser.replacePage(partner, with: carried)
            try await settle(view)

            #expect(previewed == pair)
            let target = try #require(pair[partner.id])
            #expect(pane.frame == CGRect(x: target.minX, y: target.minY - Metrics.paneBar, width: target.width,
                                         height: target.height + Metrics.paneBar))
            #expect(view.shownFrames[carried.id] == target)
            #expect(view.shownFrames.count == 2)
        }
    }

    private func settle(_ view: SplitStageView) async throws {
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(60))
            view.layoutSubtreeIfNeeded()
        }
    }

    private func withStage(width: Double, _ body: (Browser, SplitStageView, Tab, Tab) async throws -> Void) async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = prefs.splitView
        prefs.splitView = true
        browser.newTab()
        let front = try #require(browser.tabs.last)
        front.restore(url: URL(string: "about:blank#front")!, title: "Front")
        browser.newTab()
        let carried = try #require(browser.tabs.last)
        carried.restore(url: URL(string: "about:blank#carried")!, title: "Carried")
        browser.select(front)
        let view = SplitStageView(browser: browser)
        view.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: width, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        view.update(find: browser.findState, corner: Metrics.pageRadius, immersed: nil, hold: nil, card: nil)
        defer {
            TabDrag.shared.aim(browser: browser, source: carried, target: nil, side: .centre)
            view.returnBorrowedPages()
            browser.closeAll()
            window.close()
            prefs.splitView = saved
        }
        try await settle(view)
        try await body(browser, view, front, carried)
    }
}
