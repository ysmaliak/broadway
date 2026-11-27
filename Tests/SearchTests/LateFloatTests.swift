import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct LateFloatTests {
    private func stage() -> (NSWindow, StageView, NSView, NSView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let stage = StageView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(stage)
        let page = NSView(), other = NSView()
        stage.show(page, space: nil)
        stage.wait(page)
        stage.show(other, space: nil)
        return (window, stage, page, other)
    }

    @Test func aLeftPageWaitingForItsVideoStaysInTheWindowUnseen() {
        let (window, stage, page, other) = stage()

        stage.layoutSubtreeIfNeeded()

        #expect(page.superview === stage)
        #expect(page.window === window)
        #expect(page.alphaValue == 0)
        #expect(other.alphaValue == 1)
        window.close()
    }

    @Test func aPageNoLongerWaitingLeavesTheWindow() {
        let (window, stage, page, other) = stage()

        stage.stopWaiting(page)

        #expect(page.superview == nil)
        #expect(other.superview === stage)
        window.close()
    }

    @Test func aWaitingPageShownAgainIsSeenAndStaysWhenTheWaitEnds() {
        let (window, stage, page, other) = stage()

        stage.show(page, space: nil)
        stage.stopWaiting(page)
        stage.layoutSubtreeIfNeeded()

        #expect(page.superview === stage)
        #expect(page.alphaValue == 1)
        #expect(stage.subviews.last === page)
        #expect(other.superview == nil)
        window.close()
    }

    @Test func twoWaitingPagesPutTheOneShownAgainInFront() {
        let (window, stage, page, other) = stage()
        stage.wait(other)

        stage.show(page, space: nil)
        stage.layoutSubtreeIfNeeded()

        #expect(page.alphaValue == 1)
        #expect(other.alphaValue == 0)
        #expect(stage.subviews.last === page)
        window.close()
    }

    @Test func aWaitThatEndsBeforeTheTabIsLeftChangesNothing() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let stage = StageView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(stage)
        let page = NSView()
        stage.show(page, space: nil)

        stage.wait(page)
        stage.stopWaiting(page)
        stage.layoutSubtreeIfNeeded()

        #expect(page.superview === stage)
        #expect(page.alphaValue == 1)
        window.close()
    }

    @Test func thePageOnShowIsNeverHiddenByItsWait() {
        let (window, stage, _, other) = stage()

        stage.wait(other)
        stage.layoutSubtreeIfNeeded()

        #expect(other.alphaValue == 1)
        window.close()
    }

    @Test func aVideoToldToPlayWithSoundAndNoPictureYetIsStarting() {
        let starting: [[String: Any]] = [["paused": false, "ended": false, "muted": false, "volume": 0.01, "ready": 0]]
        let metadataOnly: [[String: Any]] = [["paused": false, "ended": false, "muted": false, "volume": 1, "ready": 1]]

        #expect(FloatFind.starting(starting))
        #expect(FloatFind.starting(metadataOnly))
    }

    @Test func aMutedPausedEndedOrPlayingVideoIsNotStarting() {
        func video(paused: Bool = false, ended: Bool = false, muted: Bool = false, volume: Double = 1, ready: Int = 0) -> [[String: Any]] {
            [["paused": paused, "ended": ended, "muted": muted, "volume": volume, "ready": ready]]
        }

        #expect(!FloatFind.starting(video(muted: true)))
        #expect(!FloatFind.starting(video(volume: 0)))
        #expect(!FloatFind.starting(video(paused: true)))
        #expect(!FloatFind.starting(video(ended: true)))
        #expect(!FloatFind.starting(video(ready: 4)))
        #expect(!FloatFind.starting([[String: Any]]()))
        #expect(!FloatFind.starting(nil))
        #expect(!FloatFind.starting("loading"))
    }

    @Test func aMissedFloatSaysHowLongItHasLeft() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let miss = FloatMiss(tab: UUID(), quietly: true, now: start)

        #expect(miss.left(now: start.addingTimeInterval(3)) == FloatMiss.lasts - 3)
        #expect(miss.left(now: start.addingTimeInterval(FloatMiss.lasts + 2)) == 0)
    }
}
