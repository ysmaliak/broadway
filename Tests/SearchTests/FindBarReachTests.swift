import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FindBarReachTests {
    private func bar() -> (FindBarView, NSWindow, Browser) {
        let browser = Browser(record: WindowRecord())
        browser.needle = "orchid"
        let bar = FindBarView(browser: browser)
        let size = bar.intrinsicContentSize
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let stage = KitFlippedView(frame: NSRect(origin: .zero, size: size))
        window.contentView = stage
        bar.frame = stage.bounds
        stage.addSubview(bar)
        bar.layoutSubtreeIfNeeded()
        return (bar, window, browser)
    }

    @Test func aClickAboveOrBelowTheTextLineLandsOnTheField() {
        let (bar, window, browser) = bar()
        defer {
            window.close()
            browser.closeAll()
        }
        let field = bar.field.frame

        let above = bar.hitTest(NSPoint(x: field.midX, y: 3))
        let below = bar.hitTest(NSPoint(x: field.midX, y: bar.bounds.height - 3))

        #expect(field.height < 24)
        #expect(above.map { $0 === bar.field || $0.isDescendant(of: bar.field) } ?? false)
        #expect(below.map { $0 === bar.field || $0.isDescendant(of: bar.field) } ?? false)
    }

    @Test func aClickOnAKeyStillLandsOnTheKey() {
        let (bar, window, browser) = bar()
        defer {
            window.close()
            browser.closeAll()
        }
        let close = bar.kitSubviews(of: KitButton.self).first { $0.accessibilityLabel() == "Close Find on Page" }
        let middle = close.map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: bar) } ?? .zero

        let hit = bar.hitTest(middle)

        #expect(close != nil)
        #expect(hit.map { view in close.map { view === $0 || view.isDescendant(of: $0) } ?? false } ?? false)
    }
}
