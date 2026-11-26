import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PickedDragTests {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    init() {
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers {
            browser.cancelTabEdit()
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
            Pins.forget(browser.spaceID)
        }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
    }

    private func pick(_ browser: Browser, _ tabs: [Tab]) {
        for tab in tabs { browser.extendTabSelection(to: tab, modifiers: .command) }
    }

    private func middle(_ tab: Tab, in window: NSWindow) throws -> NSPoint {
        let frame = try #require(Bench.rowFrames[tab.id])
        return point(x: 70, y: frame.midY, in: window)
    }

    @Test func aPressOnAPickedRowKeepsThePickAndTheReleaseSelectsIt() async throws {
        let browser = makeBrowser(count: 5)
        let t = browser.tabs
        browser.select(t[0])
        pick(browser, [t[2], t[3]])
        let picked = Set([t[0], t[2], t[3]].map(\.id))
        #expect(browser.selectedTabIDs == picked)
        let window = makeWindow(browser)
        try await settle(in: window)
        let at = try middle(t[2], in: window)

        try await send(.leftMouseDown, at: at, in: window)
        #expect(browser.selectedTabIDs == picked, "the press keeps the pick")
        #expect(browser.activeID == t[0].id, "the press leaves the page in front")

        try await send(.leftMouseUp, at: at, in: window)
        #expect(browser.activeID == t[2].id, "a click on a picked row shows it")
        #expect(browser.selectedTabIDs.isEmpty, "and lets the pick go")
    }

    @Test func aPressOnARowOutsideThePickStillSelectsAtOnceAndClearsIt() async throws {
        let browser = makeBrowser(count: 5)
        let t = browser.tabs
        browser.select(t[0])
        pick(browser, [t[2], t[3]])
        let window = makeWindow(browser)
        try await settle(in: window)
        let at = try middle(t[4], in: window)

        try await send(.leftMouseDown, at: at, in: window)
        #expect(browser.activeID == t[4].id)
        #expect(browser.selectedTabIDs.isEmpty)
        try await send(.leftMouseUp, at: at, in: window)
    }

    @Test func pickedRowsCarriedOntoAFolderAllJoinItWithACountOnTheCarriedRow() async throws {
        let browser = makeBrowser(count: 6)
        let t = browser.tabs
        let folder = browser.addTabGroup(containing: t[0], pinned: false)
        browser.editingGroupID = nil
        browser.select(t[2])
        pick(browser, [t[4], t[5]])
        let window = makeWindow(browser)
        try await settle(in: window)
        let member = try #require(Bench.rowFrames[t[0].id])
        let start = try middle(t[2], in: window)

        let last = try await carry(from: start, through: [
            point(x: 70, y: member.midY + 30, in: window),
            point(x: 70, y: member.midY + 2, in: window),
        ], in: window)
        let page = try #require(livePage(in: window))
        let morph = try #require(page.morphView)
        #expect(morph.count == 3, "the carried row says how many go")
        let badge = try #require(morph.tallyFrame)
        #expect(abs(badge.maxX - (morph.bounds.width - PinMorphView.tallyInset)) < 0.5, "at the right")
        #expect(abs(badge.minY - PinMorphView.tallyInset) < 0.5, "at the top")
        try await send(.leftMouseUp, at: last, in: window)
        try await waitUntil("the picked rows did not join the folder") { browser.group(of: t[5]) == folder }
        try await settle(in: window)

        #expect(browser.group(of: t[2]) == folder)
        #expect(browser.group(of: t[4]) == folder)
        #expect(browser.group(of: t[5]) == folder)
        #expect(browser.group(of: t[1]) == nil)
        #expect(browser.group(of: t[3]) == nil)
    }

    @Test func pickedRowsCarriedOntoThePinsAllBecomePinsInColumnOrder() async throws {
        let browser = makeBrowser(count: 6)
        let t = browser.tabs
        browser.pin(t[0])
        browser.select(t[1])
        pick(browser, [t[3], t[4]])
        let window = makeWindow(browser)
        try await settle(in: window)
        let start = try middle(t[3], in: window)

        try await drag(from: start, through: [
            point(x: 70, y: columnTop + 50, in: window),
            point(x: 70, y: columnTop + 35, in: window),
            point(x: 70, y: columnTop + 22, in: window),
        ], in: window, until: { t[4].pin != nil })

        #expect(browser.squarePins.map(\.id) == [t[0], t[1], t[3], t[4]].map(\.id))
        #expect(t[2].pin == nil)
        #expect(t[5].pin == nil)
    }

    @Test func aRowOutsideThePickCarriedOntoThePinsGoesAlone() async throws {
        let browser = makeBrowser(count: 6)
        let t = browser.tabs
        browser.pin(t[0])
        browser.select(t[1])
        pick(browser, [t[3], t[4]])
        let window = makeWindow(browser)
        try await settle(in: window)
        let start = try middle(t[5], in: window)

        try await drag(from: start, through: [
            point(x: 70, y: columnTop + 50, in: window),
            point(x: 70, y: columnTop + 35, in: window),
            point(x: 70, y: columnTop + 22, in: window),
        ], in: window, until: { t[5].pin != nil })

        #expect(browser.pinnedCount == 2)
        #expect(t[3].pin == nil)
        #expect(t[4].pin == nil)
    }

    @Test func pickedRowsLetGoOnAnotherSpaceLeaveNoCarriedRowInTheAir() async throws {
        let browser = makeBrowser(count: 5)
        let t = browser.tabs
        browser.select(t[0])
        pick(browser, [t[2], t[3]])
        let window = makeWindow(browser)
        try await settle(in: window)
        let page = try #require(livePage(in: window))
        var dropped: [Search.Tab.ID] = []
        page.outside = { tab, _, ended in
            if ended { dropped.append(tab.id) }
            return ended
        }
        let row = try #require(Bench.rowFrames[t[2].id])

        let last = try await carry(from: try middle(t[2], in: window), through: [
            point(x: 70, y: row.midY + 30, in: window),
        ], in: window)
        let carried = page.morphView
        try await send(.leftMouseUp, at: last, in: window)
        try await waitUntil("the carried row stayed in the air") { page.morphCarried == nil }

        #expect(carried?.count == 3)
        #expect(dropped == [t[2].id])
        #expect(page.morphView == nil)
    }

    @Test func aPickedRowLetGoOnAnotherSpaceTakesEveryPickedTab() async throws {
        let browser = makeBrowser(count: 5)
        let t = browser.tabs
        let second = Space(id: UUID(), name: "Elsewhere", colour: 1, sharesSignIns: true)
        browser.prefs.usesSpaces = true
        browser.spaces.append(second)
        browser.select(t[0])
        pick(browser, [t[2], t[3]])

        browser.stackedDrop(t[2], onto: second.id)
        try await waitUntil("the picked tabs did not reach the other space") {
            browser.parked[second.id]?.tabs.contains { $0 === t[3] } == true
        }

        let moved = browser.parked[second.id]?.tabs ?? []
        #expect([t[0], t[2], t[3]].allSatisfy { tab in moved.contains { $0 === tab } })
        #expect(browser.tabs.contains { $0 === t[1] })
        #expect(browser.tabs.contains { $0 === t[4] })
    }

    @Test func aPickedPairLetGoOnAnotherSpaceStillGoesAsThePairAlone() async throws {
        let browser = makeBrowser(count: 4)
        let t = browser.tabs
        browser.prefs.splitView = true
        let second = Space(id: UUID(), name: "Elsewhere", colour: 1, sharesSignIns: true)
        browser.prefs.usesSpaces = true
        browser.spaces.append(second)
        browser.pair(t[2], with: t[1], onLeft: false)
        let pair = try #require(browser.split(for: t[1]))
        browser.select(t[3])
        pick(browser, [t[1]])
        #expect(browser.menuTabs(for: t[1]).count > 1)

        browser.stackedDrop(t[1], onto: second.id)
        try await waitUntil("the pair did not reach the other space") {
            browser.parked[second.id]?.tabs.contains { $0 === t[2] } == true
        }

        let row = try #require(browser.parked[second.id])
        #expect(row.splits.contains { $0.id == pair.id })
        #expect(row.tabs.contains { $0 === t[1] })
        #expect(browser.tabs.contains { $0 === t[3] })
    }

    @Test func aLoneTabLetGoOnAnotherSpaceGoesAlone() async throws {
        let browser = makeBrowser(count: 4)
        let t = browser.tabs
        let second = Space(id: UUID(), name: "Elsewhere", colour: 1, sharesSignIns: true)
        browser.prefs.usesSpaces = true
        browser.spaces.append(second)
        browser.select(t[0])
        pick(browser, [t[2]])

        browser.stackedDrop(t[3], onto: second.id)
        try await waitUntil("the tab did not reach the other space") {
            browser.parked[second.id]?.tabs.contains { $0 === t[3] } == true
        }

        #expect(browser.parked[second.id]?.tabs.count == 1)
        #expect(browser.tabs.contains { $0 === t[2] })
    }

    @Test func threePickedRowsCarriedAmongTheLooseRowsShowTheDropLineAndTravelThereTogether() async throws {
        try await carryThreeAmongTheLooseRows(reduced: false)
    }

    @Test func underReduceMotionThePickedRowsLandWithoutTravel() async throws {
        try await carryThreeAmongTheLooseRows(reduced: true)
    }

    @Test func aPickedRowInAFolderTravelsOutWithTheBlock() async throws {
        let store = Store.settings
        let saved = ["motion.testReduced", "motion.testLowPower"].map { ($0, store.object(forKey: $0)) }
        for (key, _) in saved { store.set(false, forKey: key) }
        defer { for (key, value) in saved { store.set(value, forKey: key) } }
        let browser = makeBrowser(count: 6)
        let t = browser.tabs
        browser.prefs.usesTabGroups = true
        let folder = browser.addTabGroup(containing: t[0], pinned: false)
        browser.move(t[1], toGroup: folder)
        browser.editingGroupID = nil
        browser.select(t[3])
        pick(browser, [t[1], t[4]])
        let window = makeWindow(browser)
        try await settle(in: window)
        let target = try #require(Bench.rowFrames[t[4].id])

        let last = try await carry(from: try middle(t[3], in: window), through: [
            point(x: 70, y: target.midY + 10, in: window),
            point(x: 70, y: target.minY + 4, in: window),
        ], in: window)
        let page = try #require(livePage(in: window))
        #expect(page.looseOn == LoosePlace(before: .tab(t[5].id)))
        try await send(.leftMouseUp, at: last, in: window)
        let root = try #require(window.contentView)
        let moving = subviews(of: TabRowView.self, in: root).filter { $0.tab?.id == t[1].id && !($0.superview is SideFoldClip) }
        let travels = moving.contains { $0.layer?.animation(forKey: "position") != nil }
        try await waitUntil("the picked rows did not leave the folder") { browser.group(of: t[1]) == nil }
        try await settle(in: window)

        let loose = browser.displayedTabs.filter { browser.group(of: $0) == nil }.compactMap { tab in t.firstIndex { $0 === tab } }
        #expect(loose == [2, 1, 3, 4, 5])
        #expect(browser.group(of: t[0]) == folder)
        #expect(travels, "the row leaving its folder travels to its new place")
    }

    private func carryThreeAmongTheLooseRows(reduced: Bool) async throws {
        let store = Store.settings
        let saved = ["motion.testReduced", "motion.testLowPower"].map { ($0, store.object(forKey: $0)) }
        store.set(reduced, forKey: "motion.testReduced")
        store.set(false, forKey: "motion.testLowPower")
        defer { for (key, value) in saved { store.set(value, forKey: key) } }
        let browser = makeBrowser(count: 6)
        let t = browser.tabs
        browser.select(t[3])
        pick(browser, [t[4], t[5]])
        let window = makeWindow(browser)
        try await settle(in: window)
        let page = try #require(livePage(in: window))
        let target = try #require(Bench.rowFrames[t[1].id])

        let last = try await carry(from: try middle(t[3], in: window), through: [
            point(x: 70, y: target.midY + 10, in: window),
            point(x: 70, y: target.minY + 4, in: window),
        ], in: window)
        #expect(page.morphView?.count == 3)
        #expect(page.looseOn == LoosePlace(before: .tab(t[1].id)), "the drop line shows as for one row")
        let line = try #require(SidePageView.benchDrop["line"] as? [Double])
        #expect(abs(line[1] - Double(target.minY)) < 8, "the line sits at the top of the row it goes before")
        #expect(browser.tabs.map(\.id) == t.map(\.id), "the other picked rows stay where they are")

        try await send(.leftMouseUp, at: last, in: window)
        let others = subviews(of: TabRowView.self, in: try #require(window.contentView)).first { $0.tab?.id == t[5].id }
        let travels = others?.layer?.animation(forKey: "position") != nil
        try await waitUntil("the picked rows did not land at the drop line") {
            browser.tabs.map(\.id) == [t[0], t[3], t[4], t[5], t[1], t[2]].map(\.id)
        }
        try await settle(in: window)

        #expect(travels == !reduced, reduced ? "no travel under Reduce Motion" : "the picked rows travel to their new places")
        #expect(browser.selectedTabIDs == Set([t[3], t[4], t[5]].map(\.id)), "and stay picked")
    }

    private func livePage(in window: NSWindow) -> SidePageView? {
        guard let root = window.contentView else { return nil }
        return subviews(of: SidePageView.self, in: root).first { $0.preview == nil && !$0.embedded && !$0.isHiddenOrHasHiddenAncestor }
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
        let space = Space(id: UUID(), name: "Picked drag fixture", colour: 0, sharesSignIns: true)
        browser.spaces = [space]
        browser.spaceID = space.id
        browsers.append(browser)
        for index in 0..<count {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "about:blank#row-\(index)")!, title: "row \(index)")
        }
        #expect(browser.tabs.count == count)
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

    private func point(x: CGFloat, y: CGFloat, in window: NSWindow) -> NSPoint {
        NSPoint(x: x, y: window.frame.height - y)
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool,
                           sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("\(message)", sourceLocation: sourceLocation)
        throw WaitError.timedOut
    }

    private func settle(in window: NSWindow) async throws {
        var previous: [Search.Tab.ID: CGRect] = [:]
        var since = ProcessInfo.processInfo.systemUptime
        try await waitUntil("the sidebar rows did not finish layout") {
            window.contentView?.layoutSubtreeIfNeeded()
            let current = Bench.rowFrames.filter { id, _ in browsers.contains { $0.tabs.contains { $0.id == id } } }
            guard !current.isEmpty else { return false }
            if current != previous {
                previous = current
                since = ProcessInfo.processInfo.systemUptime
            }
            return ProcessInfo.processInfo.systemUptime - since >= 0.3
        }
    }

    private enum WaitError: Error { case timedOut }

    private func drag(from start: NSPoint, through points: [NSPoint], in window: NSWindow, until landed: (() -> Bool)? = nil) async throws {
        let last = try await carry(from: start, through: points, in: window)
        try await send(.leftMouseUp, at: last, in: window)
        if let landed { try await waitUntil("the drop did not reach its destination", landed) }
        try await settle(in: window)
    }

    private func carry(from start: NSPoint, through points: [NSPoint], in window: NSWindow) async throws -> NSPoint {
        try await send(.leftMouseDown, at: start, in: window)
        var last = start
        for target in points {
            let steps = max(1, Int((hypot(target.x - last.x, target.y - last.y) / 4).rounded(.up)))
            for step in 1...steps {
                let f = CGFloat(step) / CGFloat(steps)
                let p = NSPoint(x: last.x + (target.x - last.x) * f, y: last.y + (target.y - last.y) * f)
                try await send(.leftMouseDragged, at: p, in: window)
            }
            last = target
        }
        return last
    }

    private var columnTop: CGFloat { Metrics.strip + SpaceTitleSize.room + Metrics.sidePill - 3 + 8 }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(30))
    }
}
