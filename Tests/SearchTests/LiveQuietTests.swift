import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class LiveQuietTests {
    private var browsers: [Browser] = []
    private var made: [UUID] = []
    private let space = UUID()
    private let rows = (1...3).map { LiveItem(key: "https://github.com/acme/rocket/pull/\($0)", title: "Pull \($0)") }

    init() {
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "live-quiet-\(getpid())", 1)
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        LiveFolders.shared.reader = { _ in .signIn }
        LiveFolders.shared.benchHere(.distantPast)
        LiveFolders.shared.idleness = { 10_000 }
        LiveFolders.shared.frontmost = { false }
    }

    private func tearDown() async {
        for id in made { LiveFolders.shared.remove(id) }
        LiveFolders.shared.network(true)
        LiveFolders.shared.benchHere(.distantPast)
        LiveFolders.shared.every = { Shared.prefs.liveEvery.interval }
        LiveFolders.shared.reader = { await LiveReader.read($0) }
        LiveFolders.shared.idleness = { LiveFolders.idleSeconds() }
        LiveFolders.shared.frontmost = { NSApp?.isActive ?? false }
        for browser in browsers { browser.closeAll() }
        made = []
        browsers = []
    }

    private func folder(_ name: String = "PRs", items: [LiveItem]? = nil, ago: TimeInterval = 60, stuck: TimeInterval? = nil) -> UUID {
        let folder = LiveFolders.shared.add(name: name, source: .pullRequests, space: space)
        made.append(folder.id)
        LiveFolders.shared.apply(.items(items ?? rows, nil), to: folder.id, now: Date().addingTimeInterval(-ago))
        LiveQuietClock.shared.benchStuck(folder.id, for: stuck ?? ago)
        return folder.id
    }

    private func heading(_ id: UUID, _ name: String = "PRs", collapsed: Bool = true, width: CGFloat = 240, count: Int = 3) -> GroupHeadingView {
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let view = GroupHeadingView(frame: NSRect(x: 0, y: 0, width: width, height: GroupHeadingView.height))
        view.count = count
        view.show(TabGroup(id: id, name: name, collapsed: collapsed, live: true), in: browser)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func note(_ id: UUID, width: CGFloat = 240) -> LiveNoteView {
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let view = LiveNoteView(browser: browser, id: id, height: Metrics.sideRowHeight, interactive: true)
        view.frame = NSRect(x: 0, y: 0, width: width, height: Metrics.sideRowHeight)
        return view
    }

    private func status(_ heading: GroupHeadingView) -> LiveStatusView? {
        heading.layoutSubtreeIfNeeded()
        return heading.status as? LiveStatusView
    }

    private func settle() async {
        for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(15)) }
    }

    private func until(_ timeout: TimeInterval = 3, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func menu(_ id: UUID) -> [NSMenuItem] {
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        return FolderMenus.menu(browser: browser, group: TabGroup(id: id, name: "PRs", collapsed: true, live: true)).items
    }

    @Test func aReadThatFailsOnceIsNotSeenOnTheRowFoldedOrOpen() async {
        let id = folder()
        let folded = heading(id)
        let open = heading(id, collapsed: false)
        let line = note(id)
        let name = [folded, open].map { $0.benchParts["nameHost"]?.frame }

        LiveFolders.shared.apply(.failed, to: id)
        await settle()
        let failed = LiveFolders.shared.folder(id)
        let said = [status(folded)?.said, status(open)?.said]
        let after = [folded, open].map { $0.benchParts["nameHost"]?.frame }
        let first = menu(id).prefix(2).map { ($0.title, $0.isSectionHeader) }

        #expect(failed?.state == .failed)
        #expect(failed?.status == "Can't read")
        #expect(said == [nil, nil])
        #expect(folded.showsCount)
        #expect(line.said["text"] as? String == "")
        #expect(!LiveQuiet.stale(id))
        #expect(name == after)
        #expect(first.map(\.0) == ["Updated a moment ago", "Couldn't read GitHub"])
        #expect(first.map(\.1) == [true, true])
    }

    @Test func anOldListWhoseFirstReadAfterALongSleepFailsStaysQuietUntilItHasStayedThatWay() async {
        let id = folder(ago: 8 * 3600, stuck: 0)
        let away = folder("Reviews", ago: 8 * 3600, stuck: 0)
        let folded = heading(id)
        let open = heading(id, collapsed: false)
        let other = heading(away, "Reviews")

        LiveFolders.shared.apply(.failed, to: id)
        LiveQuietClock.shared.sync()
        await settle()
        let failed = [status(folded)?.said, status(open)?.said]
        let since = LiveQuietClock.shared.since[id]
        let looked = menu(id).prefix(2).map(\.title)

        LiveFolders.shared.network(false)
        LiveQuietClock.shared.sync()
        await settle()
        let offline = [status(folded)?.said, status(other)?.said]

        LiveFolders.shared.network(true)
        LiveFolders.shared.apply(.items(rows, nil), to: id)
        LiveQuietClock.shared.sync()
        await settle()

        #expect(failed == [nil, nil])
        #expect(since != nil)
        #expect(looked.first?.hasPrefix("Updated ") == true)
        #expect(looked.last == "Couldn't read GitHub")
        #expect(offline == [nil, nil])
        #expect(!LiveQuiet.stale(id))
        #expect(LiveQuietClock.shared.since[id] == nil)
        #expect([status(folded)?.said, status(open)?.said] == [nil, nil])
    }

    @Test func aFolderThatGotStuckWhileThePersonWasAwaySaysNothingWhenTheyComeBackUntilAnotherTryHasFailed() async {
        let id = folder(ago: 8 * 3600)
        let folded = heading(id)

        LiveFolders.shared.benchHere(nil)
        LiveFolders.shared.apply(.failed, to: id)
        LiveQuietClock.shared.sync()
        await settle()
        let away = status(folded)?.said
        let stuck = LiveQuietClock.shared.since[id].map { Date().timeIntervalSince($0) } ?? 0

        LiveFolders.shared.benchHere(Date())
        LiveQuietClock.shared.sync()
        await settle()
        let back = status(folded)?.said

        LiveFolders.shared.benchHere(Date().addingTimeInterval(-7 * 60))
        await until { LiveQuiet.stale(id) }
        await settle()
        let later = status(folded)?.said

        LiveFolders.shared.benchHere(nil)
        LiveQuietClock.shared.sync()
        await settle()
        let leftAgain = status(folded)?.said
        LiveFolders.shared.benchHere(Date())
        LiveQuietClock.shared.sync()
        await settle()
        let backAgain = status(folded)?.said

        LiveFolders.shared.apply(.items(rows, nil), to: id)
        await until { !LiveQuiet.stale(id) }
        await settle()

        #expect(stuck >= 8 * 3600 - 5)
        #expect(away == nil)
        #expect(back == nil)
        #expect(later == "Out of date")
        #expect(leftAgain == "Out of date")
        #expect(backAgain == "Out of date")
        #expect(status(folded)?.said == nil)
    }

    @Test func aFolderThatHasFailedForLongSaysOutOfDateWithTheDetailInItsHelpTag() async {
        let id = folder(ago: 3 * 3600)
        let folded = heading(id)
        let open = heading(id, collapsed: false)
        let line = note(id)

        LiveFolders.shared.apply(.failed, to: id)
        await until { LiveQuiet.stale(id) }
        await settle()
        let shown = [status(folded), status(open)]

        #expect(shown.map { $0?.said } == ["Out of date", "Out of date"])
        #expect(shown.map { $0?.isHidden } == [false, false])
        #expect(shown.map { $0?.marked } == [false, false])
        #expect(shown[0]?.toolTip?.hasPrefix("Updated ") == true)
        #expect(shown[0]?.toolTip?.hasSuffix(". Couldn't read GitHub.") == true)
        #expect(shown[0]?.accessibilityLabel()?.hasPrefix("Out of date. Updated ") == true)
        #expect(folded.showsCount)
        #expect(line.said["text"] as? String == "")
        #expect(LiveFolders.shared.folder(id)?.items.count == 3)

        LiveFolders.shared.apply(.items(rows, nil), to: id)
        await until { !LiveQuiet.stale(id) }
        await settle()

        #expect(status(folded)?.said == nil)
        #expect(status(open)?.said == nil)
    }

    @Test func inANarrowSidebarOutOfDateBecomesAMarkAndIsNeverHidden() async {
        let name = "Rocket Pull Requests Waiting for Review"
        let id = folder(name, ago: 3 * 3600)
        LiveFolders.shared.apply(.failed, to: id)
        await until { LiveQuiet.stale(id) }
        let narrow = heading(id, name, width: 182)
        let wide = heading(id, name, width: 420)
        await settle()
        let shown = [status(narrow), status(wide)]
        let chip = narrow.benchParts["chip"]?.frame ?? .zero
        let place = shown[0].map { narrow.convert($0.bounds, from: $0) } ?? .zero

        #expect(shown.map { $0?.marked } == [true, false])
        #expect(shown.map { $0?.isHidden } == [false, false])
        #expect(shown.map { $0?.said } == ["Out of date", "Out of date"])
        #expect(place.maxX <= chip.minX)
        #expect(place.minX >= (narrow.benchParts["chevron"]?.frame.maxX ?? .infinity))
        #expect(shown[0]?.toolTip == shown[1]?.toolTip)
    }

    @Test func anEmptyFolderKeepsItsEmptyWordsAfterOneFailedReadAndOffersTryAgainAfterLongFailure() async {
        let id = folder(items: [], ago: 60)
        let line = note(id)
        await settle()
        let empty = line.said["text"] as? String

        LiveFolders.shared.apply(.failed, to: id)
        await settle()
        let once = line.said

        let old = folder("Reviews", items: [], ago: 3 * 3600)
        let late = note(old)
        LiveFolders.shared.apply(.failed, to: old)
        await until { LiveQuiet.stale(old) }
        await settle()
        let long = late.said

        let never = LiveFolders.shared.add(name: "Inbox", source: .pullRequests, space: space)
        made.append(never.id)
        let first = note(never.id)
        await settle()
        let waiting = first.said["text"] as? String
        LiveFolders.shared.apply(.missed(LiveMiss(cause: .limited, wait: 600)), to: never.id)
        await until { LiveQuiet.stale(never.id) }
        await settle()
        let limited = first.said

        #expect(empty == "No pull requests")
        #expect(once["text"] as? String == "No pull requests")
        #expect(long["text"] as? String == "Couldn't read GitHub")
        #expect(long["detail"] as? String == "Try again")
        #expect(long["button"] as? Bool == true)
        #expect((long["tip"] as? String)?.hasSuffix(". Couldn't read GitHub.") == true)
        #expect(waiting == "")
        #expect(limited["text"] as? String == "Couldn't read GitHub")
        #expect(limited["detail"] as? String == "")
        #expect(limited["button"] as? Bool == false)
        #expect(limited["tip"] as? String == "Not updated yet. Limited by GitHub, trying again in 10 minutes.")
    }

    @Test func offlineForLongSaysOutOfDateAndComingBackOnlineTakesItAway() async {
        let id = folder(ago: 3 * 3600)
        let recent = folder("Reviews")
        let folded = heading(id)
        let other = heading(recent, "Reviews")
        await settle()
        let before = status(folded)?.said

        LiveFolders.shared.network(false)
        await until { LiveQuiet.stale(id) }
        await settle()
        let offline = [status(folded)?.said, status(other)?.said]
        let tip = status(folded)?.toolTip
        let lines = menu(id).prefix(2).map(\.title)

        LiveFolders.shared.network(true)
        await until { !LiveQuiet.stale(id) }
        await settle()

        #expect(before == nil)
        #expect(offline == ["Out of date", nil])
        #expect(tip?.hasSuffix(". You're offline.") == true)
        #expect(lines.last == "You're offline")
        #expect(status(folded)?.said == nil)
    }

    @Test func pausedAndSignInKeepTheirWords() async {
        let id = folder()
        let asking = folder("Reviews")
        let paused = heading(id)
        let signIn = heading(asking, "Reviews")

        LiveFolders.shared.pause(id, true)
        LiveFolders.shared.apply(.signIn, to: asking)
        await settle()

        #expect(status(paused)?.said == "Paused")
        #expect(status(signIn)?.pill?.title == "Sign in")
        #expect(menu(id).first?.title == "Updated a moment ago")
        #expect(menu(id).contains { $0.title == "Start Updating" })
        #expect(menu(asking).contains { $0.title == "Update Now" } && menu(asking).contains { $0.title == "Stop Updating" })
    }

    @Test func theIntervalIsASettingAgentsCanReachAndTheTickUsesIt() {
        let prefs = Preferences()
        let before = prefs.liveEvery
        defer { prefs.liveEvery = before }

        let applied = SettingsIndex.apply(LiveEvery.key, 15, to: prefs)
        let chosen = prefs.liveEvery
        let refused = SettingsIndex.apply(LiveEvery.key, 7, to: prefs)
        let access = PersonSettings.table[LiveEvery.key]
        let item = SettingsIndex.item(LiveEvery.key)
        let neighbour = PersonSettings.table["live.offers"]

        #expect(applied)
        #expect(chosen == .quarter)
        #expect(!refused)
        #expect(prefs.liveEvery == .quarter)
        #expect(item?.page == .liveFolders)
        #expect(item?.keys == ["live.every"])
        #expect(access != nil)
        #expect(access?.bar == neighbour?.bar)
        #expect(access?.takes == "1, 5, 15, 30, 60 minutes")
        #expect(SettingsIndex.values(prefs)[LiveEvery.key] as? Int == 15)
        #expect(SettingsIndex.find("how often").contains { $0.id == LiveEvery.key })
    }

    @Test func theLongWaitFollowsTheChosenInterval() async {
        let id = folder(ago: 30 * 60)
        LiveFolders.shared.apply(.failed, to: id)
        await until { LiveQuiet.stale(id) }
        let five = LiveQuiet.stale(id)

        LiveFolders.shared.every = { 1800 }
        LiveQuietClock.shared.sync()
        let half = LiveQuiet.stale(id)

        #expect(five)
        #expect(!half)
    }
}
