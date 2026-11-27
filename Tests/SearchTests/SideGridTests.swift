import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SideGridTests {
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

    @Test func theMeasuresComeFromTheMarkTheRowAndTheMargin() {
        #expect(SideGrid.gap == SideGrid.mark / 2)
        #expect(SideGrid.tail == SideGrid.gap / 2)
        #expect(SideGrid.keyGap == SideGrid.tail / 2)
        #expect(SideGrid.pad == SideGrid.edge / 2)
        #expect(SideGrid.row == Metrics.sideRowHeight)
        #expect(SideGrid.lead + SideGrid.mark / 2 == SideGrid.row / 2)
        #expect(SideGrid.words == SideGrid.lead + SideGrid.mark + SideGrid.gap)
        #expect(SideGrid.key + 2 * SideGrid.tail == SideGrid.row)
        #expect(SideGrid.bar + 2 * SideGrid.pad == SideGrid.row)
        #expect(SideGrid.step == SideGrid.mark + SideGrid.gap)
    }

    @Test func theOlderNamesReadTheSameMeasures() {
        #expect(Metrics.sideInset == SideGrid.edge)
        #expect(Metrics.sideGap == SideGrid.pad)
        #expect(Metrics.folderPad == SideGrid.pad)
        #expect(Metrics.closeInset(SideGrid.row) == SideGrid.tail)
        #expect(Metrics.closeSquare(SideGrid.row) == SideGrid.key)
        #expect(SideLook.rowMark == SideGrid.mark)
        #expect(SideLook.titleLine == SideGrid.mark)
        #expect(SideLook.rowLead == SideGrid.lead)
        #expect(SideLook.markGap == SideGrid.gap)
        #expect(SideLook.pillLead == SideGrid.lead)
        #expect(SideLook.cardRowInset == SideGrid.step)
        #expect(RowTitleFade.whole == SideGrid.lead)
        #expect(AddressDoorsView.side == SideGrid.key)
        #expect(MiniPlayerView.key == SideGrid.key)
        #expect(MiniPlayerView.keyGap == SideGrid.keyGap)
        #expect(SplitChipView.height == SideGrid.bar)
        #expect(SpaceFootView.side == SideGrid.bar)
        #expect(PinPlaces.gap == SideGrid.edge)
    }

    @Test func everyIconStartsOnOneLine() async throws {
        let (_, column) = try await world()
        let line = SideGrid.edge + SideGrid.lead
        let row = try #require(rows(in: column).first { near(span($0, in: column).min, SideGrid.edge) })
        let heading = try #require(views(of: GroupHeadingView.self, in: column).first)
        let glyph = try #require(views(of: FolderMarkView.self, in: heading).first)
        let quiet = try #require(views(of: QuietRowView.self, in: column).first { !$0.isHiddenOrHasHiddenAncestor })
        let plus = try #require(views(of: KitSymbol.self, in: quiet).first)
        let words = try #require(views(of: AddressWordsView.self, in: column).first { !$0.isHiddenOrHasHiddenAncestor })
        let address = try #require(views(of: KitLabel.self, in: words).first)
        let chip = try #require(views(of: SplitChipView.self, in: column).min { span($0, in: column).min < span($1, in: column).min })
        let chipMark = try #require(views(of: KitMark.self, in: chip).first)

        #expect(near(try leading(row, in: column), line))
        #expect(near(span(glyph, in: column).mid, line + SideGrid.mark / 2))
        #expect(near(span(plus, in: column).min, line))
        #expect(near(span(address, in: column).min, line))
        #expect(near(span(chipMark, in: column).min, line))
        #expect(UpdateCardView.pad == SideGrid.lead)
        #expect(SpaceFootView.iconMiddle == line + SideGrid.mark / 2)
    }

    @Test func everyNameStartsOnOneLine() async throws {
        let (_, column) = try await world()
        let line = SideGrid.edge + SideGrid.words
        let heading = try #require(views(of: GroupHeadingView.self, in: column).first)
        let name = try #require(views(of: KitLabel.self, in: heading).first { $0.text == "Design" })
        let quiet = try #require(views(of: QuietRowView.self, in: column).first { !$0.isHiddenOrHasHiddenAncestor })
        let label = try #require(views(of: KitLabel.self, in: quiet).first)
        let chip = try #require(views(of: SplitChipView.self, in: column).min { span($0, in: column).min < span($1, in: column).min })
        let chipName = try #require(chip.subviews.compactMap { $0 as? KitLabel }.first)

        #expect(near(span(name, in: column).min, line))
        #expect(near(span(label, in: column).min, line))
        #expect(near(span(chipName, in: column).min, line))
        #expect(SpaceTitleLineView.wordsStart == SideGrid.words)
    }

    @Test func aRowInAFolderStartsItsIconUnderTheFoldersName() async throws {
        let (_, column) = try await world()
        let heading = try #require(views(of: GroupHeadingView.self, in: column).first)
        let name = try #require(views(of: KitLabel.self, in: heading).first { $0.text == "Design" })
        let inside = rows(in: column).filter { span($0, in: column).min > SideGrid.edge + 1 }
        let first = try #require(try inside.map { try leading($0, in: column) }.min())

        #expect(near(first, span(name, in: column).min))
        #expect(SidePageView.cardLead + Metrics.folderPad == SideGrid.step)
        #expect(GroupHeadingView.indent == SideGrid.step)
        #expect(FolderHeadingMetrics.indent == SideGrid.step)
    }

    @Test func everyKeyAtTheColumnsEndSitsOnOneLine() async throws {
        let (_, column) = try await world()
        let line = column.bounds.width - SideGrid.edge - SideGrid.row / 2
        let helm = try #require(views(of: HelmView.self, in: column).first)
        let top = try #require(keys(in: helm, column).last)
        let doors = try #require(views(of: AddressDoorsView.self, in: column).first { !$0.isHiddenOrHasHiddenAncestor })
        let site = try #require(keys(in: doors, column).last)
        let row = try #require(rows(in: column).first { near(span($0, in: column).min, SideGrid.edge) })
        let close = try #require(views(of: CloseSpotView.self, in: row).max { span($0, in: column).mid < span($1, in: column).mid })
        let heading = try #require(views(of: GroupHeadingView.self, in: column).first)
        let headingClose = try #require(views(of: CloseSpotView.self, in: heading).max { span($0, in: column).mid < span($1, in: column).mid })

        #expect(near(top.mid, line))
        #expect(near(site.mid, line))
        #expect(near(span(close, in: column).mid, line))
        #expect(near(span(headingClose, in: column).mid, line))
        #expect(column.bounds.width - SpaceFootView.lead - SpaceFootView.side / 2 == line)
    }

    @Test func aBarInsideACardKeepsItsOwnEndCellOnePadFurtherIn() async throws {
        let (_, column) = try await world()
        let line = column.bounds.width - SideGrid.edge - SideGrid.pad - SideGrid.row / 2
        let inside = try #require(rows(in: column).first { span($0, in: column).min > SideGrid.edge + 1 })
        let close = try #require(views(of: CloseSpotView.self, in: inside).max { span($0, in: column).mid < span($1, in: column).mid })

        #expect(near(span(close, in: column).mid, line))
    }

    @Test func everyLevelOfAFolderStepsInByAMarkAndItsGap() async throws {
        let (_, column) = try await world()
        let inside = rows(in: column).filter { span($0, in: column).min > SideGrid.edge + 1 }
        let starts = Set(try inside.map { try leading($0, in: column) }).sorted()
        let nested = try #require(views(of: GroupHeadingView.self, in: column).first { heading in
            views(of: KitLabel.self, in: heading).contains { $0.text == "Nested" }
        })
        let glyph = try #require(views(of: FolderMarkView.self, in: nested).first)

        #expect(starts.count == 2)
        #expect(near(starts[0], SideGrid.edge + SideGrid.words))
        #expect(near(starts[1], starts[0] + SideGrid.step))
        #expect(near(span(glyph, in: column).mid, starts[0] + SideGrid.mark / 2))
    }

    @Test(arguments: [200, 202, 203, 204, 205, 206, 208, 258, 272])
    func theTopKeysKeepClearOfTheWindowButtonsWithTheSidebarKeyShown(_ width: Int) async throws {
        let (_, column) = try await world(width: CGFloat(width), button: true)
        let helm = try #require(views(of: HelmView.self, in: column).first)

        #expect(span(helm, in: column).min >= Metrics.helmLights)
        #expect(near(span(helm, in: column).max, column.bounds.width - SideGrid.edge - SideGrid.tail))
    }

    @Test func theTopKeysStandOverTheAddressKeys() async throws {
        let (_, column) = try await world()
        let helm = try #require(views(of: HelmView.self, in: column).first)
        let doors = try #require(views(of: AddressDoorsView.self, in: column).first { !$0.isHiddenOrHasHiddenAncestor })
        let above = keys(in: helm, column).suffix(2)
        let below = keys(in: doors, column).suffix(2)

        #expect(above.count == 2)
        #expect(below.count == 2)
        for (top, under) in zip(above, below) {
            #expect(near(top.min, under.min))
            #expect(near(top.max, under.max))
        }
    }

    @Test func aSplitPairsChipsNestInTheirRow() async throws {
        let (_, column) = try await world()
        let item = try #require(views(of: SplitTabItemView.self, in: column).first)
        let chips = views(of: SplitChipView.self, in: item).sorted { $0.frame.minX < $1.frame.minX }
        let first = try #require(chips.first)
        let second = try #require(chips.last)

        #expect(chips.count == 2)
        #expect(near(first.frame.minX, first.frame.minY))
        #expect(near(first.frame.minX, SideGrid.pad))
        #expect(near(second.frame.minX - first.frame.maxX, SideGrid.pad))
        #expect(near(item.bounds.width - second.frame.maxX, SideGrid.pad))
    }

    @Test func whatAGlassCardEndsWithKeepsTheRowsLead() {
        #expect(MiniPlayerView.keysEnd == SideGrid.lead)
        #expect(UpdateCardView.pad == SideGrid.lead)
    }

    private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.5 }

    private func span(_ view: NSView, in column: NSView) -> (min: CGFloat, mid: CGFloat, max: CGFloat) {
        let box = view.convert(view.bounds, to: column)
        return (box.minX, box.midX, box.maxX)
    }

    private func views<V: NSView>(of type: V.Type, in view: NSView?) -> [V] {
        guard let view else { return [] }
        return view.subviews.flatMap { (($0 as? V).map { [$0] } ?? []) + views(of: type, in: $0) }
    }

    private func rows(in column: NSView) -> [TabRowView] {
        views(of: TabRowView.self, in: column).filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 }
    }

    private func leading(_ row: TabRowView, in column: NSView) throws -> CGFloat {
        let marks = views(of: NSView.self, in: row).filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width == SideGrid.mark }
        return try #require(marks.map { span($0, in: column).min }.min())
    }

    private func keys(in host: NSView, _ column: NSView) -> [(min: CGFloat, mid: CGFloat, max: CGFloat)] {
        host.subviews.filter { !$0.isHidden && $0.frame.width == SideGrid.key && $0.alphaValue > 0 }
            .map { span($0, in: column) }.sorted { $0.mid < $1.mid }
    }

    private func world(width: CGFloat = 272, button: Bool = false) async throws -> (Browser, NSView) {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        if restorePreferences == nil {
            let previous = (prefs.splitView, prefs.usesSpaces, prefs.sideWidth, prefs.sideButton)
            restorePreferences = {
                (prefs.splitView, prefs.usesSpaces, prefs.sideWidth, prefs.sideButton) = previous
            }
        }
        prefs.splitView = true
        prefs.usesSpaces = false
        prefs.sideWidth = width
        prefs.sideButton = button
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let space = Space(id: UUID(), name: "Side grid fixture", colour: 0, sharesSignIns: true)
        browser.spaces = [space]
        browser.spaceID = space.id
        browsers.append(browser)
        func open(_ name: String) -> Tab {
            browser.newTab()
            let tab = browser.tabs.last!
            tab.restore(url: URL(string: "https://example.com/\(name)")!, title: name)
            return tab
        }
        let filed = [open("first"), open("second")]
        let loose = open("loose")
        let pair = [open("left"), open("right")]
        let folder = browser.addTabGroup(containing: filed[0], pinned: false)
        browser.move(filed[1], toGroup: folder)
        browser.renameTabGroup(folder, to: "Design")
        let deeper = open("deeper")
        let nested = browser.addTabGroup(containing: deeper, inside: folder)
        browser.renameTabGroup(nested, to: "Nested")
        browser.editingGroupID = nil
        browser.pair(pair[1], with: pair[0], onLeft: false)
        browser.select(loose)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        let column = SideColumnView(browser: browser)
        window.contentView = column
        window.orderFrontRegardless()
        windows.append(window)
        for _ in 0..<8 {
            column.layoutSubtreeIfNeeded()
            column.displayIfNeeded()
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        return (browser, column)
    }
}
