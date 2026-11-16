import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SideAlwaysScrollsTests {
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

    @Test func aShortListStillScrolls() async throws {
        let browser = makeBrowser(count: 3)
        let window = makeWindow(browser)
        let page = try #require(pages(in: window.contentView).first)

        try await settle(page, in: window, count: 3)

        let scroll = try #require(subviews(of: SideScrollView.self, in: page).first { !$0.isHidden })
        #expect(scroll.documentView.map { $0.frame.height <= scroll.contentView.bounds.height + 0.5 } == true, "the list fits")
        #expect(scroll.scrolls, "it rubber-bands anyway")
        #expect(scroll.verticalScrollElasticity == .allowed)
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
        let space = Space(id: UUID(), name: "Always scrolls fixture", colour: 0, sharesSignIns: true)
        browser.spaces = [space]
        browser.spaceID = space.id
        browsers.append(browser)
        for index in 0..<count {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "about:blank#scroll-\(index)")!, title: "scroll \(index)")
        }
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 900),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SideColumnView(browser: browser)
        window.orderFrontRegardless()
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }

    @Test func theListNeverMovesSideways() {
        let scroll = SideScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let document = SideDocumentView(frame: NSRect(x: 0, y: 0, width: 260, height: 900))
        scroll.documentView = document
        scroll.scrollerStyle = .legacy

        scroll.contentView.scroll(to: NSPoint(x: 40, y: 120))
        scroll.reflectScrolledClipView(scroll.contentView)

        #expect(scroll.contentView.bounds.minX == 0)
        #expect(scroll.contentView.bounds.minY == 120)
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.contentView.frame.width == 200)
    }
}

