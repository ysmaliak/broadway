import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SidebarPressTests {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    private let realInput = HeldInput.source

    init() async throws {
        addTeardownBlock { try await self.tearDown() }
        HeldInput.source = { (0, []) }
    }

    private func tearDown() async throws {
        HeldInput.source = realInput
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.cancelTabEdit(); browser.closeAll() }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        try await settle()
    }

    @Test func selectsOnPressWithoutEditingOnRelease() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        let window = makeWindow(browser)
        try await settle()
        let point = rowPoint(0, in: window)
        try await send(.leftMouseDown, at: point, in: window)
        #expect(browser.activeID == first.id, "The page must change while the button is held")
        #expect(browser.editingTab == nil)
        try await send(.leftMouseUp, at: point, in: window)
        #expect(browser.editingTab == nil, "Releasing the selecting press must not edit the address")
        try await send(.leftMouseDown, at: point, in: window)
        try await send(.leftMouseUp, at: point, in: window)
        #expect(browser.editingTab == nil, "With the address pill up, the pill edits, not the row")
        let pill = browser.prefs.addressBar
        defer { browser.prefs.addressBar = pill }
        browser.prefs.addressBar = false
        try await settle()
        let bare = NSPoint(x: point.x, y: point.y + Metrics.sidePill - 3 + 8)
        try await send(.leftMouseDown, at: bare, in: window)
        try await send(.leftMouseUp, at: bare, in: window)
        #expect(browser.editingTab == first.id, "Without the pill, a click on the active row edits")
    }

    @Test func optionClickOpensTheRowInSplitViewBesideThePageInFront() async throws {
        let browser = makeBrowser()
        browser.prefs.splitView = true
        let first = browser.tabs[0], front = try #require(browser.active)
        let window = makeWindow(browser)
        try await settle()
        let point = rowPoint(0, in: window)

        try await send(.leftMouseDown, at: point, in: window, flags: .option)
        let pressed = browser.activeID
        try await send(.leftMouseUp, at: point, in: window, flags: .option)

        #expect(pressed == front.id, "The press must not select the row first")
        let pair = try #require(browser.split(for: first))
        #expect(pair.contains(front.id))
        #expect(browser.selectedTabIDs.isEmpty)
    }

    @Test func optionClickOnTheTabInFrontSelectsAsAPlainClick() async throws {
        let browser = makeBrowser()
        browser.prefs.splitView = true
        let first = browser.tabs[0]
        browser.select(first)
        let window = makeWindow(browser)
        try await settle()
        let point = rowPoint(0, in: window)

        try await send(.leftMouseDown, at: point, in: window, flags: .option)
        try await send(.leftMouseUp, at: point, in: window, flags: .option)

        #expect(browser.split(for: first) == nil)
        #expect(browser.activeID == first.id)
    }

    @Test func optionClickWithSplitViewOffSelectsAsAPlainClick() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        let window = makeWindow(browser)
        try await settle()
        let point = rowPoint(0, in: window)

        try await send(.leftMouseDown, at: point, in: window, flags: .option)
        try await send(.leftMouseUp, at: point, in: window, flags: .option)

        #expect(browser.split(for: first) == nil)
        #expect(browser.activeID == first.id)
    }

    @Test func commandOptionClickStillPicksTheRow() async throws {
        let browser = makeBrowser()
        browser.prefs.splitView = true
        let first = browser.tabs[0]
        let window = makeWindow(browser)
        try await settle()
        let point = rowPoint(0, in: window)

        try await send(.leftMouseDown, at: point, in: window, flags: [.command, .option])
        try await send(.leftMouseUp, at: point, in: window, flags: [.command, .option])

        #expect(browser.split(for: first) == nil)
        #expect(browser.selectedTabIDs.contains(first.id))
    }

    @Test func spaceNameSitsAboveThePillAndRows() async throws {
        let browser = makeBrowser()
        let window = makeWindow(browser)
        try await settle()
        let titleMiddle = Metrics.strip - SpaceTitleSize.lift + SpaceTitleSize.height / 2
        let pillMiddle = Metrics.strip + SpaceTitleSize.room - 3 + Metrics.sidePill / 2
        let pill = NSPoint(x: 180, y: window.frame.height - pillMiddle)

        try await send(.leftMouseDown, at: pill, in: window)
        try await send(.leftMouseUp, at: pill, in: window)

        #expect((Metrics.strip - 10) < titleMiddle, "The name has its own line under the window buttons' strip")
        #expect((titleMiddle + SpaceTitleSize.height / 2) <= (pillMiddle - Metrics.sidePill / 2))
        #expect(browser.editing, "The pill sits under the name")
        #expect((pillMiddle + Metrics.sidePill / 2) < (window.frame.height - rowPoint(0, in: window).y))
    }

    @Test func pressThenDragStillReordersWithoutEditing() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        let window = makeWindow(browser)
        try await settle()
        let start = rowPoint(0, in: window)
        try await send(.leftMouseDown, at: start, in: window)
        #expect(browser.activeID == first.id)
        let twoRows = 2 * (Metrics.sideRowHeight + 5)
        for distance in [8.0, 20, 40, 60, twoRows] {
            try await send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - distance), in: window)
        }
        try await send(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - twoRows), in: window)
        try await settle()
        #expect(browser.tabs.last?.id == first.id)
        #expect(browser.editingTab == nil)
    }

    @Test func siblingControlsDoNotSelectTheRow() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0], before = browser.activeID
        #expect(before != first.id)
        first.muted = true
        let window = makeWindow(browser)
        try await settle()
        let square = Metrics.closeSquare(Metrics.sideRowHeight), inset = Metrics.closeInset(Metrics.sideRowHeight)
        let speaker = NSPoint(x: Metrics.sideInset + SideLook.rowLead + SideLook.rowMark / 2, y: rowPoint(0, in: window).y)

        try await dispatch(.leftMouseDown, at: speaker, in: window)
        let selectedOnPress = browser.activeID
        try await dispatch(.leftMouseUp, at: speaker, in: window)
        try await eventually { !first.muted }

        #expect(selectedOnPress == before, "A press on the speaker must not select its row")
        #expect(browser.activeID == before)
        #expect(!first.muted)
    }

    @Test func theSpeakerLeadsTheFaviconAtTheCloseIconsSizeAndComesAndGoesInMotion() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        let window = makeWindow(browser)
        try await settle()
        let column = try #require(window.contentView)
        let row = try #require(column.kitSubviews(of: TabRowView.self).first { $0.accessibilityLabel() == first.label && $0.window != nil })
        let speaker = try #require(row.kitSubviews(of: CloseSpotView.self).first { $0.swaps })
        let mark = try #require(row.kitSubviews(of: RowMarkView.self).first)
        let rest = mark.frame.minX
        #expect(speaker.isHidden)

        first.muted = true
        var slid = false
        for _ in 0..<400 where speaker.isHidden || !slid {
            slid = slid || mark.superview?.layer?.animation(forKey: "speaker") != nil
            try await Task.sleep(for: .milliseconds(5))
        }
        row.layoutSubtreeIfNeeded()

        #expect(!speaker.isHidden)
        #expect(speaker.frame.midX == rest + SideLook.rowMark / 2, "the speaker takes the icon column")
        #expect(mark.frame.minX == rest + SideLook.rowMark + SideLook.markGap, "the favicon moves one column over")
        #expect(speaker.side == Metrics.closeSquare(Metrics.sideRowHeight) && speaker.face == nil, "the close cross's size")
        #expect(slid || !Motion.kitSettle.animates, "the favicon and title slide over")

        first.muted = false
        try await eventually { speaker.isHidden }
        row.layoutSubtreeIfNeeded()

        #expect(speaker.isHidden)
        #expect(speaker.alphaValue == 1, "left ready for the next time")
        #expect(mark.frame.minX == rest)
    }

    @Test func theSpeakerRestsAtItsHoveredSizeHoweverItsAppearRan() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        let window = makeWindow(browser)
        try await settle()
        let column = try #require(window.contentView)
        let row = try #require(column.kitSubviews(of: TabRowView.self).first { $0.accessibilityLabel() == first.label && $0.window != nil })
        let speaker = try #require(row.kitSubviews(of: CloseSpotView.self).first { $0.swaps })
        let glyph = try #require(speaker.mark.kitSubviews(of: KitSymbol.self).first)
        let full = CloseMarkView()
        full.side = Metrics.closeSquare(Metrics.sideRowHeight)
        let fullStyle = try #require(full.kitSubviews(of: KitSymbol.self).first).style

        func expectFullSize(_ moment: Comment) throws {
            let layer = try #require(speaker.layer)
            let shown = (layer.presentation() ?? layer).transform
            #expect(!speaker.isHidden, moment)
            #expect(CATransform3DIsIdentity(layer.transform) && CATransform3DIsIdentity(shown), moment)
            if let scaling = layer.animation(forKey: "transform") as? CABasicAnimation {
                let lands = (scaling.toValue as? NSValue)?.caTransform3DValue
                #expect(lands.map(CATransform3DIsIdentity) == true, moment)
                #expect(layer.convertTime(CACurrentMediaTime(), from: nil) >= scaling.beginTime + scaling.duration, moment)
            }
            #expect(speaker.alphaValue == 1, moment)
            #expect(glyph.style == fullStyle, moment)
            #expect(glyph.image === KitSymbol.image(glyph.name, fullStyle), moment)
            #expect(glyph.layer?.animation(forKey: KitSwap.leave) == nil, moment)
            let rest = glyph.image
            speaker.mark.over = true
            #expect(glyph.image === rest, moment)
            speaker.mark.over = false
        }

        first.muted = true
        try await eventually { !speaker.isHidden && speaker.layer?.animation(forKey: "transform") == nil }
        try await Task.sleep(for: .milliseconds(300))

        try expectFullSize("after a plain appear")

        first.muted = false
        try await Task.sleep(for: .milliseconds(20))
        first.muted = true
        try await Task.sleep(for: .milliseconds(20))
        first.muted = false
        try await eventually { speaker.isHidden }
        first.muted = true
        try await Task.sleep(for: .milliseconds(10))
        row.layoutSubtreeIfNeeded()
        first.muted = false
        row.layoutSubtreeIfNeeded()
        first.muted = true
        try await Task.sleep(for: .seconds(SideLook.speakerLeave + 0.5))

        try expectFullSize("after appears cut short by leaves")

        first.noisy = true
        first.muted = false
        try await Task.sleep(for: .milliseconds(Int(KitSwap.out * 1000) + 400))

        #expect(glyph.name == "speaker.wave.2")
        try expectFullSize("after unmuting swaps the picture in place")
        #expect(Motion.kitSettle.animates || Motion.reduced, "the appear's motion ran")
    }

    @Test func pinSelectsOnPressAndStillDoubleClicks() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        browser.pin(first)
        let window = makeWindow(browser)
        try await settle()
        let point = NSPoint(x: 40, y: window.frame.height - columnTop - 22)
        try await send(.leftMouseDown, at: point, in: window)
        #expect(browser.activeID == first.id)
        try await send(.leftMouseUp, at: point, in: window)
        #expect(browser.editingPin == nil)
        try await doubleClick(at: point, in: window)
        #expect(browser.editingPin == first.id, "A pin already home still edits its letter on double-click")
    }

    @Test func eachSplitHalfFocusesOnPressWithoutEditingOnRelease() async throws {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.prefs.splitView = true
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.select(tabs[2])
        let window = makeWindow(browser)
        try await settle()
        let row = rowPoint(0, in: window)
        for (index, point) in [(0, row), (1, NSPoint(x: window.frame.width - 60, y: row.y))] {
            try await send(.leftMouseDown, at: point, in: window)
            #expect(browser.activeID == tabs[index].id)
            try await send(.leftMouseUp, at: point, in: window)
            #expect(browser.editingTab == nil)
            try await settle()
        }
    }

    @Test func splitPaddingClickAfterEarlierSelectionIsNotSuppressed() async throws {
        let browser = makeBrowser()
        let tabs = browser.tabs
        browser.prefs.splitView = true
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.select(tabs[2])
        let window = makeWindow(browser)
        try await settle()
        let title = rowPoint(0, in: window)
        try await send(.leftMouseDown, at: title, in: window)
        try await send(.leftMouseUp, at: title, in: window)
        browser.select(tabs[2])
        try await settle()
        let padding = NSPoint(x: 14, y: title.y)
        try await send(.leftMouseDown, at: padding, in: window)
        #expect(browser.activeID == tabs[0].id, "The leading padding must also select on press")
        try await send(.leftMouseUp, at: padding, in: window)
        #expect(browser.activeID == tabs[0].id)
    }

    @Test func smallPointerMovementDoesNotTurnSelectionIntoEditing() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        let window = makeWindow(browser)
        try await settle()
        let start = rowPoint(0, in: window)
        let end = NSPoint(x: start.x + 1, y: start.y)
        try await send(.leftMouseDown, at: start, in: window)
        try await send(.leftMouseDragged, at: end, in: window)
        try await send(.leftMouseUp, at: end, in: window)
        #expect(browser.activeID == first.id)
        #expect(browser.editingTab == nil)
    }

    // What else a press in the column does, checked when it landed (#625).

    @Test func pressOnTheCrossLeavesTheRowAlone() async throws {
        // The cross itself answers only under a real pointer (onHover), which
        // a hidden test can't give; that it closes is checked by hand. Here:
        // its place at the end of the row takes the press, so the row isn't
        // selected under a click meant for the cross.
        let browser = makeBrowser()
        let first = browser.tabs[0], before = browser.activeID
        #expect(before != first.id)
        let window = makeWindow(browser)
        try await settle()
        let cross = NSPoint(x: browser.prefs.sideWidth - 24, y: rowPoint(0, in: window).y)
        try await send(.leftMouseDown, at: cross, in: window)
        #expect(browser.activeID == before, "A press on the cross must not select its row")
        try await send(.leftMouseUp, at: cross, in: window)
        try await settle()
        #expect(browser.activeID == before)
        #expect(browser.tabs.contains { $0 === first })
        let title = rowPoint(0, in: window)
        try await send(.leftMouseDown, at: title, in: window)
        #expect(browser.activeID == first.id, "The rest of the row still selects on press")
        try await send(.leftMouseUp, at: title, in: window)
    }

    @Test func renameFieldKeepsItsClicks() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0]
        browser.select(first)
        let window = makeWindow(browser)
        try await settle()
        browser.beginTabRename(first)
        try await settle()
        // The field's own press waits in a loop for its release from the
        // queue: the release is queued first, in this process only.
        let point = rowPoint(0, in: window)
        NSApp.postEvent(try event(.leftMouseUp, at: point, in: window), atStart: false)
        window.sendEvent(try event(.leftMouseDown, at: point, in: window))
        try await settle()
        #expect(browser.editingTab == first.id, "A click in the name field keeps the rename open")
        #expect(browser.renamingTab)
        #expect(browser.activeID == first.id)
        browser.tabDraft = "Renamed"
        browser.commitTabEdit()
        #expect(first.name == "Renamed")
    }

    @Test func otherButtonsDoNotSelectOnPress() async throws {
        let browser = makeBrowser()
        let first = browser.tabs[0], before = browser.activeID
        #expect(before != first.id)
        let window = makeWindow(browser)
        try await settle()
        let point = rowPoint(0, in: window)
        let row = try #require(window.contentView?.hitTest(point).flatMap(rowView))

        let menu = row.menu(for: try event(.rightMouseDown, at: point, in: window))
        try await dispatch(.otherMouseDown, at: rowPoint(1, in: window), in: window)
        let pressedOther = browser.activeID
        try await dispatch(.otherMouseUp, at: rowPoint(1, in: window), in: window)
        try await settle()

        #expect(menu != nil, "Right-click stays the menu's")
        #expect(pressedOther == before, "Only the left button selects on press")
        #expect(browser.activeID == before)
        try await dispatch(.leftMouseDown, at: point, in: window)
        #expect(browser.activeID == first.id, "The same route with the left button does select")
        try await dispatch(.leftMouseUp, at: point, in: window)
    }

    @Test func pressingAnUnselectedRowBringsItsSlabInsideThePress() async throws {
        let restore = motionOn()
        defer { restore() }
        let browser = makeBrowser()
        let first = browser.tabs[0]
        #expect(browser.activeID != first.id)
        let window = makeWindow(browser)
        try await settle()
        let point = rowPoint(0, in: window)
        let row = try #require(window.contentView?.hitTest(point).flatMap(rowView))
        let (face, live, content) = row.pressLayers
        let pressed = try #require(face)

        try await send(.leftMouseDown, at: point, in: window)
        var grew = false
        for _ in 0..<20 {
            grew = grew || live?.animation(forKey: "grow") != nil
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(browser.activeID == first.id)
        #expect(live?.superlayer === pressed, "The slab sits in the pressed face")
        #expect(content?.superlayer === pressed, "The row's content sits in the same face")
        #expect(abs(pressed.transform.m11 - Motion.give) < 0.0001)
        #expect(abs(pressed.transform.m22 - Motion.give) < 0.0001)
        #expect(CATransform3DIsIdentity(live?.transform ?? CATransform3DIdentity))
        #expect(CATransform3DIsIdentity(content?.transform ?? CATransform3DIdentity))
        #expect(!grew, "No second scale runs against the press")
        let middle = CGPoint(x: pressed.bounds.midX, y: pressed.bounds.midY)
        let pivot = CGPoint(x: middle.x * pressed.transform.m11 + pressed.transform.m41,
                            y: middle.y * pressed.transform.m22 + pressed.transform.m42)
        #expect(abs(pivot.x - middle.x) < 0.01 && abs(pivot.y - middle.y) < 0.01, "The press scales about the row's centre")
        #expect(pressed.anchorPoint == .zero)

        try await send(.leftMouseUp, at: point, in: window)

        #expect(CATransform3DIsIdentity(pressed.transform), "Release springs the face back")
    }

    @Test func aSelectionWithoutAPressStillArrives() async throws {
        let restore = motionOn()
        defer { restore() }
        let browser = makeBrowser()
        let first = browser.tabs[0]
        let window = makeWindow(browser)
        try await settle()
        let row = try #require(window.contentView?.hitTest(rowPoint(0, in: window)).flatMap(rowView))
        let live = try #require(row.pressLayers.live)

        browser.select(first)
        var grew = false
        for _ in 0..<20 where !grew {
            grew = live.animation(forKey: "grow") != nil
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(grew, "A keyboard or switcher selection keeps its gentle arrive")
        #expect(CATransform3DIsIdentity(try #require(row.pressLayers.face).transform))
    }

    private func motionOn() -> () -> Void {
        let store = Store.settings
        let saved = ["motion.testReduced", "motion.testLowPower"].map { ($0, store.object(forKey: $0)) }
        for (key, _) in saved { store.set(false, forKey: key) }
        return { for (key, value) in saved { store.set(value, forKey: key) } }
    }

    private func rowView(_ view: NSView) -> TabRowView? {
        var view: NSView? = view
        while let found = view {
            if let row = found as? TabRowView { return row }
            view = found.superview
        }
        return nil
    }

    @Test func pinDragStillReorders() async throws {
        let browser = makeBrowser()
        let (first, second) = (browser.tabs[0], browser.tabs[1])
        browser.pin(first)
        browser.pin(second)
        let window = makeWindow(browser)
        try await settle()
        let start = NSPoint(x: 40, y: window.frame.height - columnTop - 22)
        try await send(.leftMouseDown, at: start, in: window)
        #expect(browser.activeID == first.id)
        for distance in [8.0, 20, 40, 60, 80] {
            try await send(.leftMouseDragged, at: NSPoint(x: start.x + distance, y: start.y), in: window)
        }
        try await send(.leftMouseUp, at: NSPoint(x: start.x + 80, y: start.y), in: window)
        try await settle()
        #expect(browser.tabs.prefix(2).map(\.id) == [second.id, first.id], "A pin carried past the next swaps with it")
        #expect(browser.editingPin == nil)
    }

    @Test func aFaviconArrivingMidCarryKeepsThePinInHand() async throws {
        let browser = makeBrowser()
        let glyph = browser.prefs.glyph
        defer { browser.prefs.glyph = glyph }
        browser.prefs.glyph = .icons
        let (first, second) = (browser.tabs[0], browser.tabs[1])
        browser.pin(first)
        browser.pin(second)
        let window = makeWindow(browser)
        try await settle()
        let start = NSPoint(x: 40, y: window.frame.height - columnTop - 22)

        try await send(.leftMouseDown, at: start, in: window)
        for distance in [8.0, 20] {
            try await send(.leftMouseDragged, at: NSPoint(x: start.x + distance, y: start.y), in: window)
        }
        first.icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        try await Task.sleep(for: .milliseconds(120))
        for distance in [40.0, 60, 80] {
            try await send(.leftMouseDragged, at: NSPoint(x: start.x + distance, y: start.y), in: window)
        }
        try await send(.leftMouseUp, at: NSPoint(x: start.x + 80, y: start.y), in: window)
        try await settle()

        #expect(browser.tabs.prefix(2).map(\.id) == [second.id, first.id], "The pin stays in the hand through its favicon")
    }

    @Test func aFaviconArrivingMidCarryKeepsTheRowInHand() async throws {
        let browser = makeBrowser()
        let glyph = browser.prefs.glyph
        defer { browser.prefs.glyph = glyph }
        browser.prefs.glyph = .icons
        let first = browser.tabs[0]
        let window = makeWindow(browser)
        try await settle()
        let start = rowPoint(0, in: window)
        let twoRows = 2 * (Metrics.sideRowHeight + 5)

        try await send(.leftMouseDown, at: start, in: window)
        for distance in [8.0, 20] {
            try await send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - distance), in: window)
        }
        first.icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        try await Task.sleep(for: .milliseconds(120))
        for distance in [40.0, 60, twoRows] {
            try await send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - distance), in: window)
        }
        try await send(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - twoRows), in: window)
        try await settle()

        #expect(browser.tabs.last?.id == first.id, "The row stays in the hand through its favicon")
    }

    /// The press that selects (TabPress) held the drag back until the
    /// release: nothing moved under the hand, the row jumped on letting go,
    /// and a pin held still a moment before letting go wasn't moved at all.
    @Test func rowsAndPinsMoveWhileTheButtonIsDown() async throws {
        for kind in ["row", "pin"] {
            let browser = makeBrowser()
            let tabs = browser.tabs
            if kind == "pin" { browser.pin(tabs[0]); browser.pin(tabs[1]) }
            let window = makeWindow(browser)
            try await settle()
            let before = browser.tabs.map(\.id)
            let start = kind == "pin" ? NSPoint(x: 40, y: window.frame.height - columnTop - 22) : rowPoint(0, in: window)
            try await send(.leftMouseDown, at: start, in: window)
            var last = start
            for distance in [8.0, 20, 40, 60, 80] {
                last = kind == "pin" ? NSPoint(x: start.x + distance, y: start.y) : NSPoint(x: start.x, y: start.y - distance * 0.8)
                try await send(.leftMouseDragged, at: last, in: window)
            }
            if kind == "pin" {
                try await eventually { browser.tabs.map(\.id) != before }
                #expect(browser.tabs.map(\.id) != before, "pin: the tiles make room while the button is still down")
            } else {
                #expect(browser.tabs.map(\.id) == before, "row: the list waits for the release")
            }
            // Held still a little, then let go (not long: a window off the
            // screen gets no real button, and a pin's tooltip ends the drag).
            try await Task.sleep(for: .milliseconds(150))
            try await send(.leftMouseUp, at: last, in: window)
            try await settle()
            #expect(browser.tabs.map(\.id) != before, "\(kind): still moved once let go")
            #expect(browser.editingTab == nil)
            #expect(browser.editingPin == nil)
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
        }
    }

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        if activationPolicy == nil { activationPolicy = NSApp.activationPolicy() }
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        if restorePreferences == nil {
            let previous = (prefs.usesTabGroups, prefs.splitView)
            restorePreferences = {
                (prefs.usesTabGroups, prefs.splitView) = previous
            }
        }
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.prefs.usesTabGroups = false
        browser.prefs.splitView = false
        for word in ["one", "two", "three"] {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(word)")!, title: word)
        }
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SideColumnView(browser: browser)
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private var rowsAbove: Int { Shared.prefs.newTabsAtBottom ? 0 : 1 }

    private var columnTop: CGFloat { Metrics.strip + SpaceTitleSize.room + Metrics.sidePill - 3 + 8 }

    private func rowPoint(_ index: Int, in window: NSWindow) -> NSPoint {
        NSPoint(x: 70, y: window.frame.height - columnTop - Metrics.sideRowHeight / 2 - CGFloat(index + rowsAbove) * (Metrics.sideRowHeight + 5))
    }

    private func eventually(_ condition: () -> Bool) async throws {
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<40 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int = 1,
                      flags: NSEvent.ModifierFlags = []) async throws {
        window.sendEvent(try event(type, at: point, in: window, clicks: clicks, flags: flags))
        try await Task.sleep(for: .milliseconds(30))
    }

    private func dispatch(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        while let waiting = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(waiting) }
        NSApp.postEvent(try event(type, at: point, in: window), atStart: false)
        let taken = try #require(NSApp.nextEvent(matching: NSEvent.EventTypeMask(type: type), until: Date(), inMode: .default, dequeue: true))
        NSApp.sendEvent(taken)
        try await Task.sleep(for: .milliseconds(30))
    }

    private func doubleClick(at point: NSPoint, in window: NSWindow) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let steps: [(NSEvent.EventType, Int)] = [(.leftMouseDown, 1), (.leftMouseUp, 1), (.leftMouseDown, 2), (.leftMouseUp, 2)]
        for (index, (type, clicks)) in steps.enumerated() {
            window.sendEvent(try event(type, at: point, in: window, clicks: clicks, stamped: start + Double(index) * 0.03))
        }
        try await Task.sleep(for: .milliseconds(30))
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int = 1,
                       stamped timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
                       flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags, timestamp: timestamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }
}
