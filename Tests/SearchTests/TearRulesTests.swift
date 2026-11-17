import AppKit
import Testing
@testable import Search

@Suite
struct TearRulesTests {
    let window = NSRect(x: 100, y: 100, width: 800, height: 600)
    let screen = TearRules.Screen(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                  visible: NSRect(x: 0, y: 0, width: 1440, height: 875))

    @Test func aPointTwelvePointsPastTheEdgeIsStillTheWindows() {
        #expect(!TearRules.beyond(NSPoint(x: 88, y: 300), window))
        #expect(!TearRules.beyond(NSPoint(x: 911, y: 300), window))
        #expect(!TearRules.beyond(NSPoint(x: 400, y: 711), window))
    }

    @Test func aPointMoreThanTwelvePointsPastTheEdgeIsOutside() {
        #expect(TearRules.beyond(NSPoint(x: 87, y: 300), window))
        #expect(TearRules.beyond(NSPoint(x: 912, y: 300), window), "the far edges are half open, as dragOut always had them")
        #expect(TearRules.beyond(NSPoint(x: 400, y: 87), window))
        #expect(TearRules.beyond(NSPoint(x: 400, y: 712), window))
    }

    @Test func aTabGoesOutsideOnlyPastTwelvePoints() {
        var state = TearRules.State()
        state = TearRules.step(state, point: NSPoint(x: 90, y: 300), moved: .zero, window: window, screen: screen)
        #expect(!state.out)
        state = TearRules.step(state, point: NSPoint(x: 80, y: 300), moved: .zero, window: window, screen: screen)
        #expect(state.out)
    }

    @Test func anOutsideTabComesBackOnlyAtTheWindowsOwnEdge() {
        var state = TearRules.State(out: true)
        state = TearRules.step(state, point: NSPoint(x: 95, y: 300), moved: .zero, window: window, screen: screen)
        #expect(state.out, "inside the twelve points but not the frame")
        state = TearRules.step(state, point: NSPoint(x: 100, y: 300), moved: .zero, window: window, screen: screen)
        #expect(!state.out, "the edge itself is inside")
    }

    @Test func aWindowThatFillsItsScreenLetsATabOutAfterTwelvePointsPushedAtTheEdge() {
        let full = screen.visible
        var state = TearRules.State()
        state = TearRules.step(state, from: NSPoint(x: 6, y: 400), point: NSPoint(x: 0, y: 400), moved: CGVector(dx: -10, dy: 0),
                               window: full, screen: screen)
        #expect(state.pushed == 5)
        #expect(!state.out)
        state = TearRules.step(state, from: NSPoint(x: 0, y: 400), point: NSPoint(x: 0, y: 400), moved: CGVector(dx: -6, dy: 0),
                               window: full, screen: screen)
        #expect(!state.out)
        state = TearRules.step(state, from: NSPoint(x: 0, y: 400), point: NSPoint(x: 0, y: 400), moved: CGVector(dx: -1, dy: 0),
                               window: full, screen: screen)
        #expect(state.out)
    }

    @Test func thePushCountsAtEachOfTheFourScreenEdgesWithinAPoint() {
        let frame = screen.frame
        #expect(TearRules.outward(from: NSPoint(x: 1, y: 400), to: NSPoint(x: 1, y: 400), moved: CGVector(dx: -5, dy: 0), screen: frame) == 5)
        #expect(TearRules.outward(from: NSPoint(x: 1439, y: 400), to: NSPoint(x: 1439, y: 400), moved: CGVector(dx: 5, dy: 0), screen: frame) == 5)
        #expect(TearRules.outward(from: NSPoint(x: 700, y: 1), to: NSPoint(x: 700, y: 1), moved: CGVector(dx: 0, dy: -5), screen: frame) == 5)
        #expect(TearRules.outward(from: NSPoint(x: 700, y: 900), to: NSPoint(x: 700, y: 900), moved: CGVector(dx: 0, dy: 5), screen: frame) == 5)
        #expect(TearRules.outward(from: NSPoint(x: 700, y: 400), to: NSPoint(x: 700, y: 400), moved: CGVector(dx: -5, dy: 0), screen: frame) == nil)
    }

    @Test func aTabPushedOutAtTheScreenEdgeAimsAtNoOtherWindow() {
        #expect(!TearRules.aims(NSPoint(x: 0, y: 400), leaving: screen.visible))
        #expect(TearRules.aims(NSPoint(x: 80, y: 300), leaving: window))
    }

    @Test func movingAlongTheScreenEdgeIsNotPushingOutward() {
        var state = TearRules.State()
        for _ in 0..<10 {
            state = TearRules.step(state, from: NSPoint(x: 0, y: 400), point: NSPoint(x: 0, y: 400), moved: CGVector(dx: 0, dy: 8),
                                   window: screen.visible, screen: screen)
        }
        #expect(!state.out)
        #expect(state.pushed == 0)
    }

