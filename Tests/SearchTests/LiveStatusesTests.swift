import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LiveStatusesTests {
    private var browser: Browser!
    private var read: [LiveSource] = []
    private var answer: [LiveItem] = []

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
            self?.read.append(folder.source)
            return .items(self?.answer ?? [], nil)
        }
    }

    private func tearDown() async {
        LiveFolders.shared.reader = { await LiveReader.read($0) }
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    private func issue(_ key: String, _ name: String, _ type: String?) -> LiveItem {
        LiveItem(key: "https://linear.app/acme/issue/\(key)/a-title", title: key, label: name, author: key, status: type)
    }

    private func body(_ list: LinearAPI.List, leaving: [LinearStatus] = []) -> String {
        String(decoding: LinearAPI.body(for: list, leaving: leaving), as: UTF8.self)
    }

    private func settle(_ id: UUID) async {
        for _ in 0..<200 where LiveFolders.shared.reading.contains(id) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aFolderFromAnOlderVersionLoadsUnchangedAndLeavesOutBacklog() throws {
        let space = UUID()
        let old = """
        [{"id":"\(UUID().uuidString)","space":"\(space.uuidString)","name":"My Issues","paused":false,"state":"fine",
          "source":{"kind":"linear","address":"https://linear.app/acme/my-issues/assigned"},
          "items":[{"key":"https://linear.app/acme/issue/ENG-1/a-title","title":"Old row","label":"Backlog"}],"hidden":[]}]
        """

        let (kept, retired) = try #require(LiveFolders.sorted(Data(old.utf8)))
        let folder = try #require(kept.first)
        let again = String(decoding: try JSONEncoder().encode(kept), as: UTF8.self)

        #expect(retired.isEmpty)
        #expect(folder.source.statuses == nil)
        #expect(folder.items.map(\.title) == ["Old row"])
        #expect(folder.items.first?.status == nil)
        #expect(folder.source.linearStatuses == [.triage, .unstarted, .started])
        #expect(folder.source.leftOut == [.backlog])
        #expect(!again.contains("statuses"))
        #expect(!again.contains("\"status\""))
    }

    @Test func aStatusNameFromALaterVersionDoesNotLoseTheFolder() throws {
        let old = """
        [{"id":"\(UUID().uuidString)","space":"\(UUID().uuidString)","name":"My Issues","paused":false,"state":"fine",
          "source":{"kind":"linear","address":"https://linear.app/my-issues/assigned","statuses":["started","someday"]},
          "items":[],"hidden":[]}]
        """

        let (kept, _) = try #require(LiveFolders.sorted(Data(old.utf8)))

        #expect(kept.first?.source.linearStatuses == [.started])
    }

    @Test func onlyListsOfIssuesChooseTheirStatuses() {
        #expect(LiveSource.linear(.assigned).linearStatuses == LinearStatus.standard)
        #expect(LiveSource.linear(.created).linearStatuses == LinearStatus.standard)
        #expect(LiveSource.linear(.cycle("ENG")).linearStatuses == LinearStatus.standard)
        #expect(LiveSource.linear(.inbox).linearStatuses == nil)
        #expect(LiveSource.linear(.mentions).linearStatuses == nil)
        #expect(LiveSource.pullRequests.linearStatuses == nil)
        #expect(LiveSource.assignedIssues.linearStatuses == nil)
        #expect(LiveSource.linear(.inbox).leftOut.isEmpty)
    }

    @Test func statusesAreNamedPlainly() {
        #expect(LinearStatus.allCases.map(\.title) == ["Triage", "Backlog", "Todo", "In Progress"])
        #expect(LinearStatus.named("todo") == .unstarted)
        #expect(LinearStatus.named("unstarted") == .unstarted)
        #expect(LinearStatus.named("In Progress") == .started)
        #expect(LinearStatus.named("progress") == .started)
        #expect(LinearStatus.named("in-progress") == .started)
        #expect(LinearStatus.named("BACKLOG") == .backlog)
        #expect(LinearStatus.named("done") == nil)
        #expect(LinearStatus.named("canceled") == nil)
        #expect(LinearStatus.words([.backlog]) == "Backlog")
        #expect(LinearStatus.words([.backlog, .triage]) == "Triage and Backlog")
        #expect(LinearStatus.words([.started, .triage, .backlog]) == "Triage, Backlog and In Progress")
    }

    @Test func theRequestLeavesOutWhatTheFolderLeavesOut() {
        #expect(body(.assigned).contains(#"filter: { state: { type: { nin: [\"completed\", \"canceled\"] } } }"#))
        #expect(body(.assigned, leaving: [.backlog]).contains(#"assignedIssues(first: 30, orderBy: updatedAt, filter: { state: { type: { nin: [\"completed\", \"canceled\", \"backlog\"] } } })"#))
        #expect(body(.created, leaving: [.backlog, .triage]).contains(#"createdIssues(first: 30, orderBy: updatedAt, filter: { state: { type: { nin: [\"completed\", \"canceled\", \"triage\", \"backlog\"] } } })"#))
        #expect(body(.cycle("ENG")).contains("activeCycle { issues(first: 50, orderBy: updatedAt) { nodes"))
        #expect(body(.cycle("ENG"), leaving: [.backlog]).contains(#"activeCycle { issues(first: 50, orderBy: updatedAt, filter: { state: { type: { nin: [\"backlog\"] } } }) { nodes"#))
        #expect(!body(.inbox, leaving: [.backlog]).contains("backlog"))
        #expect(body(.inbox, leaving: [.backlog]) == body(.inbox))
    }

    @Test func eachRowKnowsItsStatusType() throws {
        let row: [String: Any] = ["identifier": "A-1", "title": "One", "url": "https://linear.app/acme/issue/A-1",
                                  "updatedAt": "2026-11-03T22:01:10.511Z", "state": ["name": "In Review", "type": "started", "position": 1]]
        let data = try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["id": "me", "assignedIssues": ["nodes": [row]]]]])

        let items = try #require(LinearAPI.items(from: data, list: .assigned))

        #expect(items.map(\.status) == ["started"])
        #expect(items.map(\.label) == ["In Review"])
    }

    @Test func aReadAnswerNeverBringsBackALeftOutRow() {
        let made = LiveFolders.shared.add(name: "My Issues", source: .linear(.assigned), space: browser.spaceID)

        LiveFolders.shared.apply(.items([issue("A-1", "Backlog", "backlog"), issue("A-2", "Todo", "unstarted"),
                                         issue("A-3", "Done", "completed")], nil), to: made.id)

        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.title) == ["A-2", "A-3"])
    }

    @Test func aCycleKeepsItsDoneRowsAndLeavesOutBacklog() {
        let made = LiveFolders.shared.add(name: "ENG Cycle", source: .linear(.cycle("ENG")), space: browser.spaceID)

        LiveFolders.shared.apply(.items([issue("E-1", "Backlog", "backlog"), issue("E-2", "Done", "completed"),
                                         issue("E-3", "Canceled", "canceled"), issue("E-4", "Triage", "triage")], nil), to: made.id)

        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.title) == ["E-2", "E-3", "E-4"])
    }

    @Test func theInboxShowsEveryStatus() {
        let made = LiveFolders.shared.add(name: "Inbox", source: .linear(.inbox), space: browser.spaceID)

        LiveFolders.shared.apply(.items([issue("A-1", "Mention", "backlog"), issue("A-2", "Assigned", "triage")], nil), to: made.id)

        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.title) == ["A-1", "A-2"])
    }

    @Test func anOldBacklogRowGoesAtTheFirstReadAfterTheUpdate() async {
        let made = LiveFolders.shared.add(name: "My Issues", source: .linear(.assigned), space: browser.spaceID)
        LiveFolders.shared.apply(.items([issue("A-1", "Backlog", nil), issue("A-2", "Todo", nil)], nil), to: made.id)
        browser.syncLive()
        let before = browser.tabs(in: made.id).count
        answer = [issue("A-2", "Todo", "unstarted")]

        LiveFolders.shared.update(made.id)
        await settle(made.id)
        browser.syncLive()

        #expect(before == 2)
        #expect(read.last?.leftOut == [.backlog])
        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.title) == ["A-2"])
        #expect(browser.tabs(in: made.id).map(\.liveKey) == [issue("A-2", "Todo", nil).key])
    }

    @Test func turningAStatusOffTakesItsRowsAwayAtOnceAndReadsAgain() async {
        let made = LiveFolders.shared.add(name: "My Issues", source: .linear(.assigned), space: browser.spaceID)
        LiveFolders.shared.apply(.items([issue("A-1", "Triage", "triage"), issue("A-2", "In Review", "started")], nil), to: made.id)
        answer = [issue("A-2", "In Review", "started")]

        LiveFolders.shared.setStatuses(made.id, [.started, .unstarted])
        let atOnce = LiveFolders.shared.folder(made.id)?.items.map(\.title)
        await settle(made.id)

        #expect(atOnce == ["A-2"])
        #expect(LiveFolders.shared.folder(made.id)?.source.statuses == ["unstarted", "started"])
        #expect(read.last?.leftOut == [.triage, .backlog])
    }

    @Test func turningBacklogOnIsKeptAndAsksForIt() async {
        let made = LiveFolders.shared.add(name: "My Issues", source: .linear(.assigned), space: browser.spaceID)
        answer = [issue("A-1", "Backlog", "backlog")]

        LiveFolders.shared.setStatuses(made.id, LinearStatus.allCases)
        await settle(made.id)

        #expect(read.last?.leftOut == [])
        #expect(LiveFolders.shared.folder(made.id)?.source.linearStatuses == LinearStatus.allCases)
        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.title) == ["A-1"])
        #expect(LiveFolders.shared.folder(made.id)?.source.emptyWording == "No issues")
    }

    @Test func noStatusesAndOtherFoldersChangeNothing() {
        let linear = LiveFolders.shared.add(name: "My Issues", source: .linear(.assigned), space: browser.spaceID)
        let inbox = LiveFolders.shared.add(name: "Inbox", source: .linear(.inbox), space: browser.spaceID)

        LiveFolders.shared.setStatuses(linear.id, [])
        LiveFolders.shared.setStatuses(inbox.id, [.backlog])

        #expect(LiveFolders.shared.folder(linear.id)?.source.statuses == nil)
        #expect(LiveFolders.shared.folder(inbox.id)?.source.statuses == nil)
        #expect(read.isEmpty)
    }

    @Test func aRowThatMovesToBacklogLeavesWhenItsPageIsRead() {
        let made = LiveFolders.shared.add(name: "My Issues", source: .linear(.assigned), space: browser.spaceID)
        LiveFolders.shared.apply(.items([issue("A-1", "Todo", "unstarted"), issue("A-2", "Todo", "unstarted")], nil), to: made.id)

        LiveFolders.shared.refreshed([issue("A-1", "Backlog", "backlog")], asks: [LiveTouch.Ask(key: issue("A-1", "", nil).key, space: browser.spaceID)])

        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.title) == ["A-2"])
    }

    @Test func anEmptyFolderSaysWhatItLeavesOut() {
        var source = LiveSource.linear(.assigned)
        #expect(source.emptyWording == "No issues outside Backlog")
        source.statuses = ["started"]
        #expect(source.emptyWording == "No issues outside Triage, Backlog and Todo")
        source.statuses = LinearStatus.allCases.map(\.rawValue)
        #expect(source.emptyWording == "No issues")
        #expect(LiveSource.linear(.inbox).emptyWording == "No issues")
        #expect(LiveSource.pullRequests.emptyWording == "No pull requests")
    }

    @Test func theSettingsFooterSaysWhatAlwaysShows() {
        #expect(LiveFolderRows.statusesFooter(.assigned).hasPrefix("Done and canceled issues never show."))
        #expect(LiveFolderRows.statusesFooter(.cycle("ENG")).hasPrefix("Done and canceled issues in the cycle show too."))
    }

    @Test func theCommandChangesTheChoiceBehindTheSameGateAsRename() async throws {
        let made = LiveFolders.shared.add(name: "My Issues", source: .linear(.assigned), space: browser.spaceID)
        let verb = try #require(PersonCommands.find("live", "statuses"))
        let box = BrowserToolbox()
        box.browser = browser
        let id = String(made.id.uuidString.prefix(8)).lowercased()

        let changed = try await verb.run(PersonCall(noun: "live", verb: "statuses", arguments: ["id": id, "status": ["todo", "Backlog"]],
                                                    browser: browser, box: box))
        let shown = try await PersonCommands.find("live", "show")!.run(PersonCall(noun: "live", verb: "show", arguments: ["id": id],
                                                                                 browser: browser, box: box))

        #expect(verb.kind == PersonCommands.find("live", "rename")?.kind)
        #expect(verb.kind == .arrange)
        #expect(changed["message"] as? String == "Leaves out Triage and In Progress")
        #expect(changed["statuses"] as? [String] == ["Backlog", "Todo"])
        #expect(shown["statuses"] as? [String] == ["Backlog", "Todo"])
        #expect(shown["leftOut"] as? [String] == ["Triage", "In Progress"])
    }

    @Test func theCommandRefusesWhatItCannotChoose() async throws {
        let linear = LiveFolders.shared.add(name: "My Issues", source: .linear(.assigned), space: browser.spaceID)
        let prs = LiveFolders.shared.add(name: "PRs", source: .pullRequests, space: browser.spaceID)
        let verb = try #require(PersonCommands.find("live", "statuses"))
        let box = BrowserToolbox()
        box.browser = browser
        func ask(_ folder: LiveFolder, _ statuses: [String]) -> PersonCall {
            PersonCall(noun: "live", verb: "statuses", arguments: ["id": String(folder.id.uuidString.prefix(8)).lowercased(), "status": statuses],
                       browser: browser, box: box)
        }

        await #expect(throws: PersonRefusal.self) { try await verb.run(ask(linear, ["done"])) }
        await #expect(throws: PersonRefusal.self) { try await verb.run(ask(linear, [])) }
        await #expect(throws: PersonRefusal.self) { try await verb.run(ask(prs, ["backlog"])) }
        await #expect(throws: PersonRefusal.self) { try await verb.first?(ask(prs, ["backlog"])) }
        #expect(LiveFolders.shared.folder(linear.id)?.source.statuses == nil)
    }
}
