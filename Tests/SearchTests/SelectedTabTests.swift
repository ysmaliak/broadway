import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SelectedTabTests {
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
    func everySelectedCaseIsDressedByTheOneBuilder(_ look: String) async throws {
        let (browser, window, tabs) = try await world(look)
        let page = try #require(views(of: SidePageView.self, in: window.contentView).first)

        var seen: [String] = []
        for (name, tab) in [("loose", tabs.loose[0]), ("card first", tabs.card[0]), ("card last", tabs.card[2])] {
            browser.select(tab)
            try await settle(window)
            let row = try #require(row(of: tab, in: page), "\(name)")
            expectDressed(row.liveGround, greys: row.state.ground.greys, ink: row.state.ground.ink, name,
                          radius: name == "loose" ? Metrics.sideRadius : SideLook.cardRowRadius)
            seen.append(name)
        }
        browser.select(tabs.pair[0])
        try await settle(window)
        let sign = try #require(views(of: SplitSignView.self, in: page).first)
        let chip = try #require(sign.item.chips.first { $0.tab === tabs.pair[0] })
        expectDressed(chip.slab, greys: sign.ground.greys, ink: sign.ground.ink, "split", radius: 7)
        #expect(chip.slab.layer?.opacity == 1)
        browser.select(tabs.pin)
        try await settle(window)
        let pin = try #require(views(of: PinSquareView.self, in: page).first { $0.tab === tabs.pin })
        let lift = try #require(pin.liveFace.layer)
        let dark = pin.liveFace.kitDark

        #expect(seen.count == 3)
        #expect(lift.shadowOpacity == (dark ? SelectedLook.shadow.dark : SelectedLook.shadow.light))
        #expect(lift.shadowRadius == SelectedLook.shadow.radius)
    }

    @Test func noContainerCutsTheSelectedShadow() async throws {
        let (browser, window, tabs) = try await world("aqua")
        let page = try #require(views(of: SidePageView.self, in: window.contentView).first)
        let scroll = try #require(views(of: SideScrollView.self, in: page).first { !$0.isHidden })

        var cuts: [String] = []
        for (name, tab) in [("loose at the top", tabs.loose[0]), ("card first", tabs.card[0]), ("card middle", tabs.card[1]),
                            ("card last", tabs.card[2])] {
            browser.select(tab)
            try await settle(window)
            let row = try #require(row(of: tab, in: page), "\(name)")
            cuts += self.cuts(row.liveGround.layer, name)
        }
        browser.select(tabs.pair[0])
        try await settle(window)
        let sign = try #require(views(of: SplitSignView.self, in: page).first)
        cuts += self.cuts(sign.item.chips.first { $0.tab === tabs.pair[0] }?.slab.layer, "split")
        browser.select(tabs.pin)
        try await settle(window)
        let pin = try #require(views(of: PinSquareView.self, in: page).first { $0.tab === tabs.pin })
        cuts += self.cuts(pin.liveFace.layer, "pin")
        let last = try #require(tabs.loose.last)
        browser.select(last)
        try await settle(window)
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(window)
        let low = try #require(row(of: last, in: page))
        cuts += self.cuts(low.liveGround.layer, "the last row with the list scrolled to its end")
        browser.select(tabs.loose[28])
        try await settle(window)
        browser.select(last)
        let moved = "the last row once a selection at the end has moved the rows"
        var after = ["\(moved): never measured"]
        for _ in 0..<10 where !after.isEmpty {
            try await settle(window)
            after = self.cuts(try #require(row(of: last, in: page)).liveGround.layer, moved)
        }
        cuts += after

        #expect(cuts.isEmpty, "\(cuts)")
    }

    @Test func everyShadowInTheColumnHasAShape() async throws {
        let (browser, window, tabs) = try await world("aqua")
        let page = try #require(views(of: SidePageView.self, in: window.contentView).first)

        var bare: [String] = []
        for tab in [tabs.loose[0], tabs.card[1], tabs.pair[0], tabs.pin!] {
            browser.select(tab)
            try await settle(window)
            bare += shapeless(page.layer)
        }

        #expect(bare.isEmpty, "\(bare)")
    }

    private struct Tabs {
        var loose: [Tab] = []
        var card: [Tab] = []
        var pair: [Tab] = []
        var pin: Tab!
    }

    private func expectDressed(_ plate: KitPlate, greys: KitGreys, ink: KitInk, _ name: String, radius: CGFloat) {
        let reference = KitPlate(radius: plate.radius)
        SelectedLook.dress(reference, greys: greys, ink: ink)
        #expect(plate.fill == reference.fill, "\(name)")
        #expect(plate.stroke == reference.stroke, "\(name)")
        #expect(plate.rim == reference.rim, "\(name)")
        #expect(plate.hairline == reference.hairline, "\(name)")
        #expect(plate.radius == radius, "\(name)")
        #expect(plate.lift == SelectedLook.shadow, "\(name)")
    }

    private func cuts(_ shadow: CALayer?, _ name: String) -> [String] {
        guard let shadow else { return ["\(name): no layer"] }
        let room = SelectedLook.room
        var rect = shadow.bounds.insetBy(dx: -room, dy: -room)
        var found: [String] = []
        var layer = shadow
        if layer.mask != nil || layer.masksToBounds { found.append("\(name): the shadow's own layer clips") }
        while let up = layer.superlayer {
            rect = layer.convert(rect, to: up)
            let owner = (up.delegate as? NSView).map { "\(type(of: $0))" } ?? "\(type(of: up))"
            if up.masksToBounds, !up.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect) {
                found.append("\(name): \(owner) bounds \(up.bounds) cut \(rect)")
            }
            if let mask = up.mask, !mask.frame.insetBy(dx: -0.5, dy: -0.5).contains(rect) {
                found.append("\(name): \(owner) mask \(mask.frame) cut \(rect)")
            }
            layer = up
        }
        return found
    }

    private func shapeless(_ layer: CALayer?) -> [String] {
        guard let layer, !layer.isHidden else { return [] }
        var found: [String] = []
        if layer.shadowOpacity > 0, layer.shadowPath == nil {
            found.append((layer.delegate as? NSView).map { "\(type(of: $0))" } ?? "\(type(of: layer))")
        }
        for sub in layer.sublayers ?? [] { found += shapeless(sub) }
        return found
    }

    private func row(of tab: Tab, in view: NSView) -> TabRowView? {
        views(of: TabRowView.self, in: view).first { $0.tab === tab && !$0.isHidden }
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

    private func world(_ look: String) async throws -> (Browser, NSWindow, Tabs) {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        if restorePreferences == nil {
            let previous = (prefs.splitView, prefs.usesSpaces, prefs.sideWidth,
                            prefs.cards)
            restorePreferences = {
                (prefs.splitView, prefs.usesSpaces, prefs.sideWidth,
                 prefs.cards) = previous
            }
        }
        prefs.splitView = true
        prefs.usesSpaces = false
        prefs.sideWidth = 258
        prefs.cards = true
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let space = Space(id: UUID(), name: "Selected tab fixture", colour: 0, sharesSignIns: true)
        browser.spaces = [space]
        browser.spaceID = space.id
        browsers.append(browser)
        func open(_ name: String) -> Tab {
            browser.newTab()
            let tab = browser.tabs.last!
            tab.restore(url: URL(string: "about:blank#\(name)")!, title: name)
            return tab
        }
        var tabs = Tabs()
        tabs.loose = (0..<2).map { open("loose \($0)") }
        tabs.card = (0..<3).map { open("card \($0)") }
        tabs.pair = (0..<2).map { open("pair \($0)") }
        tabs.loose += (2..<30).map { open("loose \($0)") }
        tabs.pin = open("pin")
        browser.pin(tabs.pin)
        let group = browser.addTabGroup(containing: tabs.card[0])
        for tab in tabs.card.dropFirst() { browser.move(tab, toGroup: group) }
        browser.pair(tabs.pair[1], with: tabs.pair[0], onLeft: false)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 900),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: look == "darkAqua" ? .darkAqua : .aqua)
        window.contentView = SideColumnView(browser: browser)
        window.orderFrontRegardless()
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        try await settle(window)
        return (browser, window, tabs)
    }
}
