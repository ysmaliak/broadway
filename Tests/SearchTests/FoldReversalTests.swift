import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FoldReversalTests {
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

    struct Sample {
        var time: CFTimeInterval
        var values: [String: CGFloat]
        var copies: Int
    }

    enum Start: String, CaseIterable, Sendable {
        case open, shut, hovered, hoveredShut, kept
    }

    @Test(arguments: [CGFloat(0.1), 0.5, 0.9], Start.allCases)
    func aFoldReversedInFlightCarriesOnFromWhereItIs(at progress: CGFloat, from start: Start) throws {
        let (browser, folder, window, members) = try scene(start)

        let samples = try run(browser, folder, window, members, reversals: [progress])

        try check(samples, reversals: 1, label: "\(start) reversed at \(progress)")
        if [.hovered, .hoveredShut, .kept].contains(start) {
            let lit = samples.joined().compactMap { $0.values["light.opacity"] }
            #expect(lit.count > 20 && lit.allSatisfy { $0 > 0.9 }, "\(start): the light stays lit through the reversal")
        }
    }

    @Test func aDoubleReversalCarriesOnTwice() throws {
        let (browser, folder, window, members) = try scene(.kept)

        let samples = try run(browser, folder, window, members, reversals: [0.5, 0.5])

        try check(samples, reversals: 2, label: "double")
    }

    private func check(_ runs: [[Sample]], reversals: Int, label: String) throws {
        #expect(runs.count == reversals + 1)
        let start = try #require(runs.first?.first).values, end = try #require(runs.last?.last).values
        let omega = CGFloat(KitSpring.cover.omega)
        var kept = 0
        for (index, seam) in zip(runs, runs.dropFirst()).enumerated() {
            let (before, after) = seam
            let target = index % 2 == 0 ? start : end
            let last = try #require(before.last), previous = try #require(before.dropLast().last)
            let first = try #require(after.first), next = try #require(after.dropFirst().first)
            for key in last.values.keys.sorted() {
                guard let a = previous.values[key], let b = last.values[key], let c = first.values[key], let d = next.values[key] else { continue }
                let speed = (b - a) / CGFloat(max(last.time - previous.time, 1.0 / 1000))
                let gap = c - b
                let lag = CGFloat(first.time - last.time)
                let pull = target[key].map { 0.5 * omega * omega * abs($0 - b) * lag * lag } ?? 0
                let room = abs(speed) * lag * 1.6 + pull + tolerance(key)
                #expect(abs(gap) <= room, "\(label) #\(index): \(key) jumped \(gap) in \(lag * 1000) ms at the reversal (moving \(speed)/s)")
                guard let goal = target[key], abs(goal - b) > tolerance(key), (goal - b) * speed < 0 else { continue }
                let away = abs(speed) / abs(goal - b)
                let turning = away / (omega * (omega + away))
                let clock = key == "glyph" ? last.time : first.time
                guard turning > 0.004 + CGFloat(next.time - clock) else { continue }
                let after = (d - c) / CGFloat(max(next.time - first.time, 1.0 / 1000))
                kept += 1
                #expect(after * speed > 0, "\(label) #\(index): \(key) turned at once (\(speed)/s then \(after)/s; a spring that kept its speed turns after \(turning * 1000) ms)")
            }
        }
        if reversals > 0, label.contains("0.5") || label == "double" { #expect(kept > 0, "\(label): no reversal was fast enough to check its speed") }
        for (index, run) in runs.enumerated() {
            #expect(run.allSatisfy { $0.copies <= 1 }, "\(label) run \(index): a row was drawn twice: \(run.map(\.copies))")
            for key in ["row.opacity"] {
                let seen = run.compactMap { $0.values[key] }
                let rising = zip(seen, seen.dropFirst()).map { $1 - $0 }
                let turns = zip(rising, rising.dropFirst()).filter { $0 < -0.02 && $1 > 0.02 }.count
                #expect(turns == 0, "\(label) run \(index): \(key) dipped and came back: \(seen.prefix(16))")
            }
        }
    }

    private func tolerance(_ key: String) -> CGFloat {
        key.hasSuffix("opacity") ? 0.08 : key == "chevron" ? 0.05 : key == "glyph" ? 0.08 : key == "light.radius" ? 0.3
            : key == "light.tone" ? 0.03 : 0.75
    }

    private func scene(_ start: Start) throws -> (Browser, UUID, NSWindow, [UUID]) {
        let browser = makeBrowser(count: 8)
        let tabs = browser.tabs
        let folder = browser.addTabGroup(containing: tabs[1])
        for tab in tabs[2...4] { browser.move(tab, toGroup: folder) }
        browser.editingGroupID = nil
        if start == .kept { browser.select(tabs[3]) }
        let window = makeWindow(browser)
        settle(window)
        if start == .shut || start == .hoveredShut {
            browser.toggleTabGroup(folder)
            settle(window)
        }
        if start != .open && start != .shut, let root = window.contentView, let page = all(SidePageView.self, in: root).first {
            page.benchFolder(folder, look: "hover")
            settle(window)
        }
        return (browser, folder, window, Array(tabs[1...4].map(\.id)))
    }

    private func run(_ browser: Browser, _ folder: UUID, _ window: NSWindow, _ members: [UUID], reversals: [CGFloat]) throws -> [[Sample]] {
        var runs: [[Sample]] = []
        var current: [Sample] = []
        let spring = KitSpring.cover
        let model = try #require(cardModel(folder, in: window))
        browser.toggleTabGroup(folder)
        try waitForChange(from: model, folder, window)
        var started = CACurrentMediaTime()
        for progress in reversals {
            let at = spring.time(toReach: Double(progress))
            while CACurrentMediaTime() - started < at {
                current.append(sample(folder, window, members))
                RunLoop.current.run(until: Date().addingTimeInterval(0.002))
            }
            current.append(contentsOf: pair(folder, window, members))
            runs.append(current)
            current = []
            let shown = try #require(cardModel(folder, in: window))
            browser.toggleTabGroup(folder)
            try waitForChange(from: shown, folder, window)
            started = CACurrentMediaTime()
            current.append(contentsOf: pair(folder, window, members))
        }
        let end = Date().addingTimeInterval(0.6)
        while Date() < end {
            current.append(sample(folder, window, members))
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
        runs.append(current)
        settle(window)
        return runs
    }

    private func pair(_ folder: UUID, _ window: NSWindow, _ members: [UUID]) -> [Sample] {
        let first = sample(folder, window, members)
        while CACurrentMediaTime() - first.time < 0.0015 {}
        return [first, sample(folder, window, members)]
    }

    private func waitForChange(from frame: NSRect, _ folder: UUID, _ window: NSWindow) throws {
        let deadline = Date().addingTimeInterval(0.5)
        while cardModel(folder, in: window) == frame, Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if cardModel(folder, in: window) != frame { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        CATransaction.flush()
        #expect(cardModel(folder, in: window) != frame, "the fold laid out")
    }

    private func sample(_ folder: UUID, _ window: NSWindow, _ members: [UUID]) -> Sample {
        CATransaction.flush()
        let time = CACurrentMediaTime()
        var values: [String: CGFloat] = [:]
        guard let root = window.contentView, let top = root.layer else { return Sample(time: time, values: values, copies: 0) }
        let base = top.presentation() ?? top
        func shown(_ view: NSView) -> (CALayer, NSRect)? {
            guard let layer = view.layer else { return nil }
            let presented = layer.presentation() ?? layer
            return (presented, presented.convert(presented.bounds, to: base))
        }
        if let heading = all(GroupHeadingView.self, in: root).first(where: { $0.group?.id == folder }) {
            if let card = plate(behind: heading), let box = shown(card)?.1 {
                values["card.height"] = box.height
                values["card.top"] = box.minY
            }
            if let turn = all(KitTurnView.self, in: heading).first, let layer = turn.layer {
                let m = (layer.presentation() ?? layer).sublayerTransform
                values["chevron"] = atan2(m.m12, m.m11)
            }
            if let glyph = all(FolderGlyphView.self, in: heading).first,
               let shape = glyph.layer?.sublayers?.dropFirst().first as? CAShapeLayer, let path = (shape.presentation() ?? shape).path {
                var moves: [CGPoint] = []
                path.applyWithBlock { element in
                    if element.pointee.type == .moveToPoint { moves.append(element.pointee.points[0]) }
                }
                if let start = moves.first { values["glyph"] = start.y }
            }
            if let layer = heading.chipFold.layer, !heading.chipFold.isHidden {
                values["chip.opacity"] = CGFloat((layer.presentation() ?? layer).opacity)
            }
        }
        if let light = all(FolderLightView.self, in: root).first, light.lit, let found = shown(light) {
            let (layer, box) = found
            values["light.top"] = box.minY
            values["light.left"] = box.minX
            values["light.width"] = box.width
            values["light.height"] = box.height
            values["light.radius"] = layer.cornerRadius
            values["light.tone"] = layer.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }.map(\.alphaComponent)
            values["light.opacity"] = CGFloat(layer.opacity)
        }
        let everyRow = all(TabRowView.self, in: root).filter { !$0.isHiddenOrHasHiddenAncestor }
        let rows = everyRow.filter { $0.tab != nil }
        let ghosts = everyRow.filter { $0.tab == nil && $0.superview is SideFoldClip }.compactMap { view -> NSRect? in
            guard let found = shown(view) else { return nil }
            var opacity = found.0.opacity
            var parent = found.0.superlayer
            while let up = parent { opacity *= up.opacity; parent = up.superlayer }
            return opacity > 0.02 ? found.1 : nil
        }
        var copies = 0
        for id in members {
            let drawn = rows.filter { $0.tab?.id == id }.compactMap { view -> (Swift.Float, NSRect)? in
                guard let found = shown(view) else { return nil }
                let (layer, box) = found
                var opacity = layer.opacity
                var parent = layer.superlayer
                while let up = parent { opacity *= up.opacity; parent = up.superlayer }
                guard opacity > 0.02 else { return nil }
                return (opacity, box)
            }
            let over = ghosts.filter { ghost in drawn.contains { $0.1.insetBy(dx: 0, dy: 1).intersects(ghost) } }.count
            copies = max(copies, drawn.count + over)
            if id == members[1], let best = drawn.max(by: { $0.0 < $1.0 }) {
                values["row.top"] = best.1.minY
                values["row.opacity"] = CGFloat(best.0)
            }
        }
        if let below = rows.first(where: { $0.tab?.id == browsers.last?.tabs[6].id }), let box = shown(below)?.1 {
            values["below.top"] = box.minY
        }
        return Sample(time: time, values: values, copies: copies)
    }

    private func cardModel(_ folder: UUID, in window: NSWindow) -> NSRect? {
        guard let root = window.contentView,
              let heading = all(GroupHeadingView.self, in: root).first(where: { $0.group?.id == folder }) else { return nil }
        return plate(behind: heading)?.frame
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
        var still = 0
        for _ in 0..<6 where still < 2 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            still = moving(window.contentView?.layer) ? 0 : still + 1
        }
    }

    private func moving(_ layer: CALayer?) -> Bool {
        guard let layer else { return false }
        if layer.animationKeys()?.isEmpty == false { return true }
        return layer.sublayers?.contains { moving($0) } ?? false
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
        let space = Space(id: UUID(), name: "Reversal fixture", colour: 0, sharesSignIns: true)
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
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }
}
