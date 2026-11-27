import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class LiveLoadingTests {
    private var browsers: [Browser] = []
    private var made: [UUID] = []
    private var windows: [NSWindow] = []
    private let space = UUID()
    private let rows = (1...3).map { LiveItem(key: "https://github.com/acme/rocket/pull/\($0)", title: "Pull \($0)") }
    private static let long = "Rocket Pull Requests Waiting for Review"

    init() {
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "live-loading-\(getpid())", 1)
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
    }

    private func tearDown() async {
        Store.settings.removeObject(forKey: "motion.testReduced")
        LiveFolders.shared.reader = { await LiveReader.read($0) }
        LiveLoadingClock.shared.wait = LiveLoadingPace.wait
        LiveLoadingClock.shared.stay = LiveLoadingPace.stay
        for id in made { LiveFolders.shared.remove(id) }
        for browser in browsers { browser.closeAll() }
        for window in windows { window.contentView = nil }
        made = []
        browsers = []
        windows = []
    }

    private final class Reads {
        var waiting: [CheckedContinuation<LiveReader.Answer, Never>] = []
        var count = 0

        func answer(_ answer: LiveReader.Answer) {
            guard !waiting.isEmpty else { return }
            waiting.removeFirst().resume(returning: answer)
        }
    }

    private func held() -> Reads {
        let reads = Reads()
        LiveFolders.shared.reader = { _ in
            reads.count += 1
            return await withCheckedContinuation { reads.waiting.append($0) }
        }
        return reads
    }

    private func pace(_ wait: TimeInterval, _ stay: TimeInterval) {
        LiveLoadingClock.shared.wait = wait
        LiveLoadingClock.shared.stay = stay
    }

    private func folder(_ name: String = "PRs", items: Bool = true) -> UUID {
        let folder = LiveFolders.shared.add(name: name, source: .pullRequests, space: space)
        made.append(folder.id)
        if items { LiveFolders.shared.apply(.items(rows, nil), to: folder.id, now: Date().addingTimeInterval(-60)) }
        return folder.id
    }

    private func loading(_ name: String = "PRs") -> UUID {
        let id = folder(name)
        LiveFolders.shared.apply(.signIn, to: id, now: Date().addingTimeInterval(-60))
        LiveFolders.shared.signInMayBeOver(id)
        return id
    }

    private func heading(_ id: UUID, _ name: String = "PRs", collapsed: Bool = true, width: CGFloat = 240, count: Int = 3,
                         number: Int? = nil, depth: Int = 0, shown: Bool = false) -> GroupHeadingView {
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let view = GroupHeadingView(frame: NSRect(x: 0, y: 0, width: width, height: GroupHeadingView.height))
        view.count = count
        view.number = number
        view.depth = depth
        if shown {
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: GroupHeadingView.height),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(view)
            windows.append(window)
        }
        view.show(TabGroup(id: id, name: name, collapsed: collapsed, live: true), in: browser)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func status(_ heading: GroupHeadingView) -> LiveStatusView? { heading.status as? LiveStatusView }

    private func rings(_ heading: GroupHeadingView) -> Bool {
        heading.layoutSubtreeIfNeeded()
        return heading.liveRing.map { !$0.isHidden } ?? false
    }

    private func ringFrame(_ heading: GroupHeadingView) -> NSRect {
        heading.layoutSubtreeIfNeeded()
        return heading.liveRing.map { heading.convert($0.bounds, from: $0) } ?? .zero
    }

    private func part(_ heading: GroupHeadingView, _ name: String) -> NSRect {
        heading.layoutSubtreeIfNeeded()
        return heading.benchParts[name]?.frame ?? .zero
    }

    private func until(_ timeout: TimeInterval = 3, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    @Test func aReadThatEndsInABlinkShowsNothing() {
        let start = Date(timeIntervalSince1970: 1000)
        var pace = LiveLoadingPace()

        pace.see(loading: true, at: start)
        let early = [0, 0.1, 0.39].map { pace.shows(at: start.addingTimeInterval($0)) }
        let due = pace.turns(after: start)
        pace.see(loading: false, at: start.addingTimeInterval(0.39))
        let after = [0.39, 0.4, 0.5, 2].map { pace.shows(at: start.addingTimeInterval($0)) }

        #expect(LiveLoadingPace.wait == 0.4)
        #expect(early == [false, false, false])
        #expect(due == start.addingTimeInterval(0.4))
        #expect(after == [false, false, false, false])
        #expect(!pace.busy)
        #expect(pace.turns(after: start.addingTimeInterval(0.39)) == nil)
    }

    @Test func onceShownTheRingStaysForOneWholeTurn() {
        let start = Date(timeIntervalSince1970: 1000)
        var pace = LiveLoadingPace()

        pace.see(loading: true, at: start)
        let appeared = pace.shows(at: start.addingTimeInterval(0.4))
        pace.see(loading: false, at: start.addingTimeInterval(0.45))
        let kept = [0.45, 0.8, 1.24].map { pace.shows(at: start.addingTimeInterval($0)) }
        let due = pace.turns(after: start.addingTimeInterval(0.45))
        let gone = pace.shows(at: start.addingTimeInterval(1.25))
        pace.see(loading: false, at: start.addingTimeInterval(1.25))

        #expect(LiveLoadingPace.stay == RingView.turn)
        #expect(RingView.turn == 0.85)
        #expect(appeared)
        #expect(kept == [true, true, true])
        #expect(due == start.addingTimeInterval(1.25))
        #expect(!gone)
        #expect(!pace.busy)
    }

    @Test func aLongReadShowsTheRingUntilItEndsAndNoLonger() {
        let start = Date(timeIntervalSince1970: 1000)
        var pace = LiveLoadingPace()

        pace.see(loading: true, at: start)
        let during = [0.4, 3, 9.99].map { pace.shows(at: start.addingTimeInterval($0)) }
        let due = pace.turns(after: start.addingTimeInterval(3))
        pace.see(loading: false, at: start.addingTimeInterval(10))

        #expect(during == [true, true, true])
        #expect(due == nil)
        #expect(!pace.shows(at: start.addingTimeInterval(10)))
        #expect(!pace.busy)
    }

    @Test func aSecondReadDuringTheStayKeepsTheRingWithoutAGap() {
        let start = Date(timeIntervalSince1970: 1000)
        var pace = LiveLoadingPace()

        pace.see(loading: true, at: start)
        pace.see(loading: false, at: start.addingTimeInterval(0.5))
        pace.see(loading: true, at: start.addingTimeInterval(0.7))
        let through = [0.7, 1.25, 4].map { pace.shows(at: start.addingTimeInterval($0)) }
        pace.see(loading: false, at: start.addingTimeInterval(4))

        #expect(through == [true, true, true])
        #expect(!pace.shows(at: start.addingTimeInterval(4)))
    }

    @Test func twoBlinksDoNotAddUpToARing() {
        let start = Date(timeIntervalSince1970: 1000)
        var pace = LiveLoadingPace()

        pace.see(loading: true, at: start)
        pace.see(loading: false, at: start.addingTimeInterval(0.3))
        pace.see(loading: true, at: start.addingTimeInterval(0.35))
        let second = [0.4, 0.74].map { pace.shows(at: start.addingTimeInterval($0)) }
        let third = pace.shows(at: start.addingTimeInterval(0.75))

        #expect(second == [false, false])
        #expect(third)
    }

    @Test func theHeadingTakesTheRingForAReadAPersonWaitsOnOpenOrFoldedEmptyOrNot() {
        var folder = LiveFolder(space: space, name: "PRs", source: .pullRequests)
        let empty = LiveLoading.waits(folder)
        let line = LiveQuiet.note(folder, stale: false)
        folder.items = rows
        let kept = LiveLoading.waits(folder)
        folder.paused = true
        let paused = [LiveLoading.waits(folder), LiveLoading.waits(folder, asked: true)]
        folder.paused = false
        let routine = [LiveFolder.State.fine, .signIn, .failed].map { state -> Bool in
            var other = folder
            other.state = state
            return LiveLoading.waits(other)
        }
        let asked = [LiveFolder.State.fine, .signIn, .failed].map { state -> Bool in
            var other = folder
            other.state = state
            return LiveLoading.waits(other, asked: true)
        }

        #expect(empty)
        #expect(line == nil)
        #expect(kept)
        #expect(paused == [false, false])
        #expect(routine == [false, false, false])
        #expect(asked == [true, false, true])
        #expect(LiveLoading.side == 11)
        #expect(LiveLoading.spoken(folder) == "Loading PRs")
    }

    @Test func theStayGivesWayToWordsAndToTheSignInButtonButNotToAnEmptySlot() {
        var folder = LiveFolder(space: space, name: "PRs", source: .pullRequests)
        folder.items = rows
        let yields = { (folder: LiveFolder, asked: Bool, stale: Bool) in
            LiveLoading.yields(folder, asked: asked, status: LiveQuiet.status(folder, stale: stale))
        }
        let waiting = yields(folder, false, false)
        folder.state = .fine
        let fine = yields(folder, false, false)
        var asking = folder
        asking.state = .signIn
        var failed = folder
        failed.state = .failed
        let words = [yields(asking, false, false), yields(failed, false, true)]
        let once = yields(failed, false, false)
        let asked = yields(failed, true, true)
        folder.paused = true

        #expect(!waiting)
        #expect(!fine)
        #expect(words == [true, true])
        #expect(!once)
        #expect(!asked)
        #expect(yields(folder, false, false))
    }

    @Test func theRingComesAfterTheWaitTakesTheCountsPlaceOnAFoldedRowAndTheRowsEndOnAnOpenOne() async {
        pace(0.15, 0.3)
        let reads = held()
        let id = loading()
        let folded = heading(id)
        let open = heading(id, collapsed: false)
        let first = [rings(folded), rings(open)]
        let spoken = [folded, open].map(\.liveSpoken)
        let counted = folded.showsCount
        await until { self.rings(folded) && self.rings(open) }
        let shown = [rings(folded), rings(open)]
        let frames = [ringFrame(folded), ringFrame(open)]
        let chip = part(folded, "chip")
        let swapped = folded.showsCount
        let place = status(folded).map { folded.convert($0.bounds, from: $0) } ?? .zero
        let name = part(folded, "nameHost")
        let chevron = part(folded, "chevron")

        await until { !reads.waiting.isEmpty }
        reads.answer(.items(rows, nil))
        await until { LiveFolders.shared.folder(id)?.state == .fine }
        await until { !self.rings(folded) && !self.rings(open) }
        let gone = [rings(folded), rings(open)]

        #expect(first == [false, false])
        #expect(spoken == ["Loading PRs", "Loading PRs"])
        #expect(shown == [true, true])
        #expect(frames.map(\.size) == [NSSize(width: 11, height: 11), NSSize(width: 11, height: 11)])
        #expect(counted)
        #expect(!swapped)
        #expect(frames[0].maxX == chip.maxX)
        #expect(frames[0] == frames[1])
        #expect(frames[0].minX >= chip.minX && frames[0].maxX <= chip.maxX)
        #expect(frames[0].minX >= chevron.maxX)
        #expect(place == frames[0])
        #expect(abs(chevron.minX - name.maxX - SideLook.chevronGap) < 0.6)
        #expect(frames[1].maxX == open.bounds.width - SideGrid.lead)
        #expect(frames.allSatisfy { abs($0.midY - GroupHeadingView.height / 2) < 0.51 })
        #expect(gone == [false, false])
        #expect(folded.showsCount)
        #expect(folded.liveSpoken != "Loading PRs")
    }

    @Test(arguments: [240, 200, 184] as [CGFloat])
    func nothingOnTheRowMovesWhenTheRingComesOrGoes(width: CGFloat) async {
        pace(0.05, 0.1)
        let reads = held()
        var moved: [String] = []
        for name in ["PRs", Self.long] {
            let id = folder(name)
            for collapsed in [true, false] {
                let view = heading(id, name, collapsed: collapsed, width: width)
                let parts = ["nameHost", "chevron", "chip", "mark"]
                let before = parts.map { part(view, $0) }
                LiveFolders.shared.update(id, asked: true)
                await until { self.rings(view) }
                let during = parts.map { part(view, $0) }
                let ring = ringFrame(view)
                let name = part(view, "nameHost")
                let shown = rings(view)
                await until { !reads.waiting.isEmpty }
                reads.answer(.items(rows, nil))
                await until { !LiveFolders.shared.reading.contains(id) && !self.rings(view) }
                let after = parts.map { part(view, $0) }
                if !shown { moved.append("\(name) \(collapsed): no ring") }
                if before != during || during != after { moved.append("\(name) \(collapsed): \(before) \(during) \(after)") }
                if ring.minX < name.maxX || ring.maxX > width { moved.append("\(name) \(collapsed): ring \(ring) over the name \(name)") }
            }
        }

        #expect(moved == [])
    }

    @Test func theRingShowsInTheNarrowestRowBesideTheCountAndTheShortcutNumber() async {
        pace(0.05, 0.1)
        let reads = held()
        let id = loading(Self.long)
        let view = heading(id, Self.long, width: 184, count: 12, number: 3, depth: 2)

        await until { self.rings(view) }
        let ring = ringFrame(view)
        let name = part(view, "nameHost")
        let chip = part(view, "chip")

        #expect(rings(view))
        #expect(status(view)?.isHidden == false)
        #expect(ring.size == NSSize(width: 11, height: 11))
        #expect(ring.minX >= name.maxX)
        #expect(ring.minX >= chip.minX && ring.maxX <= chip.maxX)
        #expect(name.width > 0)
    }

    @Test func aRoutineReadShowsNothingAndAReadAPersonAskedForShowsTheRing() async {
        pace(0.05, 0.1)
        let reads = held()
        let id = folder()
        let view = heading(id)

        LiveFolders.shared.update(id)
        await until { reads.count == 1 }
        await wait(0.2)
        let routine = (rings(view), status(view)?.loads, LiveFolders.shared.requested.contains(id))
        reads.answer(.items(rows, nil))
        await until { !LiveFolders.shared.reading.contains(id) }

        LiveFolders.shared.update(id, asked: true)
        await until { reads.count == 2 }
        let said = view.liveSpoken
        await until { self.rings(view) }
        let asked = (rings(view), status(view)?.loads, LiveFolders.shared.requested.contains(id))
        reads.answer(.items(rows, nil))
        await until { !LiveFolders.shared.reading.contains(id) && !self.rings(view) }

        #expect(routine.0 == false && routine.1 == false && routine.2 == false)
        #expect(said == "Loading PRs")
        #expect(asked.0 && asked.1 == true && asked.2)
        #expect(!LiveFolders.shared.requested.contains(id))
        #expect(!rings(view))
    }

    @Test func theSignInButtonTakesTheRingsPlaceAtOnce() async throws {
        pace(0.05, 5)
        let reads = held()
        let id = loading()
        let view = heading(id)

        await until { self.rings(view) }
        let shown = rings(view)
        await until { !reads.waiting.isEmpty }
        reads.answer(.signIn)
        await until { LiveFolders.shared.folder(id)?.state == .signIn }
        await wait(0.1)
        let after = rings(view)
        let pill = status(view)?.pill

        #expect(shown)
        #expect(!after)
        #expect(pill != nil && pill?.isHiddenOrHasHiddenAncestor == false)
        #expect(!LiveLoadingClock.shared.shown.contains(id))
    }

    @Test func aLongNameKeepsAllItsRoomAtRestAndWhileTheRingShows() async {
        pace(0.05, 0.1)
        let reads = held()
        let id = folder(Self.long)
        let folded = heading(id, Self.long, width: 222)
        let open = heading(id, Self.long, collapsed: false, width: 222)
        let chip = part(folded, "chip")
        let rest = [part(folded, "chevron"), part(open, "chevron")]

        LiveFolders.shared.update(id, asked: true)
        await until { self.rings(folded) && self.rings(open) }
        let during = [part(folded, "chevron"), part(open, "chevron")]
        await until { !reads.waiting.isEmpty }
        reads.answer(.items(rows, nil))
        await until { !self.rings(folded) && !self.rings(open) }

        #expect(folded.benchNameWidth > part(folded, "nameHost").width)
        #expect(rest[0].maxX == chip.minX - SideGrid.gap)
        #expect(rest == during)
        #expect(rest[1].maxX <= 222 - SideGrid.lead - LiveLoading.side - SideGrid.gap)
    }

    @Test func theUnseenCountOfAFoldedRowStaysBesideTheRing() async {
        pace(0.05, 0.1)
        let reads = held()
        let id = folder()
        let fresh = (4...5).map { LiveItem(key: "https://github.com/acme/rocket/pull/\($0)", title: "Pull \($0)", activity: Date()) }
        LiveFolders.shared.apply(.items(fresh, nil), to: id)
        let view = heading(id)
        let count = LiveFolders.shared.folder(id)?.freshCount ?? 0
        let before = status(view).map { view.convert($0.bounds, from: $0) } ?? .zero

        LiveFolders.shared.update(id, asked: true)
        await until { self.rings(view) }
        let during = status(view).map { view.convert($0.bounds, from: $0) } ?? .zero
        let said = view.liveSpoken
        await until { !reads.waiting.isEmpty }
        reads.answer(.items(fresh, nil))
        await until { !self.rings(view) }

        #expect(count > 0)
        #expect(before.width > 0)
        #expect(before == during)
        #expect(said == "Loading PRs")
    }

    @Test func underReduceMotionTheRingStandsStillAndOtherwiseItTurns() async {
        pace(0.05, 0.1)
        let reads = held()
        let id = loading()
        let turning = heading(id, shown: true)
        await until { self.rings(turning) }
        let turns = turning.liveRing?.turning

        Store.settings.set(true, forKey: "motion.testReduced")
        let still = heading(id, shown: true)
        await until { self.rings(still) }
        let stands = (rings(still), still.liveRing?.turning, still.liveRing?.layer?.sublayers?.first?.animationKeys() ?? [])
        Store.settings.removeObject(forKey: "motion.testReduced")
        await until { !reads.waiting.isEmpty }
        reads.answer(.items(rows, nil))
        await until { LiveFolders.shared.folder(id)?.state == .fine }

        #expect(turns == true)
        #expect(stands.0)
        #expect(stands.1 == false)
        #expect(stands.2 == [])
    }

    @Test func anOpenEmptyFolderThatLoadsShowsTheRingOnItsHeadingAndNoLineUnderIt() async {
        pace(0.05, 0.1)
        let reads = held()
        let id = folder(items: false)
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let note = LiveNoteView(browser: browser, id: id, height: Metrics.sideRowHeight, interactive: true)
        note.frame = NSRect(x: 0, y: 0, width: 240, height: Metrics.sideRowHeight)
        let open = heading(id, collapsed: false, count: 0)
        let folded = heading(id, count: 0)

        LiveFolders.shared.update(id)
        await until { reads.count == 1 }
        await until { self.rings(folded) && self.rings(open) }
        let said = note.said
        let line = LiveFolders.shared.folder(id).flatMap(LiveQuiet.note)
        let heads = [rings(open), rings(folded)]
        await until { !reads.waiting.isEmpty }
        reads.answer(.items([], nil))
        await until { LiveFolders.shared.folder(id)?.state == .fine }
        await until { !self.rings(open) }
        let empty = note.said

        #expect(said["text"] as? String == "")
        #expect(line == nil)
        #expect(heads == [true, true])
        #expect(empty["text"] as? String == "No pull requests")
        #expect(!rings(open))
    }

}
