import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct MiniPlayerCardTests {
    private func reading(playing: Bool, duration: Double, minor: Bool = false, source: String = "audio", time: Double = 100) -> MiniReport.Reading {
        MiniReport.Reading(playing: playing, time: time, duration: duration, minor: minor, source: source)
    }

    private func item(pair: MiniPair, duration: Double, speed: Bool, title: String = "Born To Fly") -> MiniPlayer.Item {
        MiniPlayer.Item(id: UUID(), title: title, detail: "A Singer", site: "music.example", art: nil, playing: true, pair: pair,
                        previous: true, next: true, position: MiniPosition(time: 71, duration: duration, rate: 1, playing: true, at: Date()),
                        live: false, rate: 1, speed: speed, seekable: true, muted: false, skip: 15)
    }

    @Test func aShortLoopInAnotherFrameNeverTakesTheCardFromThePausedSong() {
        let song = MiniFrameSeen(key: "main", main: true, reading: reading(playing: false, duration: 285), since: 10, at: 20)
        let loop = MiniFrameSeen(key: "inner", reading: reading(playing: true, duration: 6, minor: true), since: 19, at: 21)

        let lead = MiniRule.lead([song, loop], was: "main")

        #expect(lead == "main")
    }

    @Test func aShortLoopIsSetAsideEvenBeforeAnyFrameLed() {
        let song = MiniFrameSeen(key: "a", reading: reading(playing: false, duration: 285), since: 10, at: 20)
        let loop = MiniFrameSeen(key: "b", reading: reading(playing: true, duration: 6, minor: true), since: 19, at: 21)

        let lead = MiniRule.lead([song, loop], was: nil)

        #expect(lead == "a")
    }

    @Test func thePagesOwnReportedPositionIsTheTruth() {
        let element = MiniFrameSeen(key: "inner", reading: reading(playing: true, duration: 600), since: 30, at: 31)
        let page = MiniFrameSeen(key: "main", main: true, reading: reading(playing: false, duration: 285, source: "page"), since: 0, at: 20)

        let lead = MiniRule.lead([element, page], was: "inner")

        #expect(lead == "main")
    }

    @Test func anotherLongSoundThatStartsLaterTakesTheCard() {
        let first = MiniFrameSeen(key: "a", main: true, reading: reading(playing: false, duration: 285), since: 10, at: 20)
        let second = MiniFrameSeen(key: "b", reading: reading(playing: true, duration: 1800), since: 25, at: 26)

        let lead = MiniRule.lead([first, second], was: "a")

        #expect(lead == "b")
    }

    @Test func aSeekHoldsItsTargetAgainstAStaleReading() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let hold = MiniHold(time: 200, at: start)
        let stale = reading(playing: true, duration: 285, time: 101)
        let landed = reading(playing: true, duration: 285, time: 200.6)

        let early = hold.holds(against: stale, now: start.addingTimeInterval(0.4))
        let reached = hold.holds(against: landed, now: start.addingTimeInterval(0.5))
        let late = hold.holds(against: stale, now: start.addingTimeInterval(MiniHold.longest + 0.1))

        #expect(early)
        #expect(!reached)
        #expect(!late)
    }

    @Test func aPickedSpeedShowsUntilThePageAnswers() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let asked = (rate: 2.0, at: start)

        let waiting = MiniRule.rateShown(reading: 1, asked: asked, refused: false, now: start.addingTimeInterval(0.2))
        let refused = MiniRule.rateShown(reading: 1, asked: asked, refused: true, now: start.addingTimeInterval(0.2))
        let tooLong = MiniRule.rateShown(reading: 1, asked: asked, refused: false, now: start.addingTimeInterval(MiniHold.rateLongest + 0.1))

        #expect(waiting == 2)
        #expect(refused == 1)
        #expect(tooLong == 1)
    }

    @Test func speedIsOfferedOnlyForLongAudioThePageHasNotRefused() {
        let actions: Set<String> = [MiniAction.previous.rawValue, MiniAction.next.rawValue]

        let song = MiniRule.long(actions: actions, duration: 285, live: false)
        let book = MiniRule.long(actions: actions, duration: 10800, live: false)
        let live = MiniRule.long(actions: actions, duration: 0, live: true)
        let bookAsTracks = MiniRule.pair(actions: actions, duration: 10800, live: false, spoken: .tracks)

        #expect(!MiniRule.speed(long: song, element: true, refused: false, on: true))
        #expect(MiniRule.speed(long: book, element: true, refused: false, on: true))
        #expect(bookAsTracks == .tracks && MiniRule.speed(long: book, element: true, refused: false, on: true))
        #expect(!MiniRule.speed(long: book, element: true, refused: true, on: true))
        #expect(!MiniRule.speed(long: book, element: false, refused: false, on: true))
        #expect(!MiniRule.speed(long: book, element: true, refused: false, on: false))
        #expect(!MiniRule.speed(long: live, element: true, refused: false, on: true))
    }

    @Test func aSongsMenuHasNoSpeedAndLongAudiosDoes() {
        let player = MiniPlayer(surface: item(pair: .tracks, duration: 285, speed: false))

        let song = MiniPlayerView.menuItems(item(pair: .tracks, duration: 285, speed: false), mini: player)
        let book = MiniPlayerView.menuItems(item(pair: .seconds, duration: 10800, speed: true), mini: player)

        func speed(_ items: [KitMenuItem]) -> Bool {
            items.contains { if case .submenu(let title, _, _) = $0 { return title == "Speed" } else { return false } }
        }
        #expect(!speed(song))
        #expect(speed(book))
    }

    @Test func theKeySwapsWithMotionOnlyForTheItemTheCardAlreadyShows() {
        let song = UUID(), other = UUID()

        #expect(MiniPlayerView.swaps(song, after: song, share: 1))
        #expect(MiniPlayerView.swaps(song, after: song, share: 0.4))
        #expect(!MiniPlayerView.swaps(song, after: nil, share: 1))
        #expect(!MiniPlayerView.swaps(song, after: other, share: 1))
        #expect(!MiniPlayerView.swaps(song, after: song, share: 0))
    }

    @Test func aCardThatArrivesAlreadyPlayingShowsPauseWithNoSwap() throws {
        Store.settings.set(false, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: MiniPlayerView.full), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = MiniPlayerView(mini: MiniPlayer(surface: item(pair: .tracks, duration: 285, speed: false)))
        view.frame = NSRect(x: 0, y: 0, width: 258, height: MiniPlayerView.full)
        window.contentView?.addSubview(view)
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()

        let toggle = try #require(view.kitSubviews(of: MiniToggle.self).first)
        let glyph = try #require(toggle.kitSubviews(of: PlayGlyph.self).first)

        #expect(toggle.window === window)
        #expect(toggle.showing == "pause")
        #expect(glyph.image === KitGlyph.image("pause.fill", PlayGlyph.sidebar))
        #expect(glyph.replaced == 0)
        #expect(!glyph.swapped)
    }

    private func card(_ shown: MiniPlayer.Item, width: CGFloat = 258) -> MiniPlayerView {
        let view = MiniPlayerView(mini: MiniPlayer(surface: shown))
        view.frame = NSRect(x: 0, y: 0, width: width, height: MiniPlayerView.full)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func box(_ state: [String: Any], _ key: String) -> NSRect {
        let numbers = state[key] as? [Double] ?? []
        guard numbers.count == 4 else { return .zero }
        return NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    @Test(arguments: [MiniPair.tracks, MiniPair.seconds])
    func theCardIsOneRowWithTheKeysAtTheRight(pair: MiniPair) throws {
        let view = card(item(pair: pair, duration: pair == .seconds ? 10800 : 285, speed: pair == .seconds))

        let state = view.benchState
        let whole = box(state, "cardFrame")
        let art = box(state, "artFrame")
        let keys = try #require(state["keyFrames"] as? [[Double]])

        #expect(whole.height == 44)
        #expect(whole.width == 258 - Metrics.sideInset * 2)
        #expect(art.width == 28 && art.height == 28)
        #expect(art.minX == art.minY && art.minY == whole.height - art.maxY)
        #expect(keys.count == 3)
        #expect(keys[0][0] < keys[1][0] && keys[1][0] < keys[2][0])
        #expect(keys.allSatisfy { $0[2] == Double(SideGrid.key) && $0[1] == Double(MiniPlayerView.height - SideGrid.key) / 2 })
        #expect(Double(whole.width) - keys[2][0] - keys[2][2] == Double(MiniPlayerView.keysEnd))
        #expect(box(state, "titleFrame").maxX <= CGFloat(keys[0][0]))
    }

    @Test func thereIsNoSoundKeyAndNoCloseButtonAtRestOnHoverOrMuted() {
        var shown = item(pair: .tracks, duration: 285, speed: false)
        shown.muted = true
        let view = card(shown)

        let rest = view.benchState["buttons"] as? [String]
        view.benchPillHover(true)
        view.layoutSubtreeIfNeeded()
        let over = view.benchState["buttons"] as? [String]
        view.benchPillHover(false)

        #expect(rest == ["Born To Fly, A Singer", "Previous", "Pause", "Next"])
        #expect(over == rest)
    }

    @Test func hidingStaysInTheMenuWithMuteAndSpeed() {
        let player = MiniPlayer(surface: item(pair: .seconds, duration: 10800, speed: true))
        let shown = item(pair: .seconds, duration: 10800, speed: true)

        let titles = MiniPlayerView.menuItems(shown, mini: player).compactMap { entry -> String? in
            switch entry {
            case .action(let title, _, _, _, _, _, _, _): return title
            case .submenu(let title, _, _): return title
            default: return nil
            }
        }

        #expect(titles.last == "Hide Player")
        #expect(titles.contains("Mute Tab"))
        #expect(titles.contains("Speed"))
        #expect(titles.contains("Go to Tab"))
    }

    @Test func aRightClickAnywhereOnTheCardOffersHidePlayer() throws {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: MiniPlayerView.full), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let ground = KitFlippedView(frame: NSRect(x: 0, y: 0, width: 258, height: MiniPlayerView.full))
        window.contentView = ground
        let view = card(item(pair: .seconds, duration: 10800, speed: true))
        ground.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let state = view.benchState
        let keys = try #require(state["keyFrames"] as? [[Double]])
        let inset = Metrics.sideInset
        let places = [
            "artwork": NSPoint(x: inset + box(state, "artFrame").midX, y: box(state, "artFrame").midY),
            "title": NSPoint(x: inset + box(state, "titleFrame").midX, y: box(state, "titleFrame").midY),
            "key": NSPoint(x: inset + keys[1][0] + keys[1][2] / 2, y: keys[1][1] + keys[1][3] / 2),
            "line": NSPoint(x: inset + box(state, "lineFrame").midX, y: box(state, "lineFrame").midY),
        ]
        let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

        for (name, point) in places {
            var at = view.hitTest(point)
            var menu: NSMenu?
            while let here = at, menu == nil {
                menu = here.menu(for: click)
                at = here.superview
            }
            let titles = menu?.items.map(\.title) ?? []
            #expect(titles.last == "Hide Player", "\(name): \(titles)")
            #expect(titles.contains("Mute Tab") && titles.contains("Speed"), "\(name): \(titles)")
        }
    }

    @Test func progressIsAThinLineAtTheBottomEdgeInsideTheCorners() {
        let view = card(item(pair: .tracks, duration: 285, speed: false))

        let rest = view.benchState
        let whole = box(rest, "cardFrame")
        let line = box(rest, "lineFrame")
        view.benchLineHover(true)
        view.layoutSubtreeIfNeeded()
        let over = view.benchState
        let lit = box(over, "lineFrame")
        view.benchLineHover(false)

        #expect(line.height == 2)
        #expect(line.maxY == whole.height - 1)
        #expect(line.minX == SideLook.cardRadius && line.maxX == whole.width - SideLook.cardRadius)
        #expect(line.minY > box(rest, "artFrame").maxY)
        #expect(lit.height == 4 && lit.maxY == line.maxY)
        #expect(rest["detail"] as? String == "A Singer")
        #expect(over["detail"] as? String == "1:11 / 4:45")
        #expect(rest["frames"] as? [String: [Double]] == over["frames"] as? [String: [Double]])
    }

    @Test func theLineTakesAPressOnlyWhereThePageCanSeekAndSaysWhereTheDragIs() throws {
        var fixed = item(pair: .tracks, duration: 285, speed: false)
        fixed.seekable = false
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: MiniPlayerView.full), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let ground = KitFlippedView(frame: NSRect(x: 0, y: 0, width: 258, height: MiniPlayerView.full))
        window.contentView = ground
        let view = card(item(pair: .tracks, duration: 285, speed: false))
        let still = card(fixed)
        ground.addSubview(view)
        ground.addSubview(still)
        still.isHidden = true
        view.layoutSubtreeIfNeeded()
        let line = box(view.benchState, "lineFrame")
        let point = NSPoint(x: Metrics.sideInset + line.midX, y: MiniPlayerView.above + line.midY)

        let hit = try #require(view.hitTest(point) as? MiniProgressView)
        still.isHidden = false
        view.isHidden = true
        still.layoutSubtreeIfNeeded()
        let other = still.hitTest(point)
        still.isHidden = true
        view.isHidden = false
        let at = hit.convert(NSPoint(x: hit.bounds.midX, y: hit.bounds.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: at, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        hit.mouseDown(with: down)
        view.layoutSubtreeIfNeeded()
        let dragging = view.benchState

        #expect(other != nil && !(other is MiniProgressView))
        #expect(dragging["detail"] as? String == "2:22 / 4:45")
        #expect(box(dragging, "lineFrame").height == 4)
        #expect(abs((dragging["line"] as? Double ?? 0) - 0.5) < 0.01)
    }

    @Test func aLiveStreamHasNoLineAndSaysLive() {
        var shown = item(pair: .none, duration: 0, speed: false)
        shown.position = nil
        shown.live = true
        let view = card(shown)

        let state = view.benchState

        #expect(box(state, "lineFrame") == .zero)
        #expect(state["detail"] as? String == "Live · A Singer")
        #expect(state["value"] as? String == "Live")
        #expect((state["keyFrames"] as? [[Double]])?.count == 1)
    }

    @Test func theTimesAreInTheValueAndTheTooltipNotOnTheCard() {
        var shown = item(pair: .tracks, duration: 285, speed: false)
        shown.playing = false
        shown.position = MiniPosition(time: 113, duration: 285, rate: 1, playing: false, at: Date())
        let view = card(shown)

        let state = view.benchState

        #expect(state["value"] as? String == "1:53 of 4:45")
        #expect(state["tip"] as? String == "Born To Fly\nA Singer\n1:53 of 4:45")
        #expect(state["detail"] as? String == "A Singer")
        #expect(!view.kitSubviews(of: KitLabel.self).contains { $0.text.contains(":") })
    }

    @Test func theTimeLineSaysPositionAndTotalInTabularDigitsAndNeverWhatIsLeft() throws {
        let view = card(item(pair: .tracks, duration: 285, speed: false))
        view.benchLineHover(true)
        view.layoutSubtreeIfNeeded()

        let clock = try #require(view.kitSubviews(of: MiniTimeView.self).first)
        let runs = clock.kitSubviews(of: KitLabel.self).flatMap(\.runs).filter { !$0.text.isEmpty }
        let state = view.benchState
        view.benchLineHover(false)
        view.layoutSubtreeIfNeeded()
        let after = view.benchState

        #expect(runs.map(\.text) == ["1:11", " / 4:45"])
        #expect(runs.first?.color == KitColor.ink)
        #expect(runs.last?.color == nil)
        #expect(runs.allSatisfy { $0.font == NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) })
        #expect(MiniTimeView.width("1:11 / 4:45") == MiniTimeView.width("0:00 / 9:59"))
        #expect(state["time"] as? String == "1:11 / 4:45")
        #expect(state["timeShare"] as? Double == 1)
        #expect(!(state["tip"] as? String ?? "left").contains("left"))
        #expect(after["time"] as? String == "")
        #expect(after["detail"] as? String == "A Singer")
        #expect(after["timeShare"] as? Double == 0)
    }

    @Test func aTrackThatCannotBeSeekedShowsItsTimeUnderThePointerAndItsLineStaysThin() throws {
        var fixed = item(pair: .tracks, duration: 285, speed: false)
        fixed.seekable = false
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: MiniPlayerView.full), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            KitHoverView.pointerStandIn = nil
            window.close()
        }
        let ground = KitFlippedView(frame: NSRect(x: 0, y: 0, width: 258, height: MiniPlayerView.full))
        window.contentView = ground
        let view = card(fixed)
        ground.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let line = try #require(view.kitSubviews(of: MiniProgressView.self).first)
        let rest = view.benchState

        KitHoverView.pointerStandIn = (window, line.convert(NSPoint(x: line.bounds.midX, y: line.bounds.midY), to: nil))
        line.settleHover()
        view.layoutSubtreeIfNeeded()
        let over = view.benchState

        #expect(rest["detail"] as? String == "A Singer")
        #expect(over["detail"] as? String == "1:11 / 4:45")
        #expect(box(over, "lineFrame").height == 2)
        #expect(line.drawn == 2)
        #expect(rest["frames"] as? [String: [Double]] == over["frames"] as? [String: [Double]])
    }

    @Test func theSwapFadesOneLineUpAndTheOtherInFromBelowBothWays() {
        let travel = MiniPlayerView.timeTravel
        let shares = (0...20).map { Double($0) / 20 }

        let into = shares.map { MiniPlayerView.swapLook($0, rising: true, moves: true) }
        let back = shares.reversed().map { MiniPlayerView.swapLook($0, rising: false, moves: true) }
        let still = shares.map { MiniPlayerView.swapLook($0, rising: true, moves: false) }

        #expect(travel == 4)
        #expect(MiniPlayerView.timeCross == 0.5)
        #expect(MiniPlayerView.timeFade == 0.12)
        #expect(into.first?.line.opacity == 1 && into.first?.line.lift == 0 && into.first?.time.opacity == 0 && into.first?.time.lift == travel)
        #expect(into.last?.line.opacity == 0 && into.last?.line.lift == -travel && into.last?.time.opacity == 1 && into.last?.time.lift == 0)
        #expect(back.first?.time.opacity == 1 && back.first?.time.lift == 0 && back.first?.line.opacity == 0 && back.first?.line.lift == travel)
        #expect(back.last?.time.opacity == 0 && back.last?.time.lift == -travel && back.last?.line.opacity == 1 && back.last?.line.lift == 0)
        #expect(zip(into, into.dropFirst()).allSatisfy { $0.line.lift >= $1.line.lift && $0.time.lift >= $1.time.lift })
        #expect(zip(back, back.dropFirst()).allSatisfy { $0.line.lift >= $1.line.lift && $0.time.lift >= $1.time.lift })
        #expect((into + back).allSatisfy { min($0.line.opacity, $0.time.opacity) == 0 && max($0.line.opacity, $0.time.opacity) <= 1 })
        #expect(still.allSatisfy { $0.line.lift == 0 && $0.time.lift == 0 && abs($0.line.opacity + $0.time.opacity - 1) < 1e-9 })
        #expect(still.first?.line.opacity == 1 && still.last?.time.opacity == 1)
    }

    @Test(arguments: [(245.0, "1:23 / 4:45", "1:02:05 / 3:00:00"), (200.0, "1:23", "1:02:05"), (182.0, "1:23 / 4:45", "1:02:05")])
    func theTotalStaysWhileBothNumbersFitAndThePositionStandsAloneWhenTheyDoNot(width: Double, song: String, book: String) {
        var long = item(pair: .seconds, duration: 10800, speed: true)
        long.position = MiniPosition(time: 3725, duration: 10800, rate: 1, playing: false, at: Date())
        long.playing = false
        var short = item(pair: .tracks, duration: 285, speed: false)
        short.position = MiniPosition(time: 83, duration: 285, rate: 1, playing: false, at: Date())
        short.playing = false
        let views = [card(short, width: width), card(long, width: width)]

        for view in views {
            view.benchLineHover(true)
            view.layoutSubtreeIfNeeded()
        }

        #expect(views[0].benchState["detail"] as? String == song)
        #expect(views[1].benchState["detail"] as? String == book)
    }

    @Test func theLineThickensByTheSameShareAsTheSwap() throws {
        let view = card(item(pair: .tracks, duration: 285, speed: false))
        let line = try #require(view.kitSubviews(of: MiniProgressView.self).first)
        let position = MiniPosition(time: 71, duration: 285, rate: 1, playing: false, at: Date())

        let drawn = [0.0, 0.25, 0.5, 1.0].map { share -> CGFloat in
            line.show(position, ink: .flat, dark: true, scrub: nil, lit: share)
            return line.drawn
        }

        #expect(drawn == [2, 2.5, 3, 4])
        #expect(line.thick == 2)
    }

    @Test func aSpeedOtherThanOneIsSaidOnTheSecondLine() {
        var fast = item(pair: .seconds, duration: 10800, speed: true)
        fast.rate = 1.5
        let usual = item(pair: .seconds, duration: 10800, speed: true)
        var unoffered = fast
        unoffered.speed = false

        #expect(MiniPlayerView.second(fast) == "\(VideoSpeed.label(1.5)) · A Singer")
        #expect(MiniPlayerView.second(usual) == "A Singer")
        #expect(MiniPlayerView.second(unoffered) == "A Singer")
    }

    @Test(arguments: [200.0, 140.0])
    func narrowTheKeysStayWholeAndTheWordsThenTheArtworkGiveWay(width: Double) throws {
        let view = card(item(pair: .tracks, duration: 285, speed: false), width: width)

        let state = view.benchState
        let whole = box(state, "cardFrame")
        let keys = try #require(state["keyFrames"] as? [[Double]])
        let words = box(state, "titleFrame")

        #expect(keys.count == 3)
        #expect(keys[0][0] >= 0 && keys[2][0] + keys[2][2] <= Double(whole.width))
        #expect(words.maxX <= CGFloat(keys[0][0]))
        #expect((box(state, "artFrame") != .zero) == (width == 200))
        #expect(words.width >= (width == 200 ? MiniPlayerView.fewestWords : 20))
    }

    @Test func theCardKeepsTheUpdateCardsGapFromTheListAndTheFoot() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.mini = MiniPlayer(surface: item(pair: .tracks, duration: 285, speed: false))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: 640), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        browser.window = window
        let column = SideColumnView(browser: browser)
        window.contentView = column
        column.layoutSubtreeIfNeeded()

        let mini = try #require(column.kitSubviews(of: MiniPlayerView.self).first { !$0.isHidden })
        let foot = try #require(column.kitSubviews(of: SpaceFootView.self).first)
        let whole = mini.cardFrameInColumn

        #expect(whole.height == 44)
        #expect(foot.frame.minY - whole.maxY == UpdateCardView.foot - UpdateCardView.height)
        #expect(whole.minY == mini.frame.minY)
        #expect(mini.frame.height == MiniPlayerView.full)
        #expect(MiniPlayerView.full == 44 + UpdateCardView.foot - UpdateCardView.height)
        #expect(MiniPlayerView.above == 0)
        #expect(AgentsLayout.below == MiniPlayerView.below)
    }

    @Test(arguments: [MiniPair.tracks, MiniPair.seconds])
    func hoverMovesNothing(pair: MiniPair) {
        let shown = item(pair: pair, duration: pair == .seconds ? 10800 : 285, speed: pair == .seconds,
                         title: "Bohemian Rhapsody (Remastered 2011, the long version with the opera section)")
        let view = card(shown)
        let rest = view.benchFrames

        view.benchPillHover(true)
        view.layoutSubtreeIfNeeded()
        let over = view.benchFrames
        view.benchPillHover(false)

        #expect(!rest.isEmpty)
        #expect(rest == over)
    }

    @Test func aSlidingTitleCarriesTheWholeTitleNotOnlyWhatShowedAtRest() throws {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: MiniPlayerView.full), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let ground = KitFlippedView(frame: NSRect(x: 0, y: 0, width: 258, height: MiniPlayerView.full))
        window.contentView = ground
        let view = card(item(pair: .tracks, duration: 285, speed: false,
                             title: "Bohemian Rhapsody (Remastered 2011, the long version with the opera section)"))
        ground.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let title = try #require(view.kitSubviews(of: MiniWordsView.self).first)

        view.benchPillHover(true)
        view.layoutSubtreeIfNeeded()
        let sliding = title.sliding
        let picture = title.slidingPicture
        view.benchPillHover(false)
        view.layoutSubtreeIfNeeded()

        #expect(sliding == Motion.kitQuick.animates)
        #expect(title.slidingPicture == nil)
        guard sliding else { return }
        let drawn = try #require(picture)
        let context = try #require(CGContext(data: nil, width: drawn.width, height: drawn.height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(drawn, in: CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var last = 0
        for x in 0..<drawn.width {
            for y in 0..<drawn.height where pixels[y * context.bytesPerRow + x * 4 + 3] > 40 { last = x }
        }
        #expect(CGFloat(drawn.width) > title.bounds.width * 3)
        #expect(last > drawn.width - 40)
    }

    @Test func aSeekHoldsItsSpotAndItsPlayKeyWhileThePagePausesToSeek() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let hold = MiniHold(time: 200, at: start, playing: true)
        let pausedThere = reading(playing: false, duration: 285, time: 200)
        let playingThere = reading(playing: true, duration: 285, time: 200.3)
        let soon = start.addingTimeInterval(0.4)
        let afterSettling = start.addingTimeInterval(MiniHold.settle + 0.1)

        let waiting = hold.holds(against: pausedThere, now: soon)
        let resumed = hold.holds(against: playingThere, now: start.addingTimeInterval(0.7))
        let stayedPaused = hold.holds(against: pausedThere, now: afterSettling)
        let wasPaused = MiniHold(time: 200, at: start, playing: false).holds(against: pausedThere, now: soon)
        let askedToPause = MiniHold(time: 200, at: start).holds(against: pausedThere, now: soon)
        let spot = hold.position(duration: 285, rate: 1)

        #expect(waiting)
        #expect(!resumed)
        #expect(!stayedPaused)
        #expect(!wasPaused)
        #expect(!askedToPause)
        #expect(spot.elapsed(now: start.addingTimeInterval(2)) == 200)
        #expect(hold.sounding(now: soon))
        #expect(!hold.sounding(now: afterSettling))
        #expect(!MiniHold(time: 200, at: start, playing: false).sounding(now: soon))
        #expect(MiniHold.settle < MiniHold.longest)
    }

    @Test func aPressAndReleaseLeaveTheFillAndTheClockAtThePressedSpotAtOnce() throws {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: MiniPlayerView.full), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let ground = KitFlippedView(frame: NSRect(x: 0, y: 0, width: 258, height: MiniPlayerView.full))
        window.contentView = ground
        let view = card(item(pair: .tracks, duration: 285, speed: false))
        ground.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let line = box(view.benchState, "lineFrame")
        let hit = try #require(view.hitTest(NSPoint(x: Metrics.sideInset + line.midX, y: MiniPlayerView.above + line.midY)) as? MiniProgressView)
        let at = hit.convert(NSPoint(x: hit.bounds.width * 0.75, y: hit.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        view.benchLineHover(true)
        view.layoutSubtreeIfNeeded()
        let before = hit.gliding

        hit.mouseDown(with: try event(.leftMouseDown))
        view.layoutSubtreeIfNeeded()
        let pressed = view.benchState
        let glides = hit.gliding
        hit.mouseUp(with: try event(.leftMouseUp))
        view.layoutSubtreeIfNeeded()
        let released = view.benchState

        #expect(!before)
        #expect(glides == Motion.kitSettle.animates)
        #expect(pressed["time"] as? String == "3:33 / 4:45")
        #expect(released["time"] as? String == "3:33 / 4:45")
        #expect(released["timeShare"] as? Double == pressed["timeShare"] as? Double)
        #expect(released["lineThick"] as? Double == 4)
        #expect(abs((released["line"] as? Double ?? 0) - 0.75) < 0.01)
        #expect(abs((view.item?.position?.fraction(now: Date()) ?? 0) - 0.75) < 0.01)
        #expect(view.item?.playing == true)
    }

    @Test func theCoverHandsItsPictureToTheLayerOnceNotOnEveryLayout() throws {
        var shown = item(pair: .tracks, duration: 285, speed: false)
        shown.art = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let view = card(shown)
        let cover = try #require(view.kitSubviews(of: MiniCoverView.self).first)
        let first = cover.paints

        for _ in 0..<5 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
        let after = cover.paints
        cover.art = NSImage(size: NSSize(width: 64, height: 64))
        cover.paint(ink: .flat, greys: .white, dark: false, scale: 2)
        let changed = cover.paints
        cover.paint(ink: .flat, greys: .white, dark: false, scale: 2)

        #expect(first == 1)
        #expect(after == 1)
        #expect(changed == 2)
        #expect(cover.paints == 2)
    }

    @Test func aTitleLeftMidScrollGoesHomeAndOneAtItsStartOnlyRests() throws {
        guard Motion.kitRoll.animates, Motion.kitQuick.animates else { return }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: MiniPlayerView.full), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let ground = KitFlippedView(frame: NSRect(x: 0, y: 0, width: 258, height: MiniPlayerView.full))
        window.contentView = ground
        let view = card(item(pair: .tracks, duration: 285, speed: false, title: "Did you know that there's a tunnel under Ocean Blvd"))
        ground.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let title = try #require(view.kitSubviews(of: MiniWordsView.self).first)

        view.benchPillHover(true)
        view.layoutSubtreeIfNeeded()
        title.offsetStandIn = 0
        view.benchPillHover(false)
        view.layoutSubtreeIfNeeded()
        let restedAtStart = !title.homing && title.slidingPicture == nil

        view.benchPillHover(true)
        view.layoutSubtreeIfNeeded()
        let slidAgain = title.sliding
        title.offsetStandIn = -60
        view.benchPillHover(false)
        view.layoutSubtreeIfNeeded()
        let wentHome = title.homing && !title.sliding && title.slidingPicture != nil
        view.benchPillHover(true)
        view.layoutSubtreeIfNeeded()
        let waitsForHome = title.homing && !title.sliding
        title.text = "Another"
        let cutForNewWords = !title.homing && title.slidingPicture == nil

        #expect(restedAtStart)
        #expect(slidAgain)
        #expect(wentHome)
        #expect(waitsForHome)
        #expect(cutForNewWords)
    }

    @Test func arrivingAndLeavingMoveOneWayOnly() {
        let curves: [KitCurve] = [.spring(.cover), .spring(.settle), .easeOut(0.18), .easeOut(0.12)]

        let runs = curves.map { curve in stride(from: 0.0, through: 1.2, by: 1.0 / 60).map { MiniPlayerView.progress(curve, at: $0).share } }

        for run in runs {
            #expect(zip(run, run.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })
            #expect(run.last == 1)
            #expect(run.first == 0)
        }
    }

    @Test func aRefusalAndTheRawReadingsAreParsed() {
        let body: [String: Any] = [
            "reading": ["playing": false, "time": 100, "duration": 285, "rate": 1, "source": "audio", "why": "the latest to start",
                        "minor": false, "element": true],
            "refused": 2,
            "media": [["kind": "audio", "duration": 285, "time": 100, "paused": true, "chosen": true],
                      ["kind": "audio", "duration": 6, "time": 3, "paused": false, "loop": true]],
            "reported": ["duration": 285, "time": 99, "rate": 1],
        ]

        let made = MiniReport.parse(body)

        #expect(made.refused == 2)
        #expect(made.media.count == 2 && made.media[0].chosen && made.media[1].loop)
        #expect(made.reported?.duration == 285)
        #expect(made.reading?.why == "the latest to start")
    }
}