    @Test func leavingTheScreenEdgeInwardBringsTheTabBack() {
        var state = TearRules.State(out: true, pushed: 20)
        state = TearRules.step(state, from: NSPoint(x: 0, y: 400), point: NSPoint(x: 30, y: 400), moved: CGVector(dx: 30, dy: 0),
                               window: screen.visible, screen: screen)
        #expect(!state.out)
        #expect(state.pushed == 0)
    }

    @Test func theEdgePushIsOnlyForAWindowThatFillsItsScreen() {
        var state = TearRules.State()
        let small = NSRect(x: 0, y: 100, width: 800, height: 600)
        state = TearRules.step(state, from: NSPoint(x: 0, y: 400), point: NSPoint(x: 0, y: 400), moved: CGVector(dx: -30, dy: 0),
                               window: small, screen: screen)
        #expect(!state.out)
        #expect(state.pushed == 0)
    }

    @Test func aWindowCoveringTheVisibleFrameFillsItsScreen() {
        #expect(TearRules.fills(screen.visible, screen.visible))
        #expect(TearRules.fills(screen.frame, screen.visible))
        #expect(!TearRules.fills(window, screen.visible))
    }

    @Test func pinsBenchTabsLiveFolderRowsAndAgentTabsNeverLeave() {
        #expect(TearRules.mayLeave(TearRules.Facts()))
        #expect(!TearRules.mayLeave(TearRules.Facts(pin: true)))
        #expect(!TearRules.mayLeave(TearRules.Facts(bench: true)))
        #expect(!TearRules.mayLeave(TearRules.Facts(live: true)))
        #expect(!TearRules.mayLeave(TearRules.Facts(agent: true)))
    }

    @Test func aPrivateTabGoesOnlyToAPrivateWindowAndAnOrdinaryOneNeverDoes() {
        #expect(TearRules.takes(sourcePrivate: false, targetPrivate: false, targetPopup: false))
        #expect(TearRules.takes(sourcePrivate: true, targetPrivate: true, targetPopup: false))
        #expect(!TearRules.takes(sourcePrivate: true, targetPrivate: false, targetPopup: false))
        #expect(!TearRules.takes(sourcePrivate: false, targetPrivate: true, targetPopup: false))
        #expect(!TearRules.takes(sourcePrivate: false, targetPrivate: false, targetPopup: true))
    }

    @Test func theNewWindowPutsItsRowUnderTheHandAsBefore() {
        let frame = TearRules.newWindow(at: NSPoint(x: 600, y: 700), leaving: NSSize(width: 900, height: 500), zoomed: false, visible: nil)
        #expect(frame == NSRect(x: 480, y: 220, width: 900, height: 500))
    }

    @Test func theNewWindowIsMovedOnlyAsFarAsTheScreenNeeds() {
        let visible = screen.visible
        let right = TearRules.newWindow(at: NSPoint(x: 1400, y: 700), leaving: NSSize(width: 900, height: 500), zoomed: false, visible: visible)
        #expect(right == NSRect(x: 540, y: 220, width: 900, height: 500))
        let low = TearRules.newWindow(at: NSPoint(x: 600, y: 100), leaving: NSSize(width: 900, height: 500), zoomed: false, visible: visible)
        #expect(low == NSRect(x: 480, y: 0, width: 900, height: 500))
        let high = TearRules.newWindow(at: NSPoint(x: 600, y: 890), leaving: NSSize(width: 900, height: 500), zoomed: false, visible: visible)
        #expect(high == NSRect(x: 480, y: 375, width: 900, height: 500))
        let left = TearRules.newWindow(at: NSPoint(x: 20, y: 700), leaving: NSSize(width: 900, height: 500), zoomed: false, visible: visible)
        #expect(left == NSRect(x: 0, y: 220, width: 900, height: 500))
    }

    @Test func aWindowLargerThanTheScreenKeepsItsTopLeftOnIt() {
        let frame = TearRules.clamp(NSRect(x: 300, y: -400, width: 2000, height: 1200), into: screen.visible)
        #expect(frame.minX == 0)
        #expect(frame.maxY == screen.visible.maxY)
    }

    @Test func aZoomedWindowsTabTakesANewWindowsSize() {
        let frame = TearRules.newWindow(at: NSPoint(x: 600, y: 800), leaving: screen.visible.size, zoomed: true, visible: screen.visible)
        #expect(frame.size == TearRules.newWindowSize)
        #expect(screen.visible.contains(frame))
    }

    @Test func withNoScreenUnderTheHandTheNewWindowIsNotMoved() {
        let frame = TearRules.newWindow(at: NSPoint(x: -20_000, y: -20_000), leaving: NSSize(width: 900, height: 500), zoomed: false, visible: nil)
        #expect(frame.origin == NSPoint(x: -20_120, y: -20_480))
    }
}
