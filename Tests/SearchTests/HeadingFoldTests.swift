import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class HeadingFoldTests {
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

    enum Place: String, CaseIterable, Sendable {
        case top, nested, pinned, between
    }

    @Test(arguments: Place.allCases)
    func theHeadingTitleStaysPutThroughAFoldAndAnUnfold(place: Place) throws {
        let browser = makeBrowser(count: place == .between ? 30 : 6)
        let tabs = browser.tabs
        let first = place == .between ? 6 : 1
        let outer = browser.addTabGroup(containing: tabs[first], pinned: place == .pinned)
        browser.move(tabs[first + 1], toGroup: outer)
        let folder = place == .nested ? browser.addTabGroup(containing: tabs[first + 1], inside: outer) : outer
        let window = makeWindow(browser)
        settle(window)
        if place == .between { try scroll(in: window, to: 40.37) }
        let start = try #require(title(of: folder, in: window))

        for _ in 0..<2 {
            browser.toggleTabGroup(folder)
            var seen: [NSRect] = []
            let end = Date().addingTimeInterval(0.9)
            while Date() < end {
                RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 120))
                window.displayIfNeeded()
                CATransaction.flush()
                if let frame = title(of: folder, in: window) { seen.append(frame) }
            }
            settle(window)

            #expect(!seen.isEmpty)
            let moved = seen.filter { abs($0.minY - start.minY) > 0.01 || abs($0.minX - start.minX) > 0.01 }
            #expect(moved.isEmpty, "\(place): the title moved to \(moved.map(\.minY).prefix(8)) from \(start.minY)")
            #expect(title(of: folder, in: window) == start)
        }
    }

    @Test func whenAFoldGivesTheScrollBackTheTitleRidesItsCardInOneMotion() throws {
        let browser = makeBrowser(count: 30)
        let tabs = browser.tabs
        let folder = browser.addTabGroup(containing: tabs[24])
        for tab in tabs[25...28] { browser.move(tab, toGroup: folder) }
        let window = makeWindow(browser)
        settle(window)
        try scroll(in: window, to: nil)
        let start = try #require(title(of: folder, in: window))
        let card = try #require(plate(of: folder, in: window))
        let inset = start.minY - card.minY

        let list = try #require(longestScroll(in: window))
        let tall = list.documentView?.frame.height ?? 0
        browser.toggleTabGroup(folder)
        let deadline = Date().addingTimeInterval(0.5)
        while (list.documentView?.frame.height ?? 0) >= tall, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        let given = list.documentView?.layer?.animationKeys()?.compactMap { list.documentView?.layer?.animation(forKey: $0) as? CAPropertyAnimation } ?? []
        let atEnd = list.contentView.bounds.minY
        var seen: [(title: NSRect, card: NSRect)] = []
        let end = Date().addingTimeInterval(0.9)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 120))
            window.displayIfNeeded()
            CATransaction.flush()
            if let frame = title(of: folder, in: window), let box = plate(of: folder, in: window) { seen.append((frame, box)) }
        }
        settle(window)

        let rest = try #require(title(of: folder, in: window))
        let ys = [start.minY] + seen.map(\.title.minY) + [rest.minY]
        let travel = rest.minY - start.minY
        #expect(abs(travel) > 1, "the scroll was given back")
        #expect(seen.allSatisfy { abs($0.title.minY - $0.card.minY - inset) < 0.01 }, "the title never moves on its card")
        #expect(zip(ys, ys.dropFirst()).allSatisfy { ($1 - $0) * travel >= -0.01 }, "one way only: \(ys.prefix(12))")
        #expect(zip(ys, ys.dropFirst()).allSatisfy { abs($1 - $0) <= abs(travel) * 0.25 }, "no jump: \(ys.prefix(12))")
        #expect(seen.map(\.title.minX).allSatisfy { $0 == start.minX })
        #expect((list.documentView?.frame.height ?? tall) < tall, "the fold shrank the list")
        #expect(abs(atEnd - (list.documentView.map { $0.frame.height - list.contentView.bounds.height } ?? -1)) < 0.5,
                "the list is at its new end in the fold's own pass")
        let curve = Motion.kitSettle.animation("position", from: nil, to: nil)
        #expect(given.contains { $0.keyPath == "position" && $0.isAdditive && type(of: $0) == curve.map { type(of: $0) }
                && $0.duration == curve?.duration }, "the give-back rides the rows' curve on Core Animation: \(given)")
    }

    private func longestScroll(in window: NSWindow) -> NSScrollView? {
        guard let root = window.contentView else { return nil }
        return scrollViews(in: root).filter { !$0.isHiddenOrHasHiddenAncestor }.max { $0.frame.height < $1.frame.height }
    }

    private func plate(of folder: UUID, in window: NSWindow) -> NSRect? {
        guard let root = window.contentView,
              let heading = headings(in: root).first(where: { $0.group?.id == folder && !$0.isHiddenOrHasHiddenAncestor }),
              let parent = heading.superview, let top = root.layer else { return nil }
        let card = parent.subviews.compactMap { $0 as? KitPlate }
            .filter { $0.frame.contains(NSPoint(x: heading.frame.midX, y: heading.frame.midY)) }
            .min { $0.frame.height < $1.frame.height }
        guard let layer = card?.layer else { return nil }
        let shown = layer.presentation() ?? layer
        let base = top.presentation() ?? top
        return shown.convert(shown.bounds, to: base)
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
    }

    private func headings(in view: NSView) -> [GroupHeadingView] {
        view.subviews.flatMap { ($0 as? GroupHeadingView).map { [$0] } ?? [] + headings(in: $0) }
    }

    private func labels(in view: NSView) -> [KitLabel] {
        view.subviews.flatMap { ($0 as? KitLabel).map { [$0] } ?? [] + labels(in: $0) }
    }

    private func title(of folder: UUID, in window: NSWindow) -> NSRect? {
        guard let root = window.contentView,
              let heading = headings(in: root).first(where: { $0.group?.id == folder && !$0.isHiddenOrHasHiddenAncestor }),
              let name = labels(in: heading).first(where: { $0.text == heading.group?.name }),
              let layer = name.layer, let top = root.layer else { return nil }
        let shown = layer.presentation() ?? layer
        let base = top.presentation() ?? top
        return shown.convert(shown.bounds, to: base)
    }

    private func scroll(in window: NSWindow, to offset: CGFloat?) throws {
        guard let root = window.contentView else { return }
        let scrolls = scrollViews(in: root).filter { !$0.isHiddenOrHasHiddenAncestor }
        let scroll = try #require(scrolls.max { $0.frame.height < $1.frame.height })
        let clip = scroll.contentView
        let bottom = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: offset ?? bottom))
        scroll.reflectScrolledClipView(clip)
        settle(window)
        #expect(clip.bounds.minY > 0, "the list scrolls")
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { ($0 as? NSScrollView).map { [$0] } ?? [] + scrollViews(in: $0) }
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
        let space = Space(id: UUID(), name: "Heading fixture", colour: 0, sharesSignIns: true)
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
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SideColumnView(browser: browser)
        window.orderFrontRegardless()
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }
}
