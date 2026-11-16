import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)), .serialized)
@MainActor
final class FolderShapeTests {
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

    @Test func theTokensNestInsideTheCard() {
        #expect(SideLook.cardRowRadius == SideLook.cardRadius - SideLook.cardPad)
        #expect(Metrics.folderPad == SideLook.cardPad)
        #expect(Metrics.folderRadius == SideLook.cardRadius)
        #expect(Metrics.pageRadius == 11)
    }

    enum Shape: String, CaseIterable, Sendable {
        case open, selectedFirst, selectedLast, heading, folded, renamed, dropTarget
    }

    @Test(arguments: Shape.allCases)
    func everyShapeInACardIsConcentricWithIt(_ shape: Shape) throws {
        let (browser, folder, window, members) = try scene()
        let root = try #require(window.contentView)
        let page = try #require(all(SidePageView.self, in: root).first)

        switch shape {
        case .open: browser.select(browser.tabs[0])
        case .selectedFirst: browser.select(try #require(browser.tabs.first { $0.id == members.first }))
        case .selectedLast: browser.select(try #require(browser.tabs.first { $0.id == members.last }))
        case .heading: page.benchFolder(folder, look: "hover")
        case .folded: browser.toggleTabGroup(folder); settle(window); page.benchFolder(folder, look: "hover")
        case .renamed: browser.editingGroupID = folder
        case .dropTarget: page.benchFolder(folder, look: "drop")
        }
        settle(window)

        let heading = try #require(all(GroupHeadingView.self, in: page).first { $0.group?.id == folder })
        let card = try #require(plate(behind: heading))
        let outer = card.convert(card.bounds, to: page)
        let radius = card.radius
        #expect(radius == SideLook.cardRadius)
        let shown = card.fill?.opacity ?? 0
        let lifted = ![KitGreys.white.card.opacity, KitGreys.frame.card.opacity].contains { abs($0 - shown) < 0.001 }
        #expect(lifted == (shape == .dropTarget), "\(shape): the card's fill lifts only for a drop")
        if shape == .heading || shape == .folded {
            let light = try #require(all(FolderLightView.self, in: page).first { $0.lit })
            let box = light.convert(light.bounds, to: page)
            let hair = 1 / max(1, window.backingScaleFactor)
            let inset = shape == .heading ? Metrics.folderPad : card.fill == nil ? 0 : hair
            let wanted = shape == .heading ? SideLook.cardRowRadius : Metrics.folderRadius - inset
            #expect(abs(box.minX - outer.minX - inset) <= 0.01 && abs(outer.maxX - box.maxX - inset) <= 0.01, "\(shape): light \(box) in card \(outer)")
            #expect(abs(box.minY - outer.minY - inset) <= 0.01, "\(shape): light \(box) in card \(outer)")
            if shape == .folded { #expect(abs(outer.maxY - box.maxY - inset) <= 0.01, "shut, the light is the card's box: \(box) \(outer)") }
            #expect(abs(light.radius - wanted) <= 0.01, "\(shape): light radius \(light.radius), not \(wanted)")
            #expect(abs(light.radius - (radius - inset)) <= 0.5, "\(shape): the light is concentric with the card")
        }
        var nested: [(String, KitPlate)] = grounds(in: heading).map { ("heading", $0) }
        for row in all(TabRowView.self, in: page) where row.tab.map({ members.contains($0.id) }) == true {
            nested += grounds(in: row).map { ("row \(row.tab?.title ?? "")", $0) }
        }
        #expect(nested.count >= (shape == .folded ? 1 : 4), "\(shape): the card's shapes were found")
        let wells = all(KitPlate.self, in: heading).filter { !$0.isHidden && $0.fill != nil && $0.radius == SideLook.fieldRadius }
        #expect(wells.count == (shape == .renamed ? 1 : 0), "\(shape): the rename well shows only while renaming")
        nested += wells.map { ("rename well", $0) }
        var shared = 0
        for (name, inner) in nested where !inner.isHidden && inner.bounds.width > 0 {
            let box = inner.convert(inner.bounds, to: page)
            if name != "rename well" { #expect(abs(inner.radius - SideLook.cardRowRadius) <= 0.5, "\(shape) \(name): radius \(inner.radius)") }
            for (dx, dy) in insets(box, in: outer) where dx < radius && dy < radius {
                shared += 1
                let wanted = radius - max(dx, dy)
                #expect(abs(inner.radius - wanted) <= 0.5, "\(shape) \(name): a corner \(dx), \(dy) in has radius \(inner.radius), not \(wanted)")
            }
        }
        #expect(shared > 0, "\(shape): some shape shares a corner with the card")
        if shape == .dropTarget {
            let outline = try #require(all(KitPlate.self, in: page).first { !$0.isHidden && $0.stroke != nil && $0.fill == nil && $0.strokeWidth > 1 })
            let box = outline.convert(outline.bounds, to: page)
            #expect(abs(box.minX - outer.minX) <= 0.5 && abs(box.width - outer.width) <= 0.5, "the drop outline is the card")
            #expect(abs(outline.radius - radius) <= 0.5, "the drop outline keeps the card's radius")
        }
    }

    @Test(arguments: [false, true])
    func theChevronStaysOnHoverUnlessTheCloseWouldCoverIt(_ long: Bool) throws {
        let (browser, folder, window, _) = try scene()
        let root = try #require(window.contentView)
        let page = try #require(all(SidePageView.self, in: root).first)
        if long { browser.renameTabGroup(folder, to: String(repeating: "A very long folder name ", count: 4)) }
        settle(window)

        page.benchFolder(folder, look: "hover")
        settle(window)

        let heading = try #require(all(GroupHeadingView.self, in: page).first { $0.group?.id == folder })
        let chevron = try #require(all(KitTurnView.self, in: heading).first)
        let close = try #require(all(CloseSpotView.self, in: heading).first { !$0.isHidden })
        let covered = chevron.frame.maxX > close.frame.minX - 2
        #expect(chevron.alphaValue == (covered ? 0 : 1), "long \(long): the chevron shows unless the close covers it")
        #expect(!long || chevron.frame.maxX <= heading.bounds.maxX - 10 + 0.5, "the name truncates before the chevron leaves the heading")
    }

    private func grounds(in view: NSView) -> [KitPlate] {
        all(KitPlate.self, in: view).filter { plate in
            let box = plate.convert(plate.bounds, to: view)
            return box.width >= view.bounds.width * 0.8 && box.height >= view.bounds.height - 1
        }
    }

    private func insets(_ inner: NSRect, in outer: NSRect) -> [(CGFloat, CGFloat)] {
        let left = inner.minX - outer.minX, right = outer.maxX - inner.maxX
        let top = inner.minY - outer.minY, bottom = outer.maxY - inner.maxY
        return [(left, top), (right, top), (left, bottom), (right, bottom)].map { (max(0, $0), max(0, $1)) }
    }

    enum Change: String, CaseIterable, Sendable {
        case add, remove, create, ungroup
    }

    struct Sample {
        var time: CFTimeInterval
        var top: CGFloat?
        var bottom: CGFloat?
        var below: CGFloat?
    }

    @Test(arguments: Change.allCases)
    func theCardAndTheRowsBelowMoveOnOneCurve(_ change: Change) throws {
        let (browser, folder, window, _) = try scene()
        let root = try #require(window.contentView)
        let tabs = browser.tabs
        let belowTab = switch change {
        case .add, .remove: tabs[5]
        case .create: tabs[7]
        case .ungroup: tabs[6]
        }
        var card = all(GroupHeadingView.self, in: root).first { $0.group?.id == folder }.flatMap(plate(behind:))
        let before = sample(card, below: belowTab, in: window)

        switch change {
        case .add: browser.move(tabs[7], toGroup: folder)
        case .remove: browser.closeTab(tabs[2])
        case .create:
            let made = browser.addTabGroup(containing: tabs[6])
            browser.editingGroupID = nil
            root.layoutSubtreeIfNeeded()
            card = all(GroupHeadingView.self, in: root).first { $0.group?.id == made }.flatMap(plate(behind:))
        case .ungroup: browser.removeTabGroup(folder)
        }
        root.layoutSubtreeIfNeeded()
        var samples: [Sample] = []
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < 0.7 {
            samples.append(sample(card, below: belowTab, in: window))
            let mark = CACurrentMediaTime()
            while CACurrentMediaTime() - mark < 0.0015 {}
            RunLoop.current.run(until: Date().addingTimeInterval(0.0005))
        }
        let after = sample(card, below: belowTab, in: window)
        if let folder = ProcessInfo.processInfo.environment["FOLDER_TRACE_DIR"] {
            let rows = samples.map { [($0.time - start) * 1000, $0.top ?? -1, $0.bottom ?? -1, $0.below ?? -1].map { ($0 * 100).rounded() / 100 } }
            let data = try JSONSerialization.data(withJSONObject: ["columns": ["ms", "cardTop", "cardBottom", "rowBelowTop"], "rows": rows])
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(change).json"))
        }

        #expect(samples.count > 100, "\(change): sampled \(samples.count) times")
        #expect(card != nil, "\(change): the card was found")
        let moved = abs((after.below ?? 0) - (before.below ?? 0))
        #expect(moved > 10, "\(change): the row below moved (\(moved))")
        for (key, path) in [("top", \Sample.top), ("bottom", \Sample.bottom), ("below", \Sample.below)] as [(String, KeyPath<Sample, CGFloat?>)] {
            let seen = samples.compactMap { sample in sample[keyPath: path].map { (sample.time, $0) } }
            if key != "top" { #expect(seen.count > (change == .ungroup && key == "bottom" ? 30 : 100), "\(change): \(key) was sampled") }
            for (a, b) in zip(seen, seen.dropFirst()) {
                let lag = b.0 - a.0
                let room = 1.5 + 700 * lag
                #expect(abs(b.1 - a.1) <= room, "\(change): \(key) jumped \(b.1 - a.1) in \(lag * 1000) ms")
            }
            if key != "top", let first = seen.first?.1, let was = key == "below" ? before.below : before.bottom,
               !(change == .create && key == "bottom") {
                #expect(abs(first - was) <= 2, "\(change): \(key) started at \(first), not where it was shown (\(was))")
            }
        }
        if change == .create, let first = samples.first(where: { $0.top != nil }), let top = first.top, let bottom = first.bottom {
            #expect(bottom - top <= Metrics.sideRowHeight + 4, "create: the card first showed \(bottom - top) tall, not the founding row's height")
        }
        let gaps = samples.compactMap { sample in sample.bottom.flatMap { bottom in sample.below.map { $0 - bottom } } }
        if let first = gaps.first, let last = gaps.last {
            let low = min(first, last) - 1.5, high = max(first, last) + 1.5
            let strays = gaps.filter { $0 < low || $0 > high }
            #expect(strays.isEmpty, "\(change): the gap under the card left \(first)…\(last): \(strays.prefix(6))")
        }
    }

    private func sample(_ card: KitPlate?, below tab: Tab, in window: NSWindow) -> Sample {
        CATransaction.flush()
        var made = Sample(time: CACurrentMediaTime())
        guard let root = window.contentView, let base = root.layer.map({ $0.presentation() ?? $0 }) else { return made }
        if let card, card.superview != nil, let layer = card.layer {
            let shown = layer.presentation() ?? layer
            if shown.opacity > 0.02 {
                let box = shown.convert(shown.bounds, to: base)
                made.top = box.minY
                made.bottom = box.maxY
            }
        }
        if let row = all(TabRowView.self, in: root).first(where: { $0.tab?.id == tab.id }), let layer = row.layer {
            let shown = layer.presentation() ?? layer
            made.below = shown.convert(shown.bounds, to: base).minY
        }
        return made
    }

    private func scene() throws -> (Browser, UUID, NSWindow, [UUID]) {
        let browser = makeBrowser(count: 8)
        let tabs = browser.tabs
        let folder = browser.addTabGroup(containing: tabs[1])
        browser.editingGroupID = nil
        for tab in tabs[2...4] { browser.move(tab, toGroup: folder) }
        let window = makeWindow(browser)
        settle(window)
        return (browser, folder, window, Array(tabs[1...4].map(\.id)))
    }

    private func plate(behind heading: GroupHeadingView) -> KitPlate? {
        guard let parent = heading.superview else { return nil }
        return parent.subviews.compactMap { $0 as? KitPlate }
            .filter { $0.frame.minY <= heading.frame.minY && $0.frame.maxY >= heading.frame.maxY && $0.frame.minX <= heading.frame.minX }
            .min { $0.frame.height < $1.frame.height }
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { sub -> [T] in ((sub as? T).map { [$0] } ?? []) + all(type, in: sub) }
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
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
        prefs.usesTabGroups = true
        prefs.splitView = false
        prefs.usesSpaces = false
        prefs.sharesPins = false
        prefs.addressBar = true
        prefs.sideWidth = 258
        prefs.newTabPlace = .end
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let space = Space(id: UUID(), name: "Folder shape fixture", colour: 0, sharesSignIns: true)
        browser.spaces = [space]
        browser.spaceID = space.id
        browsers.append(browser)
        for index in 0..<count {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "about:blank#row-\(index)")!, title: "row \(index)")
        }
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SideColumnView(browser: browser)
        window.orderFrontRegardless()
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }
}
