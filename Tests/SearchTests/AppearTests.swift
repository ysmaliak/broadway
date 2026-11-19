import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct LinkShowTests {
    @Test func aLinkShowsAtOnce() {
        var show = LinkShow()

        show.point(at: "https://a.example/", now: 10)

        #expect(show.destination == "https://a.example/")
        #expect(show.leavingAt == nil)
    }

    @Test func leavingALinkKeepsThePillThroughTheGrace() {
        var show = LinkShow()
        show.point(at: "https://a.example/", now: 10)

        show.point(at: nil, now: 11)
        let goneEarly = show.tick(11 + LinkShow.grace / 2)

        #expect(!goneEarly)
        #expect(show.destination == "https://a.example/")

        let gone = show.tick(11 + LinkShow.grace)

        #expect(gone)
        #expect(show.destination == nil)
    }

    @Test func movingLinkToLinkAcrossAGapSwapsTheTextAndNeverHides() {
        var show = LinkShow()
        show.point(at: "https://a.example/", now: 10)
        show.point(at: nil, now: 10.1)

        show.point(at: "https://b.example/", now: 10.2)
        let gone = show.tick(10.1 + LinkShow.grace)

        #expect(!gone)
        #expect(show.destination == "https://b.example/")
        #expect(show.leavingAt == nil)
    }

    @Test func moreEmptyReportsDoNotPushTheGraceBack() {
        var show = LinkShow()
        show.point(at: "https://a.example/", now: 10)
        show.point(at: nil, now: 10)

        show.point(at: nil, now: 10.2)

        #expect(abs((show.leavingAt ?? 0) - (10 + LinkShow.grace)) <= 0.0001)
    }

    @Test func dismissingHidesAtOnce() {
        var show = LinkShow()
        show.point(at: "https://a.example/", now: 10)

        show.dismiss()

        #expect(show.destination == nil)
        #expect(show.leavingAt == nil)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FindBarWidthTests {
    @Test func theCountsSlotIsOneWidthWhateverItSays() {
        let statuses: [String?] = [nil, "1 of 3", "12 of 400", "999+ of 999+", "No matches", "Whole words unavailable"]
        let count = FindCountView()

        let widths = statuses.map { status -> CGFloat in
            count.status = status
            count.layoutSubtreeIfNeeded()
            return count.intrinsicContentSize.width
        }

        #expect(Set(widths).count == 1, "\(widths)")
        #expect(widths[0] >= FindCountView.width)
    }

    @Test func theBarKeepsItsWidthAsTheQueryChanges() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let bar = FindBarView(browser: browser)
        bar.availableWidth = 600

        var widths: [CGFloat] = []
        for query in ["", "a", "appear", "a much longer query than the field could ever show"] {
            browser.needle = query
            bar.shown = FindBarView.Shown(browser)
            bar.layoutSubtreeIfNeeded()
            widths.append(bar.intrinsicContentSize.width)
        }
        bar.availableWidth = 260
        let narrow = bar.intrinsicContentSize.width

        #expect(Set(widths).count == 1, "\(widths)")
        #expect(narrow < widths[0])
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct BarStackTests {
    private final class Block: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 40) }
    }

    private func stage() -> (NSWindow, BarStack) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let stack = BarStack(frame: window.contentView!.bounds)
        window.contentView?.addSubview(stack)
        return (window, stack)
    }

    @Test func anEmptyStackHoldsNothingAndPassesClicksThrough() {
        let (window, stack) = stage()
        defer { window.close() }

        stack.show([])
        stack.layoutSubtreeIfNeeded()

        #expect(stack.subviews.isEmpty)
        #expect(stack.hitTest(NSPoint(x: 200, y: 150)) == nil)
    }

    @Test func barsStackFromTheBottomWithTheirSpacing() {
        let (window, stack) = stage()
        defer { window.close() }
        let lower = Block(), upper = Block()

        stack.show([.init(view: upper, kind: .note), .init(view: lower, kind: .note)])
        stack.layoutSubtreeIfNeeded()

        #expect(lower.frame.maxY == stack.bounds.height - stack.bottom)
        #expect(upper.frame.maxY == lower.frame.minY - stack.spacing)
        #expect(lower.frame.midX == stack.bounds.midX)
        #expect(stack.hitTest(NSPoint(x: 200, y: 150)) == nil)
        let on = stack.convert(NSPoint(x: lower.frame.midX, y: lower.frame.midY), to: nil)
        #expect(stack.hitTest(on) === lower)
    }

    @Test func aBarArrivesAndLeavesAndCanComeBack() async throws {
        let (window, stack) = stage()
        defer { window.close() }
        let bar = Block()
        stack.show([])

        for _ in 0..<2 {
            stack.show([.init(view: bar, kind: .note)])
            try await Task.sleep(for: .milliseconds(400))

            #expect(bar.superview === stack)
            #expect(bar.layer?.opacity == 1)

            stack.show([])
            try await Task.sleep(for: .milliseconds(600))

            #expect(bar.superview == nil)
        }
    }

    @Test func aBarCentresOnItsPaneWhenItFits() {
        let (window, stack) = stage()
        defer { window.close() }
        let bar = Block()

        stack.show([.init(view: bar, kind: .note, pane: CGRect(x: 200, y: 0, width: 200, height: 300))])
        stack.layoutSubtreeIfNeeded()

        #expect(bar.frame.midX == 300)
    }

    @Test func aBarWiderThanItsPaneCentresOnTheWindow() {
        let (window, stack) = stage()
        defer { window.close() }
        let bar = Block()

        stack.show([.init(view: bar, kind: .note, pane: CGRect(x: 280, y: 0, width: 120, height: 300))])
        stack.layoutSubtreeIfNeeded()

        #expect(bar.frame.midX == stack.bounds.midX)
    }
}
