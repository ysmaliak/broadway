import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SpaceStageTests {
    @Test func spaceHandoffDoesNotAddASecondPageFade() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let stage = StageView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(stage)
        let first = NSView(), second = NSView()
        stage.show(first, space: UUID())
        stage.layer?.removeAllAnimations()

        stage.show(second, space: UUID())
        stage.layoutSubtreeIfNeeded()

        #expect(stage.layer?.animation(forKey: "page") == nil)
        #expect(second.superview === stage)
        #expect(first.superview == nil)
        window.close()
    }

    private func borrowedPage() -> (NSWindow, StageView, StageView, NSView, NSView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let source = StageView(frame: window.contentView!.bounds)
        let preview = StageView(frame: NSRect(x: 0, y: 0, width: 340, height: 260))
        window.contentView?.addSubview(source)
        window.contentView?.addSubview(preview)
        let page = NSView(), other = NSView()
        source.show(page, space: UUID())
        source.keep(page)
        source.show(other, space: UUID())
        preview.borrowing = true
        preview.show(page, space: UUID())
        return (window, source, preview, page, other)
    }

    @Test func cancelledPreviewReturnsItsRetainedPageToItsOriginalWindow() {
        let (window, source, preview, page, other) = borrowedPage()
        #expect(page.superview === preview)
        #expect(page.alphaValue == 1)

        preview.returnBorrowedPages()

        #expect(page.superview === source)
        #expect(page.window === window)
        #expect(other.superview === source)
        #expect(page.alphaValue == 0)
        #expect(page.frame == source.bounds)
        window.close()
    }

    @Test func committedPreviewLeavesItsPageInTheDestinationStage() {
        let (window, source, preview, page, _) = borrowedPage()

        source.show(page, space: UUID())
        preview.returnBorrowedPages()

        #expect(page.superview === source)
        #expect(page.window === window)
        #expect(page.alphaValue == 1)
        window.close()
    }

    @Test func singlePagePreviewReturnsItsPageWhenItLeavesTheWindow() async {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let previousSplit = browser.prefs.splitView
        browser.prefs.splitView = false
        defer { browser.prefs.splitView = previousSplit; browser.closeAll() }
        let tab = Search.Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.restore(url: URL(string: "http://127.0.0.1:9/preview")!, title: "Local preview")
        tab.wake()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let source = StageView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(source)
        source.show(tab.web, space: UUID())
        source.keep(tab.web)
        source.show(NSView(), space: UUID())
        let preview = SpaceStagePreviewView(browser: browser, row: Parked(tabs: [tab], active: tab.id), space: UUID(), corner: 0)
        preview.frame = window.contentView!.bounds
        window.contentView?.addSubview(preview)
        preview.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!(tab.web.superview === source))

        preview.removeFromSuperview()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(tab.web.superview === source)
        #expect(tab.web.window === window)
        #expect(tab.web.alphaValue == 0)
        window.close()
    }

    @Test func calmPoliciesCanBeProbedWithoutChangingTheMac() {
        let store = Store.settings
        let reduced = store.object(forKey: "motion.testReduced")
        defer { store.set(reduced, forKey: "motion.testReduced") }
        store.set(false, forKey: "motion.testReduced")

        let movingIsCalm = Motion.calm
        store.set(true, forKey: "motion.testReduced")

        #expect(!movingIsCalm)
        #expect(Motion.calm)
        #expect(Motion.pageChange == nil)
        #expect(Motion.reduced)
        #expect(Motion.kitSettle == .none)
        #expect(Motion.kitGlide == .none)
    }

    @Test func reducedSpaceCarryLandsWithoutStartingATimer() {
        let store = Store.settings
        let saved = store.object(forKey: "motion.testReduced")
        defer { store.set(saved, forKey: "motion.testReduced") }
        store.set(true, forKey: "motion.testReduced")
        let motion = SpaceMotion()
        motion.follow(-30, width: 240)
        var landed = false

        motion.carry(to: -240, width: 240) { landed = true }

        #expect(landed)
        #expect(motion.offset == -240)
        #expect(!motion.moving)
    }
}
