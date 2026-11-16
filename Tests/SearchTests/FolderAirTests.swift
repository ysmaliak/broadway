import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FolderAirTests {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    init() {
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.closeAll() }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
    }

    @Test func twoFoldersInARowSitATabRowsGapApart() {
        let gap = SideAir.between(.folder, .folder)

        #expect(gap == Metrics.sideGap)
    }

    @Test func aFoldedFolderKeepsTheTabRowsPitch() {
        let row = Metrics.sideRowHeight
        let folded = GroupHeadingView.height + 2 * Metrics.folderPad

        let rows = row + SideAir.between(.row, .row)
        let rowToHeading = row / 2 + SideAir.between(.row, .folder) + Metrics.folderPad + GroupHeadingView.height / 2
        let foldedToRow = folded / 2 + SideAir.between(.folder, .row) + row / 2
        let lastRowToRow = row / 2 + Metrics.folderPad + SideAir.between(.folder, .row) + row / 2

        #expect(rows == 37)
        #expect(rowToHeading == rows)
        #expect(foldedToRow == rows)
        #expect(lastRowToRow == rows + Metrics.folderPad)
    }

    @Test func aFolderAndATabRowAreOneMarginApart() {
        let below = SideAir.between(.folder, .row)
        let above = SideAir.between(.row, .folder)

        #expect(below == Metrics.folderAir)
        #expect(above == Metrics.folderAir)
    }

    @Test func tabRowsKeepTheirGap() {
        let gap = SideAir.between(.row, .row)

        #expect(gap == Metrics.sideGap)
    }

    @Test func theDividerKeepsItsRoomBesideRowsAndTheTopEdgeAddsNone() {
        let row = SideAir.between(.divider, .row)
        let folder = SideAir.between(.folder, .divider)
        let top = SideAir.between(nil, .folder)

        #expect(row == Metrics.sideDividerGap)
        #expect(folder == Metrics.sideDividerGap)
        #expect(Metrics.sideDividerGap > Metrics.folderAir)
        #expect(top == 0)
    }

    @Test func theDividerIsCentredInItsOwnRoomUnderAFolderAndUnderARow() {
        var underFolder = SideFlow()
        var underRow = SideFlow()

        let folderAbove = [underFolder.take(.folder), underFolder.take(.divider), underFolder.take(.row)]
        let rowAbove = [underRow.take(.row), underRow.take(.divider), underRow.take(.row)]

        #expect(folderAbove == [0, Metrics.sideDividerGap, Metrics.sideDividerGap])
        #expect(rowAbove == [0, Metrics.sideDividerGap, Metrics.sideDividerGap])
    }

    @Test func aSpanCollapsesNeighbouringMargins() {
        let blocks: [(air: SideAir, height: CGFloat)] = [(.row, 32), (.folder, 100), (.folder, 40), (.row, 32), (.row, 32)]

        let span = SideAir.span(blocks)

        #expect(span == 236 + 2 * Metrics.folderAir + 2 * Metrics.sideGap)
    }

    @Test func folderDropTargetsCoverTheMarginsWithNoDeadZone() {
        let air = Metrics.folderAir
        let one = UUID(), two = UUID(), tab = UUID()
        let first = CGRect(x: 6, y: 100, width: 240, height: 80)
        let second = CGRect(x: 6, y: first.maxY + air, width: 240, height: 80)
        let row = CGRect(x: 6, y: second.maxY + air, width: 240, height: 32)
        let items: [(item: Browser.ListItem, rect: CGRect)] = [(.folder(one), first), (.folder(two), second), (.tab(tab), row)]

        let places = stride(from: first.minY, through: row.maxY + 8, by: 1).map {
            FolderDrop.place(y: $0, rowsTop: 0, raised: [], items: items, moving: nil)
        }
        let between = FolderDrop.line(for: FolderDrop.Place(pinned: false, before: .folder(two)), raised: [], items: items, gap: Metrics.sideGap)
        let beforeRow = FolderDrop.line(for: FolderDrop.Place(pinned: false, before: .tab(tab)), raised: [], items: items, gap: Metrics.sideGap)

        #expect(places.allSatisfy { !$0.pinned })
        #expect(Set(places.map(\.before)) == [.folder(one), .folder(two), .tab(tab), nil])
        #expect(FolderDrop.place(y: first.maxY + air / 2, rowsTop: 0, raised: [], items: items, moving: nil).before == .folder(two))
        #expect(between == first.maxY + air / 2)
        #expect(beforeRow == second.maxY + air / 2)
    }

    @Test func aPinDroppedAmongTabsUsesWhereTheRowsAre() {
        let rows = [CGRect(x: 0, y: 0, width: 200, height: 32), CGRect(x: 0, y: 132, width: 200, height: 32)]
        let ghost = (at: 1, rect: CGRect(x: 0, y: 132, width: 200, height: 32))
        let shifted = [rows[0], rows[1].offsetBy(dx: 0, dy: 34)]

        let overFirst = PinDrop.slot(y: 10, rows: rows, ghost: nil)
        let inTheMargin = PinDrop.slot(y: 100, rows: rows, ghost: nil)
        let belowAll = PinDrop.slot(y: 160, rows: rows, ghost: nil)
        let onGhost = PinDrop.slot(y: 150, rows: shifted, ghost: ghost)

        #expect(overFirst == 0)
        #expect(inTheMargin == 1)
        #expect(belowAll == 2)
        #expect(onGhost == 1)
    }

    @Test func theColumnLaysFoldersOutWithCollapsedMargins() async throws {
        let browser = makeBrowser(count: 7)
        let tabs = browser.tabs
        let reading = browser.addTabGroup(containing: tabs[1], pinned: false)
        browser.move(tabs[2], toGroup: reading)
        let work = browser.addTabGroup(containing: tabs[3], pinned: false)
        browser.move(tabs[4], toGroup: work)
        #expect(browser.listItems(browser.displayedTabs) == [.tab(tabs[0].id), .folder(reading), .folder(work), .tab(tabs[5].id), .tab(tabs[6].id)])

        let window = makeWindow(browser)
        let page = try #require(pages(in: window.contentView).first)
        let blocks = try await laid(page, in: window, count: 5)

        #expect(blocks.map(\.kind) == ["row", "folder", "folder", "row", "row"])
        let gaps = zip(blocks, blocks.dropFirst()).map { $1.rect.minY - $0.rect.maxY }
        #expect(gaps == [Metrics.folderAir, Metrics.sideGap, Metrics.folderAir, Metrics.sideGap])
    }

    @Test func foldingAFolderKeepsItsMargins() async throws {
        let browser = makeBrowser(count: 4)
        let tabs = browser.tabs
        let folder = browser.addTabGroup(containing: tabs[1], pinned: false)
        browser.move(tabs[2], toGroup: folder)
        let window = makeWindow(browser)
        let page = try #require(pages(in: window.contentView).first)
        _ = try await laid(page, in: window, count: 3)

        browser.toggleTabGroup(folder)
        let blocks = try await laid(page, in: window, count: 3, folderHeight: GroupHeadingView.height + 2 * Metrics.folderPad)

        let gaps = zip(blocks, blocks.dropFirst()).map { $1.rect.minY - $0.rect.maxY }
        #expect(gaps == [Metrics.folderAir, Metrics.folderAir])
    }

    private func laid(_ page: SidePageView, in window: NSWindow, count: Int,
                      folderHeight: CGFloat? = nil) async throws -> [(kind: String, rect: CGRect)] {
        for _ in 0..<200 {
            window.contentView?.layoutSubtreeIfNeeded()
            let blocks = page.blocksNow
            let folded = folderHeight.map { height in blocks.filter { $0.kind == "folder" }.allSatisfy { $0.rect.height == height } } ?? true
            if blocks.count == count && folded { return blocks.sorted { $0.rect.minY < $1.rect.minY } }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("the column did not lay out \(count) blocks: \(page.blocksNow)")
        return page.blocksNow
    }

    private func pages(in view: NSView?) -> [SidePageView] {
        guard let view else { return [] }
        if let page = view as? SidePageView { return [page] }
        return view.subviews.flatMap(pages)
    }

    private func makeBrowser(count: Int) -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        if restorePreferences == nil {
            let previous = (prefs.usesTabGroups, prefs.splitView, prefs.usesSpaces, prefs.addressBar, prefs.sideWidth, prefs.newTabPlace)
            restorePreferences = {
                (prefs.usesTabGroups, prefs.splitView, prefs.usesSpaces, prefs.addressBar, prefs.sideWidth, prefs.newTabPlace) = previous
            }
        }
        prefs.usesTabGroups = true
        prefs.splitView = false
        prefs.usesSpaces = false
        prefs.addressBar = true
        prefs.sideWidth = 258
        prefs.newTabPlace = .end
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let space = Space(id: UUID(), name: "Folder air fixture", colour: 0, sharesSignIns: true)
        browser.spaces = [space]
        browser.spaceID = space.id
        browsers.append(browser)
        for index in 0..<count {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "about:blank#air-\(index)")!, title: "air \(index)")
        }
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 900),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SideColumnView(browser: browser)
        window.orderFrontRegardless()
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }
}
