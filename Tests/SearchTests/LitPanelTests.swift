import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct LitPanelTests {
    private static let frame = NSRect(x: -20_000, y: -20_000, width: 240, height: 80)
    private static let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]

    private func ask(_ window: NSWindow, _ selector: String) -> Bool {
        let name = NSSelectorFromString(selector)
        typealias Ask = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(window.method(for: name), to: Ask.self)(window, name)
    }

    private func lit(_ window: NSWindow) -> Bool {
        ask(window, "_hasActiveAppearance") && ask(window, "_hasActiveAppearanceIgnoringKeyFocus")
    }

    private func floating() -> [(String, KitLitPanel)] {
        [
            ("floating video", FloatPanel(contentRect: Self.frame, styleMask: Self.style, backing: .buffered, defer: true)),
            ("floating video ghost", KitLitPanel(contentRect: Self.frame, styleMask: Self.style, backing: .buffered, defer: true)),
            ("call window", CallFloat.Panel(contentRect: Self.frame, styleMask: Self.style, backing: .buffered, defer: true)),
            ("meeting alert", MeetingAlertPanel.Lifted(contentRect: Self.frame, styleMask: Self.style, backing: .buffered, defer: true)),
            ("meeting alert that takes keys", MeetingAlertPanel.Keyed(contentRect: Self.frame, styleMask: Self.style, backing: .buffered, defer: true)),
            ("file choice", FileChoice.ChoicePanel(contentRect: Self.frame, styleMask: Self.style, backing: .buffered, defer: true)),
            ("full screen reminder", ReminderPanel()),
            ("recording pill", PillPanel(indicator: RecordingIndicator())),
            ("full screen sidebar", FullScreenSidePanel(browser: Browser(record: WindowRecord()))),
        ]
    }

    @Test func everyFloatingPanelHoldsItsGlassLitWhileItIsNotKey() {
        _ = NSApplication.shared
        for (name, panel) in floating() {
            panel.isReleasedWhenClosed = false
            #expect(!panel.isKeyWindow, "\(name) is key")
            #expect(lit(panel), "\(name) is not lit")
            panel.close()
        }
    }

    @Test func aPanelWithTitleBarButtonsLeavesTheActiveLookToAppKit() {
        _ = NSApplication.shared
        let preview = FileChoice.ChoicePanel(contentRect: Self.frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                                             backing: .buffered, defer: true)
        let window = NSWindow(contentRect: Self.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        for made in [preview, window] as [NSWindow] {
            made.isReleasedWhenClosed = false
            #expect(!made.isKeyWindow && !NSApp.isActive)
            #expect(!lit(made))
            made.close()
        }
        #expect(!preview.heldLit)
    }

    @Test func theTestSwitchTurnsTheHoldOff() {
        _ = NSApplication.shared
        defer { KitLitPanel.benchHold = true }
        KitLitPanel.benchHold = false
        for (name, panel) in floating() {
            panel.isReleasedWhenClosed = false
            #expect(!panel.heldLit, "\(name) still held")
            #expect(!lit(panel), "\(name) still lit")
            panel.close()
        }
        #expect(FloatOutline(frame: Self.frame).state == .followsWindowActiveState)
        KitLitPanel.benchHold = true
        #expect(FloatOutline(frame: Self.frame).state == .active)
    }

    @Test func appKitAsksAShownPanelWithGlass() async throws {
        _ = NSApplication.shared
        let panel = KitLitPanel(contentRect: Self.frame, styleMask: Self.style, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: Self.frame.size))
        panel.contentView = glass
        defer {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        let before = KitLitPanel.asked
        panel.orderFrontRegardless()
        for _ in 0..<4 {
            glass.needsDisplay = true
            panel.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(KitLitPanel.asked > before)
    }

    @Test func aFloatingPanelsGlassHasNoGroundOfOurs() {
        let glass = KitGlass.floating(radius: 20, ground: false)
        let content = KitFlippedView()

        glass.hold(content)

        #expect(glass.ground == nil)
        #expect(glass.contentView === content)
    }
}
