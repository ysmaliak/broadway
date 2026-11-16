import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct RingViewTests {
    private func placed() -> (NSWindow, RingView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: true)
        let ring = RingView(frame: NSRect(x: 10, y: 10, width: 11, height: 11))
        window.contentView?.addSubview(ring)
        return (window, ring)
    }

    private func turning(_ ring: RingView) -> Bool {
        ring.layer?.sublayers?.first?.animation(forKey: "turn") != nil
    }

    @Test func aRingShownAfterBeingHiddenSpins() {
        let (window, ring) = placed()
        ring.show(false, animated: false)

        ring.show(true, animated: true)

        #expect(!ring.isHidden)
        #expect(turning(ring))
        withExtendedLifetime(window) {}
    }

    @Test func aHiddenRingHasNoTurn() {
        let (window, ring) = placed()
        #expect(turning(ring))

        ring.show(false, animated: false)

        #expect(ring.isHidden)
        #expect(!turning(ring))
        withExtendedLifetime(window) {}
    }

    @Test func aRingHiddenByHandSpinsAgainWhenShown() {
        let (window, ring) = placed()
        ring.isHidden = true
        #expect(!turning(ring))

        ring.isHidden = false

        #expect(turning(ring))
        withExtendedLifetime(window) {}
    }

    @Test func aRingInAParkedRowStopsAndSpinsWhenTheRowReturns() {
        let (window, ring) = placed()
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        window.contentView?.addSubview(row)
        row.addSubview(ring)

        row.isHidden = true
        let parked = turning(ring)
        row.isHidden = false

        #expect(!parked)
        #expect(turning(ring))
        withExtendedLifetime(window) {}
    }

    @Test func aRingLeavingFadesBeforeItHides() {
        let (window, ring) = placed()
        let motion = Motion.kitQuick.animates

        ring.show(false, animated: true)

        if motion {
            #expect(!ring.isHidden)
            #expect(turning(ring))
            #expect(ring.layer?.sublayers?.first?.animation(forKey: "leave") != nil)
        } else {
            #expect(ring.isHidden)
        }
        withExtendedLifetime(window) {}
    }
}
