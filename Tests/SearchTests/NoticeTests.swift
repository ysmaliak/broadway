import AppKit
import Foundation
import QuartzCore
import Testing
@testable import Search

private final class Plate: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 30) }
}

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct NoticeTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func watched<T>(_ holds: @escaping () -> [NoticeClock.Hold] = { [] }, _ body: () throws -> T) rethrows -> T {
        let now = NoticeClock.now
        let looks = NoticeClock.looks
        NoticeClock.now = { [start] in start }
        NoticeClock.looks = { _, _ in holds() }
        defer {
            NoticeClock.now = now
            NoticeClock.looks = looks
        }
        return try body()
    }

    private func shop() -> Tab {
        let tab = Tab(bench: true)
        tab.hold(URL(string: "https://shop.example.test/cart")!)
        return tab
    }

    private func window() -> NSWindow {
        let made = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300), styleMask: .borderless, backing: .buffered,
                            defer: false)
        made.isReleasedWhenClosed = false
        return made
    }

    @Test func everyKindHasItsTime() {
        #expect(NoticeKind.note.seconds == 4)
        #expect(NoticeKind.action.seconds == 8)
        #expect(NoticeKind.error.seconds == 10)
        #expect(NoticeKind.offer.seconds == 30)
        #expect(NoticeKind.question.seconds == nil)
        #expect(NoticeKind.progress.seconds == 3)
    }

    @Test(arguments: NoticeKind.allCases.filter { $0.seconds != nil })
    func aNoticeGoesAtItsTime(kind: NoticeKind) throws {
        let seconds = try #require(kind.seconds)
        var gone = false
        let clock = watched { NoticeClock(kind) { gone = true } }
        watched { clock.tick(at: start.addingTimeInterval(seconds - 0.1)) }
        #expect(!gone)
        watched { clock.tick(at: start.addingTimeInterval(seconds)) }
        #expect(gone)
        #expect(!clock.live)
    }

    @Test func aQuestionHasNoTimeAndStays() {
        var gone = false
        let clock = watched { NoticeClock(.question) { gone = true } }
        watched { clock.tick(at: start.addingTimeInterval(3600)) }
        #expect(!gone)
        #expect(clock.live)
        clock.cancel()
    }

    @Test(arguments: [NoticeClock.Hold.pointer, .focus, .away])
    func aNoticeWaitsWhileItIsHeldAndGoesWhenTheRestOfItsTimeRunsOut(hold: NoticeClock.Hold) {
        var held = false
        var gone = false
        let clock = watched({ held ? [hold] : [] }) { NoticeClock(.note) { gone = true } }
        watched({ held ? [hold] : [] }) {
            clock.tick(at: start.addingTimeInterval(1))
            held = true
            clock.tick(at: start.addingTimeInterval(2))
            clock.tick(at: start.addingTimeInterval(60))
        }
        #expect(!gone)
        #expect(clock.holds == [hold])
        watched({ held ? [hold] : [] }) {
            held = false
            clock.tick(at: start.addingTimeInterval(61))
            clock.tick(at: start.addingTimeInterval(62.9))
        }
        #expect(!gone)
        watched({ held ? [hold] : [] }) { clock.tick(at: start.addingTimeInterval(63)) }
        #expect(gone)
    }

    @Test func theCountdownKeepsWhatWasLeftAcrossAPause() {
        var countdown = NoticeCountdown(8, at: start)
        countdown.hold(true, at: start.addingTimeInterval(3))
        #expect(countdown.remaining(at: start.addingTimeInterval(100)) == 5)
        #expect(!countdown.due(at: start.addingTimeInterval(100)))
        countdown.hold(false, at: start.addingTimeInterval(100))
        #expect(countdown.remaining(at: start.addingTimeInterval(104)) == 1)
        #expect(countdown.due(at: start.addingTimeInterval(105)))
    }

    @Test func thePointerOverANoticeHoldsIt() {
        let shown = window()
        defer { shown.close() }
        let note = NSView(frame: NSRect(x: 10, y: 10, width: 120, height: 30))
        shown.contentView?.addSubview(note)
        #expect(!NoticeClock.seen(note, nil).contains(.pointer))
        NoticeClock.pointerStandIn = note
        defer { NoticeClock.pointerStandIn = nil }
        #expect(NoticeClock.seen(note, nil).contains(.pointer))
    }

    @Test func keyboardFocusInsideANoticeHoldsIt() {
        let shown = window()
        defer { shown.close() }
        let note = NSView(frame: NSRect(x: 10, y: 10, width: 200, height: 40))
        let field = NSTextField(frame: NSRect(x: 4, y: 4, width: 120, height: 22))
        note.addSubview(field)
        shown.contentView?.addSubview(note)
        #expect(!NoticeClock.seen(note, nil).contains(.focus))
        shown.makeFirstResponder(field)
        #expect(NoticeClock.seen(note, nil).contains(.focus))
    }

    @Test func aWindowAwayFromTheFrontOrAHiddenNoticeHoldsIt() {
        let shown = window()
        defer { shown.close() }
        let note = NSView(frame: NSRect(x: 10, y: 10, width: 120, height: 30))
        shown.contentView?.addSubview(note)
        #expect(!NoticeClock.seen(note, nil).contains(.away))
        Store.settings.set(true, forKey: "notice.testAway")
        #expect(NoticeClock.seen(note, nil).contains(.away))
        Store.settings.removeObject(forKey: "notice.testAway")
        note.isHidden = true
        #expect(NoticeClock.seen(note, nil).contains(.away))
        note.isHidden = false
        note.removeFromSuperview()
        #expect(NoticeClock.seen(note, nil).contains(.away))
    }

    @Test func anOfferGoesWhenItsPageChangesAndThatIsNotNow() {
        var page = "https://shop.example.test/cart"
        var answer: String?
        let clock = watched { NoticeClock(.offer, page: { page }) { answer = "not now" } }
        watched { clock.tick(at: start.addingTimeInterval(1)) }
        #expect(answer == nil)
        page = "https://shop.example.test/thanks"
        watched { clock.tick(at: start.addingTimeInterval(2)) }
        #expect(answer == "not now")
    }

    @Test func anOfferGoesWhenItsTabCloses() {
        var open = true
        var gone = false
        let clock = watched { NoticeClock(.offer, page: { open ? "tab" : nil }) { gone = true } }
        open = false
        watched { clock.tick(at: start.addingTimeInterval(1)) }
        #expect(gone)
    }

    @Test func switchingToAnotherTabDropsAnOffersClockWithoutAnsweringIt() async throws {
        let tab = shop()
        let book = NoticeBook()
        var answered = false
        book.begin()
        let clock = watched { book.clock("offer", .offer, view: nil, window: { nil }, page: NoticeOffers.page(tab)) { answered = true } }
        book.end()
        book.begin()
        book.end()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!answered)
        #expect(!clock.live)
    }

    @Test func anOfferWhoseTabIsGoneWhenItStopsShowingIsAnsweredNotNow() async throws {
        var tab: Tab? = shop()
        let book = NoticeBook()
        var answered = false
        book.begin()
        _ = watched { book.clock("offer", .offer, view: nil, window: { nil }, page: NoticeOffers.page(tab)) { answered = true } }
        book.end()
        tab = nil
        book.begin()
        book.end()
        try await Task.sleep(for: .milliseconds(50))
        #expect(answered)
    }

    @Test func aTabInAnotherSpaceIsStillOpenForItsOffer() {
        let browser = Browser(record: WindowRecord())
        let away = UUID()
        #expect(NoticeOffers.alive(browser, away)() == nil)
        if let tab = browser.tabs.first { #expect(NoticeOffers.alive(browser, tab.id)() == tab.id.uuidString) }
    }

    @Test func theShieldOfferGoingByItselfIsNotNowAndAllowsNothing() {
        let browser = Browser(record: WindowRecord())
        let book = NoticeBook()
        let host = "ads.example.test"
        Shield.shared.offer = host
        defer { Shield.shared.offer = nil }
        let clock = watched { NoticeOffers.shield(book, browser, host, NSView()) }
        watched { clock.tick(at: start.addingTimeInterval(30)) }
        #expect(Shield.shared.offer == nil)
        #expect(!Shield.shared.isPaused(on: host))
    }

    @Test func aLineAfterAnActionGoesAfterFourSecondsAndALineWithAButtonAfterEight() {
        let browser = Browser(record: WindowRecord())
        watched { browser.announce("Copied") }
        #expect(browser.announcedKind == .note)
        watched { NoticeClocks.tick(at: start.addingTimeInterval(3.9)) }
        #expect(browser.announcement == "Copied")
        watched { NoticeClocks.tick(at: start.addingTimeInterval(4)) }
        #expect(browser.announcement == nil)
        watched { browser.announce("Tab closed", undo: {}) }
        #expect(browser.announcedKind == .action)
        watched { NoticeClocks.tick(at: start.addingTimeInterval(7.9)) }
        #expect(browser.announcement == "Tab closed")
        watched { NoticeClocks.tick(at: start.addingTimeInterval(8)) }
        #expect(browser.announcement == nil)
        #expect(browser.announcedUndo == nil)
    }

    @Test func anErrorStaysTenSeconds() {
        let browser = Browser(record: WindowRecord())
        watched { browser.announce("Couldn't save page", kind: .error) }
        #expect(browser.announcedKind == .error)
        watched { NoticeClocks.tick(at: start.addingTimeInterval(9.9)) }
        #expect(browser.announcement != nil)
        watched { NoticeClocks.tick(at: start.addingTimeInterval(10)) }
        #expect(browser.announcement == nil)
    }

    @Test func aDownloadRingGoesThreeSecondsAfterItEnds() {
        #expect(Fetches.linger == 3)
    }

    @Test func aQuestionStaysWhileItsAgentWaitsAndGoesAsNoWhenItStops() async {
        let desk = AgentDesk.shared
        let question = AgentQuestion(kind: .choice(["Done"]), title: "Type the code from your phone")
        let asking = Task { @MainActor in await desk.ask(question) }
        for _ in 0..<200 where desk.front?.id != question.id { await Task.yield() }
        #expect(desk.front?.id == question.id)
        desk.take(question.id, .dropped)
        let answer = await asking.value
        #expect(answer == .dropped)
        #expect(desk.front?.id != question.id)
    }

    @Test(arguments: [true, false])
    func underReduceMotionANoticeComesAndGoesWithAFadeOnly(shown: Bool) {
        Store.settings.set(true, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let holder = window()
        defer { holder.close() }
        let note = NSView(frame: NSRect(x: 40, y: 40, width: 200, height: 36))
        note.wantsLayer = true
        holder.contentView?.addSubview(note)
        NoticeMotion.show(note, !shown, animated: false)
        NoticeMotion.show(note, shown)
        let layer = note.layer!
        let animations = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }
        #expect(CATransform3DIsIdentity(layer.transform))
        #expect(!animations.isEmpty)
        #expect(animations.allSatisfy(Motion.staysUnderReduce))
        NoticeMotion.change(note)
        let change = layer.animation(forKey: kCATransition)
        #expect(change.map(Motion.staysUnderReduce) ?? false)
    }

    @Test func withMotionANoticeRisesAndFadesFromTheBottomEdge() {
        let holder = window()
        defer { holder.close() }
        let note = NSView(frame: NSRect(x: 40, y: 40, width: 200, height: 36))
        holder.contentView?.addSubview(note)
        guard !Motion.calm else { return }
        NoticeMotion.enter(note)
        let layer = note.layer!
        #expect(layer.animation(forKey: "arrive") is CASpringAnimation)
        #expect(layer.animation(forKey: "arrive.fade") != nil)
        #expect(NoticeMotion.arrival == KitArrival.rise(by: 18))
        #expect(NoticeMotion.arrival.anchor == KitArrival.bottom)
    }

    @Test func everyBarOfTheStackArrivesWithTheSharedMotionAndHandsItsClockTheView() {
        let holder = window()
        defer { holder.close() }
        let stack = BarStack(frame: holder.contentView!.bounds)
        holder.contentView?.addSubview(stack)
        stack.show([])
        let views = NoticeKind.allCases.map { _ in Plate(frame: NSRect(x: 0, y: 0, width: 160, height: 30)) }
        let clock = watched { NoticeClock(.offer) {} }
        defer { clock.cancel() }
        let bars = zip(views, NoticeKind.allCases).map { BarStack.Bar(view: $0, kind: $1, clock: $1 == .offer ? clock : nil) }
        stack.show(bars)
        #expect(clock.view === views[NoticeKind.allCases.firstIndex(of: .offer)!])
        if !Motion.calm {
            #expect(views.allSatisfy { $0.layer?.animation(forKey: "arrive.fade") != nil })
        }
        let frames = views.map(\.frame)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { !$0.intersects($1) })
    }

    @Test func everyNoticeInTheCodeUsesTheSharedMotion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/Search")
        func read(_ name: String) throws -> String { try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8) }
        for name in ["ShellLayers.swift", "Windows.swift"] {
            let text = try read(name)
            let appended = text.components(separatedBy: "bars.append(.init(view:").dropFirst()
            #expect(!appended.isEmpty)
            for call in appended {
                let line = call.prefix { $0 != "\n" }
                #expect(line.contains("kind:"), "a bar in \(name) has no kind: \(line)")
            }
            #expect(!text.contains("rises:"))
        }
        let hosts = ["ShellStage.swift": "NoticeMotion.show(going, false)", "UpdateCard.swift": "NoticeMotion.show(card, false)",
                     "ShellLayers.swift": "NoticeMotion.show(view, false)"]
        for (name, needle) in hosts { #expect(try read(name).contains(needle), "\(name) leaves without the shared motion") }
        let notNotices: Set<String> = ["Notice.swift", "StageCards.swift", "LinkChooser.swift", "StatusLine.swift", "FloatGlass.swift",
                                       "ShellLayers.swift", "UpdateCard.swift", "FloatExtraChrome.swift", "SelectedPointer.swift"]
        let names = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        for name in names where !notNotices.contains(name) {
            let text = try read(name)
            #expect(!text.contains("kitArrive("), "\(name) moves a surface with its own arrival: give it NoticeMotion or say why it is not a notice")
            #expect(!text.contains(".rise(by:"), "\(name) rises with its own distance instead of NoticeMotion.arrival")
        }
        let layers = try read("ShellLayers.swift")
        #expect(!layers.contains("kitArrive(true, Self.arrival)"))
    }
}
