import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class TalkPlaceTests {
    private var browser: Browser!
    private var window: NSWindow!
    private var now: CFTimeInterval = 1000
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        Store.settings.set(false, forKey: "motion.testReduced")
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.liveFolders = true
        LiveRefs.known = [:]
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        TabRowView.clock = { [unowned self] in self.now }
    }

    private func tearDown() async {
        TabRowView.clock = CACurrentMediaTime
        Store.settings.removeObject(forKey: "motion.testReduced")
        window?.close()
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        LiveRefs.known = [:]
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    private func column() -> SideColumnView {
        let made = LiveFolders.shared.add(name: "PRs", source: .reviewRequests, space: browser.spaceID)
        let base = "https://github.com/acme/rocket/pull/"
        LiveFolders.shared.apply(.items([
            LiveItem(key: base + "1", title: "Rest", unanswered: 1),
            LiveItem(key: base + "2", title: "Lit", unanswered: 3),
            LiveItem(key: base + "3", title: "Plain"),
        ], nil), to: made.id, now: start.addingTimeInterval(60))
        browser.syncLive()
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: 600), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        browser.sightForBench = true
        browser.unfoldFolder(made.id)
        let column = SideColumnView(browser: browser)
        window.contentView = column
        column.layoutSubtreeIfNeeded()
        return column
    }

    private func row(_ title: String, in column: SideColumnView) throws -> TabRowView {
        try #require(column.kitSubviews(of: TabRowView.self).first { $0.window != nil && $0.accessibilityLabel() == title })
    }

    private func end(_ row: TabRowView) throws -> [String: Any] { try #require(row.benchEnd) }

    private func number(_ end: [String: Any], _ key: String) -> CGFloat { CGFloat(end[key] as? Double ?? .nan) }

    private func titleEnd(_ end: [String: Any]) -> CGFloat { CGFloat((end["model"] as? [Double])?.last ?? .nan) }

    private func asideRight(_ row: TabRowView) -> CGFloat {
        let height = row.bounds.height
        return row.bounds.width - Metrics.closeInset(height) - Metrics.closeSquare(height) - TalkPlace.gap
    }

    private func hover(_ row: TabRowView, _ over: Bool) {
        row.benchPillHover(over)
        row.layoutSubtreeIfNeeded()
    }

    private func press(_ view: NSView) throws {
        let spot = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: kind, location: spot, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if kind == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    private func cross(of row: TabRowView) throws -> CloseSpotView {
        try #require(row.kitSubviews(of: CloseSpotView.self).first { $0.superview is RowCloseZone })
    }

    @Test func atRestWithNoDotTheSignEndsWhereTheCloseGlyphEnds() throws {
        let column = column()
        let rest = try end(row("Rest", in: column))

        #expect(number(rest, "dot") == 0)
        #expect(rest["talkAside"] as? Bool == false)
        #expect(abs(number(rest, "talkRight") - number(rest, "crossRight")) <= 0.5)
        #expect(abs(titleEnd(rest) - (number(rest, "talkX") - 2)) <= 0.5)
    }

    @Test func onHoverTheSignSlidesToItsOldPlaceAndBackWhenThePointerLeaves() throws {
        let column = column()
        let row = try row("Rest", in: column)
        let rest = try end(row)

        hover(row, true)
        let over = try end(row)

        #expect(over["talkAside"] as? Bool == true)
        #expect(abs(number(over, "talkRight") - asideRight(row)) <= 0.5)
        #expect(over["talkSliding"] as? Bool == true)
        #expect(abs(titleEnd(over) - (number(over, "talkX") - 2)) <= 0.5)
        #expect(titleEnd(over) < titleEnd(rest))
        #expect(number(over, "cross") > 0 || over["crossTurning"] as? Bool == true)

        hover(row, false)
        let back = try end(row)

        #expect(back["talkAside"] as? Bool == false)
        #expect(abs(number(back, "talkRight") - number(back, "crossRight")) <= 0.5)
        #expect(abs(titleEnd(back) - titleEnd(rest)) <= 0.5)
    }

    @Test func aDotThatComesMovesTheSignAsideAndItStaysBesideItOnHover() throws {
        let column = column()
        let row = try row("Lit", in: column)
        let rest = try end(row)
        let tab = try #require(row.tab)

        tab.unread = true
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        let lit = try end(row)

        #expect(rest["talkAside"] as? Bool == false)
        #expect(number(lit, "dot") > 0 || lit["dotTurning"] as? Bool == true)
        #expect(lit["talkAside"] as? Bool == true)
        #expect(lit["talkSliding"] as? Bool == true)
        #expect(abs(number(lit, "talkRight") - asideRight(row)) <= 0.5)
        #expect(abs(titleEnd(lit) - (number(lit, "talkX") - 2)) <= 0.5)

        hover(row, true)
        let over = try end(row)

        #expect(number(over, "talkX") == number(lit, "talkX"))
        #expect(abs(titleEnd(over) - titleEnd(lit)) <= 0.5)
    }

    @Test func aPressOnTheSignAtRestDoesNotCloseTheTab() throws {
        let column = column()
        let row = try row("Rest", in: column)
        var closed = 0
        row.close = { closed += 1 }
        let rest = try end(row)
        let spot = NSPoint(x: number(rest, "talkRight") - 1, y: row.bounds.midY)
        let target = try #require(row.hitTest(row.convert(spot, to: row.superview)))

        #expect(target is RowCloseZone)
        try press(target)

        #expect(closed == 0)
    }

    @Test func theCloseButtonActsOnlyOnceTheSignHasMadeRoomForIt() throws {
        let column = column()
        let row = try row("Rest", in: column)
        var closed = 0
        row.close = { closed += 1 }
        hover(row, true)
        let cross = try cross(of: row)
        let zone = try #require(cross.superview)

        now += RowSweep.wait / 2
        try press(cross)
        try press(zone)

        #expect(closed == 0)

        now += RowSweep.wait
        try press(cross)

        #expect(closed == 1)

        try press(zone)

        #expect(closed == 2)
    }

    @Test func aRowWithoutTheSignClosesAsSoonAsTheButtonShows() throws {
        let column = column()
        let row = try row("Plain", in: column)
        var closed = 0
        row.close = { closed += 1 }
        hover(row, true)

        try press(cross(of: row))

        #expect(closed == 1)
        #expect(try end(row)["talk"] as? Double == 0)
    }

    @Test func underReduceMotionTheSignMovesWithoutSlidingAndTheButtonActsAtOnce() throws {
        Store.settings.set(true, forKey: "motion.testReduced")
        let column = column()
        let row = try row("Rest", in: column)
        var closed = 0
        row.close = { closed += 1 }

        hover(row, true)
        let over = try end(row)

        #expect(abs(number(over, "talkRight") - asideRight(row)) <= 0.5)
        #expect(over["talkSliding"] as? Bool == false)

        try press(cross(of: row))

        #expect(closed == 1)
    }
}
