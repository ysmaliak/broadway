import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class SelectedShortcutTests {
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

    private func edge(_ offset: CGFloat, visible: CGFloat = 300, row: CGRect? = nil, on: Bool = true, settled: Bool = true)
        -> SelectedShortcutView.Edge? {
        SelectedShortcut.edge(row: row ?? self.row, offset: offset, visible: visible, height: 34, gap: 4, on: on, settled: settled)
    }

    @Test func aRowScrolledAboveTheListDocksAtTheTop() {
        #expect(edge(500) == .above)
    }

    @Test func aRowScrolledBelowTheListDocksAtTheBottom() {
        #expect(edge(0) == .below)
    }

    @Test func aRowInSightHasNoShortcut() {
        #expect(edge(200) == nil)
    }

    @Test func aRowPartlyInSightHasNoShortcut() {
        #expect(edge(420) == nil)
        #expect(edge(433) == nil)
        #expect(edge(120) == nil)
        #expect(edge(101) == nil)
    }

    @Test func aRowJustOutOfSightDocks() {
        #expect(edge(434) == .above)
        #expect(edge(100) == .below)
    }

    @Test func aTabOutsideTheListHasNoShortcut() {
        #expect(SelectedShortcut.edge(row: nil, offset: 500, visible: 300, height: 34, gap: 4) == nil)
    }

    @Test func theSettingOffHasNoShortcut() {
        #expect(edge(500, on: false) == nil)
        #expect(edge(0, on: false) == nil)
    }

    @Test func aScrollStillMovingHasNoShortcut() {
        #expect(edge(500, settled: false) == nil)
        #expect(edge(0, settled: false) == nil)
    }

    @Test func aListTooShortForTheDockHasNoShortcut() {
        #expect(edge(500, visible: 40) == nil)
    }

    @Test func theDockIsNeverOverTheRowItPointsTo() {
        for visible in [CGFloat(42), 80, 300, 640] {
            for offset in stride(from: CGFloat(-50), through: 900, by: 1) {
                guard let edge = edge(offset, visible: visible) else { continue }
                let band = SelectedShortcut.band(edge, offset: offset, visible: visible, height: 34, gap: 4)
                #expect(!(band.minY < row.maxY && row.minY < band.maxY), "offset \(offset) visible \(visible)")
                #expect(band.minY >= offset && band.maxY <= offset + visible, "offset \(offset) visible \(visible)")
            }
        }
    }

    @Test func everyRowTheShortcutShowsForIsOneTheGlideScrollsTo() {
        for offset in stride(from: CGFloat(0), through: 800, by: 7) where edge(offset) != nil {
            #expect(SelectedShortcut.target(row: row, offset: offset, visible: 300, fade: ColumnEdges.fade) != nil)
        }
    }

    @Test func theGlideLandsOnItsCurveAndJumpsWithoutOne() {
        #expect(SelectedShortcut.share(.none, at: 0) == (1, true))
        let early = SelectedShortcut.share(.spring(.roll), at: 0.05)
        #expect(early.share > 0 && early.share < 1 && !early.done)
        #expect(SelectedShortcut.share(.spring(.roll), at: 2).done)
    }

    @Test func itArrivesWithoutScaleAndLeavesWithoutTravel() {
        for side in [SelectedShortcutView.Edge.above, .below] {
            #expect(SelectedShortcutView.arrival(side).scale == 1)
            #expect(SelectedShortcutView.arrival(side).leaveScale == nil)
            #expect(SelectedShortcutView.arrival(side).travel.height != 0)
            #expect(SelectedShortcutView.leaving(side).travel == .zero)
            #expect(SelectedShortcutView.leaving(side).scale == 1)
        }
    }

    @Test func theSettingIsOffUntilTurnedOn() async throws {
        let (_, page) = try await scene(selecting: 0, on: false)

        try await scroll(page, to: 100_000)

        #expect(page.shortcutNow == nil)
        #expect(shortcut(in: page)?.isHidden != false)
    }

    @Test func theDockedRowShowsAboveWhenTheSelectedRowIsScrolledUpAndOut() async throws {
        let (browser, page) = try await scene(selecting: 0)

        try await scroll(page, to: 100_000)

        #expect(page.shortcutNow == .above)
        let docked = try #require(shortcut(in: page))
        #expect(!docked.isHidden)
        #expect(docked.chevron.name == "chevron.up")
        #expect(docked.accessibilityLabel() == "Show Selected Tab")
        #expect(docked.tabID == browser.activeID)
        #expect(docked.title.label == browser.active?.label)
        #expect(docked.mark.letter == browser.active?.monogram)
    }

    @Test func theDockedRowIsAsWideAndTallAsTheRowAndSitsInsideTheList() async throws {
        let (browser, page) = try await scene(selecting: 0)
        let id = try #require(browser.activeID)
        let start = try #require(page.frame(of: id))

        try await scroll(page, to: 100_000)

        let docked = try #require(shortcut(in: page))
        let list = try #require(scrollView(in: page))
        #expect(abs(docked.frame.width - start.width) < 0.5)
        #expect(abs(docked.frame.height - start.height) < 0.5)
        #expect(abs(docked.frame.minX - start.minX) < 0.5)
        #expect(docked.frame.minY >= list.frame.minY && docked.frame.maxY <= list.frame.maxY)
        let row = try #require(page.frame(of: id))
        #expect(!docked.frame.intersects(row))
    }

    @Test func theDockedRowShowsBelowWhenTheSelectedRowIsScrolledDownAndOut() async throws {
        let (_, page) = try await scene(selecting: 39)

        try await scroll(page, to: 0)

        #expect(page.shortcutNow == .below)
        #expect(shortcut(in: page)?.chevron.name == "chevron.down")
    }

    @Test func itWaitsForTheScrollToSettle() async throws {
        let (_, page) = try await scene(selecting: 0)

        try await scroll(page, to: 100_000, settles: false)
        window?.contentView?.layoutSubtreeIfNeeded()

        #expect(page.shortcutNow == nil)
        try await settle()
        #expect(page.shortcutNow == .above)
    }

    @Test func itStaysAwayDuringALiveScroll() async throws {
        let (_, page) = try await scene(selecting: 0)
        let list = try #require(scrollView(in: page))
        try await scroll(page, to: 100_000)
        #expect(page.shortcutNow == .above)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: list)
        try await settle()

        #expect(page.shortcutNow == nil)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: list)
        try await settle()
        #expect(page.shortcutNow == .above)
    }

    @Test func turningTheSettingOffTakesItAway() async throws {
        let (browser, page) = try await scene(selecting: 0)
        try await scroll(page, to: 100_000)
        #expect(page.shortcutNow == .above)

        browser.prefs.selectedShortcut = false
        try await settle()

        #expect(page.shortcutNow == nil)
        browser.prefs.selectedShortcut = true
        try await settle()
        #expect(page.shortcutNow == .above)
    }

    @Test func itLeavesWhenAScrollBringsTheRowBack() async throws {
        let (_, page) = try await scene(selecting: 0)
        try await scroll(page, to: 100_000)
        #expect(page.shortcutNow == .above)

        try await scroll(page, to: 0)

        #expect(page.shortcutNow == nil)
    }

    @Test func aClickGlidesTheRowIntoViewAndTheDockLeaves() async throws {
        let (browser, page) = try await scene(selecting: 0)
        try await scroll(page, to: 100_000)

        page.showSelected()
        try await settle(rounds: 8)

        #expect(page.shortcutNow == nil)
        let id = try #require(browser.activeID)
        let frame = try #require(page.frame(of: id))
        let list = try #require(scrollView(in: page))
        #expect(frame.minY >= list.frame.minY && frame.maxY <= list.frame.maxY)
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

    @Test func aSelectedTabInAnOpenFolderDocksAndTheClickBringsItBack() async throws {
        let (browser, page) = try await scene(selecting: 0, folder: true)
        let id = try #require(browser.activeID)
        #expect(browser.group(of: try #require(browser.active)) != nil)
        let list = try #require(scrollView(in: page))
        let start = try #require(page.frame(of: id))
        try await scroll(page, to: start.midY < list.frame.midY ? 100_000 : 0)
        #expect(page.shortcutNow != nil)
        let docked = try #require(shortcut(in: page))
        #expect(abs(docked.frame.minX - start.minX) < 0.5 && abs(docked.frame.width - start.width) < 0.5)

        page.showSelected()
        try await settle(rounds: 8)

        let frame = try #require(page.frame(of: id))
        #expect(frame.midY > list.frame.minY && frame.midY < list.frame.maxY)
        #expect(page.shortcutNow == nil)
    }

    @Test func itLeavesWhenTheSelectedTabIsPinned() async throws {
        let (browser, page) = try await scene(selecting: 0)
        try await scroll(page, to: 100_000)
        #expect(page.shortcutNow == .above)

        let tab = try #require(browser.active)
        browser.pin(tab)
        try await settle()

        #expect(page.shortcutNow == nil)
    }

    private func shortcut(in view: NSView) -> SelectedShortcutView? { all(SelectedShortcutView.self, in: view).first }

    private func scrollView(in page: SidePageView) -> SideScrollView? { all(SideScrollView.self, in: page).first }

    private func scroll(_ page: SidePageView, to y: CGFloat, settles: Bool = true) async throws {
        let list = try #require(scrollView(in: page))
        let clip = list.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin)
        list.reflectScrolledClipView(clip)
        if settles { try await settle() }
    }

    private func scene(selecting index: Int, folder: Bool = false, on: Bool = true) async throws -> (Browser, SidePageView) {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let prefs = browser.prefs
        let saved = (prefs.usesTabGroups, prefs.splitView, prefs.sideWidth, prefs.sidePosition, prefs.sideHides, prefs.stackedSpaces,
                     prefs.selectedShortcut)
        restore = {
            (prefs.usesTabGroups, prefs.splitView, prefs.sideWidth, prefs.sidePosition, prefs.sideHides, prefs.stackedSpaces,
             prefs.selectedShortcut) = saved
        }
        prefs.selectedShortcut = on
        prefs.usesTabGroups = folder
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
        let chosen = loose[min(index, loose.count - 1)]
        if folder {
            let made = browser.addTabGroup(containing: chosen)
            browser.move(loose[min(index + 1, loose.count - 1)], toGroup: made)
            try await settle()
        }
        browser.select(chosen)
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
