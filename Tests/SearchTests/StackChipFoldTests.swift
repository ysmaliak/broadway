import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class StackChipFoldTests {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?
    private var live: [UUID] = []

    init() {
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.closeAll() }
        for id in live { LiveFolders.shared.remove(id) }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
    }

    enum Place: String, CaseIterable, Sendable { case middle, first, last }
    enum Turn: String, CaseIterable, Sendable { case fold, unfold, foldBack, unfoldBack }

    struct Case: Sendable, CustomTestStringConvertible {
        var place: Place = .middle
        var turn: Turn
        var stackFolded = false
        var pinned = true
        var front = false
        var width: CGFloat = 258
        var reduced = false
        var testDescription: String {
            "\(turn) \(place)\(stackFolded ? " folded stack" : "")\(pinned ? "" : " unpinned")\(front ? " front" : "") \(Int(width))"
                + (reduced ? " reduced" : "")
        }
    }

    nonisolated static let cases: [Case] = Turn.allCases.map { Case(turn: $0) }
        + [Case(place: .first, turn: .fold), Case(place: .first, turn: .unfold),
           Case(place: .last, turn: .fold), Case(place: .last, turn: .unfold),
           Case(turn: .fold, stackFolded: true), Case(turn: .unfold, stackFolded: true), Case(turn: .foldBack, stackFolded: true),
           Case(turn: .fold, pinned: false), Case(turn: .unfold, pinned: false),
           Case(turn: .fold, front: true), Case(turn: .unfold, front: true),
           Case(turn: .fold, width: 340), Case(turn: .unfold, width: 210),
           Case(turn: .fold, reduced: true), Case(turn: .unfold, reduced: true)]

    @Test(arguments: cases)
    func theStackChipStaysOnItsRowsIconThroughAFold(_ made: Case) throws {
        let (browser, folder, window, top, rest) = try scene(made)
        let root = try #require(window.contentView)

        var seen: [(ms: Double, offset: CGPoint, chip: Double, row: Double)] = []
        let began = CACurrentMediaTime()
        browser.toggleTabGroup(folder)
        root.layoutSubtreeIfNeeded()
        var turned = false
        while CACurrentMediaTime() - began < 0.6 {
            CATransaction.flush()
            let ms = (CACurrentMediaTime() - began) * 1000
            if !turned, ms > 80, made.turn == .foldBack || made.turn == .unfoldBack {
                turned = true
                browser.toggleTabGroup(folder)
                root.layoutSubtreeIfNeeded()
                CATransaction.flush()
            }
            for chip in placed(top, in: root) where chip.alpha > 0.02 {
                seen.append((ms, chip.offset, chip.alpha, chip.rowAlpha))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }

        if made.reduced {
            let after = placed(top, in: root)
            #expect(made.turn == .fold ? after.isEmpty : after.count == 1, "under Reduce Motion the fold lands at once")
        } else {
            #expect(seen.count > 20, "the chip was seen while the fold ran")
        }
        let off = seen.filter { abs($0.offset.x - rest.offset.x) > 0.5 || abs($0.offset.y - rest.offset.y) > 0.5 }
        #expect(off.isEmpty, "the chip parts from its icon: \(off.prefix(6).map { "\(Int($0.ms)) ms \($0.offset)" }), rest \(rest.offset)")
        let faded = seen.filter { abs($0.chip - $0.row) > 0.04 }
        #expect(faded.isEmpty, "the chip fades apart from its row: \(faded.prefix(6).map { "\(Int($0.ms)) ms \($0.chip) vs \($0.row)" })")
    }

    @Test func theChipIsPartOfItsRowAndStillTakesThePressAndReadsAsFoldStack() throws {
        let (browser, folder, window, top, _) = try scene(Case(turn: .fold))
        let root = try #require(window.contentView)
        let row = try #require(all(TabRowView.self, in: root).first { $0.tab?.id == top && !($0.superview is SideFoldClip) })
        let chip = try #require(all(StackFoldButton.self, in: root).first)
        let middle = chip.convert(NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil)

        let hit = root.superview?.hitTest(middle)
        let label = chip.accessibilityLabel()
        let pressed = chip.accessibilityPerformPress()
        settle(window)

        #expect(chip.isDescendant(of: row), "drawn in the row")
        #expect(hit === chip, "the chip takes the press before the row")
        #expect(label == "Fold Stack")
        #expect(row.accessibilityChildren()?.contains { ($0 as AnyObject) === chip } == true, "VoiceOver reaches the chip from its row")
        #expect(chip.accessibilityRole() == .button && chip.isAccessibilityElement())
        #expect(pressed)
        #expect(browser.tabGroups.first { $0.id == folder }?.foldedStacks.isEmpty == false)
        #expect(chip.accessibilityLabel() == "Unfold Stack")
    }

    @Test func aRowThatStaysFadesItsChipInAndOut() throws {
        let (_, _, window, top, _) = try scene(Case(turn: .fold))
        let root = try #require(window.contentView)
        let row = try #require(all(TabRowView.self, in: root).first { $0.tab?.id == top })
        StackFoldButton.dress(row, nil, lit: false, fades: false)

        StackFoldButton.dress(row, StackFoldButton.Dress(folded: false) {}, lit: false, fades: true)
        let arriving = try #require(StackFoldButton.on(row))
        let fadeIn = arriving.layer?.animation(forKey: "chip.opacity") as? CABasicAnimation
        StackFoldButton.dress(row, nil, lit: false, fades: true)
        let fadeOut = arriving.layer?.animation(forKey: "chip.opacity") as? CABasicAnimation

        #expect((fadeIn?.fromValue as? NSNumber)?.floatValue == 0)
        #expect((fadeOut?.toValue as? NSNumber)?.floatValue == 0)
        #expect(arriving.superview === row, "it stays until its fade ends")
    }

    private func placed(_ top: UUID, in root: NSView) -> [(offset: CGPoint, alpha: Double, rowAlpha: Double)] {
        guard let base = root.layer else { return [] }
        let tops = all(TabRowView.self, in: root).filter { $0.tab?.id == top || $0.tab == nil }
        let marks = tops.compactMap { row -> (NSView, CGRect, Double)? in
            guard let mark = all(RowMarkView.self, in: row).first(where: { !$0.isHidden }), let rect = shown(mark, in: base) else { return nil }
            return (row, rect, alpha(row))
        }
        return all(StackFoldButton.self, in: root).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { chip in
            guard let rect = shown(chip, in: base) else { return nil }
            let mark = marks.min { distance($0.1, rect) < distance($1.1, rect) }
            guard let mark else { return (CGPoint(x: 9999, y: 9999), alpha(chip), 0) }
            return (CGPoint(x: rect.midX - mark.1.minX, y: rect.midY - mark.1.minY), alpha(chip), mark.2)
        }
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.minX - b.minX, a.minY - b.minY)
    }

    private func shown(_ view: NSView, in base: CALayer) -> CGRect? {
        guard let layer = view.layer else { return nil }
        let drawn = layer.presentation() ?? layer
        let top = base.presentation() ?? base
        return drawn.convert(drawn.bounds, to: top)
    }

    private func alpha(_ view: NSView) -> Double {
        var value = 1.0
        var layer = view.layer
        while let at = layer {
            value *= Double((at.presentation() ?? at).opacity)
            layer = at.superlayer
        }
        return value
    }

    private func scene(_ made: Case) throws -> (Browser, UUID, NSWindow, UUID, (offset: CGPoint, alpha: Double, rowAlpha: Double)) {
        keepSettings("motion.testReduced")
        if made.reduced { Store.settings.set(true, forKey: "motion.testReduced") }
        let browser = makeBrowser(width: made.width)
        let tabs = browser.tabs
        keepSetting(browser.prefs, \.liveFolders, "live.on")
        browser.prefs.liveFolders = true
        let source = LiveSource(kind: .feed, address: "https://example.com/stack-\(UUID().uuidString).xml")
        let folder = LiveFolders.shared.add(name: "PRs", source: source, space: browser.spaceID)
        live.append(folder.id)
        let stacked = [3, 2, 1].map { position in
            LiveItem(key: "https://example.com/pr/\(10 + position)", title: "Stacked \(position)", author: "octo",
                     stack: LiveStack(position: position, count: 3),
                     branch: LiveBranch(repository: "acme/rocket", base: "b\(position - 1)", head: "b\(position)"))
        }
        let loose = (1...2).map { LiveItem(key: "https://example.com/pr/\($0)", title: "Loose \($0)", author: "dana") }
        let items: [LiveItem] = switch made.place {
        case .middle: [loose[0]] + stacked + [loose[1]]
        case .first: stacked + loose
        case .last: loose + stacked
        }
        LiveFolders.shared.apply(.items(items, nil), to: folder.id)
        browser.syncLive()
        let id = folder.id
        if let index = browser.tabGroups.firstIndex(where: { $0.id == id }) { browser.tabGroups[index].pinned = made.pinned }
        if browser.tabGroups.first(where: { $0.id == id })?.collapsed == true { browser.toggleTabGroup(id) }
        let group = try #require(browser.tabGroups.first { $0.id == id })
        let top = try #require(browser.stackTops(in: group).keys.first, "the folder holds a stack")
        if made.stackFolded { browser.toggleStack(top, in: id) }
        browser.editingGroupID = nil
        browser.select(made.front ? try #require(browser.tabs.first { $0.id == top }) : tabs[0])
        let window = makeWindow(browser)
        settle(window)
        let content = try #require(window.contentView)
        let rest = try #require(placed(top, in: content).first, "the chip rests on its row")
        #expect(rest.alpha > 0.99 && rest.rowAlpha > 0.99)
        if made.turn == .unfold || made.turn == .unfoldBack {
            browser.toggleTabGroup(id)
            settle(window)
        }
        return (browser, id, window, top, rest)
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

    private func makeBrowser(width: CGFloat) -> Browser {
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
        prefs.sideWidth = width
        prefs.newTabPlace = .end
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let space = Space(id: UUID(), name: "Stack chip fixture", colour: 0, sharesSignIns: true)
        browser.spaces = [space]
        browser.spaceID = space.id
        browsers.append(browser)
        for index in 0..<3 {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "about:blank#row-\(index)")!, title: "row \(index)")
        }
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SideColumnView(browser: browser)
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }
}
