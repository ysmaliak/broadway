import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PaneCornersTests {
    @Test func everyPaneCardIsRoundButWhereItsHostsClipRoundsIt() throws {
        _ = NSApplication.shared
        let left = Tab(bench: true)
        let right = Tab(bench: true)
        let stage = PaneStage(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        stage.corner = Metrics.pageRadius
        let window = makeWindow(stage)
        defer { window.close() }

        stage.show([left, right], split: TabSplit(left: left.id, right: right.id), focused: left.id)
        stage.layoutSubtreeIfNeeded()

        let frame = try #require(stage.subviews.compactMap { $0 as? PageFrame }.first?.layer)
        #expect(frame.mask == nil)
        #expect(!frame.masksToBounds)
        let slots = stage.subviews.compactMap { $0 as? PageFrame }.first?.subviews.compactMap { $0 as? StageView }.filter { !$0.isHidden } ?? []
        #expect(slots.count == 2)
        for slot in slots {
            let layer = try #require(slot.layer)
            #expect(layer.cornerRadius == Metrics.pageRadius)
            #expect(layer.cornerCurve == .continuous)
            #expect(layer.masksToBounds)
            #expect(layer.maskedCorners == PaneStage.bottoms(flipped: layer.contentsAreFlipped()))
        }
        let columns = (frame.sublayers ?? []).filter { !$0.isHidden && $0.shadowPath != nil && $0.delegate == nil }
        #expect(columns.count == 2)
        for column in columns {
            #expect(column.cornerRadius == Metrics.pageRadius)
            #expect(column.cornerCurve == .continuous)
            #expect(column.bounds.height == 600)
            let path = try #require(column.shadowPath)
            expectRound(path, in: column.bounds)
        }
        let cues = stage.rims.subviews.compactMap { $0 as? FocusCue }
        #expect(cues.count == 2)
        for (index, cue) in cues.enumerated() {
            #expect(cue.frame.minY == 0)
            #expect(cue.frame.height == 600)
            let line = cue.line
            let shape = CardRim.shape(cue.card ?? cue.bounds, in: cue.bounds, cut: cue.cut, corner: cue.corner, line: line)
            let near: CGFloat = 1
            let outside = index == 0 ? cue.bounds.minX + near : cue.bounds.maxX - near
            let gutter = index == 0 ? cue.bounds.maxX - near : cue.bounds.minX + near
            for y in [cue.bounds.minY + near, cue.bounds.maxY - near] {
                #expect(shape.outer.contains(CGPoint(x: outside, y: y)))
                #expect(!shape.outer.contains(CGPoint(x: gutter, y: y)))
            }
            expectRound(shape.inner, in: cue.bounds.insetBy(dx: line, dy: line))
        }
    }

    @Test func aSinglePageLeavesItsCornersToTheFrameItPassesThrough() throws {
        _ = NSApplication.shared
        let tab = Tab(bench: true)
        let stage = PaneStage(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        stage.corner = Metrics.pageRadius
        let window = makeWindow(stage)
        defer { window.close() }

        stage.show([tab], split: nil, focused: tab.id)
        stage.layoutSubtreeIfNeeded()

        let frame = try #require(stage.subviews.compactMap { $0 as? PageFrame }.first?.layer)
        #expect(frame.cornerRadius == 0)
        #expect(frame.masksToBounds)
        #expect(stage.framed)
        let slot = try #require(stage.subviews.compactMap { $0 as? PageFrame }.first?.subviews.compactMap { $0 as? StageView }.first)
        #expect(slot.layer?.cornerRadius == 0)
    }

    private func expectRound(_ path: CGPath, in rect: CGRect) {
        let near: CGFloat = 1
        for corner in [CGPoint(x: rect.minX + near, y: rect.minY + near), CGPoint(x: rect.maxX - near, y: rect.minY + near),
                       CGPoint(x: rect.minX + near, y: rect.maxY - near), CGPoint(x: rect.maxX - near, y: rect.maxY - near)] {
            #expect(!path.contains(corner))
        }
        #expect(path.contains(CGPoint(x: rect.midX, y: rect.minY + near)))
        #expect(path.contains(CGPoint(x: rect.minX + near, y: rect.midY)))
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
