import AppKit
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SideChromeTests {
    init() {
        _ = NSApplication.shared
    }

    private func row(in browser: Browser, width: CGFloat) -> TabRowView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: false, configuration: configuration)
        tab.setAddressOptimistically(URL(string: "https://example.com/")!)
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.sideRowHeight))
        var state = RowState()
        state.live = true
        row.show(tab, in: browser, state: state)
        row.layoutSubtreeIfNeeded()
        return row
    }

    private func grid(in browser: Browser, width: CGFloat) throws -> (icon: CGFloat, words: CGFloat) {
        let row = row(in: browser, width: width)
        let mark = try #require(row.kitSubviews(of: RowMarkView.self).first { !$0.isHidden })
        let title = try #require(row.kitSubviews(of: RowTitleView.self).first)
        return (mark.convert(mark.bounds, to: row).midX, title.convert(title.bounds, to: row).minX)
    }

    private final class ScaledWindow: NSWindow {
        var scale: CGFloat = 2
        override var backingScaleFactor: CGFloat { scale }
    }

    private func window(_ size: NSSize, scale: CGFloat?) -> NSWindow {
        let rect = NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height)
        guard let scale else { return NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false) }
        let made = ScaledWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        made.scale = scale
        return made
    }

    private func ink(in view: NSView, _ region: NSRect, unit: Int) throws -> NSRect {
        let wide = Int(ceil(view.bounds.width)) * unit, high = Int(ceil(view.bounds.height)) * unit
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32))
        rep.size = NSSize(width: CGFloat(wide) / CGFloat(unit), height: CGFloat(high) / CGFloat(unit))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try #require(rep.bitmapData)
        let step = CGFloat(unit)
        let left = max(0, Int((region.minX * step).rounded())), right = min(wide, Int((region.maxX * step).rounded()))
        let top = max(0, Int((region.minY * step).rounded())), bottom = min(high, Int((region.maxY * step).rounded()))
        var columns = [Int](repeating: 0, count: right - left), rows = [Int](repeating: 0, count: bottom - top)
        for y in top..<bottom {
            for x in left..<right {
                let alpha = Int(data[y * rep.bytesPerRow + x * 4 + 3])
                columns[x - left] = max(columns[x - left], alpha)
                rows[y - top] = max(rows[y - top], alpha)
            }
        }
        let across = try #require(KitGlyph.inkSpan(columns)), down = try #require(KitGlyph.inkSpan(rows))
        return NSRect(x: (CGFloat(left) + across.lowerBound) / step, y: (CGFloat(top) + down.lowerBound) / step,
                      width: (across.upperBound - across.lowerBound) / step, height: (down.upperBound - down.lowerBound) / step)
    }

    private func foot(_ browser: Browser, width: CGFloat = 258, scale: CGFloat? = nil) -> (SpaceFootView, NSWindow) {
        let window = window(NSSize(width: width, height: SpaceFootView.height), scale: scale)
        window.isReleasedWhenClosed = false
        browser.window = window
        let made = SpaceFootView(browser: browser)
        made.fetch = FetchDoorView(browser: browser, fetches: browser.fetches, always: true)
        window.contentView = made
        made.layoutSubtreeIfNeeded()
        return (made, window)
    }

    private func brightness(_ color: NSColor?) -> CGFloat {
        guard let color = color?.usingColorSpace(.sRGB) else { return -1 }
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    @Test func theSpaceTitleSitsOnTheTabRowsIconAndWords() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let width: CGFloat = 246
        let grid = try grid(in: browser, width: width)
        let kinds: [SpaceTitleLineView.Kind] = [
            .space(TabIcon(symbol: "house"), "Personal", muted: false),
            .space(TabIcon(emoji: "📚"), "Reading", muted: false),
            .privateWindow,
        ]

        for kind in kinds {
            let line = SpaceTitleLineView()
            line.kind = kind
            line.act = {}
            line.frame = NSRect(x: 0, y: 0, width: width, height: SpaceTitleSize.height)
            line.layoutSubtreeIfNeeded()
            let icon = try #require(line.subviews.first { ($0 is SpaceMarkView || $0 is KitSymbol) && !$0.isHidden })
            let name = try #require(line.subviews.compactMap { $0 as? KitLabel }.first { !$0.isHidden })

            #expect(abs(icon.frame.midX - grid.icon) <= 0.5, "\(kind)")
            #expect(abs(name.frame.minX - grid.words) <= 0.5, "\(kind)")
            #expect(abs(icon.frame.midY - name.frame.midY) <= 0.5, "\(kind)")
            #expect(line.chip.minX == 0 && line.chip.maxX > name.frame.maxX, "\(kind)")
        }
        #expect(SpaceTitleLineView.iconMiddle == grid.icon)
        #expect(SpaceTitleLineView.wordsStart == grid.words)
    }

    @Test func aStackedSpacesHeadingSitsOnTheSameIconAndWords() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let width: CGFloat = 246
        let grid = try grid(in: browser, width: width)
        let header = StackedHeaderView(browser: browser, folds: StackedFolds(), space: browser.space, count: 1)
        header.frame = NSRect(x: 0, y: 0, width: width, height: StackedHeaderView.height)

        header.layoutSubtreeIfNeeded()

        let icon = try #require(header.subviews.first { $0 is SpaceMarkView })
        let name = try #require(header.subviews.compactMap { $0 as? KitLabel }.first)
        #expect(abs(icon.frame.midX - grid.icon) <= 0.5)
        #expect(abs(name.frame.minX - grid.words) <= 0.5)
    }

    @Test func theFootsThreeThingsAreBigEnoughToPressAndSitOnTheRowsIconLine() throws {
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let previous = (prefs.usesSpaces, prefs.stackedSpaces)
        (prefs.usesSpaces, prefs.stackedSpaces) = (true, false)
        let width: CGFloat = 258
        let (view, window) = foot(browser, width: width)
        defer {
            window.contentView = nil
            window.close()
            browser.closeAll()
            (prefs.usesSpaces, prefs.stackedSpaces) = previous
        }
        let grid = try grid(in: browser, width: width - 2 * Metrics.sideInset)

        let downloads = try #require(view.kitSubviews(of: FetchDoorView.self).first)
        let plus = try #require(view.kitSubviews(of: DoorView.self).first)
        let spot = try #require(view.kitSubviews(of: SpaceSpotView.self).first)

        for frame in [downloads.frame, plus.frame, spot.frame] {
            #expect(frame.width >= 28 && frame.height >= 28)
            #expect(frame.midY == downloads.frame.midY)
            #expect(frame.maxY == view.bounds.maxY - SpaceFootView.below)
        }
        #expect(downloads.frame.midX == Metrics.sideInset + grid.icon)
        #expect(plus.frame.midX == width - Metrics.sideInset - grid.icon)
        #expect(abs(spot.frame.midX - width / 2) <= 0.5)
        #expect(downloads.intrinsicContentSize == NSSize(width: SpaceFootView.side, height: SpaceFootView.side))
        #expect(plus.intrinsicContentSize == NSSize(width: SpaceFootView.side, height: SpaceFootView.side))
        #expect(plus.size == SpaceFootView.glyph && downloads.glyph == SpaceFootView.glyph)
        #expect(plus.weight == IconLook.weight)
    }

    @Test func theFootsThreeGlyphsAreCentredInTheirPlatesByTheirInk() throws {
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let previous = (prefs.usesSpaces, prefs.stackedSpaces)
        (prefs.usesSpaces, prefs.stackedSpaces) = (true, false)
        defer {
            browser.closeAll()
            (prefs.usesSpaces, prefs.stackedSpaces) = previous
        }

        for (scale, within) in [(CGFloat(2), CGFloat(0.26)), (1, 0.51)] {
            let (view, window) = foot(browser, scale: scale)
            defer {
                window.contentView = nil
                window.close()
            }
            let downloads = try #require(view.kitSubviews(of: FetchDoorView.self).first)
            let plus = try #require(view.kitSubviews(of: DoorView.self).first)
            let spot = try #require(view.kitSubviews(of: SpaceSpotView.self).first)

            let grown = within * 1.08 + 0.05
            for (name, plate, within) in [("downloads", downloads.frame, within), ("plus", plus.frame, within), ("space", spot.frame, grown)] {
                let ink = try ink(in: view, plate, unit: Int(scale))

                #expect(plate.size == NSSize(width: SpaceFootView.side, height: SpaceFootView.side), "\(name) at \(scale)x")
                #expect(abs(ink.midX - plate.midX) <= within, "\(name) at \(scale)x \(ink) in \(plate)")
                #expect(abs(ink.midY - plate.midY) <= within, "\(name) at \(scale)x \(ink) in \(plate)")
            }
        }
    }

    @Test func aSpacesSymbolIsCentredInItsFootPlateByItsInk() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let side = SpaceFootView.side

        for (scale, within) in [(CGFloat(2), CGFloat(0.26)), (1, 0.51)] {
            for symbol in ["house", "briefcase", "book", "star", "gamecontroller", "square.dashed"] {
                let stage = KitFlippedView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
                let window = window(stage.frame.size, scale: scale)
                window.isReleasedWhenClosed = false
                defer {
                    window.contentView = nil
                    window.close()
                }
                let spot = SpaceSpotView(browser: browser, kind: .draft, icon: TabIcon(symbol: symbol), here: false, next: false)
                spot.frame = NSRect(x: 15, y: 17, width: side, height: side)
                stage.addSubview(spot)
                window.contentView = stage
                stage.layoutSubtreeIfNeeded()

                let ink = try ink(in: stage, spot.frame, unit: Int(scale))

                #expect(abs(ink.midX - spot.frame.midX) <= within, "\(symbol) at \(scale)x \(ink) in \(spot.frame)")
                #expect(abs(ink.midY - spot.frame.midY) <= within, "\(symbol) at \(scale)x \(ink) in \(spot.frame)")
            }
        }
    }

    @Test func everyDoorsGlyphIsCentredInItsPlateByItsInk() throws {
        let doors: [(icon: String, size: CGFloat, weight: NSFont.Weight, box: CGFloat)] = [
            ("plus", SpaceFootView.glyph, IconLook.weight, SpaceFootView.side),
            ("sidebar.left", 15, IconLook.control, 30),
            ("arrow.left", 15, IconLook.control, 30),
            ("arrow.right", 15, IconLook.control, 30),
            ("link", SideLook.doorSize, SideLook.doorWeight, AddressDoorsView.side),
            (SideLook.siteIcon, SideLook.doorSize, SideLook.doorWeight, AddressDoorsView.side),
            ("arrow.up.forward.square", 12, IconLook.control, 26),
            ("xmark", 12, IconLook.control, 26),
        ]

        for (scale, within) in [(CGFloat(2), CGFloat(0.26)), (1, 0.51)] {
            for made in doors {
                let stage = KitFlippedView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
                let window = window(stage.frame.size, scale: scale)
                window.isReleasedWhenClosed = false
                defer {
                    window.contentView = nil
                    window.close()
                }
                let door = DoorView(icon: made.icon, act: {})
                door.size = made.size
                door.weight = made.weight
                door.box = made.box
                door.frame = NSRect(x: 11, y: 13, width: made.box, height: made.box)
                stage.addSubview(door)
                window.contentView = stage
                stage.layoutSubtreeIfNeeded()
                let plate = try #require(door.kitSubviews(of: KitPlate.self).first)
                let square = plate.convert(plate.bounds, to: stage)

                let ink = try ink(in: stage, door.frame, unit: Int(scale))

                #expect(square == door.frame, "\(made.icon) at \(scale)x")
                #expect(abs(ink.midX - square.midX) <= within, "\(made.icon) at \(scale)x \(ink) in \(square)")
                #expect(abs(ink.midY - square.midY) <= within, "\(made.icon) at \(scale)x \(ink) in \(square)")
            }
        }
    }

    @Test func aDoorsGlyphStaysCentredWhenItsIconOrSizeChanges() throws {
        let stage = KitFlippedView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
        let window = window(stage.frame.size, scale: 2)
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        let door = DoorView(icon: "plus", act: {})
        door.box = 28
        door.frame = NSRect(x: 16, y: 16, width: 28, height: 28)
        stage.addSubview(door)
        window.contentView = stage
        stage.layoutSubtreeIfNeeded()

        for change in [{ door.size = 16 }, { door.weight = .bold }, { door.icon = "sidebar.left" }, { door.size = 13 }] {
            change()
            stage.layoutSubtreeIfNeeded()

            let ink = try ink(in: stage, door.frame, unit: 2)

            #expect(abs(ink.midX - door.frame.midX) <= 0.26, "\(door.icon) \(door.size) \(ink)")
            #expect(abs(ink.midY - door.frame.midY) <= 0.26, "\(door.icon) \(door.size) \(ink)")
        }
    }

    @Test func theColumnsFootIsAsTallAsItsButtonsAndTheGapUnderThem() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: 640), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        browser.window = window
        let column = SideColumnView(browser: browser)
        window.contentView = column
        column.layoutSubtreeIfNeeded()

        let foot = try #require(column.kitSubviews(of: SpaceFootView.self).first)
        let downloads = try #require(foot.kitSubviews(of: FetchDoorView.self).first)

        #expect(SpaceFootView.height == SpaceFootView.side + SpaceFootView.below)
        #expect(foot.frame.height == SpaceFootView.height)
        #expect(foot.frame.maxY == column.bounds.maxY)
        #expect(downloads.frame.size == NSSize(width: SpaceFootView.side, height: SpaceFootView.side))
        #expect(downloads.glyph == SpaceFootView.glyph)
    }

    @Test func aFootIconPointedAtKeepsTheSidebarsInkNotTheSystems() throws {
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let previous = (prefs.usesSpaces, prefs.stackedSpaces)
        (prefs.usesSpaces, prefs.stackedSpaces) = (true, false)
        let (view, window) = foot(browser)
        defer {
            KitHoverView.pointerStandIn = nil
            window.contentView = nil
            window.close()
            browser.closeAll()
            (prefs.usesSpaces, prefs.stackedSpaces) = previous
        }
        var seen: [(dark: Bool, pointed: CGFloat, left: CGFloat)] = []

        for dark in [true, false] {
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.ground = RowGround(greys: .frame, ink: KitInk(lift: dark ? 0.4 : 0.2), dark: dark)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            let spot = try #require(view.kitSubviews(of: SpaceSpotView.self).first)
            let symbol = try #require(spot.kitSubviews(of: KitSymbol.self).first { !$0.isHidden })
            let inside = spot.convert(NSPoint(x: spot.bounds.midX, y: spot.bounds.midY), to: nil)
            var pointed: CGFloat = -1
            var left: CGFloat = -1
            NSAppearance(named: dark ? .aqua : .darkAqua)?.performAsCurrentDrawingAppearance {
                KitHoverView.pointerStandIn = (window, inside)
                spot.settleHover()
                pointed = brightness(symbol.contentTintColor)
                KitHoverView.pointerStandIn = (window, NSPoint(x: -500, y: -500))
                spot.settleHover()
                left = brightness(symbol.contentTintColor)
            }
            seen.append((dark, pointed, left))
        }

        for (dark, pointed, left) in seen {
            #expect(dark ? pointed > 0.7 : pointed >= 0 && pointed < 0.3, "dark \(dark) pointed \(pointed)")
            #expect(dark ? left > 0.7 : left >= 0 && left < 0.3, "dark \(dark) left \(left)")
        }
    }

    @Test func aFootIconBetweenTwoSpacesIsMixedFromTheSidebarsOwnInks() {
        let ink = KitInk(lift: 0.5)

        let lit = SpaceSpotView.tint(lit: 1, ink: ink, dark: true)
        let rest = SpaceSpotView.tint(lit: 0, ink: ink, dark: true)
        let onDark = SpaceSpotView.tint(lit: 0.5, ink: ink, dark: true)
        let onLight = SpaceSpotView.tint(lit: 0.5, ink: ink, dark: false)

        #expect(lit === KitColor.ink)
        #expect(rest === KitColor.muted)
        #expect(brightness(onDark) > 0.7)
        #expect(brightness(onLight) < 0.3)
        #expect(onDark.alphaComponent > ink.color(KitColor.muted, .quiet, dark: true).alphaComponent)
        #expect(onDark.alphaComponent < 1)
    }

    @Test func everyInternalPagesGlyphIsOneSizeAndCentredInItsMark() throws {
        let side = InternalPage.glyphSide

        for kind in InternalPage.Kind.allCases {
            let page = InternalPage(kind)
            let glyph = try #require(page.glyph)
            let ink = KitGlyph.ink(of: glyph)

            #expect(glyph.size == NSSize(width: side, height: side), "\(kind)")
            #expect(glyph.isTemplate, "\(kind)")
            #expect(glyph.accessibilityDescription == page.title, "\(kind)")
            #expect(max(ink.width, ink.height) <= side, "\(kind) \(ink)")
            #expect(max(ink.width, ink.height) >= side - 2, "\(kind) \(ink)")
            #expect(abs(ink.midX - side / 2) <= 0.5 && abs(ink.midY - side / 2) <= 0.5, "\(kind) \(ink)")
            #expect(page.glyph === glyph, "\(kind)")
        }
        #expect(side + 2 == SideLook.rowMark)
    }
}
