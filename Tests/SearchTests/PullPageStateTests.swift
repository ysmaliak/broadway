import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PullPageStateTests {
    private var browser: Browser!
    private let reader = LiveFolders.shared.reader
    private var reads = 0

    init() async throws {
        _ = NSApplication.shared
        keepSetting(Shared.prefs, \.liveFolders, "live.on")
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesTabGroups = true
        browser.prefs.liveFolders = true
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        LiveFolders.shared.reader = { [weak self] folder in
            self?.reads += 1
            return .items(folder.items, nil)
        }
    }

    private func tearDown() async {
        LiveFolders.shared.reader = reader
        LiveFolders.shared.mergedHold = LiveFolders.hold
        LiveFolders.shared.saidHold = LiveFolders.pageHold
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    private func pull(_ number: Int, label: String? = nil, draft: Bool = false, checks: LiveChecks? = nil,
                      stack: LiveStack? = nil) -> LiveItem {
        LiveItem(key: "https://github.com/acme/rocket/pull/\(number)", title: "PR \(number)", label: label, author: "dana",
                 checks: checks, stack: stack, draft: draft ? true : nil)
    }

    private func url(_ number: Int) -> URL { URL(string: pull(number).key)! }

    private func folder(_ items: [LiveItem], source: LiveSource = .pullRequests, read: Date = Date().addingTimeInterval(-600)) -> LiveFolder {
        let made = LiveFolders.shared.add(name: "PRs", source: source, space: browser.spaceID)
        LiveFolders.shared.apply(.items(items, nil), to: made.id, now: read)
        browser.syncLive()
        return made
    }

    private func item(_ made: LiveFolder, _ number: Int) -> LiveItem? {
        LiveFolders.shared.folder(made.id)?.items.first { $0.key == pull(number).key }
    }

    private func tab(_ made: LiveFolder, _ number: Int) -> Tab? {
        browser.tabs(in: made.id).first { $0.liveKey == pull(number).key }
    }

    private func settle() async throws {
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(20))
            if LiveFolders.shared.reading.isEmpty { break }
        }
    }

    @Test func aDraftRowBecomesReadyWhenItsPageSaysOpen() async throws {
        let made = folder([pull(1, label: "Draft", draft: true), pull(2, label: "Draft", draft: true)])
        let page = try #require(tab(made, 1))

        browser.livePullState(page, at: URL(string: "https://github.com/acme/rocket/pull/1/files")!, said: .open)
        browser.syncLive()
        try await settle()

        #expect(item(made, 1)?.draft == nil)
        #expect(item(made, 1)?.label == nil)
        #expect(item(made, 1)?.byline == "dana")
        #expect(page.liveItem?.draft == nil)
        #expect(item(made, 2)?.draft == true)
        #expect(item(made, 2)?.label == "Draft")
    }

    @Test func anOpenRowBecomesADraftWhenItsPageSaysDraft() async throws {
        let made = folder([pull(1, checks: .passing)])

        LiveFolders.shared.pageSays(.draft, at: url(1), space: browser.spaceID)
        browser.syncLive()
        try await settle()

        #expect(item(made, 1)?.draft == true)
        #expect(item(made, 1)?.label == "Draft")
        #expect(item(made, 1)?.checks == .passing)
        #expect(tab(made, 1)?.liveItem?.byline == "dana • Draft")
    }

    @Test func aRowTurnsClosedWhenItsPageSaysClosed() async throws {
        let made = folder([pull(1, label: "Approved")])

        LiveFolders.shared.pageSays(.closed, at: url(1), space: browser.spaceID)
        try await settle()

        #expect(item(made, 1)?.label == "Closed")
        #expect(item(made, 1)?.draft == nil)
        #expect(!LiveFolders.shared.turning(pull(1).key))
    }

    @Test func aDraftMadeReadyKeepsTheReviewStateItAlreadyHad() async throws {
        let made = folder([pull(1, label: "Changes requested", draft: true, checks: .failing)])

        LiveFolders.shared.pageSays(.open, at: url(1), space: browser.spaceID)
        try await settle()

        #expect(item(made, 1)?.draft == nil)
        #expect(item(made, 1)?.label == "Changes requested")
        #expect(item(made, 1)?.checks == .failing)
    }

    @Test func aReadWithinTheHoldDoesNotPutDraftBackAndALaterOneCan() async throws {
        LiveFolders.shared.saidHold = 1.6
        let made = folder([pull(1, label: "Draft", draft: true)])
        let said = Date()
        LiveFolders.shared.pageSays(.open, at: url(1), space: browser.spaceID, now: said)
        try await settle()

        LiveFolders.shared.apply(.items([pull(1, label: "Draft", draft: true)], nil), to: made.id, now: said.addingTimeInterval(1))
        let within = item(made, 1)
        LiveFolders.shared.apply(.items([pull(1, label: "Draft", draft: true)], nil), to: made.id, now: said.addingTimeInterval(2))

        #expect(within?.draft == nil)
        #expect(within?.label == nil)
        #expect(item(made, 1)?.draft == true)
        #expect(item(made, 1)?.label == "Draft")
    }

    @Test func aReadWithinTheHoldStillBringsItsReviewAndChecks() async throws {
        let made = folder([pull(1, label: "Draft", draft: true)])
        let said = Date()
        LiveFolders.shared.pageSays(.open, at: url(1), space: browser.spaceID, now: said)
        try await settle()

        LiveFolders.shared.apply(.items([pull(1, label: "Approved", checks: .passing)], nil), to: made.id, now: said.addingTimeInterval(0.5))

        #expect(item(made, 1)?.label == "Approved")
        #expect(item(made, 1)?.checks == .passing)
    }

    @Test func aPageOfAnotherPullRequestChangesNothing() async throws {
        let made = folder([pull(1, label: "Draft", draft: true)])
        let page = try #require(tab(made, 1))

        browser.livePullState(page, at: url(2), said: .open)
        browser.livePullState(page, at: URL(string: "https://github.com/acme/rocket/pulls")!, said: .open)
        LiveFolders.shared.pageSays(.open, at: url(1), space: UUID())
        try await settle()

        #expect(item(made, 1)?.draft == true)
        #expect(item(made, 1)?.label == "Draft")
        #expect(reads == 0)
    }

    @Test func aPageThatAgreesWithTheRowAsksForNothing() async throws {
        let made = folder([pull(1, label: "Approved")])

        LiveFolders.shared.pageSays(.open, at: url(1), space: browser.spaceID)
        try await settle()

        #expect(item(made, 1)?.label == "Approved")
        #expect(reads == 0)
    }

    @Test func aStateThatDiffersAsksTheFolderForOneEarlyRead() async throws {
        let made = folder([pull(1, label: "Draft", draft: true)])
        let other = folder([pull(3)], source: .issues)

        LiveFolders.shared.pageSays(.open, at: url(1), space: browser.spaceID)
        LiveFolders.shared.pageSays(.open, at: url(1), space: browser.spaceID)
        LiveFolders.shared.pageSays(.draft, at: url(1), space: browser.spaceID)
        LiveFolders.shared.pageSays(.open, at: URL(string: "https://github.com/acme/rocket/pull/1/files")!, space: browser.spaceID)
        try await settle()
        try await Task.sleep(for: .milliseconds(300))

        #expect(reads == 1)
        #expect(item(made, 1)?.draft == nil)
        #expect(LiveFolders.shared.folder(made.id)?.read.map { Date().timeIntervalSince($0) < 60 } == true)
        #expect(LiveFolders.shared.folder(other.id)?.read.map { Date().timeIntervalSince($0) > 60 } == true)
    }

    @Test func anEarlyReadRightAfterALateReadWaitsForTheGap() async throws {
        let made = folder([pull(1, label: "Draft", draft: true)], read: Date())

        LiveFolders.shared.pageSays(.open, at: url(1), space: browser.spaceID)
        try await settle()

        #expect(reads == 0)
        #expect(item(made, 1)?.draft == nil)
    }

    @Test func aNotificationsRowKeepsItsReasonButStillTurnsMerged() async throws {
        let made = folder([pull(1, label: "Review")], source: .gitHubNotifications)

        LiveFolders.shared.pageSays(.closed, at: url(1), space: browser.spaceID)
        let closed = item(made, 1)?.label
        LiveFolders.shared.pageSays(.merged, at: url(1), space: browser.spaceID)

        #expect(closed == "Review")
        #expect(item(made, 1)?.label == "Merged")
        #expect(LiveFolders.shared.turning(pull(1).key))
    }

    @Test func mergedFromThePageStillCelebratesAndLeaves() async throws {
        LiveFolders.shared.mergedHold = 0.05
        let made = folder([pull(1, label: "Draft", draft: true), pull(2)])
        browser.select(try #require(tab(made, 2)))

        browser.livePullState(try #require(tab(made, 1)), at: url(1), said: .merged)
        browser.syncLive()
        let held = (item(made, 1)?.label, item(made, 1)?.draft, LiveFolders.shared.turning(pull(1).key))
        try await Task.sleep(for: .milliseconds(400))
        browser.syncLive()

        #expect(held.0 == "Merged")
        #expect(held.1 == nil)
        #expect(held.2)
        #expect(item(made, 1) == nil)
        #expect(reads == 0)
    }

    @Test func aRowTurningMergedIsNotTurnedBackByTheOpenItsPageSaidBefore() async throws {
        let made = folder([pull(1, label: "Draft", draft: true)])
        LiveFolders.shared.pageSays(.merged, at: url(1), space: browser.spaceID)

        LiveFolders.shared.pageSays(.open, at: url(1), space: browser.spaceID)
        try await settle()

        #expect(item(made, 1)?.label == "Merged")
    }

    @Test func theBylineTheBadgeAndTheStackChipShowTheNewState() throws {
        let made = folder([pull(1, label: "Draft", draft: true, stack: LiveStack(position: 1, count: 2))])
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
        column.layoutSubtreeIfNeeded()
        let row = try #require(column.kitSubviews(of: TabRowView.self).first { $0.accessibilityLabel() == "PR 1" && $0.window != nil })
        let before = (row.kitSubviews(of: BylineView.self).first?.accessibilityLabel(), row.kitSubviews(of: RowMarkView.self).first?.draft)

        LiveFolders.shared.pageSays(.open, at: url(1), space: browser.spaceID)
        browser.syncLive()
        column.needsLayout = true
        column.layoutSubtreeIfNeeded()

        #expect(before.0 == "dana, stack 1 of 2, Draft")
        #expect(before.1 == true)
        #expect(row.kitSubviews(of: BylineView.self).first?.accessibilityLabel() == "dana, stack 1 of 2")
        #expect(row.kitSubviews(of: RowMarkView.self).first?.draft == false)
    }

    private func header(_ status: String, _ word: String) -> String {
        "<div data-component=\"PageHeader.Description\"><span data-component=\"StateLabel\" data-status=\"\(status)\"><svg></svg>\(word)</span></div>"
    }

    private func page(_ body: String, number: Int = 1) async throws -> (Tab, () -> [PullPageState]) {
        let page = browser.open(try #require(URL(string: "about:blank")), foreground: true)
        var said: [PullPageState] = []
        page.onPullState = { _, _, state in said.append(state) }
        let html = "<html><head><title>Fix it · Pull Request #\(number) · acme/rocket · GitHub</title></head><body>\(body)</body></html>"
        page.web.loadHTMLString(html, baseURL: URL(string: "https://github.com/acme/rocket/pull/1"))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !page.web.isLoading, (try? await page.web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(1_400))
        return (page, { said })
    }

    private func run(_ page: Tab, _ js: String) async throws {
        _ = try? await page.web.evaluateJavaScript(js)
        try await Task.sleep(for: .milliseconds(1_400))
    }

    @Test func thePageSaysEachStateItsHeaderShows() async throws {
        let open = try await page(header("pullOpened", "Open")).1()
        let draft = try await page(header("draftish", "Draft")).1()
        let closed = try await page("<div class=\"gh-header-meta\"><span class=\"State State--closed\">Closed</span></div>").1()
        let merged = try await page(header("pullMerged", "Merged")).1()

        #expect(open == [.open])
        #expect(draft == [.draft])
        #expect(closed == [.closed])
        #expect(merged == [.merged])
    }

    @Test func aChangeOnThePageIsSaidOnceItSettles() async throws {
        let (shown, said) = try await page(header("pullOpened", "Open"))

        try await run(shown, "var l = document.querySelector('[data-component=StateLabel]'); l.setAttribute('data-status', 'whatever'); l.textContent = 'Draft';")
        try await run(shown, "document.body.appendChild(document.createElement('p'))")

        #expect(said() == [.open, .draft])
    }

    @Test func aLabelInAPopoverIsIgnored() async throws {
        let said = try await page("<div class=\"Popover\">\(header("draft", "Draft"))</div>" + header("pullOpened", "Open")).1()

        #expect(said == [.open])
    }

    @Test func aHeaderLeftFromAnotherPullRequestSaysNothing() async throws {
        let said = try await page(header("pullOpened", "Open"), number: 2).1()

        #expect(said.isEmpty)
    }

    @Test func aSoftNavigationInsideThePullRequestSaysItAgain() async throws {
        let (shown, said) = try await page(header("pullOpened", "Open"))

        try await run(shown, "history.pushState({}, '', '/acme/rocket/pull/1/files'); document.body.appendChild(document.createElement('p'))")
        try await run(shown, "history.pushState({}, '', '/acme/rocket/pull/1'); document.body.appendChild(document.createElement('p'))")

        #expect(said() == [.open, .open, .open])
    }

    @Test func comingBackToTheTabAsksThePageAgain() async throws {
        let (shown, said) = try await page(header("pullOpened", "Open"))
        let other = browser.open(URL(string: "about:blank")!, foreground: true)

        browser.select(shown)
        try await Task.sleep(for: .milliseconds(1_400))
        browser.select(other)
        try await Task.sleep(for: .milliseconds(1_400))

        #expect(said() == [.open, .open])
    }
}
