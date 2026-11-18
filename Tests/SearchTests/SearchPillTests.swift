import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SearchPillTests {
    private func until(_ what: String, within seconds: TimeInterval = 5, sourceLocation: SourceLocation = #_sourceLocation,
                       _ done: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !done() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("timed out: \(what)", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func fill(_ browser: Browser, host: String) {
        for index in 0..<3 {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://\(host)/page-\(index)")!, title: "\(host) \(index)")
        }
        if let last = browser.tabs.last { browser.select(last) }
    }

    private func twoSpaces(_ body: (Browser, NSWindow, SideColumnView, UUID, UUID) async throws -> Void) async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let prefs = browser.prefs
        let previous = (prefs.usesTabGroups, prefs.usesSpaces, prefs.splitView, prefs.sharesPins, prefs.addressBar, prefs.fullAddress)
        (prefs.usesTabGroups, prefs.usesSpaces, prefs.splitView, prefs.sharesPins, prefs.addressBar, prefs.fullAddress) = (false, true, false, false, true, false)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        defer {
            window.contentView = nil
            window.close()
            browser.closeAll()
            (prefs.usesTabGroups, prefs.usesSpaces, prefs.splitView, prefs.sharesPins, prefs.addressBar, prefs.fullAddress) = previous
            NSApp.setActivationPolicy(policy)
        }
        let first = browser.spaceID
        fill(browser, host: "first.example")
        browser.addSpace(named: "Second")
        try await until("the second space is on screen") { browser.spaceID != first }
        fill(browser, host: "second.example")
        window.setContentSize(NSSize(width: prefs.columnWidth, height: 600))
        let column = SideColumnView(browser: browser)
        window.contentView = column
        window.orderFrontRegardless()
        column.layoutSubtreeIfNeeded()
        try await body(browser, window, column, first, browser.spaceID)
    }

    private func shift(_ view: NSView?) -> CGFloat {
        view?.layer?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? .nan
    }

    private func onScreen(_ pill: AddressPillView, in column: SideColumnView, lane: AddressLaneView) -> NSRect {
        let frame = pill.convert(pill.bounds, to: column)
        let lift = pill.layer.map { $0.sublayerTransform.m41 } ?? 0
        return frame.offsetBy(dx: shift(lane) + (pill === lane.here ? 0 : lift), dy: 0)
    }

    @Test func theWholePillRidesWithThePageAndLandsWhereItStarted() async throws {
        try await twoSpaces { browser, window, column, first, _ in
            let address = try #require(column.kitSubviews(of: SideAddressView.self).first)
            let pages = try #require(column.kitSubviews(of: SidePagesView.self).first)
            let lane = address.lane
            let start = onScreen(lane.here, in: column, lane: lane)
            let width = browser.prefs.columnWidth
            let target = try #require(browser.spaces.firstIndex { $0.id == first })
            KitHoverView.pointerStandIn = (window, address.convert(NSPoint(x: address.bounds.midX, y: address.bounds.midY), to: nil))
            defer { KitHoverView.pointerStandIn = nil }

            address.benchPillHover(true)
            column.layoutSubtreeIfNeeded()
            #expect(lane.here.state == .hovered)

            browser.spaceNext = target
            try await until("the pill hears the ride begin") { lane.here.state == .resting }
            column.needsLayout = true
            column.layoutSubtreeIfNeeded()
            browser.spaceMotion.follow(width * 0.4, width: width)
            column.layoutSubtreeIfNeeded()

            #expect(abs(shift(lane) - shift(pages)) < 0.5, "pill \(shift(lane)) against page \(shift(pages))")
            #expect(abs(shift(lane) - width * 0.4) < 0.5)
            #expect(address.hovering && lane.here.state == .resting, "a hovered pill rides at rest, like the incoming one it is swapped with")
            let riding = onScreen(lane.here, in: column, lane: lane)
            #expect(abs(riding.minX - (start.minX + width * 0.4)) < 0.5, "\(riding) from \(start)")
            #expect(riding.size == start.size)
            let incoming = try #require(lane.others[target])
            #expect(lane.here.words.layer?.animationKeys()?.isEmpty ?? true)
            #expect(abs(onScreen(incoming, in: column, lane: lane).minX - (start.minX - width * 0.6)) < 0.5)

            SpaceSwipe.shared.slide(browser, to: target, from: browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 1)
            try await until("the ride lands on the first space") { browser.spaceID == first && !browser.spaceMotion.moving }
            try await Task.sleep(for: .milliseconds(400))
            column.needsLayout = true
            column.layoutSubtreeIfNeeded()

            #expect(abs(shift(lane)) < 0.01)
            #expect(onScreen(lane.here, in: column, lane: lane) == start)
            #expect(lane.here.words.label.text == "first.example")
        }
    }

    @Test func theIncomingPillShowsTheIncomingSpacesSite() async throws {
        try await twoSpaces { browser, _, column, first, _ in
            let address = try #require(column.kitSubviews(of: SideAddressView.self).first)
            let lane = address.lane
            let width = browser.prefs.columnWidth
            let target = try #require(browser.spaces.firstIndex { $0.id == first })

            browser.spaceNext = target
            column.needsLayout = true
            column.layoutSubtreeIfNeeded()

            #expect(lane.here.words.label.text == "second.example")
            let incoming = try #require(lane.others[target])
            #expect(incoming.words.label.text == "first.example")
            #expect(!incoming.isHidden)
            #expect(incoming.frame == lane.here.frame, "framed in bounds so it draws")
            #expect(abs((incoming.layer?.sublayerTransform.m41 ?? 0) + width) < 0.5)
            #expect(incoming.layer?.masksToBounds == false, "a clip on the shifted pill would cut its own face away")
            #expect(incoming.face.layer?.masksToBounds == true)
        }
    }

    @Test func eachPillCarriesItsOwnDoorsThroughASwitch() async throws {
        try await twoSpaces { browser, _, column, first, _ in
            let address = try #require(column.kitSubviews(of: SideAddressView.self).first)
            let lane = address.lane
            let target = try #require(browser.spaces.firstIndex { $0.id == first })
            func hit(_ door: NSView) -> Bool {
                address.hitTest(door.convert(NSPoint(x: door.bounds.midX, y: door.bounds.midY), to: address.superview))?.isDescendant(of: door) == true
            }
            #expect(hit(lane.here.doors.site))
            #expect(hit(lane.here.doors.copy))

            browser.spaceNext = target
            address.needsLayout = true
            column.needsLayout = true
            column.layoutSubtreeIfNeeded()

            #expect(!hit(lane.here.doors.site), "a press waits for the slide to land")
            let incoming = try #require(lane.others[target])
            #expect(lane.here.lit && lane.here.doors.alphaValue == 1)
            #expect(incoming.lit && incoming.doors.alphaValue == 1)
            #expect(incoming.doors.isDescendant(of: incoming.face))
            #expect(incoming.doors.frame == lane.here.doors.frame)
            #expect(incoming.words.fadeAt == incoming.doors.frame.minX)
            #expect(incoming.doors.copy.inert && incoming.doors.site.inert)
            #expect(!incoming.doors.copy.isAccessibilityElement())
            #expect(lane.here.doors.copy.inert && lane.here.doors.site.inert, "the front pill's doors ride without a hover, like the pill")
            #expect(incoming.doors.hitTest(NSPoint(x: incoming.doors.frame.midX, y: incoming.doors.frame.midY)) == nil)
            #expect(lane.here.doors.site.icon == SideLook.siteIcon)

            SpaceSwipe.shared.slide(browser, to: target, from: browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 1)
            try await until("the ride lands on the first space") { browser.spaceID == first && !browser.spaceMotion.moving }
            address.needsLayout = true
            column.needsLayout = true
            column.layoutSubtreeIfNeeded()

            #expect(lane.here.words.label.text == "first.example")
            #expect(lane.here.lit && lane.here.doors.alphaValue == 1)
            #expect(lane.here.doors.layer?.animation(forKey: "opacity") == nil, "the arriving pill's doors never fade in again")
            let leaving = lane.others.values.first { $0.words.label.text == "second.example" }
            #expect(leaving?.lit == true)
            #expect(!lane.here.doors.copy.inert && !lane.here.doors.site.inert)
            #expect(hit(lane.here.doors.site))
            #expect(hit(lane.here.doors.copy))
        }
    }

    @Test func theBlockedPopupsSignSitsLeftOfTheLinkDoorAndTheTextStopsBeforeIt() async throws {
        try await twoSpaces { browser, _, column, _, _ in
            let address = try #require(column.kitSubviews(of: SideAddressView.self).first)
            let lane = address.lane
            let doors = lane.here.doors
            let tab = try #require(browser.shownTab)
            let plain = doors.width
            let copyAt = doors.copy.convert(doors.copy.bounds, to: lane.here).minX
            #expect(doors.sign == nil)
            func hit(_ door: NSView) -> Bool {
                address.hitTest(door.convert(NSPoint(x: door.bounds.midX, y: door.bounds.midY), to: address.superview))?.isDescendant(of: door) == true
            }

            tab.noteBlocked(URL(string: "https://ads.example.com/pop"))
            try await until("the sign comes to the pill") { column.layoutSubtreeIfNeeded(); return doors.sign != nil }

            let sign = try #require(doors.sign)
            #expect(sign.tab === tab)
            #expect(doors.width == plain + 28)
            #expect(sign.frame.size == doors.copy.frame.size)
            #expect(sign.frame.maxX + 2 == doors.copy.frame.minX)
            #expect(sign.frame.midY == doors.copy.frame.midY)
            #expect(doors.copy.convert(doors.copy.bounds, to: lane.here).minX == copyAt, "the link door stays put")
            #expect(lane.here.words.fadeAt == doors.frame.minX)
            #expect(sign.greys == doors.copy.greys && sign.ink == doors.copy.ink)
            #expect(sign.toolTip == "Pop-up blocked")
            #expect(hit(sign))

            tab.noteBlocked(URL(string: "https://ads.example.com/pop-2"))
            try await until("the count follows") { column.layoutSubtreeIfNeeded(); return doors.sign?.toolTip == "2 pop-ups blocked" }

            #expect(doors.sign === sign)

            browser.editing = true
            try await until("the sign steps aside while the address is edited") { column.layoutSubtreeIfNeeded(); return doors.sign == nil }
            browser.editing = false
            try await until("and comes back after") { column.layoutSubtreeIfNeeded(); return doors.sign != nil }
            tab.blockedPopups = []
            try await until("an empty list takes it away") { column.layoutSubtreeIfNeeded(); return doors.sign == nil }

            #expect(doors.width == plain)
            #expect(lane.here.words.fadeAt == doors.frame.minX)
        }
    }

    @Test func theSignFollowsTheShownTabAndRidesASwitchInert() async throws {
        try await twoSpaces { browser, _, column, first, _ in
            let address = try #require(column.kitSubviews(of: SideAddressView.self).first)
            let lane = address.lane
            let target = try #require(browser.spaces.firstIndex { $0.id == first })
            let blocked = try #require(browser.shownTab)
            blocked.noteBlocked(URL(string: "https://ads.example.com/pop"))
            try await until("the sign comes to the pill") { column.layoutSubtreeIfNeeded(); return lane.here.doors.sign != nil }
            let other = try #require(browser.tabs.first { $0 !== blocked && !$0.isBlank })

            browser.select(other)
            try await until("another tab takes the sign away") { column.layoutSubtreeIfNeeded(); return lane.here.doors.sign == nil }
            browser.select(blocked)
            try await until("and its own tab brings it back") { column.layoutSubtreeIfNeeded(); return lane.here.doors.sign?.tab === blocked }

            let away = try #require(browser.row(at: target)?.active)
            away.noteBlocked(URL(string: "https://ads.example.com/away"))
            browser.spaceNext = target
            address.needsLayout = true
            column.needsLayout = true
            column.layoutSubtreeIfNeeded()

            let incoming = try #require(lane.others[target])
            let still = try #require(incoming.doors.sign)
            #expect(still.tab === away)
            #expect(still.inert && still.toolTip == nil && !still.isAccessibilityElement())
            #expect(still.frame == lane.here.doors.sign?.frame)
            #expect(incoming.words.fadeAt == incoming.doors.frame.minX)
            #expect(lane.here.doors.sign?.inert == true, "the front pill's sign rides without a hover, like its doors")
        }
    }

    private func srgb(_ colour: NSColor) -> NSColor {
        colour.usingColorSpace(.sRGB) ?? colour
    }

    @Test func thePillShowsItsSiteWithNoGlassAndItsDoorsWithoutAHover() async throws {
        try await twoSpaces { browser, _, column, _, _ in
            let address = try #require(column.kitSubviews(of: SideAddressView.self).first)

            address.needsLayout = true
            column.layoutSubtreeIfNeeded()

            let words = address.lane.here.words
            let doors = column.kitSubviews(of: DoorView.self).filter { $0.isDescendant(of: address.lane.here) }
            #expect(words.kitSubviews(of: KitSymbol.self).isEmpty)
            #expect(words.label.frame.minX == SideLook.pillLead)
            #expect(doors.count == 2)
            for door in doors {
                #expect(door.superview?.alphaValue == 1)
                #expect(door.weight == SideLook.doorWeight)
                #expect(door.frame.maxX <= address.lane.here.bounds.width)
            }
            #expect(SideLook.doorWeight.rawValue > NSFont.Weight.regular.rawValue)
            #expect(browser.shownTab?.isBlank == false)
        }
    }

    @Test func thePillIsATileOfTheColumnsFamily() {
        let greys = KitGreys.frame

        let rest = (fill: PillLook.fill(greys, state: .resting, dark: true), edge: PillLook.edge(greys, state: .resting, dark: true))
        let offFrame = PillLook.edge(.white, state: .resting, dark: true)
        let hover = PillLook.fill(greys, state: .hovered, dark: true)
        let pressed = PillLook.fill(greys, state: .picked, dark: true)
        let lightRest = srgb(PillLook.fill(greys, state: .resting, dark: false).resolved(.flat, dark: false))
        let lightHover = srgb(PillLook.fill(greys, state: .hovered, dark: false).resolved(.flat, dark: false))
        let lightPressed = srgb(PillLook.fill(greys, state: .picked, dark: false).resolved(.flat, dark: false))

        #expect(rest.fill == greys.card)
        #expect(rest.edge == nil)
        #expect(offFrame == KitGreys.white.cardEdge.opacity(PillLook.edgeTone))
        for state in [PinLook.State.resting, .hovered, .picked] {
            for dark in [true, false] {
                #expect(PillLook.edge(greys, state: state, dark: dark) == nil)
                #expect(PillLook.rim(greys, state: state, dark: dark) == nil)
                #expect(PillLook.rim(.white, state: state, dark: dark) == nil)
            }
        }
        #expect(hover.opacity > rest.fill.opacity)
        #expect(pressed.opacity > hover.opacity)
        #expect(lightHover.redComponent >= lightRest.redComponent && lightHover.alphaComponent < lightRest.alphaComponent,
                "light hover moves away from the white well")
        #expect(lightPressed.redComponent < 0.5, "light press darkens the ground")
        #expect(Metrics.sidePill == Metrics.sideRowHeight)
        #expect(SideLook.pillRadius == SideLook.rowRadius)
        #expect(SideLook.pillRadius == SideLook.pinRadius)
        #expect(PillLook.textX == SideLook.pillLead)
        #expect(SideLook.pillFont.pointSize == 13)
        #expect(SideLook.pillFont.fontDescriptor.symbolicTraits.contains(.bold) == false)
    }
}
