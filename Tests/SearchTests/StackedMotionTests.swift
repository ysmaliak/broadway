import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct StackedFoldCurveTests {
    @Test func theRowsFadeOverTheSameSixTenthsBothWays() {
        let opens: [CGFloat] = [1, 0.85, 0.7, 0.4, 0.2, 0]

        let fades = opens.map(StackedFold.fade)
        let arrivals = opens.map(StackedFold.arrive)

        #expect(zip(fades, [1, 0.75, 0.5, 0, 0, 0]).allSatisfy { abs($0 - $1) < 0.000_1 })
        #expect(arrivals.first == 0 && arrivals.last == 1)
        #expect(zip(arrivals, arrivals.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func aTurnCarriesOnFromTheValueAndSpeedItHad() {
        let curve = KitCurve.spring(.settle)
        let fold = StackedFold.start(folding: true, at: 10, curve: curve)
        let turnAt = 10 + KitSpring.settle.time(toReach: 0.5)

        let back = fold.turned(folding: false, at: turnAt, curve: curve)

        #expect(abs(back.value(at: turnAt) - fold.value(at: turnAt)) < 0.000_1)
        #expect(abs(back.rate(at: turnAt) - fold.rate(at: turnAt)) < 0.000_1)
        #expect(back.rate(at: turnAt) < 0, "it is still closing at the moment it turns")
        #expect(back.value(at: turnAt + 0.004) < back.value(at: turnAt), "it keeps its way for a moment, then turns")
        #expect(abs(back.value(at: turnAt + 2) - 1) < 0.001)
        #expect(back.done(at: turnAt + 2))
    }

    @Test func withoutMotionAFoldLandsAtOnce() {
        let fold = StackedFold.start(folding: true, at: 3, curve: .none)

        let value = fold.value(at: 3)

        #expect(value == 0)
        #expect(fold.done(at: 3))
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class StackedMotionTests {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restore: [() -> Void] = []
    private var activationPolicy: NSApplication.ActivationPolicy?

    init() {
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers {
            for space in browser.spaces { StackedFolds.shared.set(space.id, folded: false) }
            browser.closeAll()
        }
        for undo in restore.reversed() { undo() }
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        restore.removeAll()
    }

    struct Scene {
        let browser: Browser
        let ids: [UUID]
        let window: NSWindow
        let column: StackedColumnView
    }

    @Test func aFoldCoversTheBodyFromBelowAndTheNextHeadingRidesItsEdge() throws {
        let scene = try make()
        let (folded, below) = (scene.ids[1], scene.ids[2])
        let section = try #require(scene.column.section(folded))
        let open = try #require(StackedProbe.bodies[folded]).height

        StackedFolds.shared.set(folded, folded: true)
        let samples = run(scene, for: 0.7, extra: { section.pages.first?.alphaValue ?? 0 })

        let moving = samples.filter { $0.bodies[folded].map { $0.height > 0.5 && $0.height < open - 0.5 } ?? false }
        #expect(moving.count >= 4, "the fold was seen in flight: \(samples.map { $0.bodies[folded]?.height ?? -1 })")
        for sample in samples {
            let body = try #require(sample.bodies[folded]), next = try #require(sample.heads[below])
            #expect(abs(next.minY - body.maxY - StackedSpaces.gap) < 0.01, "the next heading rides the body's edge: \(next.minY) after \(body.maxY)")
        }
        let heights = samples.compactMap { $0.bodies[folded]?.height }
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $1 <= $0 + 0.01 }, "the body only closes: \(heights)")
        let fades = moving.map(\.extra)
        #expect(zip(fades, fades.dropFirst()).allSatisfy { $1 <= $0 + 0.001 }, "the rows only fade: \(fades)")
        #expect(moving.allSatisfy { ($0.pages[folded] ?? 0) > 0 }, "the rows stay until the move ends")
        #expect(heights.last.map { $0 < 0.5 } == true)
        #expect(section.pages.isEmpty, "the content goes when the move has ended")
        #expect(section.header.openness == 0)
    }

    @Test func underReduceMotionAFoldAndAnUnfoldLandAtOnce() throws {
        let scene = try make()
        let folded = scene.ids[1]
        let section = try #require(scene.column.section(folded))
        let open = try #require(StackedProbe.bodies[folded]).height
        Store.settings.set(true, forKey: "motion.testReduced")

        StackedFolds.shared.set(folded, folded: true)
        scene.window.contentView?.layoutSubtreeIfNeeded()
        let shut = (StackedProbe.bodies[folded]?.height ?? -1, section.pages.count, scene.column.motion.moving, section.header.openness)
        StackedFolds.shared.set(folded, folded: false)
        scene.window.contentView?.layoutSubtreeIfNeeded()
        let opened = (StackedProbe.bodies[folded]?.height ?? -1, section.pages.count, scene.column.motion.moving, section.header.openness)

        #expect(shut.0 < 0.5)
        #expect(shut.1 == 0)
        #expect(!shut.2)
        #expect(shut.3 == 0)
        #expect(abs(opened.0 - open) < 0.5)
        #expect(opened.1 == 1)
        #expect(!opened.2)
        #expect(opened.3 == 1)
    }

    @Test func foldingASectionAboveWhatYouAreReadingDoesNotMoveIt() throws {
        let scene = try make(tabs: 12, height: 420)
        let (above, reading) = (scene.ids[1], scene.ids[2])
        let body = try #require(StackedProbe.bodies[reading])
        StackedProbe.scroll?(body.minY + 40)
        settle(scene.window)
        let top = scene.column.outerScroll.contentView.bounds.minY
        let start = try #require(StackedProbe.bodies[reading]).minY - top
        let tall = try #require(StackedProbe.bodies[above]).height

        StackedFolds.shared.set(above, folded: true)
        let folding = run(scene, for: 0.7)
        StackedFolds.shared.set(above, folded: false)
        let unfolding = run(scene, for: 0.7)

        #expect(top > tall, "the section folded is wholly above the screen")
        #expect((folding.last?.top ?? 0) < top - tall / 2, "the scroll took up what the fold removed")
        for sample in folding + unfolding {
            let shown = try #require(sample.bodies[reading]).minY - sample.top
            #expect(abs(shown - start) < 0.5, "the section being read stays where it was on screen: \(shown) against \(start)")
        }
        #expect((folding.last?.bodies[above]?.height ?? -1) < 0.5)
        #expect((unfolding.last?.pages[above] ?? 0) == 1)
    }

    @Test(arguments: [CGFloat(0.3), 0.5, 0.8])
    func aFoldReversedInFlightCarriesOnFromWhereItIs(at progress: CGFloat) throws {
        let scene = try make()
        let folded = scene.ids[1]
        let open = try #require(StackedProbe.bodies[folded]).height
        StackedFolds.shared.set(folded, folded: true)
        let before = run(scene, for: 1) { (StackedProbe.open[folded] ?? 1) <= 1 - progress }

        StackedFolds.shared.set(folded, folded: false)
        let after = run(scene, for: 0.7, extra: { scene.column.section(folded)?.pages.first?.alphaValue ?? 0 })

        let closing = distinct(before.compactMap { s in s.bodies[folded].map { (s.time, $0.height) } })
        let opening = distinct(after.compactMap { s in s.bodies[folded].map { (s.time, $0.height) } })
        let last = try #require(closing.last), first = try #require(opening.first)
        let path = closing + opening
        let speeds = zip(path, path.dropFirst()).enumerated().compactMap { index, pair -> CGFloat? in
            index == closing.count - 1 ? nil : abs(pair.1.1 - pair.0.1) / CGFloat(max(pair.1.0 - pair.0.0, 0.001))
        }
        let fastest = try #require(speeds.max())
        let lag = CGFloat(max(first.0 - last.0, 0.001))
        #expect(abs(first.1 - last.1) <= fastest * lag * 1.2 + 1, "no jump at the turn: \(last.1) then \(first.1) after \(lag) s, at most \(fastest) pt/s elsewhere")
        #expect(first.1 <= last.1 + 0.01, "it keeps closing for a moment instead of turning back at once")
        let low = opening.map(\.1).min() ?? 0
        let rising = Array(opening.map(\.1).drop { $0 > low + 0.01 })
        #expect(zip(rising, rising.dropFirst()).allSatisfy { $1 >= $0 - 0.01 }, "then it only opens: \(rising)")
        #expect(abs((rising.last ?? 0) - open) < 0.5, "it opens all the way again")
        for sample in after where (sample.pages[folded] ?? 0) > 0 {
            let shown = (sample.bodies[folded]?.height ?? 0) / open
            #expect(abs(sample.extra - StackedFold.fade(shown)) < 0.03, "the rows' fade follows the openness, so it cannot jump: \(sample.extra) at \(shown)")
        }
    }

    private func distinct(_ points: [(CFTimeInterval, CGFloat)]) -> [(CFTimeInterval, CGFloat)] {
        points.reduce(into: []) { kept, point in
            if let last = kept.last, abs(last.1 - point.1) < 0.000_1 { return }
            kept.append(point)
        }
    }

    @Test func theFrontSpaceKeepsItsTabAndCarriesItUnderTheHeading() throws {
        let scene = try make()
        let front = scene.ids[0]
        let tab = try #require(scene.browser.tabs.dropFirst(3).first)
        scene.browser.select(tab)
        settle(scene.window)
        let section = try #require(scene.column.section(front))
        let start = try #require(section.openPage?.frame(of: tab.id))

        StackedFolds.shared.set(front, folded: true)
        let samples = run(scene, for: 0.7, extra: { StackedProbe.travel[front]??.minY ?? -1 })

        let ys = samples.map(\.extra).filter { $0 >= 0 }
        #expect(ys.count >= 4, "the tab was seen travelling: \(ys)")
        #expect(abs((ys.first ?? 0) - start.minY) < 6, "it starts where it was in the list: \(ys.first ?? -1) and \(start.minY)")
        #expect(zip(ys, ys.dropFirst()).allSatisfy { $1 <= $0 + 0.01 }, "it only rises: \(ys)")
        let folded = try #require(section.pages.first)
        #expect(section.pages.count == 1)
        let rest = try #require(folded.frame(of: tab.id))
        #expect(abs((ys.last ?? 0) - rest.minY) < 1, "it lands where the folded section shows it")
        #expect(scene.browser.active?.id == tab.id)
    }

    @Test func foldingTheSectionWhoseHeadingIsHeldKeepsItsHeadingAtTheTop() throws {
        let scene = try make(tabs: 14, height: 420)
        let held = scene.ids[1]
        let head = try #require(StackedProbe.headers[held])
        StackedProbe.scroll?(head.minY + 90)
        settle(scene.window)
        let top = scene.column.outerScroll.contentView.bounds.minY
        #expect(abs((StackedProbe.headers[held]?.minY ?? 0) - top) < 0.01, "its heading is held")

        StackedFolds.shared.set(held, folded: true)
        let samples = run(scene, for: 0.7)

        for sample in samples {
            let shown = try #require(sample.heads[held]).minY - sample.top
            #expect(abs(shown) < 0.5 || sample.top >= sample.limit - 0.5, "the heading stays at the top: \(shown) at \(sample.top)")
        }
    }

    @Test func theHeldHeadingIsWhereTheScrollPutsItAndTheNextOnePushesIt() throws {
        let scene = try make(tabs: 9, height: 380)
        let limit = scene.column.documentView.frame.height - scene.column.outerScroll.contentView.bounds.height

        var checked = 0
        var y: CGFloat = 0
        while y < limit {
            StackedProbe.scroll?(y)
            let heads = scene.ids.compactMap { id in StackedProbe.headers[id].map { (id, $0) } }
            let bodies = StackedProbe.bodies

            for (index, (id, frame)) in heads.enumerated() {
                guard let body = bodies[id] else { continue }
                let natural = body.minY - StackedSpaces.bodyTop - StackedHeaderView.height
                guard natural < y - 0.01, frame.maxY > y else { continue }
                if index + 1 < heads.count, heads[index + 1].1.minY < y + StackedHeaderView.height {
                    #expect(abs(heads[index + 1].1.minY - frame.maxY) < 0.01, "pushed with no gap at \(y)")
                } else {
                    #expect(abs(frame.minY - y) < 0.01, "held exactly at \(y): \(frame.minY)")
                }
                #expect(abs(scene.column.section(id)!.body.cutTop - max(0, frame.maxY - body.minY)) < 0.01, "cut at its bottom at \(y)")
                #expect(scene.column.section(id)!.header.layer?.animation(forKey: "position") == nil, "nothing moves by itself at \(y)")
                checked += 1
            }
            y += 0.37
        }
        #expect(checked > 100)
    }

    @Test func anEmbeddedPageNeverMovesItsOwnClip() throws {
        let scene = try make(tabs: 30, height: 360)
        let front = try #require(scene.column.section(scene.ids[0])?.openPage)
        let inner = try #require(all(NSScrollView.self, in: front).first)
        let clip = inner.contentView
        let outer = scene.column.outerScroll.contentView
        let first = try #require(scene.browser.tabs.first)
        scene.browser.select(first)
        settle(scene.window)
        outer.scroll(to: .zero)

        clip.scroll(to: NSPoint(x: 0, y: 120))
        clip.setBoundsOrigin(NSPoint(x: 0, y: 80))
        let afterScroll = clip.bounds.minY
        wheel(inner.documentView ?? inner, by: -240, in: scene.window)
        let afterWheel = clip.bounds.minY
        let taker = responders(from: inner.documentView ?? inner).first { responder in
            guard let scroll = responder as? NSScrollView else { return false }
            return (scroll as? SideScrollView).map { $0.scrolls && !$0.nested } ?? true
        }
        let last = try #require(scene.browser.tabs.last)
        scene.browser.select(last)
        front.reveal(last.id)
        settle(scene.window)
        let afterReveal = (clip.bounds.minY, outer.bounds.minY)
        scene.browser.newTab()
        settle(scene.window)
        scene.browser.closeTab(try #require(scene.browser.tabs.dropFirst(2).first))
        settle(scene.window)

        #expect(afterScroll == 0)
        #expect(afterWheel == 0)
        #expect(taker === scene.column.outerScroll, "the wheel over the front section goes to the column: \(String(describing: taker))")
        #expect(afterReveal.0 == 0)
        #expect(afterReveal.1 > 20, "showing a row far down moves the column instead: \(afterReveal.1)")
        #expect(clip.bounds.minY == 0)
        #expect(!inner.hasVerticalScroller)
        #expect(inner.verticalScrollElasticity == .none)
        for body in all(StackedBodyView.self, in: scene.column) {
            for nested in all(NSScrollView.self, in: body) {
                #expect(nested.contentView.bounds.minY == 0)
                #expect(!nested.hasVerticalScroller)
                #expect(nested.verticalScrollElasticity == .none)
            }
        }
    }

    private func responders(from start: NSResponder) -> [NSResponder] {
        Array(sequence(first: start) { $0.nextResponder }.prefix(64))
    }

    @Test func theAddressFieldStaysStillWhenATabInAnotherSpaceIsPicked() throws {
        let scene = try make()
        let root = try #require(scene.window.contentView)
        let address = try #require(all(SideAddressView.self, in: root).first)
        let ride = try #require(all(RideView.self, in: address).first)
        let frame = address.frame
        let parked = try #require(scene.browser.parked[scene.ids[2]]?.tabs.first)

        scene.browser.stackedSelect(parked, in: scene.ids[2])
        var shifts: [CGFloat] = []
        let end = Date().addingTimeInterval(0.6)
        while Date() < end {
            scene.window.contentView?.layoutSubtreeIfNeeded()
            CATransaction.flush()
            let layer = ride.content.layer
            let shown = layer?.presentation() ?? layer
            shifts.append(abs((shown?.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0))
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        #expect(scene.browser.spaceID == scene.ids[2])
        #expect(shifts.allSatisfy { $0 < 0.01 }, "nothing in the field travels: \(shifts.max() ?? 0)")
        #expect(address.frame == frame)
    }

    struct Sample {
        var time: CFTimeInterval
        var top: CGFloat
        var limit: CGFloat
        var bodies: [UUID: CGRect]
        var heads: [UUID: CGRect]
        var pages: [UUID: Int]
        var extra: CGFloat
    }

    private func run(_ scene: Scene, for seconds: Double, until: () -> Bool = { false }, extra: () -> CGFloat = { 0 }) -> [Sample] {
        var samples: [Sample] = []
        let end = CACurrentMediaTime() + seconds
        repeat {
            scene.window.contentView?.layoutSubtreeIfNeeded()
            let clip = scene.column.outerScroll.contentView
            let pages = Dictionary(uniqueKeysWithValues: scene.ids.map { ($0, scene.column.section($0)?.pages.count ?? 0) })
            samples.append(Sample(time: scene.column.motion.now, top: clip.bounds.minY,
                                  limit: max(0, scene.column.documentView.frame.height - clip.bounds.height),
                                  bodies: StackedProbe.bodies, heads: StackedProbe.headers, pages: pages, extra: extra()))
            if until() { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        } while CACurrentMediaTime() < end
        return samples
    }

    private func make(tabs: Int = 5, height: CGFloat = 900) throws -> Scene {
        _ = NSApplication.shared
        if activationPolicy == nil {
            activationPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.prohibited)
        }
        let prefs = Shared.prefs
        let previous = (prefs.usesTabGroups, prefs.splitView, prefs.usesSpaces, prefs.stackedSpaces, prefs.sharesPins,
                        prefs.addressBar, prefs.sideWidth, prefs.newTabPlace)
        restore.append {
            (prefs.usesTabGroups, prefs.splitView, prefs.usesSpaces, prefs.stackedSpaces, prefs.sharesPins,
             prefs.addressBar, prefs.sideWidth, prefs.newTabPlace) = previous
        }
        for key in ["motion.testReduced", "motion.testLowPower"] {
            let saved = Store.settings.object(forKey: key)
            restore.append { Store.settings.set(saved, forKey: key) }
            Store.settings.set(false, forKey: key)
        }
        prefs.usesTabGroups = true
        prefs.splitView = false
        prefs.usesSpaces = true
        prefs.stackedSpaces = true
        prefs.sharesPins = false
        prefs.addressBar = true
        prefs.sideWidth = 258
        prefs.newTabPlace = .end
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let ids = [UUID(), UUID(), UUID()]
        browser.spaces = ids.enumerated().map { Space(id: $1, name: "Space \($0)", colour: $0, sharesSignIns: true) }
        browser.spaceID = ids[0]
        browsers.append(browser)
        for index in 0..<tabs {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "about:blank#front-\(index)")!, title: "front \(index)")
        }
        for (place, id) in ids.enumerated().dropFirst() {
            let row = (0..<tabs).map { index -> Tab in
                let tab = Tab()
                tab.restore(url: URL(string: "about:blank#s\(place)-\(index)")!, title: "space \(place) row \(index)")
                return tab
            }
            browser.parked[id] = Parked(tabs: row, active: row.first?.id)
        }
        for id in ids { StackedFolds.shared.set(id, folded: false) }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: prefs.sideWidth, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SideColumnView(browser: browser)
        window.orderFrontRegardless()
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        settle(window)
        let root = try #require(window.contentView)
        let column = try #require(all(StackedColumnView.self, in: root).first)
        return Scene(browser: browser, ids: ids, window: window, column: column)
    }

    private func wheel(_ view: NSView, by delta: Double, in window: NSWindow) {
        func send(_ phase: Int64, _ amount: Double) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(amount), wheel2: 0, wheel3: 0) else { return }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: amount)
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(amount))
            guard let event = NSEvent(cgEvent: cg) else { return }
            view.scrollWheel(with: event)
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        for _ in 0..<10 { send(0, delta / 10) }
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { sub -> [T] in ((sub as? T).map { [$0] } ?? []) + all(type, in: sub) }
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
    }
}
