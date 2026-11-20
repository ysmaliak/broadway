import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class FullScreenSideTests {
    private var window: NSWindow?
    private var standIn: NSWindow?
    private var browser: Browser?
    private var restore: (() -> Void)?

    init() {
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        FullScreenSide.shared.stop()
        FullScreenSide.shared.standIn = nil
        if let browser { ContentView.forget(browser); browser.closeAll() }
        window?.contentView = nil
        window?.close()
        standIn?.close()
        restore?()
    }

    private let screen = NSRect(x: -20_000, y: -20_000, width: 1440, height: 900)

    @Test func thePointerAtTheLeftEdgeOfAFullScreenIsAtTheEdge() {
        #expect(FullScreenSide.atEdge(NSPoint(x: screen.minX + 2, y: screen.midY), in: screen, right: false))
    }

    @Test func thePointerInsideThePageIsNotAtTheEdge() {
        #expect(!FullScreenSide.atEdge(NSPoint(x: screen.minX + 40, y: screen.midY), in: screen, right: false))
    }

    @Test func theTopCornerIsLeftToTheMenuBar() {
        #expect(!FullScreenSide.atEdge(NSPoint(x: screen.minX + 2, y: screen.maxY - 10), in: screen, right: false))
    }

    @Test func aSidebarOnTheRightWaitsAtTheRightEdge() {
        #expect(FullScreenSide.atEdge(NSPoint(x: screen.maxX - 2, y: screen.midY), in: screen, right: true))
        #expect(!FullScreenSide.atEdge(NSPoint(x: screen.minX + 2, y: screen.midY), in: screen, right: true))
    }

    @Test func restingAtTheEdgeOfAFullScreenVideoSlidesTheSidebarOutOverIt() async throws {
        let (_, host) = try await scene()

        FullScreenSide.shared.moved(at: edge)
        try await wait(FullScreenSide.dwell + 0.1)

        #expect(FullScreenSide.shared.out)
        let panel = try #require(FullScreenSide.shared.panel)
        #expect(panel.parent === host)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!all(SideColumnView.self, in: try #require(panel.contentView)).isEmpty)
    }

    @Test func thePointerOnlyPassingTheEdgeBringsNothingOut() async throws {
        _ = try await scene()

        FullScreenSide.shared.moved(at: edge)
        FullScreenSide.shared.moved(at: inside)
        try await wait(FullScreenSide.dwell + 0.1)

        #expect(!FullScreenSide.shared.out)
    }

    @Test func theSidebarGoesBackWhenThePointerLeavesIt() async throws {
        _ = try await scene()
        try await reveal()

        FullScreenSide.shared.moved(at: inside)
        try await wait(FullScreenSide.grace + 0.1)

        #expect(!FullScreenSide.shared.out)
    }

    @Test func escapeSendsTheSidebarBackAndIsKeptFromThePage() async throws {
        let (browser, _) = try await scene()
        try await reveal()

        let kept = browser.escapesSide(escape())

        #expect(kept)
        #expect(!FullScreenSide.shared.out)
    }

    @Test func afterEscapeThePointerStillAtTheEdgeBringsNothingBack() async throws {
        let (browser, _) = try await scene()
        try await reveal()
        _ = browser.escapesSide(escape())

        FullScreenSide.shared.moved(at: edge)
        try await wait(FullScreenSide.dwell + 0.1)

        #expect(!FullScreenSide.shared.out)
    }

    @Test func leavingTheEdgeAndComingBackAfterEscapeBringsItOutAgain() async throws {
        let (browser, _) = try await scene()
        try await reveal()
        _ = browser.escapesSide(escape())

        FullScreenSide.shared.moved(at: inside)
        FullScreenSide.shared.moved(at: edge)
        try await wait(FullScreenSide.dwell + 0.1)

        #expect(FullScreenSide.shared.out)
    }

    @Test func escapeWithNothingOutIsLeftToThePage() async throws {
        let (browser, _) = try await scene()

        #expect(!browser.escapesSide(escape()))
    }

    @Test func choosingAnotherTabInTheSidebarPutsItAway() async throws {
        let (browser, _) = try await scene()
        try await reveal()

        browser.select(browser.tabs[1])
        try await wait(0.2)

        #expect(!FullScreenSide.shared.out)
    }

    @Test func theEndOfTheFullScreenTakesTheSidebarAway() async throws {
        let (browser, _) = try await scene()
        try await reveal()

        browser.tabs[0].immersed = false
        FullScreenSide.shared.follow(browser, tab: nil)

        #expect(!FullScreenSide.shared.out)
        #expect(FullScreenSide.shared.panel == nil)
    }

    @Test func inAFullScreenWindowEscapePutsTheSlidOutSidebarBack() async throws {
        let (browser, _) = try await scene(immersed: false)
        browser.folded = true
        browser.fullScreen = true
        browser.peek(true)

        let kept = browser.escapesSide(escape())

        #expect(kept)
        #expect(!browser.peeking)
        #expect(browser.columnPeek.sentAway)
    }

    @Test func outsideFullScreenEscapeLeavesTheSlidOutSidebarAlone() async throws {
        let (browser, _) = try await scene(immersed: false)
        browser.folded = true
        browser.fullScreen = false
        browser.peek(true)

        #expect(!browser.escapesSide(escape()))
        #expect(browser.peeking)
    }

    private var edge: NSPoint { NSPoint(x: screen.minX + 2, y: screen.midY) }
    private var inside: NSPoint { NSPoint(x: screen.minX + 600, y: screen.midY) }

    private func reveal() async throws {
        FullScreenSide.shared.moved(at: edge)
        try await wait(FullScreenSide.dwell + 0.1)
        #expect(FullScreenSide.shared.out)
        FullScreenSide.shared.moved(at: NSPoint(x: screen.minX + 100, y: screen.midY))
    }

    private func escape() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    }

    private func scene(immersed: Bool = true) async throws -> (Browser, NSWindow) {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let prefs = browser.prefs
        let saved = (prefs.splitView, prefs.sideHides, prefs.sidePosition, prefs.sideWidth)
        restore = { (prefs.splitView, prefs.sideHides, prefs.sidePosition, prefs.sideWidth) = saved }
        prefs.splitView = false
        prefs.sideHides = false
        prefs.sidePosition = .left
        prefs.sideWidth = 258
        for index in 0..<2 {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "about:blank#row-\(index)")!, title: "row \(index)")
        }
        browser.select(browser.tabs[0])
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = ContentView(browser: browser)
        window.orderFrontRegardless()
        let host = NSWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.orderFrontRegardless()
        self.browser = browser
        self.window = window
        standIn = host
        if immersed {
            FullScreenSide.shared.standIn = host
            browser.tabs[0].immersed = true
            FullScreenSide.shared.follow(browser, tab: browser.tabs[0])
        }
        try await wait(0.2)
        return (browser, host)
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { sub -> [T] in ((sub as? T).map { [$0] } ?? []) + all(type, in: sub) }
    }

    private func wait(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        window?.contentView?.layoutSubtreeIfNeeded()
    }
}
