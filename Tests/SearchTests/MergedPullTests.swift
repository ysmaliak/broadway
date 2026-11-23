import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class MergedPullTests {
    private var browser: Browser!

    init() async throws {
        _ = NSApplication.shared
        keepSetting(Shared.prefs, \.liveFolders, "live.on")
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesTabGroups = true
        browser.prefs.liveFolders = true
        MergedCrowd.forget()
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
    }

    private func tearDown() async {
        MergedCrowd.forget()
        LiveFolders.shared.mergedHold = LiveFolders.hold
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    private func pull(_ number: Int, label: String? = "Approved", checks: LiveChecks? = .failing) -> LiveItem {
        LiveItem(key: "https://github.com/acme/rocket/pull/\(number)", title: "PR \(number)", label: label, author: "dana", checks: checks)
    }

    private func prs(_ items: [LiveItem]) -> LiveFolder {
        let made = LiveFolders.shared.add(name: "PRs", source: .pullRequests, space: browser.spaceID)
        LiveFolders.shared.apply(.items(items, nil), to: made.id)
        browser.syncLive()
        return made
    }

    private func item(_ made: LiveFolder, _ number: Int) -> LiveItem? {
        LiveFolders.shared.folder(made.id)?.items.first { $0.key == pull(number).key }
    }

    private func tab(_ made: LiveFolder, _ number: Int) -> Tab? {
        browser.tabs(in: made.id).first { $0.liveKey == pull(number).key }
    }

    private func shown(_ made: LiveFolder, onScreen: Bool = true) -> (SideColumnView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: 600), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        browser.sightForBench = onScreen
        browser.unfoldFolder(made.id)
        let column = SideColumnView(browser: browser)
        window.contentView = column
        column.layoutSubtreeIfNeeded()
        return (column, window)
    }

    private func row(_ number: Int, in column: NSView) -> TabRowView? {
        column.kitSubviews(of: TabRowView.self).first { $0.accessibilityLabel() == "PR \(number)" && $0.window != nil }
    }

    private func merge(_ number: Int, column: NSView) {
        LiveFolders.shared.pageMerged(URL(string: pull(number).key)!, space: browser.spaceID)
        browser.syncLive()
        column.needsLayout = true
        column.layoutSubtreeIfNeeded()
    }

    @Test func theRowTurnsMergedAtOnceWhenItsPageShowsItMerged() throws {
        let made = prs([pull(1), pull(2)])
        let page = try #require(tab(made, 1))

        browser.livePullState(page, at: URL(string: "https://github.com/acme/rocket/pull/1/files")!, said: .merged)
        browser.syncLive()

        #expect(item(made, 1)?.label == "Merged")
        #expect(item(made, 1)?.byline == "dana • Merged")
        #expect(page.liveItem?.label == "Merged")
        #expect(item(made, 2)?.label == "Approved")
        #expect(LiveFolders.shared.turning(pull(1).key))
    }

    @Test func aFolderReadThatFindsARowNewlyMergedTurnsItAtOnce() {
        let made = prs([pull(1), pull(2)])

        LiveFolders.shared.apply(.items([pull(1, label: "Merged"), pull(2)], nil), to: made.id)

        #expect(LiveFolders.shared.turning(pull(1).key))
        #expect(!LiveFolders.shared.turning(pull(2).key))
    }

    @Test func aRowThatArrivesAlreadyMergedIsNotTurned() {
        let made = prs([pull(2)])

        LiveFolders.shared.apply(.items([pull(1, label: "Merged"), pull(2)], nil), to: made.id)

        #expect(!LiveFolders.shared.turning(pull(1).key))
        #expect(item(made, 1)?.label == "Merged")
    }

    @Test func aReadDuringTheHoldKeepsTheRowAndItsMergedState() throws {
        let made = prs([pull(1), pull(2)])
        browser.livePullState(try #require(tab(made, 1)), at: URL(string: pull(1).key)!, said: .merged)

        LiveFolders.shared.apply(.items([pull(2)], nil), to: made.id)
        LiveFolders.shared.apply(.items([pull(1), pull(2)], nil), to: made.id)

        #expect(item(made, 1)?.label == "Merged")
        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.key) == [pull(1).key, pull(2).key])
    }

    @Test func anotherPageOnGitHubTurnsNothing() throws {
        let made = prs([pull(1)])

        browser.livePullState(try #require(tab(made, 1)), at: URL(string: "https://github.com/acme/rocket/pulls")!, said: .merged)

        #expect(item(made, 1)?.label == "Approved")
        #expect(PullPageRelay.pull(URL(string: "https://github.com/acme/rocket/pull/1/checks")!))
        #expect(!PullPageRelay.pull(URL(string: "https://github.com/acme/rocket/issues/1")!))
        #expect(!PullPageRelay.pull(URL(string: "https://example.com/acme/rocket/pull/1")!))
    }

    @Test func aRowInAnotherSpaceIsNotTurned() {
        let made = prs([pull(1)])

        LiveFolders.shared.pageMerged(URL(string: pull(1).key)!, space: UUID())

        #expect(item(made, 1)?.label == "Approved")
    }

    @Test func theMergedBadgeIsTheDoneCheckInGitHubsPurple() throws {
        let made = prs([pull(1, checks: nil)])
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: 600), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        browser.unfoldFolder(made.id)
        let column = SideColumnView(browser: browser)
        window.contentView = column
        defer {
            window.contentView = nil
            window.close()
        }

        LiveFolders.shared.pageMerged(URL(string: pull(1).key)!, space: browser.spaceID)
        browser.syncLive()
        column.layoutSubtreeIfNeeded()

        let row = try #require(column.kitSubviews(of: TabRowView.self).first { $0.accessibilityLabel() == "PR 1" && $0.window != nil })
        let badge = try #require(row.kitSubviews(of: ChecksMarkView.self).first)
        #expect(!badge.isHidden)
        #expect(badge.merged)
        #expect(badge.checks == .passing)
        #expect(badge.accessibilityLabel() == "Merged")
        #expect(ChecksTint.primer(.failing, dark: false, merged: true) == "8250DF")
        #expect(ChecksTint.primer(.failing, dark: true, merged: true) == "A371F7")
    }

    @Test func theWashPlaysOnceInTheRowWhenItTurnsMergedOnScreen() throws {
        let made = prs([pull(1), pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }
        let shownRow = try #require(row(1, in: column))

        merge(1, column: column)
        LiveFolders.shared.pageMerged(URL(string: pull(1).key)!, space: browser.spaceID)
        browser.syncLive()
        column.layoutSubtreeIfNeeded()

        #expect(shownRow.plays == 1)
        #expect(shownRow.mergedForm == .full)
        #expect(shownRow.mergedLayers == 2)
        #expect(shownRow.kitSubviews(of: ChecksMarkView.self).first?.isHidden == false)
        #expect(shownRow.kitSubviews(of: ChecksMarkView.self).first?.merged == true)
        #expect(try #require(row(2, in: column)).plays == 0)
    }

    @Test func nothingPlaysUnderReduceMotionButTheGroundTheCheckAndTheWordChange() throws {
        keepSettings("motion.testReduced")
        Store.settings.set(true, forKey: "motion.testReduced")
        let made = prs([pull(1)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }

        merge(1, column: column)

        let shownRow = try #require(row(1, in: column))
        #expect(shownRow.plays == 0)
        #expect(shownRow.mergedForm == .still)
        #expect(shownRow.mergedMoving == 0)
        #expect(shownRow.mergedLayers == 2)
        #expect(shownRow.kitSubviews(of: ChecksMarkView.self).first?.merged == true)
        #expect(item(made, 1)?.label == "Merged")
    }

    @Test func nothingPlaysWhileTheWindowIsOffScreen() throws {
        let made = prs([pull(1)])
        let (column, window) = shown(made, onScreen: false)
        defer {
            window.contentView = nil
            window.close()
        }

        merge(1, column: column)

        #expect(try #require(row(1, in: column)).plays == 0)
        #expect(try #require(row(1, in: column)).mergedForm == .still)
        #expect(tab(made, 1)?.leads == false)
    }

    @Test func theRowLeavesAfterTheHoldAndDoesNotComeBackOnTheNextRead() async throws {
        LiveFolders.shared.mergedHold = 0.05
        let made = prs([pull(1), pull(2)])
        browser.select(try #require(tab(made, 2)))

        LiveFolders.shared.pageMerged(URL(string: pull(1).key)!, space: browser.spaceID)
        browser.syncLive()
        let held = tab(made, 1)?.liveItem?.label
        try await Task.sleep(for: .milliseconds(400))
        browser.syncLive()
        LiveFolders.shared.apply(.items([pull(1), pull(2)], nil), to: made.id)
        browser.syncLive()

        #expect(held == "Merged")
        #expect(tab(made, 1) == nil)
        #expect(!browser.tabs.contains { $0.address?.absoluteString == pull(1).key })
        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.key) == [pull(2).key])
        #expect(LiveFolders.shared.folder(made.id)?.hidden == ["github:acme/rocket#1"])
        #expect(!LiveFolders.shared.turning(pull(1).key))
    }

    @Test func theTabInFrontStaysOpenAsALooseTabBelowTheFolders() async throws {
        LiveFolders.shared.mergedHold = 0.05
        let made = prs([pull(1), pull(2)])
        let loose = browser.open(URL(string: "https://example.com/")!, foreground: false)
        let page = try #require(tab(made, 1))
        browser.select(page)

        browser.livePullState(page, at: URL(string: pull(1).key)!, said: .merged)
        browser.syncLive()
        try await Task.sleep(for: .milliseconds(400))
        browser.syncLive()

        #expect(browser.tabs.contains { $0.id == page.id })
        #expect(page.groupID == nil)
        #expect(page.liveKey == nil)
        #expect(page.liveItem == nil)
        #expect(browser.activeID == page.id)
        let unfiled = browser.tabs.filter { $0.pin == nil && $0.groupID == nil }
        #expect(unfiled.first?.id == page.id)
        #expect(unfiled.contains { $0.id == loose.id })
        #expect(browser.tabs(in: made.id).compactMap(\.liveKey) == [pull(2).key])
    }

    @Test func aPullRequestClosedWithoutMergingKeepsTodaysBehaviour() {
        let made = prs([pull(1), pull(2)])

        LiveFolders.shared.apply(.items([pull(1, label: "Closed"), pull(2)], nil), to: made.id)
        browser.syncLive()

        #expect(!LiveFolders.shared.turning(pull(1).key))
        #expect(item(made, 1)?.label == "Closed")
        #expect(tab(made, 1) != nil)
    }

    @Test func theBenchMarksALiveRowMergedFromAProbe() async throws {
        let made = prs([pull(1), pull(2)])
        let page = try #require(tab(made, 1))

        let answer = await withCheckedContinuation { (done: CheckedContinuation<[String: Any], Never>) in
            TabsBench.run("live", ["args": ["merged", Bench.short(page)]], browser: browser) { done.resume(returning: $0) }
        }
        let refused = await withCheckedContinuation { (done: CheckedContinuation<[String: Any], Never>) in
            TabsBench.run("live", ["args": ["merged", "https://example.com/"]], browser: browser) { done.resume(returning: $0) }
        }

        let folders = try #require(answer["folders"] as? [[String: Any]])
        let items = try #require(folders.first?["items"] as? [[String: Any]])
        #expect(items.first?["label"] as? String == "Merged")
        #expect(items.first?["merging"] as? Bool == true)
        #expect(page.liveItem?.label == "Merged")
        #expect(refused["error"] != nil)
    }

    private func header(_ status: String, _ word: String) -> String {
        "<div data-component=\"PageHeader.Description\"><span data-component=\"StateLabel\" data-status=\"\(status)\"><svg></svg>\(word)</span></div>"
    }

    private func told(_ body: String, number: Int = 1, then change: String? = nil) async throws -> Int {
        let page = browser.open(try #require(URL(string: "about:blank")), foreground: true)
        var count = 0
        page.onPullState = { _, _, state in if state == .merged { count += 1 } }
        let html = "<html><head><title>Fix it · Pull Request #\(number) · acme/rocket · GitHub</title></head><body>\(body)</body></html>"
        page.web.loadHTMLString(html, baseURL: URL(string: "https://github.com/acme/rocket/pull/1"))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !page.web.isLoading, (try? await page.web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let change {
            try await Task.sleep(for: .milliseconds(1_400))
            _ = try? await page.web.evaluateJavaScript(change)
        }
        try await Task.sleep(for: .milliseconds(1_800))
        _ = try? await page.web.evaluateJavaScript("document.body.appendChild(document.createElement('p'))")
        try await Task.sleep(for: .milliseconds(1_400))
        return count
    }

    @Test func theOpenPageTellsOnceWhenItsHeaderSaysMerged() async throws {
        let count = try await told(header("pullMerged", "Merged"))

        #expect(count == 1)
    }

    @Test func mergedLabelsOutsideTheHeaderOrInAHovercardTellNothing() async throws {
        let hovercard = "<div class=\"Popover\">\(header("pullMerged", "Merged"))</div>"
        let linked = "<a href=\"/acme/rocket/pull/7\">Other</a><span class=\"State State--merged State--small\">Merged</span>"

        let count = try await told(hovercard + header("pullOpened", "Open") + linked)

        #expect(count == 0)
    }

    @Test func theOlderHeaderStateIsReadToo() async throws {
        let count = try await told("<div class=\"gh-header-meta\"><span class=\"State State--merged\">Merged</span></div>")

        #expect(count == 1)
    }

    @Test func mergingOnThePageIsSeenWithoutAReload() async throws {
        let merge = "var l = document.querySelector('[data-component=StateLabel]'); l.setAttribute('data-status', 'pullMerged'); l.textContent = 'Merged';"

        let count = try await told(header("pullOpened", "Open"), then: merge)

        #expect(count == 1)
    }

    @Test func aHeaderLeftOverFromAnotherPullRequestTellsNothing() async throws {
        let count = try await told(header("pullMerged", "Merged"), number: 2)

        #expect(count == 0)
    }

    @Test func theHoldOfAnEarlierTurnDoesNotEndALaterOne() async throws {
        LiveFolders.shared.mergedHold = 0.3
        let first = prs([pull(1)])
        LiveFolders.shared.pageMerged(URL(string: pull(1).key)!, space: browser.spaceID)
        try await Task.sleep(for: .milliseconds(150))
        LiveFolders.shared.remove(first.id)
        let made = prs([pull(1)])

        LiveFolders.shared.pageMerged(URL(string: pull(1).key)!, space: browser.spaceID)
        try await Task.sleep(for: .milliseconds(220))
        let midway = (LiveFolders.shared.turning(pull(1).key), item(made, 1)?.label)
        try await Task.sleep(for: .milliseconds(400))

        #expect(midway.0)
        #expect(midway.1 == "Merged")
        #expect(item(made, 1) == nil)
    }

    @Test func aRowHeldInOneFolderLeavesEveryFolderItTurnedIn() async throws {
        LiveFolders.shared.mergedHold = 0.2
        let one = prs([pull(1), pull(2)])
        let two = prs([pull(1)])
        LiveFolders.shared.apply(.items([pull(1, label: "Merged"), pull(2)], nil), to: one.id)

        LiveFolders.shared.pageMerged(URL(string: pull(1).key)!, space: browser.spaceID)
        let marked = item(two, 1)?.label
        try await Task.sleep(for: .milliseconds(500))

        #expect(marked == "Merged")
        #expect(item(one, 1) == nil)
        #expect(item(two, 1) == nil)
    }

    @Test func aRowFoundMergedByAReadPlaysTheWashToo() throws {
        let made = prs([pull(1), pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }
        let shownRow = try #require(row(1, in: column))

        LiveFolders.shared.apply(.items([pull(1, label: "Merged"), pull(2)], nil), to: made.id)
        browser.syncLive()
        column.layoutSubtreeIfNeeded()

        #expect(shownRow.plays == 1)
        #expect(shownRow.mergedForm == .full)
    }
}
