import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SettingsMeasureTests {
    private var everywhere: [SettingsPlace] {
        SettingsPage.blocks.flatMap { $0 }.map { SettingsPlace(page: $0, detail: nil, folder: nil, space: nil) }
            + SettingsDetail.allCases.map { SettingsPlace(page: $0.page, detail: $0, folder: nil, space: nil) }
    }

    private func name(_ place: SettingsPlace) -> String {
        place.detail.map { place.page.rawValue + "/" + $0.rawValue } ?? place.page.rawValue
    }

    private func walk(_ shell: SettingsShell, to place: SettingsPlace, rule: UUID) {
        shell.query = ""
        shell.go(to: place.page)
        switch place.detail {
        case nil: break
        case .linkRule: shell.openLinkRule(rule)
        case .liveFolder: shell.openLiveFolder(UUID())
        case .languages: shell.openLanguages(space: nil)
        case let detail?: shell.drill(detail)
        }
    }

    private func standing(_ size: NSSize) throws -> (Browser, UUID, SettingsFrame, SettingsSplit) {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let rule = LinkRules.shared.add(LinkRule(match: .site("example.com"), target: .window(nil)))
        let window = SettingsWindow.frame(browser, asked: "general")
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.setContentSize(size)
        return (browser, rule.id, window, try #require(window.contentViewController as? SettingsSplit))
    }

    private func close(_ browser: Browser, _ rule: UUID, _ window: SettingsFrame) {
        LinkRules.shared.remove(rule)
        window.contentViewController = nil
        window.close()
        browser.closeAll()
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(120))
        window.layoutIfNeeded()
    }

    private func off(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > 0.5 }

    @Test(arguments: [SettingsSize.opening.width, SettingsSize.minimum.width])
    func everyPageKeepsOneLeftEdgeOneRightEdgeAndControlsCentredInTheirRows(width: CGFloat) async throws {
        let languages = LanguagePrefs.shared.chosen
        LanguagePrefs.shared.chosen = ["en-US", "fr-FR"]
        defer { LanguagePrefs.shared.chosen = languages }
        let (browser, rule, window, split) = try standing(NSSize(width: width, height: SettingsSize.opening.height))
        defer { close(browser, rule, window) }
        let page = split.page
        func box(_ view: NSView) -> NSRect { view.convert(view.bounds, to: page) }
        let left = SettingsMetrics.margin + SettingsMetrics.inset
        var wrong: [String] = []
        var rows = 0

        for at in everywhere {
            walk(split.shell, to: at, rule: rule)
            try await settle(window)
            let here = name(at)
            let right = page.bounds.width - SettingsMetrics.margin - SettingsMetrics.inset
            for heading in page.kitSubviews(of: SettingsHeading.self) where !heading.isHiddenOrHasHiddenAncestor {
                guard let label = heading.subviews.first as? NSTextField else { continue }
                if off(box(label).minX + 2, left) { wrong.append("\(here): heading \(label.stringValue) starts at \(box(label).minX)") }
            }
            for footer in page.kitSubviews(of: SettingsFooter.self) where !footer.isHiddenOrHasHiddenAncestor {
                if off(box(footer.words).minX, left) { wrong.append("\(here): a footer starts at \(box(footer.words).minX)") }
            }
            for card in page.cards where !card.isHiddenOrHasHiddenAncestor {
                let sides = box(card)
                if off(sides.minX, SettingsMetrics.margin) || off(sides.maxX, page.bounds.width - SettingsMetrics.margin) {
                    wrong.append("\(here): a card spans \(sides.minX) to \(sides.maxX)")
                }
                for case let row as SettingsRowView in card.rows {
                    rows += 1
                    let id = row.rowID
                    let frame = box(row)
                    let words = box(row.title).minX + 2
                    if let icon = row.icon {
                        if off(box(icon).minX, left) { wrong.append("\(here) \(id): the icon starts at \(box(icon).minX)") }
                        if off(words, box(icon).maxX + SettingsMetrics.gap) { wrong.append("\(here) \(id): the title starts at \(words)") }
                    } else if off(words, left) {
                        wrong.append("\(here) \(id): the title starts at \(words)")
                    }
                    for info in row.kitSubviews(of: NSButton.self) where info.accessibilityLabel()?.hasPrefix("More about") == true {
                        let glyph = box(info)
                        if glyph.size != NSSize(width: 14, height: 14) || off(glyph.minX - box(row.title).maxX, 3) || off(glyph.midY, box(row.title).midY) {
                            wrong.append("\(here) \(id): the info glyph is \(glyph) beside \(box(row.title))")
                        }
                    }
                    for pill in row.kitSubviews(of: SettingsPill.self) where !pill.isHiddenOrHasHiddenAncestor && off(box(pill).height, 28) {
                        wrong.append("\(here) \(id): a button is \(box(pill).height) tall")
                    }
                    guard let control = row.control, !(control is SettingsPictureChoice), !control.isHiddenOrHasHiddenAncestor else { continue }
                    let held = box(control)
                    let spare = control is SettingsPopUp ? SettingsPopUp.spare : 0
                    if off(held.maxX - spare, right) { wrong.append("\(here) \(id): \(type(of: control)) ends at \(held.maxX - spare), not \(right)") }
                    if !(control is SettingsPopUp), off(held.midY, frame.midY) {
                        wrong.append("\(here) \(id): \(type(of: control)) sits at \(held.midY - frame.minY) in a row \(frame.height) tall")
                    }
                    if let toggle = control as? KitSwitch, let native = toggle.native, toggle.frame.size != native.intrinsicContentSize {
                        wrong.append("\(here) \(id): the switch is \(toggle.frame.size) around a drawn \(native.intrinsicContentSize)")
                    }
                }
            }
        }

        #expect(rows >= 74)
        #expect(wrong == [])
    }

    @Test func everyPageKeepsOneRhythmBetweenHeadingsCardsAndFooters() async throws {
        let (browser, rule, window, split) = try standing(SettingsSize.opening)
        defer { close(browser, rule, window) }
        let page = split.page
        func box(_ view: NSView) -> NSRect { view.convert(view.bounds, to: page) }
        var wrong: [String] = []
        var gaps = 0

        for at in everywhere {
            walk(split.shell, to: at, rule: rule)
            try await settle(window)
            let here = name(at)
            for (above, below) in zip(page.blocks, page.blocks.dropFirst()) {
                guard let content = above.subviews.first, !content.isHidden else { continue }
                if box(below).minY < box(content).maxY - 0.5 { wrong.append("\(here): a block covers the foot of the \(type(of: content)) above it") }
            }
            var parts: [(kind: String, frame: NSRect)] = []
            for heading in page.kitSubviews(of: SettingsHeading.self) where !heading.isHiddenOrHasHiddenAncestor {
                if let label = heading.subviews.first { parts.append(("heading", box(label))) }
            }
            for footer in page.kitSubviews(of: SettingsFooter.self) where !footer.isHiddenOrHasHiddenAncestor { parts.append(("footer", box(footer))) }
            for card in page.cards where !card.isHiddenOrHasHiddenAncestor { parts.append(("card", box(card))) }
            parts.sort { $0.frame.minY < $1.frame.minY }
            for (above, below) in zip(parts, parts.dropFirst()) {
                let wanted: CGFloat
                switch (above.kind, below.kind) {
                case ("heading", "card"): wanted = SettingsMetrics.headingGap
                case ("card", "footer"): wanted = SettingsMetrics.footerGap
                case ("footer", _): wanted = SettingsMetrics.footerAfter
                case ("card", _): wanted = SettingsMetrics.sectionGap
                default: continue
                }
                gaps += 1
                let gap = below.frame.minY - above.frame.maxY
                if off(gap, wanted) { wrong.append("\(here): \(gap) from a \(above.kind) at \(above.frame.minY) to the \(below.kind) under it, not \(wanted)") }
            }
        }

        #expect(gaps > 60)
        #expect(wrong == [])
    }

    @Test func theSpaceUnderTheDescriptionIsTheSameOnEveryPageAndNoMoreThanTheTitleKeepsFromThePicture() async throws {
        let (browser, rule, window, split) = try standing(SettingsSize.opening)
        defer { close(browser, rule, window) }
        let page = split.page
        var wrong: [String] = []
        var under: [CGFloat: [String]] = [:]

        for at in everywhere {
            walk(split.shell, to: at, rule: rule)
            try await settle(window)
            let here = name(at)
            let parts = page.kitSubviews(of: SettingsHeading.self) as [NSView] + page.cards
            guard let top = parts.filter({ !$0.isHiddenOrHasHiddenAncestor }).map({ $0.convert($0.bounds, to: nil).maxY }).max() else { continue }
            if SettingsStageMap.pictured(at) {
                let band = split.pane.band
                let foot = band.bounds.maxY - band.summary.frame.maxY
                let line = band.bounds.maxY - (band.summary.frame.maxY - band.summary.lastBaselineOffsetFromBottom)
                let cap = band.title.frame.minY + band.title.firstBaselineOffsetFromTop - (band.title.font?.capHeight ?? 0) - band.picture.frame.maxY
                if split.pane.compact { wrong.append("\(here): the short header at the opening size") }
                if off(foot, SettingsStageLook.foot) { wrong.append("\(here): \(foot) under the description") }
                if line > cap { wrong.append("\(here): \(line) from the description's baseline to the line, \(cap) from the picture to the title") }
                under[(band.convert(band.summary.frame, to: nil).minY - top).rounded(), default: []].append(here)
            } else if let head = page.heading {
                under[(head.summary.convert(head.summary.bounds, to: nil).minY - top).rounded(), default: []].append(here)
            } else {
                wrong.append("\(here): no header")
            }
        }

        #expect(wrong == [])
        #expect(under.keys.sorted() == [SettingsHead.below], "\(under)")
        #expect(SettingsStageLook.foot + SettingsStageLook.under == SettingsHead.below)
    }

    @Test func theSidebarsRowsShareOneHeightOneIconColumnAndOneTitleEdgeAndTheSearchFieldIsCentredOverThem() async throws {
        let (browser, rule, window, split) = try standing(SettingsSize.opening)
        defer { close(browser, rule, window) }
        try await settle(window)
        let table = split.rail.table
        let rail = split.rail.view.convert(split.rail.view.bounds, to: nil)
        let field = split.search.field.convert(split.search.field.bounds, to: nil)
        var heights: Set<CGFloat> = []
        var tiles: Set<CGFloat> = []
        var titles: Set<CGFloat> = []
        var wrong: [String] = []

        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? SettingsRailCell,
                  let tile = cell.subviews.first(where: { $0 is SettingsTile }), let icon = cell.imageView, let title = cell.textField else { continue }
            let box = tile.convert(tile.bounds, to: nil)
            let glyph = icon.convert(icon.bounds, to: nil)
            heights.insert(cell.frame.height)
            tiles.insert(box.minX)
            titles.insert(title.convert(title.bounds, to: nil).minX)
            if box.size != NSSize(width: SettingsRail.tile, height: SettingsRail.tile) { wrong.append("\(title.stringValue): a tile of \(box.size)") }
            if abs(glyph.midX - box.midX) > 1 || abs(glyph.midY - box.midY) > 1 { wrong.append("\(title.stringValue): the icon is off its tile's centre") }
            if off(cell.convert(cell.bounds, to: nil).midY, box.midY) { wrong.append("\(title.stringValue): the tile is off the row's centre") }
        }

        #expect(heights == [30])
        #expect(tiles.count == 1)
        #expect(titles.count == 1)
        #expect(wrong == [])
        #expect(field.minX - rail.minX == rail.maxX - field.maxX)
    }

    @Test func theShortHeaderKeepsNoMoreUnderItsTitleThanAboveIt() async throws {
        let (browser, rule, window, split) = try standing(NSSize(width: SettingsSize.opening.width, height: SettingsSize.minimum.height))
        defer { close(browser, rule, window) }

        walk(split.shell, to: SettingsPlace(page: .tabs, detail: nil, folder: nil, space: nil), rule: rule)
        try await settle(window)
        let band = split.pane.band

        #expect(split.pane.compact)
        #expect(band.summary.isHidden)
        #expect(band.bounds.maxY - band.title.frame.maxY == SettingsStageLook.smallFoot)
        #expect(band.bounds.maxY - band.title.frame.maxY <= band.title.frame.minY - band.picture.frame.maxY)
    }
}
