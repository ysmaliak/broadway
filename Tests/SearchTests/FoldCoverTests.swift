import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FoldCoverTests {
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

    @Test func aFoldCoversItsRowsWhereTheyStand() throws {
        let (browser, folder, window, members) = try scene(shut: false)
        let root = try #require(window.contentView)
        let before = Dictionary(uniqueKeysWithValues: rows(members, in: root).map { ($0.key, $0.value.convert($0.value.bounds, to: nil)) })

        browser.toggleTabGroup(folder)
        root.layoutSubtreeIfNeeded()
        CATransaction.flush()

        let leaving = all(TabRowView.self, in: root).filter { $0.superview is SideFoldClip }
        #expect(leaving.count == members.count)
        for row in leaving {
            let box = row.convert(row.bounds, to: nil)
            #expect(before.values.contains { abs($0.minY - box.minY) < 0.5 }, "a covered row stays where it was")
            let move = try #require(row.layer?.animation(forKey: "retire.transform") as? CABasicAnimation)
            let end = try #require(move.toValue as? NSValue).caTransform3DValue
            #expect(CATransform3DIsIdentity(end), "no rise and no squash")
            let fade = try #require(row.layer?.animation(forKey: "retire.opacity") as? CASpringAnimation)
            #expect(abs(fade.settlingDuration - KitSpring.cover.animation("opacity", from: 1, to: 0).settlingDuration) < 0.001)
        }
        let below = try #require(all(TabRowView.self, in: root).first { $0.tab?.id == browser.tabs[6].id })
        let slide = try #require(below.layer?.animation(forKey: "position") as? CASpringAnimation)
        #expect(abs(slide.settlingDuration - KitSpring.cover.animation("position", from: 0, to: 1).settlingDuration) < 0.001,
                "the rows below ride the same spring")
    }

    @Test func anUnfoldUncoversItsRowsWhereTheyLand() throws {
        let (browser, folder, window, members) = try scene(shut: true)
        let root = try #require(window.contentView)

        browser.toggleTabGroup(folder)
        root.layoutSubtreeIfNeeded()
        CATransaction.flush()

        let shown = rows(members, in: root)
        #expect(shown.count == members.count)
        for (_, row) in shown {
            let layer = try #require(row.layer)
            #expect(layer.animation(forKey: "position") == nil, "an uncovered row does not travel")
            let mask = try #require(layer.mask, "each row is cut at the edge that uncovers it")
            #expect(mask.animation(forKey: "position") is CASpringAnimation)
            #expect(layer.animation(forKey: "enter.opacity") is CASpringAnimation)
        }
        let base = try #require(root.layer)
        let below = try #require(all(TabRowView.self, in: root).first { $0.tab?.id == browser.tabs[6].id })
        var seen = 0
        let end = Date().addingTimeInterval(0.35)
        while Date() < end {
            CATransaction.flush()
            let top = base.presentation() ?? base
            if let under = below.layer?.presentation() {
                let edge = under.convert(under.bounds, to: top)
                for (_, row) in shown {
                    guard let layer = row.layer?.presentation(), let mask = row.layer?.mask else { continue }
                    let cut = (mask.presentation() ?? mask).frame
                    let drawn = layer.convert(layer.bounds.intersection(cut), to: top)
                    guard !drawn.isEmpty, drawn.height > 0.5 else { continue }
                    seen += 1
                    #expect(!drawn.insetBy(dx: 0, dy: 1).intersects(edge), "a row shows under the rows that uncover it: \(drawn) \(edge)")
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
        #expect(seen > 20)
    }

    @Test func aFolderShutAroundItsFrontTabUncoversTheRestTheSameWay() throws {
        let (browser, folder, window, members) = try scene(shut: true, front: 2)
        let root = try #require(window.contentView)
        #expect(rows(members, in: root).count == 1, "shut, it keeps the tab in front")

        browser.toggleTabGroup(folder)
        root.layoutSubtreeIfNeeded()
        CATransaction.flush()

        let shown = rows(members, in: root)
        #expect(shown.count == members.count)
        let kept = try #require(shown[members[1]]?.layer?.animation(forKey: "position") as? CASpringAnimation)
        let keptTravel = try travel(kept)
        #expect(abs(abs(keptTravel) - pitch) < 0.5, "the kept row comes down one slot: \(keptTravel)")
        for id in [members[0]] + members.suffix(2) {
            let layer = try #require(shown[id]?.layer)
            #expect(layer.mask?.animation(forKey: "position") is CASpringAnimation, "every other row is uncovered where the card shows it")
            let slide = try #require(layer.animation(forKey: "position") as? CASpringAnimation, "the rows come down with the kept one")
            #expect(abs(try travel(slide) - keptTravel) < 0.5)
            #expect(abs(slide.settlingDuration - kept.settlingDuration) < 0.001)
        }
    }

    @Test(arguments: [1, 2, 3])
    func aFolderShutAroundItsFrontTabMovesItsRowsAsOneBlock(slot: Int) throws {
        let (browser, folder, window, members) = try scene(shut: false, front: 1 + slot)
        let root = try #require(window.contentView)
        let base = try #require(root.layer)
        let keptID = members[slot]

        browser.toggleTabGroup(folder)
        root.layoutSubtreeIfNeeded()
        CATransaction.flush()

        let kept = try #require(rows([keptID], in: root)[keptID])
        let slide = try #require(kept.layer?.animation(forKey: "position") as? CASpringAnimation)
        let keptTravel = try travel(slide)
        #expect(abs(abs(keptTravel) - CGFloat(slot) * pitch) < 0.5, "slot \(slot): the kept row goes up \(slot) rows: \(keptTravel)")
        let leaving = all(TabRowView.self, in: root).filter { $0.superview is SideFoldClip }
        #expect(leaving.count == members.count - 1)
        for row in leaving {
            let move = try #require(row.layer?.animation(forKey: "retire.transform") as? CASpringAnimation)
            let end = try #require(move.toValue as? NSValue).caTransform3DValue
            #expect(abs(abs(end.m42) - abs(keptTravel)) < 0.5, "slot \(slot): a leaving row moves with the kept one: \(end.m42)")
            #expect(abs(move.settlingDuration - KitSpring.cover.animation("transform", from: 0, to: 1).settlingDuration) < 0.001)
        }
        var seen = 0
        let stop = Date().addingTimeInterval(0.4)
        while Date() < stop {
            CATransaction.flush()
            let top = base.presentation() ?? base
            if let keptLayer = kept.layer?.presentation() {
                let keptBox = keptLayer.convert(keptLayer.bounds, to: top)
                for row in leaving {
                    guard let layer = row.layer?.presentation(), let clip = row.superview?.layer?.presentation(), layer.opacity > 0.02 else { continue }
                    let box = layer.convert(layer.bounds, to: top).intersection(clip.convert(clip.bounds, to: top))
                    guard !box.isEmpty, box.height > 0.5 else { continue }
                    seen += 1
                    #expect(!box.insetBy(dx: 0, dy: 0.5).intersects(keptBox), "slot \(slot): a leaving row lies over the kept one: \(box) \(keptBox)")
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
        #expect(seen > 20, "slot \(slot): leaving rows were seen \(seen) times")
    }

    enum Way: String, CaseIterable, Sendable {
        case fold, unfold
    }

    @Test(arguments: Way.allCases)
    func theHoverLightStaysOnTheHeadingThroughTheFold(_ way: Way) throws {
        let (browser, folder, window, _) = try scene(shut: way == .unfold)
        let root = try #require(window.contentView)
        let base = try #require(root.layer)
        let page = try #require(all(SidePageView.self, in: root).first)
        page.benchFolder(folder, look: "hover")
        settle(window)
        let heading = try #require(all(GroupHeadingView.self, in: page).first { $0.group?.id == folder })
        let light = try #require(all(FolderLightView.self, in: page).first)
        let shutHeight = GroupHeadingView.height + 2 * Metrics.folderPad

        browser.toggleTabGroup(folder)
        root.layoutSubtreeIfNeeded()
        CATransaction.flush()

        let card = try #require(plate(behind: heading))
        var insets: [CGFloat] = [], radii: [CGFloat] = [], heights: [CGFloat] = []
        let stop = Date().addingTimeInterval(0.45)
        while Date() < stop {
            CATransaction.flush()
            let top = base.presentation() ?? base
            if let shown = light.layer?.presentation(), let plate = card.layer?.presentation() {
                let box = shown.convert(shown.bounds, to: top)
                let outer = plate.convert(plate.bounds, to: top)
                #expect(shown.opacity > 0.9, "\(way): the light stays lit under the pointer")
                #expect(box.height >= GroupHeadingView.height - 0.5 && box.height <= shutHeight + 0.5, "\(way): light \(box.height) tall")
                insets.append(box.minX - outer.minX)
                radii.append(shown.cornerRadius)
                heights.append(box.height)
                let fill = card.fill?.opacity ?? 0
                #expect([0, KitGreys.white.card.opacity, KitGreys.frame.card.opacity].contains { abs($0 - fill) < 0.001 },
                        "\(way): the card's own fill is never lit by a hover")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
        #expect(insets.count > 40)
        for (name, values) in [("inset", insets), ("radius", radii), ("height", heights)] {
            let whole = (values.last ?? 0) - (values.first ?? 0)
            #expect(abs(whole) > 1, "\(way) \(name) moved: \(values.prefix(3)) … \(values.suffix(3))")
            let steps = zip(values, values.dropFirst()).map { $1 - $0 }
            #expect(steps.allSatisfy { $0 * whole >= -0.05 }, "\(way) \(name) moves one way: \(values)")
            #expect(steps.allSatisfy { abs($0) <= abs(whole) / 4 + 0.05 }, "\(way) \(name) steps: \(steps.map { abs($0) }.max() ?? 0) of \(whole)")
        }
        let open = way == .fold ? insets.first : insets.last
        let shut = way == .fold ? insets.last : insets.first
        let hair = 1 / window.backingScaleFactor
        #expect(abs((open ?? 0) - Metrics.folderPad) < 0.5 && abs(shut ?? 9) < hair + 0.25, "inset 3 open, a hair of \(hair) shut: \(insets)")
    }

    private var pitch: CGFloat { Shared.prefs.sideRow + Metrics.sideGap }

    private func travel(_ slide: CASpringAnimation) throws -> CGFloat {
        let from = try #require(slide.fromValue as? NSValue).pointValue
        let to = try #require(slide.toValue as? NSValue).pointValue
        return to.y - from.y
    }

    private func plate(behind heading: GroupHeadingView) -> KitPlate? {
        guard let parent = heading.superview else { return nil }
        return parent.subviews.compactMap { $0 as? KitPlate }
            .filter { $0.frame.minY <= heading.frame.minY && $0.frame.maxY >= heading.frame.maxY && $0.frame.minX <= heading.frame.minX }
            .min { $0.frame.height < $1.frame.height }
    }

    private func rows(_ members: [UUID], in root: NSView) -> [UUID: TabRowView] {
        var found: [UUID: TabRowView] = [:]
        for row in all(TabRowView.self, in: root) where !(row.superview is SideFoldClip) {
            if let id = row.tab?.id, members.contains(id) { found[id] = row }
        }
        return found
    }

    private func scene(shut: Bool, front: Int = 6) throws -> (Browser, UUID, NSWindow, [UUID]) {
        let browser = makeBrowser(count: 8)
        let tabs = browser.tabs
        let folder = browser.addTabGroup(containing: tabs[1])
        for tab in tabs[2...4] { browser.move(tab, toGroup: folder) }
        browser.editingGroupID = nil
        browser.select(tabs[front])
        let window = makeWindow(browser)
        settle(window)
        if shut {
            browser.toggleTabGroup(folder)
            settle(window)
        }
        return (browser, folder, window, Array(tabs[1...4].map(\.id)))
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
            let previous = (prefs.splitView, prefs.usesSpaces, prefs.sharesPins,
                            prefs.sideWidth)
            restorePreferences = {
                (prefs.splitView, prefs.usesSpaces, prefs.sharesPins,
                 prefs.sideWidth) = previous
            }
        }
        prefs.splitView = false
        prefs.usesSpaces = false
        prefs.sharesPins = false
        prefs.sideWidth = 258
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let space = Space(id: UUID(), name: "Cover fixture", colour: 0, sharesSignIns: true)
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
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SideColumnView(browser: browser)
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }
}
