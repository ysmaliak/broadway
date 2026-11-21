import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct HoverFollowsPointerTests {
    private func row(followsPointer: Bool) -> (NSWindow, KitHoverView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: true)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = host
        let row = KitHoverView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        row.followsPointer = followsPointer
        host.addSubview(row)
        return (window, row)
    }

    @Test func aLateEnterForARowThePointerHasLeftLeavesItQuiet() {
        let (window, row) = row(followsPointer: true)
        defer { KitHoverView.pointerStandIn = nil }
        KitHoverView.pointerStandIn = (window, NSPoint(x: 100, y: 80))
        row.mouseEntered(with: NSEvent())
        #expect(!row.hovering)
        KitHoverView.pointerStandIn = (window, NSPoint(x: 100, y: 15))
        row.mouseEntered(with: NSEvent())
        #expect(row.hovering)
    }

    @Test func aLateExitForARowThePointerIsBackOnKeepsItsHover() {
        let (window, row) = row(followsPointer: true)
        defer { KitHoverView.pointerStandIn = nil }
        KitHoverView.pointerStandIn = (window, NSPoint(x: 100, y: 15))
        row.settleHover()
        row.mouseExited(with: NSEvent())
        #expect(row.hovering)
        KitHoverView.pointerStandIn = (window, NSPoint(x: 100, y: 80))
        row.mouseExited(with: NSEvent())
        #expect(!row.hovering)
    }

    @Test func aViewThatDoesNotFollowThePointerTakesTheEventAsItCame() {
        let (window, row) = row(followsPointer: false)
        defer { KitHoverView.pointerStandIn = nil }
        KitHoverView.pointerStandIn = (window, NSPoint(x: 100, y: 80))
        row.mouseEntered(with: NSEvent())
        #expect(row.hovering)
        row.mouseExited(with: NSEvent())
        #expect(!row.hovering)
    }
}
