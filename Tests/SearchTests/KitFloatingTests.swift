import AppKit
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct KitFloatingTests {
    private func panel() -> NSPanel {
        _ = NSApplication.shared
        return NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 100),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    }

    @Test func aFloatingPanelStaysOnEverySpaceAboveOrdinaryWindowsWhenTheAppIsInactive() {
        let made = panel()
        made.kitFloat(shadow: true)

        #expect(made.level == KeepOnTop.panelLevel)
        #expect(made.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary])
        #expect(made.backgroundColor == .clear)
        #expect(!made.isOpaque)
        #expect(made.hasShadow)
        #expect(!made.isReleasedWhenClosed)
        #expect(!made.hidesOnDeactivate)
        #expect(!made.canHide)
    }

    @Test func onlyAFloatingPanelThatHidesWithTheAppGoesWhenBroadwayIsHidden() {
        let made = panel()
        made.kitFloat(shadow: false, hidesWithApp: true)

        #expect(made.canHide)
        #expect(!made.hasShadow)
        #expect(!made.hidesOnDeactivate)
    }

    @Test func theVideoTheCallAndTheMeetingAlertDifferOnlyInShadowAndHiding() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try ["Float", "CallFloat", "MeetingAlerts"].map {
            try String(contentsOf: root.appendingPathComponent("Sources/Search/\($0).swift"), encoding: .utf8)
        }.joined()

        #expect(source.components(separatedBy: ".kitFloat(").count == 4)
        #expect(!source.contains("panel.hidesOnDeactivate"))
        #expect(!source.contains("panel.canHide"))
    }

    @Test func aKeptFrameCountsAsShownOnlyWhileMostOfItIsOnAScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = NSRect(x: 0, y: 0, width: 400, height: 200)

        #expect(KitKeptFrame.shown(frame, on: [screen]))
        #expect(KitKeptFrame.shown(frame.offsetBy(dx: 1000 - 400 * 0.7, dy: 0), on: [screen]))
        #expect(!KitKeptFrame.shown(frame.offsetBy(dx: 1000 - 400 * 0.5, dy: 0), on: [screen]))
        #expect(!KitKeptFrame.shown(frame.offsetBy(dx: 5000, dy: 0), on: [screen]))
        #expect(!KitKeptFrame.shown(.zero, on: [screen]))
    }

    @Test func aKeptFrameComesBackAsItWasWrittenWhileAScreenShowsIt() throws {
        let store = try #require(UserDefaults(suiteName: "kit-kept-frame-\(UUID().uuidString)"))
        let kept = KitKeptFrame(key: "spot", store: store)
        #expect(kept.frame == nil)

        let screen = try #require(NSScreen.screens.first?.visibleFrame)
        let frame = NSRect(x: screen.minX + 20, y: screen.minY + 20, width: 300, height: 180)
        kept.keep(frame)

        #expect(store.string(forKey: "spot") == NSStringFromRect(frame))
        #expect(kept.frame == frame)

        kept.keep(frame.offsetBy(dx: -100_000, dy: 0))
        #expect(kept.frame == nil)

        kept.keep(nil)
        #expect(store.object(forKey: "spot") == nil)
    }
}
