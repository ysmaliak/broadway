import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SideEdgeLineTests {
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

    @Test func nothingOfTheListIsDrawnUnderAnEdgeLineMidScroll() async throws {
        let browser = makeBrowser(count: 24)
        let window = makeWindow(browser)
        let page = try #require(pages(in: window.contentView).first)
        try await settle(page, in: window, count: 24)
        let scroll = try #require(subviews(of: SideScrollView.self, in: page).first { !$0.isHidden })
        let clip = scroll.contentView
        let middle = ((scroll.documentView?.frame.height ?? 0) - clip.bounds.height) / 2
        browser.select(browser.tabs[12])

        clip.scroll(to: NSPoint(x: 0, y: middle))
        scroll.reflectScrolledClipView(clip)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)

        let masks = page.subviews.compactMap { $0.layer?.mask }
        let mask = try #require(masks.first)
        let lines = page.subviews.filter { $0 is KitPlate && !$0.isHidden && $0.frame.height <= 1 && $0.frame.width >= page.bounds.width - 0.5 }
        #expect(lines.count == 2, "both edges are cut mid-scroll, so both lines show")
        for line in lines {
            let apart = line.frame.maxY <= mask.frame.minY + 0.01 || line.frame.minY >= mask.frame.maxY - 0.01
            #expect(apart, "the line at \(line.frame.minY) lies over the list's drawn area \(mask.frame.minY)…\(mask.frame.maxY)")
        }
    }

    @Test func aListThatFitsIsCutWhereverARubberBandCarriesItPastAnEdge() {
        let viewport: CGFloat = 400, short: CGFloat = 150, long: CGFloat = 900

        let resting = SidePageView.cuts(offset: 0, viewport: viewport, content: short)
        let pulledUp = SidePageView.cuts(offset: 30, viewport: viewport, content: short)
        let pulledDown = SidePageView.cuts(offset: -300, viewport: viewport, content: short)
        let middle = SidePageView.cuts(offset: 200, viewport: viewport, content: long)
        let end = SidePageView.cuts(offset: 500, viewport: viewport, content: long)

        #expect(resting == (false, false))
        #expect(pulledUp == (true, false))
        #expect(pulledDown == (false, true))
        #expect(middle == (true, true))
        #expect(end == (true, false))
    }

    private func settle(_ page: SidePageView, in window: NSWindow, count: Int) async throws {
        for _ in 0..<200 {
            window.contentView?.layoutSubtreeIfNeeded()
            if page.blocksNow.count == count { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("the column did not lay out \(count) blocks: \(page.blocksNow)")
    }

    private func pages(in view: NSView?) -> [SidePageView] {
        guard let view else { return [] }
        if let page = view as? SidePageView { return [page] }
        return view.subviews.flatMap(pages)
    }

    private func subviews<V: NSView>(of type: V.Type, in view: NSView) -> [V] {
        view.subviews.flatMap { ($0 as? V).map { [$0] } ?? [] + subviews(of: type, in: $0) }
    }

    private func makeBrowser(count: Int) -> Browser {
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
        prefs.usesTabGroups = true
        prefs.splitView = false
        prefs.usesSpaces = false
        prefs.addressBar = true
        prefs.sideWidth = 258
        prefs.newTabPlace = .end
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let space = Space(id: UUID(), name: "Edge line fixture", colour: 0, sharesSignIns: true)
        browser.spaces = [space]
        browser.spaceID = space.id
        browsers.append(browser)
        for index in 0..<count {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "about:blank#edge-\(index)")!, title: "edge \(index)")
        }
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 520),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SideColumnView(browser: browser)
        window.orderFrontRegardless()
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }
}
