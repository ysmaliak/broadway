import AppKit
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)), .serialized)
@MainActor
final class TabTearOffTests {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var markers: [SplitDropMarker] = []
    private var before: [Browser] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?
    private var hid = false
    private let height: CGFloat = 500

    init() {
        before = Browsers.all
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        TearOff.shared.end()
        for marker in markers { TabDrag.shared.unregister(marker) }
        for made in Browsers.all where !before.contains(where: { $0 === made }) && !browsers.contains(where: { $0 === made }) {
            let window = made.window
            Browsers.forget(made)
            made.closeAll()
            window?.contentView = nil
            window?.close()
        }
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers {
            Browsers.forget(browser)
            browser.cancelTabEdit()
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
            Pins.forget(browser.spaceID)
        }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        if hid { NSApp.unhideWithoutActivation() }
    }

    private func makeBrowser(count: Int, isPrivate: Bool = false, splitView: Bool = false) -> Browser {
        _ = NSApplication.shared
        if activationPolicy == nil {
            activationPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.prohibited)
        }
        let prefs = Shared.prefs
        if restorePreferences == nil {
            let previous = (prefs.splitView, prefs.usesSpaces, prefs.sharesPins,
                            prefs.sideWidth)
            restorePreferences = {
                (prefs.splitView, prefs.usesSpaces, prefs.sharesPins,
                 prefs.sideWidth) = previous
            }
        }
        prefs.splitView = splitView
        prefs.usesSpaces = false
        prefs.sharesPins = false
        prefs.sideWidth = 258
        let browser = isPrivate ? Browser(record: WindowRecord(), privateStore: .nonPersistent()) : Browser(record: WindowRecord())
        browser.closeAll()
        browsers.append(browser)
        for index in 0..<count {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "about:blank#row-\(index)")!, title: "row \(index)")
        }
        return browser
    }

    private func makeWindow(_ browser: Browser, x: CGFloat) -> NSWindow {
        let side = browser.prefs.sideWidth
        let window = NSWindow(contentRect: NSRect(x: x, y: -20_000, width: side + 300, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: side + 300, height: height))
        let column = SideColumnView(browser: browser)
        column.frame = NSRect(x: 0, y: 0, width: side, height: height)
        content.addSubview(column)
        window.contentView = content
        browser.window = window
        Browsers.register(browser)
        window.orderFrontRegardless()
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }

    private func row(_ tab: Tab, in window: NSWindow, at share: CGFloat = 0.5) throws -> NSPoint {
        let frame = try #require(Bench.rowFrames[tab.id])
        return NSPoint(x: frame.minX + 40, y: height - (frame.minY + frame.height * share))
    }

    private func screen(_ point: NSPoint, of window: NSWindow) -> NSPoint {
        window.convertPoint(toScreen: point)
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(30))
    }

    private func carry(from start: NSPoint, through screens: [NSPoint], in window: NSWindow) async throws -> NSPoint {
        try await send(.leftMouseDown, at: start, in: window)
        var last = start
        for target in screens.map({ window.convertPoint(fromScreen: $0) }) {
            let steps = max(1, Int((hypot(target.x - last.x, target.y - last.y) / 16).rounded(.up)))
            for step in 1...steps {
                let f = CGFloat(step) / CGFloat(steps)
                try await send(.leftMouseDragged, at: NSPoint(x: last.x + (target.x - last.x) * f, y: last.y + (target.y - last.y) * f), in: window)
            }
            last = target
        }
        return last
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("\(message)", sourceLocation: sourceLocation)
        throw WaitError.timedOut
    }

    private func settle(_ window: NSWindow, _ browser: Browser) async throws {
        try await waitUntil("the rows were not laid out") {
            window.contentView?.layoutSubtreeIfNeeded()
            return browser.tabs.allSatisfy { Bench.rowFrames[$0.id] != nil }
        }
        try await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func hideApp() async throws {
        if !NSApp.isHidden { hid = true }
        NSApp.hide(nil)
        try await waitUntil("the app did not hide") { NSApp.isHidden }
    }

    private func page(_ tab: Tab) async throws -> WKWebView {
        let address = tab.address
        if tab.asleep { _ = tab.wake() }
        let web = tab.web
        for _ in 0..<100 {
            if !web.isLoading, web.url == address, (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await web.evaluateJavaScript("window.keptMark = 7; 7")
        #expect(!tab.asleep)
        #expect(try await kept(web))
        return web
    }

    private func kept(_ web: WKWebView) async throws -> Bool {
        (try await web.evaluateJavaScript("window.keptMark || 0") as? Int) == 7
    }

    private enum WaitError: Error { case timedOut }

    private var strangers: [Browser] {
        Browsers.all.filter { made in !before.contains { $0 === made } && !browsers.contains { $0 === made } }
    }

    @Test func aTabLetGoOverNothingIsInANewWindowWithTheSameWebViewAndNoNewLoad() async throws {
        let browser = makeBrowser(count: 3)
        let window = makeWindow(browser, x: -20_000)
        try await settle(window, browser)
        let moved = browser.tabs[1]
        let web = try await page(moved)
        let start = try row(moved, in: window)
        let away = screen(NSPoint(x: window.frame.width + 200, y: 250), of: window)
        let last = try await carry(from: start, through: [away], in: window)
        #expect(TearOff.shared.out)
        #expect(TearOff.shared.ghost.up)
        #expect(TearOff.shared.target == nil)
        try await hideApp()
        try await send(.leftMouseUp, at: last, in: window)
        try await waitUntil("no new window took the tab") {
            Browsers.all.contains { $0 !== browser && $0.tabs.contains { $0.id == moved.id } }
        }
        let made = try #require(Browsers.all.first { $0 !== browser && $0.tabs.contains { $0.id == moved.id } })
        #expect(!browser.tabs.contains { $0.id == moved.id })
        #expect(moved.built === web)
        #expect(made.activeID == moved.id)
        #expect(try await kept(web), "the page did not load again")
        #expect(made.window?.isVisible != true)
        #expect(!TearOff.shared.ghost.up)
    }

    @Test func aTabLetGoOverAnotherWindowsSidebarLandsWhereTheLineShowedAndIsInFront() async throws {
        let source = makeBrowser(count: 3)
        let target = makeBrowser(count: 3)
        let from = makeWindow(source, x: -20_000)
        let to = makeWindow(target, x: -19_000)
        try await settle(from, source)
        try await settle(to, target)
        let moved = source.tabs[1]
        let web = try await page(moved)
        let rows = target.tabs.map(\.id)
        let over = screen(try row(target.tabs[1], in: to, at: 0.2), of: to)
        let last = try await carry(from: try row(moved, in: from), through: [over], in: from)
        #expect(TearOff.shared.out)
        #expect(TearOff.shared.target === target)
        let place = try #require(TearOff.shared.place)
        #expect(place == .loose(LoosePlace(before: .tab(rows[1]))))
        #expect(SidePageView.benchDrop["line"] != nil, "the line shows where it will land")
        try await send(.leftMouseUp, at: last, in: from)
        try await waitUntil("the tab did not arrive") { target.tabs.contains { $0.id == moved.id } }
        #expect(target.tabs.map(\.id) == [rows[0], moved.id, rows[1], rows[2]])
        #expect(target.activeID == moved.id)
        #expect(moved.built === web)
        #expect(try await kept(web))
        #expect(!source.tabs.contains { $0.id == moved.id })
    }

    private func folded(_ browser: Browser, _ tabs: [Tab]) -> UUID {
        let id = browser.addExtensionGroup(containing: tabs[0])
        for tab in tabs.dropFirst() { browser.move(tab, toGroup: id) }
        return id
    }

    @Test func aTabLetGoOnAnotherWindowsFolderRowGoesIntoThatFolderInFront() async throws {
        let source = makeBrowser(count: 3)
        let target = makeBrowser(count: 4)
        let folder = folded(target, [target.tabs[0], target.tabs[1]])
        let from = makeWindow(source, x: -20_000)
        let to = makeWindow(target, x: -19_000)
        try await settle(from, source)
        try await settle(to, target)
        let inside = target.tabs.filter { $0.groupID == folder }
        #expect(inside.count == 2)
        let moved = source.tabs[1]
        let over = screen(try row(inside[1], in: to, at: 0.2), of: to)
        let last = try await carry(from: try row(moved, in: from), through: [over], in: from)
        #expect(TearOff.shared.target === target)
        guard case .folder(let drop)? = TearOff.shared.place else {
            Issue.record("no folder place: \(String(describing: TearOff.shared.place))")
            return
        }
        #expect(drop.group == folder)
        #expect(SidePageView.benchDrop["group"] != nil)
        try await send(.leftMouseUp, at: last, in: from)
        try await waitUntil("the tab did not arrive") { target.tabs.contains { $0.id == moved.id } }
        #expect(moved.groupID == folder)
        #expect(target.activeID == moved.id)
        let members = target.tabs.filter { $0.groupID == folder }.map(\.id)
        #expect(members.count == 3)
        if drop.member == inside[1].id, !drop.after {
            #expect(members == [inside[0].id, moved.id, inside[1].id])
        }
    }

    @Test func aTabLetGoOnALooseRowBesideAFolderStaysLooseWhereTheLineShowed() async throws {
        let source = makeBrowser(count: 3)
        let target = makeBrowser(count: 4)
        let folder = folded(target, [target.tabs[0], target.tabs[1]])
        let from = makeWindow(source, x: -20_000)
        let to = makeWindow(target, x: -19_000)
        try await settle(from, source)
        try await settle(to, target)
        let loose = target.tabs.filter { $0.groupID == nil }
        #expect(loose.count == 2)
        let moved = source.tabs[1]
        let over = screen(try row(loose[1], in: to, at: 0.2), of: to)
        let last = try await carry(from: try row(moved, in: from), through: [over], in: from)
        #expect(TearOff.shared.place == .loose(LoosePlace(before: .tab(loose[1].id))))
        try await send(.leftMouseUp, at: last, in: from)
        try await waitUntil("the tab did not arrive") { target.tabs.contains { $0.id == moved.id } }
        #expect(moved.groupID == nil)
        #expect(target.tabs.filter { $0.groupID == nil }.map(\.id) == [loose[0].id, moved.id, loose[1].id])
        #expect(target.tabs.filter { $0.groupID == folder }.count == 2)
        #expect(target.activeID == moved.id)
    }

    @Test func aRowInALiveFolderNeverComesAwayEvenWithoutItsKey() async throws {
        let browser = makeBrowser(count: 3)
        let folder = folded(browser, [browser.tabs[0]])
        let index = try #require(browser.tabGroups.firstIndex { $0.id == folder })
        browser.tabGroups[index].live = true
        let held = browser.tabs[0]
        #expect(!TearOff.mayLeave(held, in: browser))
        browser.tabGroups[index].live = false
        #expect(TearOff.mayLeave(held, in: browser))
    }

    @Test func aTabLetGoOverAnotherWindowsPageGoesAfterTheTabItIsOnAsBefore() async throws {
        let source = makeBrowser(count: 3)
        let target = makeBrowser(count: 3)
        let from = makeWindow(source, x: -20_000)
        let to = makeWindow(target, x: -19_000)
        try await settle(from, source)
        try await settle(to, target)
        target.select(target.tabs[0])
        let rows = target.tabs.map(\.id)
        let moved = source.tabs[2]
        let over = screen(NSPoint(x: target.prefs.sideWidth + 150, y: 250), of: to)
        let last = try await carry(from: try row(moved, in: from), through: [over], in: from)
        #expect(TearOff.shared.target === target)
        #expect(TearOff.shared.place == nil)
        let expected = target.placeForNew()
        try await send(.leftMouseUp, at: last, in: from)
        try await waitUntil("the tab did not arrive") { target.tabs.contains { $0.id == moved.id } }
        #expect(target.tabs.firstIndex { $0.id == moved.id } == expected)
        #expect(target.tabs.filter { $0.id != moved.id }.map(\.id) == rows)
        #expect(target.activeID == moved.id)
    }

    @Test func aTabLetGoTwelvePointsOrLessOutsideStaysAReorder() async throws {
        let browser = makeBrowser(count: 3)
        let window = makeWindow(browser, x: -20_000)
        try await settle(window, browser)
        let moved = browser.tabs[1]
        let edge = screen(NSPoint(x: -10, y: try row(moved, in: window).y), of: window)
        let last = try await carry(from: try row(moved, in: window), through: [edge], in: window)
        #expect(!TearOff.shared.out)
        #expect(!TearOff.shared.ghost.up)
        try await send(.leftMouseUp, at: last, in: window)
        try await Task.sleep(for: .milliseconds(300))
        #expect(browser.tabs.contains { $0.id == moved.id })
        #expect(strangers.isEmpty)
    }

    @Test func aTabBroughtBackInsideBeforeLettingGoStaysInItsWindow() async throws {
        let browser = makeBrowser(count: 3)
        let window = makeWindow(browser, x: -20_000)
        try await settle(window, browser)
        let moved = browser.tabs[1]
        let start = try row(moved, in: window)
        let away = screen(NSPoint(x: window.frame.width + 200, y: 250), of: window)
        let back = screen(NSPoint(x: start.x, y: start.y - 30), of: window)
        let last = try await carry(from: start, through: [away, back], in: window)
        #expect(!TearOff.shared.out)
        #expect(!TearOff.shared.ghost.up)
        try await send(.leftMouseUp, at: last, in: window)
        try await Task.sleep(for: .milliseconds(300))
        #expect(browser.tabs.contains { $0.id == moved.id })
        #expect(strangers.isEmpty)
    }

    @Test func theOnlyTabOfAWindowLetGoOverNothingStays() async throws {
        let browser = makeBrowser(count: 1)
        let window = makeWindow(browser, x: -20_000)
        try await settle(window, browser)
        let only = browser.tabs[0]
        let away = screen(NSPoint(x: window.frame.width + 200, y: 250), of: window)
        let last = try await carry(from: try row(only, in: window), through: [away], in: window)
        #expect(TearOff.shared.out)
        try await send(.leftMouseUp, at: last, in: window)
        try await Task.sleep(for: .milliseconds(300))
        #expect(browser.tabs.map(\.id) == [only.id])
        #expect(strangers.isEmpty)
    }

    @Test func theOnlyTabOfAWindowGoesIntoAnotherWindowsSidebar() async throws {
        let source = makeBrowser(count: 1)
        let target = makeBrowser(count: 2)
        let from = makeWindow(source, x: -20_000)
        let to = makeWindow(target, x: -19_000)
        try await settle(from, source)
        try await settle(to, target)
        let only = source.tabs[0]
        let over = screen(try row(target.tabs[0], in: to, at: 0.2), of: to)
        let last = try await carry(from: try row(only, in: from), through: [over], in: from)
        try await send(.leftMouseUp, at: last, in: from)
        try await waitUntil("the tab did not arrive") { target.tabs.contains { $0.id == only.id } }
        #expect(target.tabs.first?.id == only.id)
        #expect(!source.tabs.contains { $0.id == only.id })
    }

    @Test func aPinNeverComesAway() async throws {
        let browser = makeBrowser(count: 3)
        browser.pin(browser.tabs[0])
        let window = makeWindow(browser, x: -20_000)
        try await settle(window, browser)
        let pin = browser.tabs[0]
        let start = try row(pin, in: window)
        let away = screen(NSPoint(x: window.frame.width + 200, y: 250), of: window)
        let last = try await carry(from: start, through: [away], in: window)
        #expect(!TearOff.shared.out)
        #expect(!TearOff.shared.ghost.up)
        try await send(.leftMouseUp, at: last, in: window)
        try await Task.sleep(for: .milliseconds(300))
        #expect(browser.tabs.contains { $0.id == pin.id })
        #expect(strangers.isEmpty)
    }

    @Test(arguments: ["live", "agent"])
    func aLiveFolderRowAndAnAgentsTabNeverComeAway(kind: String) async throws {
        let browser = makeBrowser(count: 3)
        let window = makeWindow(browser, x: -20_000)
        try await settle(window, browser)
        let held = browser.tabs[1]
        if kind == "live" { held.liveKey = "fixture:item" } else { held.agent = true }
        defer { held.liveKey = nil; held.agent = false }
        let page = try #require(window.contentView?.kitSubviews(of: SidePageView.self).first { $0.preview == nil })
        let away = screen(NSPoint(x: window.frame.width + 200, y: 250), of: window)
        #expect(!TearOff.shared.drag(page, tab: held, at: away, moved: nil))
        #expect(!TearOff.shared.ghost.up)
        #expect(!TearOff.shared.letGo(page, held))
        #expect(browser.tabs.contains { $0.id == held.id })
    }

    @Test func aPrivateTabNeverLandsInAnOrdinaryWindow() async throws {
        let source = makeBrowser(count: 2, isPrivate: true)
        let target = makeBrowser(count: 2)
        let from = makeWindow(source, x: -20_000)
        let to = makeWindow(target, x: -19_000)
        try await settle(from, source)
        try await settle(to, target)
        let moved = source.tabs[1]
        let over = screen(try row(target.tabs[1], in: to, at: 0.2), of: to)
        let last = try await carry(from: try row(moved, in: from), through: [over], in: from)
        #expect(TearOff.shared.out)
        #expect(TearOff.shared.target == nil)
        #expect(TearOff.shared.place == nil)
        let line = try #require(to.contentView?.kitSubviews(of: SidePageView.self).first { $0.preview == nil })
        #expect(line.looseOn == nil && line.dropOn == nil, "no line in a window that cannot take it")
        try await hideApp()
        try await send(.leftMouseUp, at: last, in: from)
        try await waitUntil("no private window took the tab") {
            Browsers.all.contains { $0 !== source && $0.tabs.contains { $0.id == moved.id } }
        }
        let made = try #require(Browsers.all.first { $0 !== source && $0.tabs.contains { $0.id == moved.id } })
        #expect(made.isPrivate)
        #expect(!target.tabs.contains { $0.id == moved.id })
    }

    @Test func escapeWhileOutsidePutsTheTabBack() async throws {
        let browser = makeBrowser(count: 3, splitView: true)
        let window = makeWindow(browser, x: -20_000)
        try await settle(window, browser)
        let order = browser.tabs.map(\.id)
        let moved = browser.tabs[1]
        let away = screen(NSPoint(x: window.frame.width + 200, y: 250), of: window)
        let last = try await carry(from: try row(moved, in: window), through: [away], in: window)
        #expect(TearOff.shared.out)
        TabDrag.shared.benchCancel()
        #expect(!TearOff.shared.out)
        #expect(!TearOff.shared.ghost.up)
        try await send(.leftMouseDragged, at: NSPoint(x: last.x + 4, y: last.y), in: window)
        try await send(.leftMouseUp, at: NSPoint(x: last.x + 4, y: last.y), in: window)
        try await Task.sleep(for: .milliseconds(300))
        #expect(browser.tabs.map(\.id) == order)
        #expect(strangers.isEmpty)
    }

    @Test func aDropOnItsOwnWindowsPageStillMakesASplit() async throws {
        let browser = makeBrowser(count: 3, splitView: true)
        let window = makeWindow(browser, x: -20_000)
        try await settle(window, browser)
        let front = browser.tabs[0]
        browser.select(front)
        let marker = SplitDropMarker(frame: NSRect(x: browser.prefs.sideWidth, y: 0, width: 300, height: height))
        marker.browser = browser
        marker.tab = front
        marker.kind = .stage
        window.contentView?.addSubview(marker)
        TabDrag.shared.register(marker)
        markers.append(marker)
        let moved = browser.tabs[2]
        let edge = screen(NSPoint(x: browser.prefs.sideWidth + 280, y: 250), of: window)
        let last = try await carry(from: try row(moved, in: window), through: [edge], in: window)
        #expect(!TearOff.shared.out)
        try await Task.sleep(for: .milliseconds(200))
        try await send(.leftMouseDragged, at: last, in: window)
        try await Task.sleep(for: .milliseconds(200))
        try await send(.leftMouseUp, at: last, in: window)
        try await waitUntil("no split was made") { browser.split(for: moved) != nil }
        #expect(browser.split(for: moved)?.contains(front.id) == true)
    }

    @Test func thePictureSitsWithThePointerTwentyFourInAndSixteenBelowItsTop() async throws {
        let browser = makeBrowser(count: 2)
        let window = makeWindow(browser, x: -20_000)
        try await settle(window, browser)
        let away = screen(NSPoint(x: window.frame.width + 200, y: 250), of: window)
        _ = try await carry(from: try row(browser.tabs[1], in: window), through: [away], in: window)
        let ghost = TearOff.shared.ghost
        #expect(ghost.up)
        let point = TearOff.shared.point
        let room = TearLook.room
        #expect(ghost.frame.minX + room + TearLook.grab.width == point.x)
        #expect(ghost.frame.maxY - room - TearLook.grab.height == point.y)
        #expect(ghost.frame.width == TearLook.width + 2 * room)
        TearOff.shared.end()
    }

    @Test func aPictureIsCroppedFromTheTopToAtMostSixteenByTen() throws {
        func image(_ width: Int, _ height: Int) throws -> NSImage {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
            let made = NSImage(size: NSSize(width: width, height: height))
            made.addRepresentation(rep)
            return made
        }
        let tall = try #require(TearGhostView.cropped(try image(400, 1000)))
        #expect(tall.size == NSSize(width: 220, height: 138))
        #expect(tall.image.height == 250)
        let wide = try #require(TearGhostView.cropped(try image(400, 100)))
        #expect(wide.size == NSSize(width: 220, height: 55))
        #expect(wide.image.height == 100)
    }
}
