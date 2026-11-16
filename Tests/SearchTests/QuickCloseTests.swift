import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class QuickCloseTests {
    private var browser: Browser!
    private var window: NSWindow!
    private var column: SideColumnView!

    init() {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.closeAll()
    }

    private func tearDown() {
        KitHoverView.pointerStandIn = nil
        window?.contentView = nil
        window?.close()
        browser?.closeAll()
        browser = nil
    }

    private func tabs(_ count: Int) -> [Tab] {
        let made = (0..<count).map { index -> Tab in
            let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
            tab.restore(url: URL(string: "https://row\(index).example/")!, title: "Row \(index)")
            return tab
        }
        _ = made.last?.wake()
        browser.showRow(made, active: made.last?.id)
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: 600), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        column = SideColumnView(browser: browser)
        window.contentView = column
        column.layoutSubtreeIfNeeded()
        return made
    }

    private func row(_ tab: Tab) throws -> TabRowView {
        try #require(column.kitSubviews(of: TabRowView.self).first { $0.tab?.id == tab.id && $0.window != nil && !$0.isHidden })
    }

    private func crossSpot(of row: TabRowView) throws -> NSPoint {
        let zone = try #require(row.kitSubviews(of: RowCloseZone.self).first)
        let frame = zone.convert(zone.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    private func click(at point: NSPoint) {
        let frameView = window.contentView?.superview
        let hit = frameView?.hitTest(frameView?.convert(point, from: nil) ?? point)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            if type == .leftMouseDown { hit?.mouseDown(with: event) } else { hit?.mouseUp(with: event) }
        }
    }

    @Test func aRowThatArrivesUnderAStillPointerIsHovered() throws {
        let made = tabs(5)
        let first = try row(made[1])
        let spot = try crossSpot(of: first)
        KitHoverView.pointerStandIn = (window, spot)
        first.settleHover()
        #expect(first.isHovering)

        browser.closeTab(made[1])
        column.layoutSubtreeIfNeeded()

        let arrived = try row(made[2])
        #expect(arrived.isHovering)
        #expect(arrived.kitSubviews(of: CloseSpotView.self).contains { $0.accessibilityLabel() == "Close Tab" && !$0.isHidden })
        #expect(try #require(arrived.kitSubviews(of: RowCloseZone.self).first).armed)
        #expect(arrived.convert(arrived.bounds, to: nil).contains(spot))
        #expect(!first.isHovering)
    }

    @Test func clicksOnTheCrossCloseEachRowThatComesUnderIt() throws {
        let made = tabs(6)
        let live = browser.activeID
        let spot = try crossSpot(of: try row(made[1]))
        KitHoverView.pointerStandIn = (window, spot)
        try row(made[1]).settleHover()

        for _ in 0..<3 {
            click(at: spot)
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        }

        #expect(browser.tabs.map(\.id) == [made[0], made[4], made[5]].map(\.id))
        #expect(browser.activeID == live)
    }

    @Test func aLeavingRowTakesNoClick() throws {
        let made = tabs(3)
        let leaving = try row(made[1])
        let inside = leaving.convert(NSPoint(x: leaving.bounds.midX, y: leaving.bounds.midY), to: leaving.superview)

        browser.closeTab(made[1])
        column.layoutSubtreeIfNeeded()

        #expect(leaving.tab == nil)
        #expect(leaving.hitTest(inside) == nil)
    }
}
