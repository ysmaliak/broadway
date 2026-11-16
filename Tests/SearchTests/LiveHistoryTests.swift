import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LiveHistoryTests {
    private let personal = UUID()
    private let work = UUID()

    private func folder() throws -> URL {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("live-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: made) }
        return made
    }

    private func history(in folder: URL) -> History {
        History(file: folder.appendingPathComponent("history.json"), pages: folder.appendingPathComponent("pagetext.sqlite"))
    }

    private func visit(_ history: History, _ address: String, times: Int = 1, in space: UUID?) {
        for _ in 0..<times { history.record(URL(string: address)!, title: "Page", space: space) }
    }

    private func suggestions(_ history: History, in space: UUID) -> [LiveSuggestion] {
        LiveSuggestions.from(history.everything(in: space), folders: [])
    }

    private func world() -> (browser: Browser, shell: SettingsShell, page: SettingsPageView, work: Space) {
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let prefs = browser.prefs
        let previous = (prefs.usesSpaces, prefs.liveFolders)
        prefs.usesSpaces = true
        let live = LiveFolders.shared
        for folder in live.folders { live.remove(folder.id) }
        browser.history.forget()
        addTeardownBlock {
            for folder in live.folders { live.remove(folder.id) }
            browser.history.forget()
            (prefs.usesSpaces, prefs.liveFolders) = previous
            browser.closeAll()
        }
        let work = Space(id: UUID(), name: "Work", colour: 1, icon: TabIcon(symbol: "briefcase"))
        browser.spaces.append(work)
        let shell = SettingsShell()
        shell.go(to: .liveFolders)
        return (browser, shell, SettingsPageView(browser: browser, shell: shell), work)
    }

    private func suggested(on page: SettingsPageView) -> [String] {
        page.kitSubviews(of: SettingsRowView.self).map(\.rowID).filter { $0.hasPrefix("live.suggest.") }
    }

    private func words(on page: SettingsPageView) -> [String] {
        page.kitSubviews(of: NSTextField.self).map(\.stringValue)
            + page.kitSubviews(of: SettingsFooter.self).compactMap { $0.accessibilityLabel() }
    }

    @Test func twoSpacesWithDifferentHistoriesGiveDifferentSuggestions() throws {
        let history = history(in: try folder())
        visit(history, "https://github.com/acme/web/pull/12", times: 3, in: work)
        visit(history, "https://github.com/acme/api/pulls", times: 2, in: work)
        visit(history, "https://linear.app/acme/issue/ACM-12", times: 2, in: work)
        visit(history, "https://www.youtube.com/@numberphile", times: 4, in: personal)
        visit(history, "https://github.com/mine/dotfiles", in: personal)

        let mine = suggestions(history, in: personal)
        let theirs = suggestions(history, in: work)

        #expect(mine.map(\.title) == ["YouTube Subscriptions", "GitHub Pull Requests"])
        #expect(mine.map(\.line) == ["4 visits · @numberphile", "1 visit · mine/dotfiles"])
        #expect(theirs.map(\.title) == ["GitHub Pull Requests", "Linear My Issues"])
        #expect(theirs.map(\.line) == ["5 visits · acme/web · acme/api", "2 visits · acme"])
    }

    @Test func aVisitInOneSpaceDoesNotCountInAnother() throws {
        let history = history(in: try folder())
        let page = "https://github.com/acme/web/pulls"

        visit(history, page, times: 3, in: work)
        visit(history, page, in: personal)

        #expect(LiveSuggestions.visits("github", in: history.everything(in: work)) == 3)
        #expect(LiveSuggestions.visits("github", in: history.everything(in: personal)) == 1)
        #expect(LiveSuggestions.visits("github", in: history.everything(in: UUID())) == 0)
        #expect(history.everything().map(\.count) == [4])
    }

    @Test func aSiteLastOpenedLongAgoInThisSpaceIsNotSuggestedBecauseAnotherSpaceOpenedItToday() throws {
        let folder = try folder()
        let old = Date().addingTimeInterval(-40 * 86_400).timeIntervalSinceReferenceDate
        let fresh = Date().addingTimeInterval(-3_600).timeIntervalSinceReferenceDate
        let saved = """
        [{"url":"https://github.com/acme/web/pulls","key":"https://github.com/acme/web/pulls","title":"Pull requests","count":9,"last":\(fresh),
          "spaces":{"\(personal.uuidString)":{"count":6,"last":\(old)},"\(work.uuidString)":{"count":3,"last":\(fresh)}}}]
        """
        try Data(saved.utf8).write(to: folder.appendingPathComponent("history.json"))

        let history = history(in: folder)

        #expect(suggestions(history, in: personal).isEmpty)
        #expect(suggestions(history, in: work).map(\.line) == ["3 visits · acme/web"])
    }

    @Test func oldVisitsKeptWithoutASpaceCountForNoSpace() throws {
        let folder = try folder()
        let yesterday = Date().addingTimeInterval(-86_400).timeIntervalSinceReferenceDate
        let saved = """
        [{"url":"https://github.com/acme/web/pulls","key":"https://github.com/acme/web/pulls","title":"Pull requests","count":82,"last":\(yesterday)},
         {"url":"https://www.youtube.com/@numberphile","key":"https://www.youtube.com/@numberphile","title":"Numberphile","count":19,"last":\(yesterday),"from":"https://youtube.com/@numberphile"}]
        """
        try Data(saved.utf8).write(to: folder.appendingPathComponent("history.json"))

        let history = history(in: folder)
        let everywhere = LiveSuggestions.from(history.everything(), folders: [])
        let before = suggestions(history, in: personal)
        visit(history, "https://github.com/acme/web/pulls", in: personal)
        let after = suggestions(history, in: personal)

        #expect(everywhere.map(\.line) == ["82 visits · acme/web", "19 visits · @numberphile"])
        #expect(before.isEmpty)
        #expect(suggestions(history, in: work).isEmpty)
        #expect(after.map(\.line) == ["1 visit · acme/web"])
        #expect(history.trace("https://github.com/acme/web/pulls")?.count == 83)
    }

    @Test func theSpaceOfAVisitIsKeptInTheFileAndReadBack() async throws {
        let folder = try folder()
        let file = folder.appendingPathComponent("history.json")
        let first = history(in: folder)
        visit(first, "https://linear.app/acme/issue/ACM-12", times: 2, in: work)

        for _ in 0..<200 where (try? String(contentsOf: file, encoding: .utf8))?.contains(work.uuidString) != true {
            try await Task.sleep(for: .milliseconds(25))
        }
        let again = history(in: folder)

        #expect(suggestions(again, in: work).map(\.line) == ["2 visits · acme"])
        #expect(suggestions(again, in: personal).isEmpty)
        #expect(again.trace("https://linear.app/acme/issue/ACM-12")?.count == 2)
    }

    @Test func aDeletedSpaceTakesItsCountWithItAndTheVisitStaysInHistory() throws {
        let history = history(in: try folder())
        visit(history, "https://github.com/acme/web/pulls", times: 3, in: work)
        visit(history, "https://github.com/acme/web/pulls", in: personal)

        history.forget(space: work)

        #expect(suggestions(history, in: work).isEmpty)
        #expect(suggestions(history, in: personal).map(\.line) == ["1 visit · acme/web"])
        #expect(history.everything().map(\.count) == [4])
    }

    @Test func switchingThePopUpChangesTheListAndTheFooterNamesTheSpace() throws {
        let (browser, shell, page, work) = world()
        let home = try #require(browser.spaces.first { $0.id == browser.spaceID })
        visit(browser.history, "https://www.youtube.com/@numberphile", times: 4, in: home.id)
        visit(browser.history, "https://github.com/acme/web/pull/12", times: 3, in: work.id)
        visit(browser.history, "https://linear.app/acme/issue/ACM-12", times: 2, in: work.id)
        page.rebuild()
        let before = (suggested(on: page), words(on: page))

        let pop = try #require(page.kitSubviews(of: NSPopUpButton.self).first { $0.accessibilityIdentifier() == "settings.space" })
        pop.selectItem(at: try #require(browser.spaces.firstIndex { $0.id == work.id }))
        _ = pop.sendAction(pop.action, to: pop.target)
        page.refresh()
        let after = (suggested(on: page), words(on: page))

        #expect(shell.space == work.id)
        #expect(before.0 == ["live.suggest.youtube"])
        #expect(before.1.contains("4 visits · @numberphile"))
        #expect(before.1.contains(LiveFolderRows.opened(in: home, offered: true)))
        #expect(after.0 == ["live.suggest.github", "live.suggest.linear"])
        #expect(after.1.contains("3 visits · acme/web"))
        #expect(after.1.contains("2 visits · acme"))
        #expect(!after.1.contains("4 visits · @numberphile"))
        #expect(after.1.contains("The sites you opened most in Work in the last 30 days come first, counted on this Mac. A folder reads its site with your sign-in in the space it is in."))
    }

    @Test func aSpaceWithNoVisitsSaysSoByName() throws {
        let (browser, _, page, work) = world()
        visit(browser.history, "https://github.com/acme/web/pull/12", times: 3, in: work.id)

        page.rebuild()
        let shown = (suggested(on: page), words(on: page))

        #expect(shown.0.isEmpty)
        #expect(!shown.1.contains(LiveFolderRows.allAdded(in: browser.spaces.first, offered: true)))
        #expect(shown.1.contains("GitHub Pull Requests"))
        #expect(LiveFolderRows.allAdded(in: work, offered: true) == "Everything is added in Work")
        #expect(LiveFolderRows.allAdded(in: work, offered: false) == "Everything is added")
        #expect(LiveFolderRows.opened(in: work, offered: false) == "The sites you opened most in the last 30 days come first, counted on this Mac. A folder reads its site with your sign-in.")
    }

    @Test func aPageCountsForTheSpaceItsTabIsInAndAPrivateWindowCountsNowhere() async throws {
        let server = try LocalPageServer([
            "/here": .init(type: "text/html", body: "<!doctype html><title>Here</title><p>here"),
            "/there": .init(type: "text/html", body: "<!doctype html><title>There</title><p>there"),
            "/hidden": .init(type: "text/html", body: "<!doctype html><title>Hidden</title><p>hidden"),
        ])
        defer { server.stop() }
        let (browser, _, _, work) = world()
        let quiet = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { quiet.closeAll() }
        let history = browser.history
        let keys = ["/here", "/there", "/hidden"].map { History.identity(for: server.url($0)) }

        browser.open(server.url("/here"), foreground: true)
        let parked = browser.makeTab(space: work.id)
        browser.prepare(parked)
        var row = browser.parked[work.id] ?? browser.loadRow(work.id)
        row.tabs.append(parked)
        browser.parked[work.id] = row
        parked.go(to: server.url("/there"))
        quiet.arrive(server.url("/hidden"))
        let hidden = try #require(quiet.active)
        for _ in 0..<400 where !history.knows(keys[0]) || !history.knows(keys[1]) || hidden.web.isLoading || hidden.web.url == nil {
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(hidden.shy)
        #expect(quiet.spaceOf(hidden) == nil)
        #expect(history.everything(in: browser.spaceID).map(\.key) == [keys[0]])
        #expect(history.everything(in: work.id).map(\.key) == [keys[1]])
        #expect(!history.knows(keys[2]))
    }
}
