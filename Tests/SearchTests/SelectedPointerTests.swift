import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class SelectedPointerTests {
    private var window: NSWindow?
    private var browser: Browser?
    private var restore: (() -> Void)?

    init() {
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        if let browser { ContentView.forget(browser); browser.closeAll() }
        window?.contentView = nil
        window?.close()
        restore?()
    }

    private let row = CGRect(x: 0, y: 400, width: 200, height: 34)

    @Test func aRowScrolledAboveTheListPointsUp() {
        #expect(SelectedPointer.edge(row: row, offset: 500, floor: 300) == .above)
    }

    @Test func aRowScrolledBelowTheListPointsDown() {
        #expect(SelectedPointer.edge(row: row, offset: 0, floor: 300) == .below)
    }

    @Test func aRowInSightHasNoPointer() {
        #expect(SelectedPointer.edge(row: row, offset: 200, floor: 300) == nil)
    }

    @Test func aRowMostlyInSightHasNoPointer() {
        #expect(SelectedPointer.edge(row: row, offset: 410, floor: 300) == nil)
        #expect(SelectedPointer.edge(row: row, offset: 120, floor: 300) == nil)
    }

    @Test func aTabOutsideTheListHasNoPointer() {
        #expect(SelectedPointer.edge(row: nil, offset: 500, floor: 300) == nil)
    }

    @Test func aDragHidesThePointer() {
        #expect(SelectedPointer.edge(row: row, offset: 500, floor: 300, held: true) == nil)
    }

    @Test func everyRowThePointerShowsForIsOneTheGlideScrollsTo() {
        for offset in stride(from: CGFloat(0), through: 800, by: 7) where SelectedPointer.edge(row: row, offset: offset, floor: 300) != nil {
            #expect(SelectedPointer.target(row: row, offset: offset, floor: 300, fade: ColumnEdges.fade) != nil)
        }
    }

    @Test func theGlideLandsOnItsCurveAndJumpsWithoutOne() {
        #expect(SelectedPointer.share(.none, at: 0) == (1, true))
        let early = SelectedPointer.share(.spring(.roll), at: 0.05)
        #expect(early.share > 0 && early.share < 1 && !early.done)
        #expect(SelectedPointer.share(.spring(.roll), at: 2).done)
    }

    @Test func theCapsuleShowsAboveWhenTheSelectedRowIsScrolledUpAndOut() async throws {
        let (browser, page) = try await scene(selecting: 0)

        try await scroll(page, to: 100_000)

        #expect(page.pointingNow == .above)
        let pointer = try #require(pointer(in: page))
        #expect(!pointer.isHidden)
        #expect(pointer.chevron.name == "chevron.up")
        #expect(pointer.accessibilityLabel() == "Show Selected Tab")
        #expect(pointer.mark.letter == browser.active?.monogram)
    }

    @Test func theCapsuleShowsBelowWhenTheSelectedRowIsScrolledDownAndOut() async throws {
        let (_, page) = try await scene(selecting: 39)

        try await scroll(page, to: 0)

        #expect(page.pointingNow == .below)
        #expect(pointer(in: page)?.chevron.name == "chevron.down")
    }

    @Test func theCapsuleLeavesWhenAScrollBringsTheRowBack() async throws {
        let (_, page) = try await scene(selecting: 0)
        try await scroll(page, to: 100_000)
        #expect(page.pointingNow == .above)

        try await scroll(page, to: 0)

        #expect(page.pointingNow == nil)
    }

    @Test func aClickGlidesTheRowIntoViewAndTheCapsuleLeaves() async throws {
        let (browser, page) = try await scene(selecting: 0)
        try await scroll(page, to: 100_000)

        page.showSelected()
        try await settle(rounds: 8)

        #expect(page.pointingNow == nil)
        let id = try #require(browser.activeID)
        let frame = try #require(page.frame(of: id))
        let list = try #require(scrollView(in: page))
        #expect(frame.midY > list.frame.minY && frame.midY < list.frame.maxY)
    }

    @Test func underReduceMotionAClickJumpsTheRowIntoView() async throws {
        Store.settings.set(true, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let (browser, page) = try await scene(selecting: 0)
        try await scroll(page, to: 100_000)

        page.showSelected()

        let id = try #require(browser.activeID)
        let frame = try #require(page.frame(of: id))
        let list = try #require(scrollView(in: page))
        #expect(frame.midY > list.frame.minY && frame.midY < list.frame.maxY)
    }

    @Test func theCapsuleLeavesWhenTheSelectedTabIsPinned() async throws {
        let (browser, page) = try await scene(selecting: 0)
        try await scroll(page, to: 100_000)
        #expect(page.pointingNow == .above)

        let tab = try #require(browser.active)
        browser.pin(tab)
        try await settle()

        #expect(page.pointingNow == nil)
    }

    private func pointer(in view: NSView) -> SelectedPointerView? { all(SelectedPointerView.self, in: view).first }

    private func scrollView(in page: SidePageView) -> SideScrollView? { all(SideScrollView.self, in: page).first }

    private func scroll(_ page: SidePageView, to y: CGFloat) async throws {
        let list = try #require(scrollView(in: page))
        let clip = list.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin)
        list.reflectScrolledClipView(clip)
        try await settle()
    }

    private func scene(selecting index: Int) async throws -> (Browser, SidePageView) {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let prefs = browser.prefs
        let saved = (prefs.usesTabGroups, prefs.splitView, prefs.sideWidth, prefs.sidePosition, prefs.sideHides, prefs.stackedSpaces)
        restore = { (prefs.usesTabGroups, prefs.splitView, prefs.sideWidth, prefs.sidePosition, prefs.sideHides, prefs.stackedSpaces) = saved }
        prefs.usesTabGroups = false
        prefs.splitView = false
        prefs.sideWidth = 258
        prefs.sidePosition = .left
        prefs.sideHides = false
        prefs.stackedSpaces = false
        for number in 0..<40 {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "about:blank#row-\(number)")!, title: "Row \(number)")
        }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1000, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = ContentView(browser: browser)
        window.orderFrontRegardless()
        self.browser = browser
        self.window = window
        try await settle()
        let loose = browser.tabs.filter { $0.pin == nil && !$0.isBlank }
        browser.select(loose[min(index, loose.count - 1)])
        try await settle()
        let root = try #require(window.contentView)
        let page = try #require(all(SidePageView.self, in: root).first { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil })
        return (browser, page)
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { sub -> [T] in ((sub as? T).map { [$0] } ?? []) + all(type, in: sub) }
    }

    private func settle(rounds: Int = 5) async throws {
        for _ in 0..<rounds {
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
