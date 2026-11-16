import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SplitChipLookTests {
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

    @Test(arguments: ["aqua", "darkAqua"])
    func onlyTheFocusedPaneWearsTheSelectedLook(_ look: String) async throws {
        let (browser, window, _, pair) = try await world(look)
        let item = try item(in: window)

        for (focused, other) in [(pair[0], pair[1]), (pair[1], pair[0])] {
            browser.select(pair[0])
            browser.focusPane(focused)
            try await settle(window)

            let lit = try chip(focused, in: item)
            let unlit = try chip(other, in: item)
            #expect(browser.activeID == focused.id)
            #expect(item.chips.filter(\.shown).count == 1, "\(look)")
            #expect(lit.shown, "\(look)")
            expectDressed(lit.slab, item: item, look)
            #expect(lit.fill.fill == nil, "\(look)")
            #expect(!unlit.shown, "\(look)")
            #expect(unlit.fill.fill == nil, "\(look)")
        }
    }

    @Test(arguments: ["aqua", "darkAqua"])
    func theOtherPaneReadsLikeAnUnselectedRow(_ look: String) async throws {
        let (browser, window, loose, pair) = try await world(look)
        let item = try item(in: window)
        browser.select(loose)
        try await settle(window)
        #expect(!item.rest.isHidden, "\(look)")

        browser.select(pair[0])
        browser.focusPane(pair[0])
        try await settle(window)

        #expect(item.rest.isHidden, "\(look)")
        #expect(try chip(pair[1], in: item).fill.fill == nil, "\(look)")
        #expect(!(try chip(pair[1], in: item).shown), "\(look)")
    }

    @Test(arguments: ["aqua", "darkAqua"])
    func theOtherPaneStillLightsUnderThePointer(_ look: String) async throws {
        let (browser, window, _, pair) = try await world(look)
        let item = try item(in: window)
        browser.select(pair[0])
        browser.focusPane(pair[0])
        try await settle(window)
        let other = try chip(pair[1], in: item)

        other.benchPillHover(true)
        try await settle(window)

        let greys = SplitGreys(onFrame: item.setup.onFrame, ink: item.setup.ink, dark: other.kitDark)
        #expect(other.fill.fill == greys.hover, "\(look)")
        #expect(!other.shown, "\(look)")
        #expect(try chip(pair[0], in: item).shown, "\(look)")
        other.benchPillHover(false)
        try await settle(window)
        #expect(other.fill.fill == nil, "\(look)")
    }

    @Test(arguments: ["aqua", "darkAqua"])
    func aPickedPaneWearsThePickedGreyAndTheFocusedOneKeepsItsLook(_ look: String) async throws {
        let (browser, window, _, pair) = try await world(look)
        let item = try item(in: window)
        browser.select(pair[0])
        browser.focusPane(pair[0])
        try await settle(window)

        browser.extendTabSelection(to: pair[1], modifiers: .command)
        try await settle(window)

        let picked = try chip(pair[1], in: item)
        let greys = SplitGreys(onFrame: item.setup.onFrame, ink: item.setup.ink, dark: picked.kitDark)
        #expect(picked.fill.fill == greys.picked, "\(look)")
        #expect(!picked.shown, "\(look)")
        #expect(try chip(pair[0], in: item).shown, "\(look)")
        #expect(try chip(pair[0], in: item).fill.fill == nil, "\(look)")
        browser.clearTabSelection()
    }

    @Test(arguments: ["aqua", "darkAqua"])
    func aPairNotInFrontWearsNoSelectedLook(_ look: String) async throws {
        let (browser, window, loose, pair) = try await world(look)
        let item = try item(in: window)
        browser.select(pair[0])
        try await settle(window)

        browser.select(loose)
        try await settle(window)

        #expect(item.chips.allSatisfy { !$0.shown }, "\(look)")
        #expect(item.chips.allSatisfy { $0.fill.fill == nil }, "\(look)")
        #expect(!item.rest.isHidden, "\(look)")
    }

    private func expectDressed(_ plate: KitPlate, item: SplitTabItemView, _ look: String) {
        let reference = KitPlate(radius: plate.radius)
        SelectedLook.dress(reference, greys: item.setup.greys, ink: item.setup.ink)
        #expect(plate.fill == reference.fill, "\(look)")
        #expect(plate.stroke == reference.stroke, "\(look)")
        #expect(plate.lift == SelectedLook.shadow, "\(look)")
    }

    private func item(in window: NSWindow) throws -> SplitTabItemView {
        try #require(views(of: SplitSignView.self, in: window.contentView).first).item
    }

    private func chip(_ tab: Tab, in item: SplitTabItemView) throws -> SplitChipView {
        try #require(item.chips.first { $0.tab === tab })
    }

    private func views<V: NSView>(of type: V.Type, in view: NSView?) -> [V] {
        guard let view else { return [] }
        return view.subviews.flatMap { ($0 as? V).map { [$0] } ?? [] + views(of: type, in: $0) }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    private func world(_ look: String) async throws -> (Browser, NSWindow, Tab, [Tab]) {
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
        prefs.usesTabGroups = false
        prefs.splitView = true
        prefs.usesSpaces = false
        prefs.addressBar = true
        prefs.sideWidth = 258
        prefs.newTabPlace = .end
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let space = Space(id: UUID(), name: "Split chip fixture", colour: 0, sharesSignIns: true)
        browser.spaces = [space]
        browser.spaceID = space.id
        browsers.append(browser)
        func open(_ name: String) -> Tab {
            browser.newTab()
            let tab = browser.tabs.last!
            tab.restore(url: URL(string: "about:blank#\(name)")!, title: name)
            return tab
        }
        let loose = open("loose")
        let pair = [open("left"), open("right")]
        browser.pair(pair[1], with: pair[0], onLeft: false)
        browser.select(loose)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: look == "darkAqua" ? .darkAqua : .aqua)
        window.contentView = SideColumnView(browser: browser)
        window.orderFrontRegardless()
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        try await settle(window)
        return (browser, window, loose, pair)
    }
}

private extension SplitChipView {
    var shown: Bool { !slab.isHidden && (slab.layer?.opacity ?? 0) > 0.5 }
}
