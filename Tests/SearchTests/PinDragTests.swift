import AppKit
import Testing
@testable import Search

/// A tab dragged onto the pins, and a pin dragged out among the tabs, with
/// the column's own gestures: the column is hosted in a borderless window
/// far off every screen (as SidebarPressTests does), never activated, and
/// the mouse events go to that window alone.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PinDragTests {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    init() {
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        for window in windows { window.contentView = nil; window.close() }
        // Pins are kept for the space in every window (Pins.swift): put
        // down, or the next test's window would hold them too.
        for browser in browsers {
            browser.cancelTabEdit()
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
            Pins.forget(browser.spaceID)
        }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
    }

    // MARK: - the pure parts

    @Test func zones() {
        #expect(PinDrop.zone(CGPoint(x: 50, y: 10), width: 212, gridBottom: 34) == .squares)
        #expect(PinDrop.zone(CGPoint(x: 50, y: 38), width: 212, gridBottom: 34) == .squares, "the upper half of the margin is the grid's")
        #expect(PinDrop.zone(CGPoint(x: 50, y: 41), width: 212, gridBottom: 34) == .loose)
        #expect(PinDrop.zone(CGPoint(x: 50, y: -20), width: 212, gridBottom: nil) == .squares, "no pins: above the rows makes the first")
        #expect(PinDrop.zone(CGPoint(x: 50, y: 5), width: 212, gridBottom: nil) == .loose)
        #expect(PinDrop.zone(CGPoint(x: 400, y: 10), width: 212, gridBottom: 34) == .none, "over the page: not the column")
    }

    @Test func rowSlots() {
        let rows: [CGFloat] = [28, 28, 28]
        #expect(PinDrop.rowSlot(y: 5, heights: rows, gap: 2, ghost: nil) == 0)
        #expect(PinDrop.rowSlot(y: 20, heights: rows, gap: 2, ghost: nil) == 1)
        #expect(PinDrop.rowSlot(y: 200, heights: rows, gap: 2, ghost: nil) == 3)
        // A line open at 1: anywhere on it keeps it, and the rows after it
        // are where they now are.
        #expect(PinDrop.rowSlot(y: 31, heights: rows, gap: 2, ghost: (1, 28)) == 1)
        #expect(PinDrop.rowSlot(y: 57, heights: rows, gap: 2, ghost: (1, 28)) == 1)
        #expect(PinDrop.rowSlot(y: 70, heights: rows, gap: 2, ghost: (1, 28)) == 1, "upper half of the row now under it")
        #expect(PinDrop.rowSlot(y: 80, heights: rows, gap: 2, ghost: (1, 28)) == 2)
    }

    @Test func gridSlots() {
        let cells = (0..<3).map { CGRect(x: CGFloat($0) * 70, y: 0, width: 66, height: 34) }
        #expect(PinDrop.gridSlot(CGPoint(x: 10, y: 17), cells: cells) == 0)
        #expect(PinDrop.gridSlot(CGPoint(x: 100, y: 17), cells: cells) == 1)
        #expect(PinDrop.gridSlot(CGPoint(x: 300, y: 60), cells: cells) == 2)
    }

    @Test func pinSlotKeepsSharedPinsAhead() {
        let browser = makeBrowser(count: 4)
        let t = browser.tabs
        browser.pin(t[0]); browser.pin(t[1])
        t[0].everywhere = true
        browser.prefs.usesSpaces = true
        browser.prefs.sharesPins = true
        #expect(browser.pinSlot(t[2], proposed: 0) == 1, "after the one every space shows")
        #expect(browser.pinSlot(t[2], proposed: 9) == 2)
        browser.prefs.sharesPins = false
        #expect(browser.pinSlot(t[2], proposed: 0) == 0)
    }

    // MARK: - the model, as the drop calls it

    @Test func droppedOnThePinsPinsInPlaceAndKeepsThePage() {
        let browser = makeBrowser(count: 5)
        let t = browser.tabs
        browser.pin(t[0]); browser.pin(t[1])
        let page = t[3].built
        #expect(browser.pinDropped(t[3], at: 1))
        #expect(browser.tabs.map(\.id) == [t[0], t[3], t[1], t[2], t[4]].map { $0.id })
        #expect(t[3].pin != nil)
        #expect(t[3].built === page, "the same web view, not a reload")
        #expect(browser.unpinDropped(t[0], at: 1))
        #expect(browser.tabs.map(\.id) == [t[3], t[1], t[2], t[0], t[4]].map { $0.id })
        #expect(t[0].pin == nil)
        #expect(t[0].home == nil)
    }

    @Test func aPairIsNotPinnedByADrag() {
        let browser = makeBrowser(count: 4)
        let t = browser.tabs
        browser.prefs.splitView = true
        browser.pair(t[2], with: t[1], onLeft: false)
        #expect(!browser.pinsByDrag(t[1]))
        #expect(!browser.pinDropped(t[1], at: 0))
        #expect(t[1].pin == nil)
        #expect(browser.split(for: t[1]) != nil, "the pair stays a pair")
    }

    // MARK: - the real gestures

    @Test func rowDraggedOntoTheGridBecomesAPinWhereItWasLetGo() async throws {
        let browser = makeBrowser(count: 5)
        let t = browser.tabs
        browser.pin(t[0]); browser.pin(t[1])
        // On screen first, so its page is made before the drag, as a tab
        // you pick up is selected by the press that picks it up.
        browser.select(t[3])
        let window = makeWindow(browser)
        try await settle(in: window)
        let page = t[3].built
        #expect(page != nil)
        // The rows start under the grid: 34 + 10.
        let start = point(x: 70, y: rowY(1), in: window)
        // Between the two squares: the middle of three places.
        let room = browser.prefs.sideWidth - 20
        let middle = 10 + room / 2
        try await drag(from: start, through: [
            point(x: 70, y: rowY(0) - 18, in: window),
            point(x: middle, y: columnTop + 35, in: window),
            point(x: middle, y: columnTop + 22, in: window),
        ], in: window, until: { t[3].pin != nil })
        #expect(browser.tabs.map(\.id) == [t[0], t[3], t[1], t[2], t[4]].map { $0.id })
        #expect(t[3].pin != nil, "pinned")
        #expect(t[3].built === page, "the same web view")
    }

    @Test func pinDraggedAmongTheRowsBecomesATabThere() async throws {
        let browser = makeBrowser(count: 5)
        let t = browser.tabs
        browser.pin(t[0]); browser.pin(t[1])
        browser.select(t[2])
        let window = makeWindow(browser)
        try await settle(in: window)
        let room = browser.prefs.sideWidth - 20
        let start = point(x: 10 + room / 6, y: columnTop + 22, in: window)
        try await drag(from: start, through: [
            point(x: 10 + room / 6, y: columnTop + 50, in: window),
            point(x: 80, y: rowY(1) - 14, in: window),
            point(x: 80, y: rowY(1) - 14, in: window),
        ], in: window, until: { t[0].pin == nil })
        #expect(t[0].pin == nil, "unpinned")
        #expect(browser.tabs.map(\.id) == [t[1], t[2], t[0], t[3], t[4]].map { $0.id })
    }

    @Test func dropsWhileTheRowsScroll() async throws {
        // More rows than the window holds: they scroll, under the grid.
        let browser = makeBrowser(count: 20)
        let t = browser.tabs
        browser.pin(t[0]); browser.pin(t[1])
        browser.select(t[2])
        let window = makeWindow(browser)
        try await settle(in: window)
        let room = browser.prefs.sideWidth - 20
        try await drag(from: point(x: 10 + room / 6, y: columnTop + 22, in: window), through: [
            point(x: 10 + room / 6, y: columnTop + 50, in: window),
            point(x: 80, y: rowY(1) - 14, in: window),
        ], in: window, until: { t[0].pin == nil })
        #expect(t[0].pin == nil)
        #expect(browser.tabs.prefix(4).map(\.id) == [t[1], t[2], t[0], t[3]].map { $0.id })
        // And back up into the grid, first.
        try await drag(from: point(x: 70, y: rowY(1), in: window), through: [
            point(x: 30, y: columnTop + 35, in: window),
            point(x: 20, y: columnTop + 22, in: window),
        ], in: window, until: { t[0].pin != nil })
        #expect(browser.squarePins.map(\.id) == [t[0], t[1]].map { $0.id })
    }

    @Test func aTabCarriedFromTheListJoinsAPinnedFolderAboveIt() async throws {
        let browser = makeBrowser(count: 6)
        let t = browser.tabs
        browser.prefs.usesTabGroups = true
        let folder = browser.addTabGroup(containing: t[0], pinned: true)
        browser.move(t[1], toGroup: GroupDropTarget(group: folder))
        browser.select(t[3])
        let window = makeWindow(browser)
        try await settle(in: window)
        let member = try #require(Bench.rowFrames[t[1].id])
        let carried = try #require(Bench.rowFrames[t[5].id])
        #expect(member.maxY < carried.minY, "the pinned folder stands above the list")
        try await drag(from: point(x: 70, y: carried.midY, in: window), through: [
            point(x: 70, y: carried.midY - 20, in: window),
            point(x: 70, y: member.midY + 4, in: window),
        ], in: window, until: { browser.group(of: t[5]) == folder })
        #expect(browser.group(of: t[5]) == folder, "it joined the pinned folder")
        #expect(browser.tabGroups.first { $0.id == folder }?.pinned == true)
    }

    @Test func firstPinMadeAboveTheRows() async throws {
        let browser = makeBrowser(count: 3)
        let t = browser.tabs
        let window = makeWindow(browser)
        try await settle(in: window)
        try await drag(from: point(x: 70, y: bareRowY(1), in: window), through: [
            point(x: 70, y: columnTop + 4, in: window),
            point(x: 70, y: columnTop - 12, in: window),
            point(x: 70, y: columnTop + 10, in: window),
        ], in: window, until: { t[1].pin != nil })
        #expect(t[1].pin != nil)
        #expect(browser.tabs.first?.id == t[1].id)
    }

    @Test func reorderingStaysWithinEachBlock() async throws {
        let browser = makeBrowser(count: 5)
        let t = browser.tabs
        browser.pin(t[0]); browser.pin(t[1])
        browser.select(t[2])
        let window = makeWindow(browser)
        try await settle(in: window)
        // A row carried down its own list.
        try await drag(from: point(x: 70, y: rowY(0), in: window), through: [
            point(x: 70, y: rowY(1), in: window),
            point(x: 70, y: rowY(2) + 3, in: window),
        ], in: window, until: { browser.tabs.last?.id == t[2].id })
        #expect(browser.tabs.map(\.id) == [t[0], t[1], t[3], t[4], t[2]].map { $0.id })
        #expect(browser.pinnedCount == 2)
        // A square carried along the grid.
        let room = browser.prefs.sideWidth - 20
        try await drag(from: point(x: 10 + room / 6, y: columnTop + 22, in: window), through: [
            point(x: 10 + room / 2, y: columnTop + 22, in: window),
            point(x: 10 + room / 2 + 4, y: columnTop + 22, in: window),
        ], in: window, until: { browser.tabs.first?.id == t[1].id })
        #expect(browser.tabs.prefix(2).map(\.id) == [t[1], t[0]].map { $0.id })
        #expect(browser.pinnedCount == 2)
    }

    @Test func aPairRowGetsNoPlaceInTheGrid() async throws {
        let browser = makeBrowser(count: 4)
        let t = browser.tabs
        browser.prefs.splitView = true
        browser.pin(t[0])
        browser.pair(t[2], with: t[1], onLeft: false)
        browser.select(t[3])
        let window = makeWindow(browser)
        try await settle(in: window)
        try await drag(from: point(x: 70, y: rowY(0), in: window), through: [
            point(x: 70, y: columnTop + 35, in: window),
            point(x: 70, y: columnTop + 22, in: window),
        ], in: window)
        #expect(t[1].pin == nil)
        #expect(t[2].pin == nil)
        #expect(browser.split(for: t[1]) != nil)
        #expect(browser.pinnedCount == 1)
    }

    @Test func pinnedFoldersAndTheTabsShareOneScroll() async throws {
        let browser = makeBrowser(count: 30)
        let t = browser.tabs
        browser.prefs.usesTabGroups = true
        let folder = browser.addTabGroup(containing: t[0], pinned: true)
        browser.move(t[1], toGroup: GroupDropTarget(group: folder))
        browser.select(t[3])
        let window = makeWindow(browser)
        try await settle(in: window)
        let page = try #require(livePage(in: window))
        let scrolls = scrollViews(in: page)
        #expect(scrolls.count == 1, "one scroll for the pinned folders and the tabs")
        let list = try #require(scrolls.first)
        let document = try #require(list.documentView)
        let heading = try #require(subviews(of: GroupHeadingView.self, in: page).first)
        #expect(heading.isDescendant(of: document), "the pinned folder is in the list's scroll")
        let member = try #require(Bench.rowFrames[t[1].id])
        let loose = try #require(Bench.rowFrames[t[4].id])
        #expect(document.frame.height > list.contentView.bounds.height + 60)

        list.contentView.scroll(to: NSPoint(x: 0, y: 60))
        list.reflectScrolledClipView(list.contentView)
        try await settle(in: window)

        let memberNow = try #require(Bench.rowFrames[t[1].id])
        let looseNow = try #require(Bench.rowFrames[t[4].id])
        #expect(abs(memberNow.minY - (member.minY - 60)) < 1, "the pinned folder's tab scrolled")
        #expect(abs(looseNow.minY - (loose.minY - 60)) < 1, "the loose tab scrolled with it")
    }

    @Test func theDividerStandsBetweenThePinnedFoldersAndTheListAndGoesWithThem() async throws {
        let browser = makeBrowser(count: 6)
        let t = browser.tabs
        browser.prefs.usesTabGroups = true
        let folder = browser.addTabGroup(containing: t[0], pinned: true)
        browser.move(t[1], toGroup: GroupDropTarget(group: folder))
        browser.select(t[3])
        let window = makeWindow(browser)
        try await settle(in: window)
        let page = try #require(livePage(in: window))
        let document = try #require(scrollViews(in: page).first?.documentView)

        let lines = hairlines(in: document)

        #expect(lines.count == 1)
        let line = try #require(lines.first)
        let shown = document.subviews.filter { !$0.isHidden && $0 !== line && !($0 is ColumnScrollReaderView) }
        let card = try #require(shown.filter { $0.frame.maxY <= line.frame.minY }.map(\.frame.maxY).max())
        let next = try #require(shown.filter { $0.frame.minY >= line.frame.maxY }.map(\.frame.minY).min())
        #expect(abs(line.frame.minY - card - Metrics.sideDividerGap) < 0.5, "the divider's room under the last pinned folder")
        #expect(abs(next - line.frame.maxY - Metrics.sideDividerGap) < 0.5, "the same room over the first list item")
        #expect(abs(line.frame.minX - (Metrics.sideInset + SideLook.ruleInset)) < 0.5)
        #expect(abs(line.frame.maxX - (document.bounds.width - Metrics.sideInset - SideLook.ruleInset)) < 0.5)

        browser.setFolderPinned(folder, false)
        try await settle(in: window)

        #expect(hairlines(in: document).isEmpty, "no pinned folders, no divider")
    }

    @Test func aFolderPinnedFromTheListKeepsItsOpenChevron() async throws {
        let browser = makeBrowser(count: 6)
        let t = browser.tabs
        browser.prefs.usesTabGroups = true
        browser.select(t[5])
        let window = makeWindow(browser)
        let first = browser.addTabGroup(containing: t[0], pinned: false)
        browser.renameTabGroup(first, to: "Work")
        browser.move(t[1], toGroup: GroupDropTarget(group: first))
        browser.editingGroupID = nil
        try await settle(in: window)
        KitChange.eased { browser.setFolderPinned(first, true) }
        try await settle(in: window)
        let second = browser.addTabGroup(containing: t[2], pinned: false)
        browser.renameTabGroup(second, to: "Home")
        browser.editingGroupID = nil
        browser.move(t[3], toGroup: GroupDropTarget(group: second))
        browser.select(t[3])

        KitChange.eased { browser.setFolderPinned(second, true) }
        try await settle(in: window)
        try await Task.sleep(for: .milliseconds(800))

        let page = try #require(livePage(in: window))
        let headings = subviews(of: GroupHeadingView.self, in: page)
        #expect(headings.count == 2)
        for heading in headings {
            let chevron = try #require(subviews(of: KitTurnView.self, in: heading).first)
            let turn = try #require(chevron.layer?.sublayerTransform)
            #expect(abs(turn.m11) < 0.01 && abs(abs(turn.m12) - 1) < 0.01, "open: turned a quarter, \(turn.m11) \(turn.m12)")
        }
    }

    @Test func aTabCarriedFromAPinnedFolderJoinsAFolderInTheList() async throws {
        let browser = makeBrowser(count: 6)
        let t = browser.tabs
        browser.prefs.usesTabGroups = true
        let pinned = browser.addTabGroup(containing: t[0], pinned: true)
        browser.move(t[1], toGroup: GroupDropTarget(group: pinned))
        let listed = browser.addTabGroup(containing: t[4], pinned: false)
        browser.move(t[5], toGroup: GroupDropTarget(group: listed))
        browser.select(t[3])
        let window = makeWindow(browser)
        try await settle(in: window)
        let carried = try #require(Bench.rowFrames[t[1].id])
        let member = try #require(Bench.rowFrames[t[5].id])
        #expect(carried.maxY < member.minY)
        let closed = carried.height + Metrics.sideGap

        try await drag(from: point(x: 70, y: carried.midY, in: window), through: [
            point(x: 70, y: carried.midY + 20, in: window),
            point(x: 70, y: member.midY - closed - 10, in: window),
            point(x: 70, y: member.midY - closed + 4, in: window),
        ], in: window, until: { browser.group(of: t[1]) == listed })

        #expect(browser.group(of: t[1]) == listed, "it joined the folder in the list")
        #expect(browser.group(of: t[0]) == pinned)
        #expect(browser.tabGroups.first { $0.id == listed }?.pinned == false)
    }

    @Test func aTabShiftedOutOfAPinnedFolderLandsInTheList() async throws {
        let browser = makeBrowser(count: 6)
        let t = browser.tabs
        browser.prefs.usesTabGroups = true
        let folder = browser.addTabGroup(containing: t[0], pinned: true)
        browser.move(t[1], toGroup: GroupDropTarget(group: folder))
        browser.select(t[3])
        let window = makeWindow(browser)
        try await settle(in: window)
        let carried = try #require(Bench.rowFrames[t[1].id])

        try await drag(from: point(x: 120, y: carried.midY, in: window), through: [
            point(x: 100, y: carried.midY + 1, in: window),
            point(x: 80, y: carried.midY + 1, in: window),
            point(x: 70, y: carried.midY + 1, in: window),
        ], in: window, until: { browser.group(of: t[1]) == nil })

        #expect(browser.group(of: t[1]) == nil, "out of the folder")
        #expect(browser.listItems(browser.displayedTabs).contains(.tab(t[1].id)), "a loose tab in the list")
        #expect(browser.group(of: t[0]) == folder)
    }

    // MARK: - helpers

    private func livePage(in window: NSWindow) -> SidePageView? {
        guard let root = window.contentView else { return nil }
        return subviews(of: SidePageView.self, in: root).first { $0.preview == nil && !$0.embedded && !$0.isHiddenOrHasHiddenAncestor }
    }

    private func subviews<V: NSView>(of type: V.Type, in view: NSView) -> [V] {
        view.subviews.flatMap { ($0 as? V).map { [$0] } ?? [] + subviews(of: type, in: $0) }
    }

    private func scrollViews(in page: SidePageView) -> [SideScrollView] {
        subviews(of: SideScrollView.self, in: page).filter { !$0.isHidden }
    }

    private func hairlines(in document: NSView) -> [KitPlate] {
        document.subviews.compactMap { $0 as? KitPlate }.filter { !$0.isHidden && $0.frame.height == 1 && $0.frame.width > 40 }
    }

    private func makeBrowser(count: Int) -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        if restorePreferences == nil {
            let previous = (prefs.usesTabGroups, prefs.splitView, prefs.usesSpaces, prefs.sharesPins,
                            prefs.addressBar, prefs.sideWidth, prefs.newTabPlace)
            restorePreferences = {
                (prefs.usesTabGroups, prefs.splitView, prefs.usesSpaces, prefs.sharesPins,
                 prefs.addressBar, prefs.sideWidth, prefs.newTabPlace) = previous
            }
        }
        prefs.usesTabGroups = false
        prefs.splitView = false
        prefs.usesSpaces = false
        prefs.sharesPins = false
        prefs.addressBar = true
        prefs.sideWidth = 258
        prefs.newTabPlace = .end
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let space = Space(id: UUID(), name: "Drag fixture", colour: 0, sharesSignIns: true)
        browser.spaces = [space]
        browser.spaceID = space.id
        browsers.append(browser)
        for index in 0..<count {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "about:blank#row-\(index)")!, title: "row \(index)")
        }
        #expect(browser.tabs.count == count)
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SideColumnView(browser: browser)
        window.orderFrontRegardless()
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }

    /// A point given from the column's top-left, in the window's terms.
    private var rowsAbove: Int { Shared.prefs.newTabsAtBottom ? 0 : 1 }

    private var columnTop: CGFloat { Metrics.strip + SpaceTitleSize.room + Metrics.sidePill - 3 + 8 }
    private var rowStep: CGFloat { Metrics.sideRowHeight + 5 }

    private func bareRowY(_ index: Int) -> CGFloat {
        columnTop + Metrics.sideRowHeight / 2 + CGFloat(index + rowsAbove) * rowStep
    }

    private func rowY(_ index: Int) -> CGFloat {
        bareRowY(index) + 45 + 8
    }

    private func point(x: CGFloat, y: CGFloat, in window: NSWindow) -> NSPoint {
        NSPoint(x: x, y: window.frame.height - y)
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool,
                           sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("\(message)", sourceLocation: sourceLocation)
        throw WaitError.timedOut
    }

    private func settle(in window: NSWindow) async throws {
        var previous: [Search.Tab.ID: CGRect] = [:]
        var since = ProcessInfo.processInfo.systemUptime
        try await waitUntil("the sidebar rows did not finish layout") {
            window.contentView?.layoutSubtreeIfNeeded()
            let current = Bench.rowFrames.filter { id, _ in browsers.contains { $0.tabs.contains { $0.id == id } } }
            guard !current.isEmpty else { return false }
            if current != previous {
                previous = current
                since = ProcessInfo.processInfo.systemUptime
            }
            return ProcessInfo.processInfo.systemUptime - since >= 0.3
        }
    }

    private enum WaitError: Error { case timedOut }

    /// Down at `start`, through `points` a few points at a time, and up at
    /// the last. Not held still long before letting go: a window that isn't
    /// on a screen gets these events from the test, not from the mouse, so
    /// AppKit doesn't know a button is down and puts up a pin's tooltip after
    /// half a second at rest, which ends the drag. A real hand's button is
    /// down, and no tooltip comes during a drag.
    private func drag(from start: NSPoint, through points: [NSPoint], in window: NSWindow, until landed: (() -> Bool)? = nil) async throws {
        let last = try await carry(from: start, through: points, in: window)
        try await send(.leftMouseUp, at: last, in: window)
        if let landed { try await waitUntil("the drop did not reach its destination", landed) }
        try await settle(in: window)
    }

    private func carry(from start: NSPoint, through points: [NSPoint], in window: NSWindow) async throws -> NSPoint {
        try await send(.leftMouseDown, at: start, in: window)
        var last = start
        for target in points {
            // As a hand moves: a few points at a time.
            let steps = max(1, Int((hypot(target.x - last.x, target.y - last.y) / 4).rounded(.up)))
            for step in 1...steps {
                let f = CGFloat(step) / CGFloat(steps)
                let p = NSPoint(x: last.x + (target.x - last.x) * f, y: last.y + (target.y - last.y) * f)
                try await send(.leftMouseDragged, at: p, in: window)
            }
            last = target
        }
        return last
    }

    /// What the column looks like mid-drag, for looking at by eye: only
    /// when PIN_DRAG_SHOTS names a folder. The column is drawn into a
    /// picture, never onto a screen.
    @Test func looks() async throws {
        guard let folder = ProcessInfo.processInfo.environment["PIN_DRAG_SHOTS"] else { return }
        func shoot(_ name: String, _ window: NSWindow) async throws {
            try await Task.sleep(for: .milliseconds(350))
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
        }
        let room = Shared.prefs.sideWidth - 20
        for name in ["row-over-grid", "pin-over-rows", "first-pin", "pair-refused"] {
            let browser = makeBrowser(count: 5)
            let t = browser.tabs
            if name == "pair-refused" { browser.prefs.splitView = true; browser.pair(t[3], with: t[2], onLeft: false) }
            if name != "first-pin" { browser.pin(t[0]); browser.pin(t[1]) }
            browser.select(t[4])
            let window = makeWindow(browser)
            try await settle(in: window)
            var last: NSPoint
            switch name {
            case "row-over-grid", "pair-refused":
                last = try await carry(from: point(x: 70, y: rowY(name == "pair-refused" ? 0 : 1), in: window), through: [
                    point(x: 10 + room / 2, y: columnTop + 35, in: window), point(x: 10 + room / 2, y: columnTop + 22, in: window)], in: window)
            case "pin-over-rows":
                last = try await carry(from: point(x: 10 + room / 6, y: columnTop + 22, in: window), through: [
                    point(x: 80, y: rowY(2) - 14, in: window)], in: window)
            default:
                last = try await carry(from: point(x: 70, y: bareRowY(1), in: window), through: [
                    point(x: 70, y: columnTop - 12, in: window), point(x: 70, y: columnTop + 10, in: window)], in: window)
            }
            try await shoot(name, window)
            try await send(.leftMouseUp, at: last, in: window)
            try await settle(in: window)
            try await shoot(name + "-after", window)
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            window.contentView = nil
            window.close()
        }
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(30))
    }
}
