import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class DraftReviewsTests {
    private var browser: Browser!
    private var asked: [URL] = []
    private var pulls: [Pull] = []
    private var unmarkedEmpty = false

    struct Pull {
        var number: Int
        var draft = false
        var review = false
        var team = false
        var created = false
        var assigned = false
        var involved = false
        var stack: Int? = nil
    }

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
            guard let self else { return .failed }
            if folder.source.pullLists != nil {
                return await LiveReader.readLists(folder.source, before: folder.items, pause: .zero) { self.answer($0) }
            }
            guard let url = folder.source.reading() else { return .failed }
            return self.answer(url)
        }
    }

    private func tearDown() async {
        LiveFolders.shared.reader = { await LiveReader.read($0) }
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    private func key(_ number: Int) -> String { "https://github.com/acme/rocket/pull/\(number)" }

    private func item(_ pull: Pull) -> LiveItem {
        var made = LiveItem(key: key(pull.number), title: "Pull \(pull.number)", label: pull.draft ? PullState.draft : nil,
                            draft: pull.draft ? true : nil)
        if let position = pull.stack {
            made.branch = LiveBranch(repository: "acme/rocket", base: "b\(position - 1)", head: "b\(position)", stack: 7, position: position)
        }
        return made
    }

    private func answer(_ url: URL) -> LiveReader.Answer {
        asked.append(url)
        let words = Set((GitHubAPI.search(for: url) ?? "").split(separator: " ").map(String.init))
        let found = pulls.filter { pull in
            if words.contains("draft:false"), pull.draft { return false }
            if words.contains("review-requested:@me") { return pull.review }
            if words.contains("team-review-requested:@me") { return pull.team }
            if words.contains("author:@me") { return pull.created }
            if words.contains("assignee:@me") { return pull.assigned }
            if words.contains("involves:@me") { return pull.involved }
            return false
        }.sorted { ($0.stack ?? 0, $0.number) > ($1.stack ?? 0, $1.number) }
        return .read(LiveRead(items: found.map(item), marked: !(found.isEmpty && unmarkedEmpty)))
    }

    private func source(_ lists: [PullList], hides: Bool) -> LiveSource {
        var made = LiveSource.pullRequests
        made.lists = lists
        made.hidesDraftReviews = hides ? true : nil
        return made
    }

    private func read(_ lists: [PullList], hides: Bool) async -> [LiveItem] {
        let answer = await LiveReader.readLists(source(lists, hides: hides), pause: .zero) { self.answer($0) }
        return answer.found ?? []
    }

    private func numbers(_ items: [LiveItem]?) -> [Int] {
        (items ?? []).compactMap { Int($0.key.split(separator: "/").last ?? "") }.sorted()
    }

    private func row(_ items: [LiveItem], _ number: Int) -> LiveItem? {
        items.first { $0.key == key(number) }
    }

    private func settle(_ id: UUID) async {
        for _ in 0..<300 where LiveFolders.shared.reading.contains(id) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func menu(_ id: UUID) -> [NSMenuItem] {
        FolderMenus.menu(browser: browser, group: TabGroup(id: id, name: "PRs", collapsed: true, live: true)).items
    }

    private let table = [
        Pull(number: 1, draft: true, review: true),
        Pull(number: 2, review: true),
        Pull(number: 3, draft: true, created: true),
        Pull(number: 4, draft: true, assigned: true),
        Pull(number: 5, draft: true, review: true, assigned: true),
        Pull(number: 6, draft: true, review: true, involved: true),
        Pull(number: 7, draft: true, team: true),
        Pull(number: 8, team: true),
    ]

    @Test func eachListAsksTheSameWordsWithTheSwitchOff() {
        #expect(PullList.reviewRequests.query(hidingDrafts: false) == "is:open is:pr archived:false review-requested:@me")
        #expect(PullList.teamReviews.query(hidingDrafts: false) == "is:open is:pr archived:false team-review-requested:@me")
        #expect(PullList.reviewRequests.page(hidingDrafts: false).absoluteString
                == "https://github.com/pulls?q=is%3Aopen+is%3Apr+archived%3Afalse+review-requested%3A%40me")
        for list in PullList.allCases {
            #expect(source(PullList.allCases, hides: false).page(list) == list.page(hidingDrafts: false))
        }
    }

    @Test func onlyTheReviewListsAskWithoutDraftsWithTheSwitchOn() {
        let on = source(PullList.allCases, hides: true)

        #expect(PullList.reviewRequests.query(hidingDrafts: true) == "is:open is:pr archived:false review-requested:@me draft:false")
        #expect(PullList.teamReviews.query(hidingDrafts: true) == "is:open is:pr archived:false team-review-requested:@me draft:false")
        #expect(on.page(.reviewRequests).absoluteString
                == "https://github.com/pulls?q=is%3Aopen+is%3Apr+archived%3Afalse+review-requested%3A%40me+draft%3Afalse")
        #expect(on.page(.teamReviews).absoluteString
                == "https://github.com/pulls?q=is%3Aopen+is%3Apr+archived%3Afalse+team-review-requested%3A%40me+draft%3Afalse")
        #expect(PullList.drafts.query(hidingDrafts: true) == "is:open is:pr archived:false author:@me draft:true")
        #expect(PullList.waiting.query(hidingDrafts: true) == "is:open is:pr archived:false author:@me review:required draft:false")
        for list in PullList.allCases where !list.asksForReview {
            #expect(on.page(list) == list.page(hidingDrafts: false))
        }
        let noReview = source([.created, .assigned], hides: true)
        #expect(!noReview.leavesOutDraftReviews)
        #expect(noReview.page(.reviewRequests) == PullList.reviewRequests.page(hidingDrafts: false))
    }

    @Test func everyListReadAndTheMoreLinkAskWithTheSwitch() async {
        pulls = table
        _ = await read([.reviewRequests, .teamReviews, .created], hides: true)
        let on = asked.compactMap { GitHubAPI.search(for: $0) }
        asked = []
        _ = await read([.reviewRequests, .teamReviews, .created], hides: false)
        let off = asked.compactMap { GitHubAPI.search(for: $0) }
        pulls = (100..<140).map { Pull(number: $0, review: true) }
        let answer = await LiveReader.readLists(source([.reviewRequests], hides: true), pause: .zero) { self.answer($0) }
        guard case .read(let full) = answer else { Issue.record("not a read: \(answer)"); return }

        #expect(on.filter { $0.contains("review-requested:@me") }.allSatisfy { $0.contains("draft:false") })
        #expect(on.filter { $0.contains("author:@me") }.allSatisfy { !$0.contains("draft:") })
        #expect(off.allSatisfy { !$0.contains("draft:") })
        #expect(full.more?.contains("draft%3Afalse") == true)
    }

    @Test func anAddressFolderAsksWithoutDraftsAndKeepsItsAddress() {
        var reviews = LiveSource.reviewRequests
        #expect(reviews.reading()?.absoluteString == reviews.address)
        reviews.hidesDraftReviews = true

        #expect(reviews.asksForReview)
        #expect(reviews.reading()?.absoluteString == reviews.address + "+draft%3Afalse")
        #expect(GitHubAPI.search(for: reviews.reading())?.hasPrefix("is:open is:pr review-requested:@me archived:false draft:false") == true)
        #expect(reviews.address == LiveSource.reviewRequests.address)

        var team = LiveSource(kind: .pullRequests, address: "https://github.com/pulls?q=is%3Aopen+team-review-requested%3A%40me&sort=updated")
        team.hidesDraftReviews = true
        #expect(team.reading()?.absoluteString == "https://github.com/pulls?q=is%3Aopen+team-review-requested%3A%40me+draft%3Afalse&sort=updated")

        var already = LiveSource(kind: .pullRequests, address: "https://github.com/pulls?q=review-requested%3A%40me+draft%3Atrue")
        already.hidesDraftReviews = true
        #expect(already.reading()?.absoluteString == already.address)

        var mine = LiveSource.myPullRequests
        mine.hidesDraftReviews = true
        #expect(!mine.asksForReview)
        #expect(mine.reading()?.absoluteString == mine.address)

        var lists = LiveSource.pullRequests
        lists.hidesDraftReviews = true
        #expect(lists.reading()?.absoluteString == LiveSource.pullRequests.address)
    }

    @Test func theFieldReadsBothWays() throws {
        let old = """
        [{"id":"\(UUID().uuidString)","space":"\(UUID().uuidString)","name":"PRs","paused":false,"state":"fine",
          "source":{"kind":"pullRequests","address":"\(LiveSource.pullRequests.address)","lists":["reviewRequests","created"]},
          "items":[],"hidden":[]}]
        """
        let (kept, _) = try #require(LiveFolders.sorted(Data(old.utf8)))
        let folder = try #require(kept.first)
        let again = String(decoding: try JSONEncoder().encode(kept), as: UTF8.self)
        var on = folder.source
        on.hidesDraftReviews = true
        let written = try JSONEncoder().encode(on)

        struct Older: Codable {
            var kind: LiveSource.Kind
            var address: String
            var range: LiveRange?
            var lists: [PullList]?
            var statuses: [String]?
        }
        let older = try JSONDecoder().decode(Older.self, from: written)

        #expect(folder.source.hidesDraftReviews == nil)
        #expect(!folder.source.leavesOutDraftReviews)
        #expect(!again.contains("hidesDraftReviews"))
        #expect(String(decoding: written, as: UTF8.self).contains("\"hidesDraftReviews\":true"))
        #expect(try JSONDecoder().decode(LiveSource.self, from: written).leavesOutDraftReviews)
        #expect(older.lists == [.reviewRequests, .created])
        #expect(older.address == LiveSource.pullRequests.address)
    }

    @Test func theTableWithAssignedToYouOn() async {
        pulls = table
        let lists: [PullList] = [.reviewRequests, .teamReviews, .created, .assigned]

        let off = await read(lists, hides: false)
        let on = await read(lists, hides: true)

        #expect(numbers(off) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(numbers(on) == [2, 3, 4, 5, 8])
        #expect(row(off, 3)?.label == PullState.draft)
        #expect(row(on, 3)?.label == PullState.draft)
        #expect(row(off, 4)?.label == PullState.draft)
        #expect(row(on, 4)?.label == PullState.draft)
        #expect(row(on, 5)?.on == [.assigned])
        #expect(row(on, 5)?.list == .assigned)
        #expect(row(on, 5)?.label == PullState.draft)
        #expect(row(off, 5)?.on == [.reviewRequests, .assigned])
    }

    @Test func aDraftAskingForReviewAndAssignedLeavesWhenAssignedToYouIsOff() async {
        pulls = table

        let off = await read([.reviewRequests, .created], hides: false)
        let on = await read([.reviewRequests, .created], hides: true)

        #expect(numbers(off) == [1, 2, 3, 5, 6])
        #expect(numbers(on) == [2, 3])
    }

    @Test func aDraftOnEverythingInvolvingYouStaysThroughThatList() async {
        pulls = table

        let off = await read([.reviewRequests, .involved], hides: false)
        let on = await read([.reviewRequests, .involved], hides: true)

        #expect(numbers(off) == [1, 2, 5, 6])
        #expect(numbers(on) == [2, 6])
        #expect(row(on, 6)?.on == [.involved])
    }

    @Test func aDraftThatBecomesReadyArrivesAndAReadyOneThatTurnsDraftLeaves() async {
        pulls = [Pull(number: 1, draft: true, review: true), Pull(number: 2, review: true)]
        let made = LiveFolders.shared.add(name: "PRs", source: source([.reviewRequests, .created], hides: true), space: browser.spaceID)
        LiveFolders.shared.update(made.id)
        await settle(made.id)
        let first = numbers(LiveFolders.shared.folder(made.id)?.items)

        pulls = [Pull(number: 1, review: true), Pull(number: 2, draft: true, review: true)]
        LiveFolders.shared.update(made.id)
        await settle(made.id)
        let second = LiveFolders.shared.folder(made.id)

        #expect(first == [2])
        #expect(numbers(second?.items) == [1])
        #expect(second?.state == .fine)
    }

    @Test func withTheSwitchOffADraftAndAReadyOneStayAsTheyTurn() async {
        pulls = [Pull(number: 1, draft: true, review: true), Pull(number: 2, review: true)]
        let made = LiveFolders.shared.add(name: "PRs", source: source([.reviewRequests, .created], hides: false), space: browser.spaceID)
        LiveFolders.shared.update(made.id)
        await settle(made.id)
        let first = numbers(LiveFolders.shared.folder(made.id)?.items)

        pulls = [Pull(number: 1, review: true), Pull(number: 2, draft: true, review: true)]
        LiveFolders.shared.update(made.id)
        await settle(made.id)
        let second = LiveFolders.shared.folder(made.id)

        #expect(first == [1, 2])
        #expect(numbers(second?.items) == [1, 2])
        #expect(second?.state == .fine)
    }

    @Test func turningItOnTakesTheDraftsAwayAtOnceAndReadsWithoutThem() async {
        pulls = table
        let made = LiveFolders.shared.add(name: "PRs", source: source([.reviewRequests, .teamReviews, .created, .assigned], hides: false),
                                          space: browser.spaceID)
        LiveFolders.shared.update(made.id)
        await settle(made.id)
        let before = numbers(LiveFolders.shared.folder(made.id)?.items)
        asked = []

        LiveFolders.shared.setHidesDraftReviews(made.id, true)
        let atOnce = LiveFolders.shared.folder(made.id)?.items ?? []
        await settle(made.id)
        let after = LiveFolders.shared.folder(made.id)

        #expect(before == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(numbers(atOnce) == [2, 3, 4, 5, 8])
        #expect(row(atOnce, 5)?.on == [.assigned])
        #expect(row(atOnce, 5)?.list == .assigned)
        #expect(row(atOnce, 5)?.label == PullState.draft)
        #expect(after?.source.hidesDraftReviews == true)
        #expect(numbers(after?.items) == [2, 3, 4, 5, 8])
        #expect(after?.state == .fine)
        #expect(asked.compactMap { GitHubAPI.search(for: $0) }.filter { $0.contains("review-requested:@me") }.allSatisfy { $0.contains("draft:false") })
    }

    @Test func anEmptyUnmarkedReviewListAfterTurningItOnIsNotAFailedRead() async {
        pulls = [Pull(number: 5, draft: true, review: true, assigned: true), Pull(number: 9, draft: true, review: true)]
        let made = LiveFolders.shared.add(name: "PRs", source: source([.reviewRequests, .assigned], hides: false), space: browser.spaceID)
        LiveFolders.shared.update(made.id)
        await settle(made.id)
        unmarkedEmpty = true

        LiveFolders.shared.setHidesDraftReviews(made.id, true)
        await settle(made.id)
        let after = LiveFolders.shared.folder(made.id)

        #expect(numbers(after?.items) == [5])
        #expect(after?.state == .fine)
        #expect(after?.cause == nil)
    }

    @Test func turningItOffReadsAgainAndTheDraftsComeBack() async {
        pulls = table
        let made = LiveFolders.shared.add(name: "PRs", source: source([.reviewRequests, .created, .assigned], hides: true), space: browser.spaceID)
        LiveFolders.shared.update(made.id)
        await settle(made.id)
        let on = numbers(LiveFolders.shared.folder(made.id)?.items)

        LiveFolders.shared.setHidesDraftReviews(made.id, false)
        await settle(made.id)
        let after = LiveFolders.shared.folder(made.id)

        #expect(on == [2, 3, 4, 5])
        #expect(numbers(after?.items) == [1, 2, 3, 4, 5, 6])
        #expect(after?.source.hidesDraftReviews == nil)
    }

    @Test func anAddressFolderDropsItsDraftsAtOnceAndReadsWithoutThem() async {
        pulls = [Pull(number: 1, draft: true, review: true), Pull(number: 2, review: true)]
        let made = LiveFolders.shared.add(name: "Reviews", source: .reviewRequests, space: browser.spaceID)
        LiveFolders.shared.update(made.id)
        await settle(made.id)
        let before = numbers(LiveFolders.shared.folder(made.id)?.items)
        asked = []

        LiveFolders.shared.setHidesDraftReviews(made.id, true)
        let atOnce = numbers(LiveFolders.shared.folder(made.id)?.items)
        await settle(made.id)
        let after = LiveFolders.shared.folder(made.id)

        #expect(before == [1, 2])
        #expect(atOnce == [2])
        #expect(numbers(after?.items) == [2])
        #expect(after?.source.address == LiveSource.reviewRequests.address)
        #expect(asked.map(\.absoluteString) == [LiveSource.reviewRequests.address + "+draft%3Afalse"])
    }

    @Test func aDraftLeftOutIsNotCountedAsAReviewRequest() async {
        pulls = [Pull(number: 2, review: true), Pull(number: 5, draft: true, review: true, assigned: true)]
        let memory = NowMemory(file: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("now-\(UUID().uuidString).json"))
        let made = LiveFolders.shared.add(name: "PRs", source: source([.reviewRequests, .assigned], hides: false), space: browser.spaceID)
        LiveFolders.shared.update(made.id)
        await settle(made.id)
        let before = IntegrationNow.rows(from: LiveFolders.shared.folders, on: true, memory: memory).map(\.title)

        LiveFolders.shared.setHidesDraftReviews(made.id, true)
        let atOnce = IntegrationNow.rows(from: LiveFolders.shared.folders, on: true, memory: memory).map(\.title)
        await settle(made.id)
        let after = IntegrationNow.rows(from: LiveFolders.shared.folders, on: true, memory: memory).map(\.title)

        #expect(Set(before) == ["Pull 2", "Pull 5"])
        #expect(atOnce == ["Pull 2"])
        #expect(after == ["Pull 2"])
    }

    @Test func aStackKeepsTheMembersThatStayAndCountsOnlyThem() async {
        pulls = [Pull(number: 11, created: true, stack: 1), Pull(number: 12, draft: true, review: true, stack: 2),
                 Pull(number: 13, created: true, stack: 3)]
        let made = LiveFolders.shared.add(name: "PRs", source: source([.reviewRequests, .created], hides: false), space: browser.spaceID)
        LiveFolders.shared.update(made.id)
        await settle(made.id)
        let before = LiveFolders.shared.folder(made.id)?.items.map { $0.stack?.said ?? "" }

        LiveFolders.shared.setHidesDraftReviews(made.id, true)
        let atOnce = LiveFolders.shared.folder(made.id)?.items ?? []
        await settle(made.id)
        let after = LiveFolders.shared.folder(made.id)?.items ?? []

        #expect(before == ["3/3", "2/3", "1/3"])
        #expect(atOnce.map { $0.stack?.said ?? "" } == ["2/2", "1/2"])
        #expect(after.map { $0.stack?.said ?? "" } == ["2/2", "1/2"])
        #expect(numbers(after) == [11, 13])
        #expect(LiveStackRuns.tops(after) == [0, 0])
    }

    @Test func aFoldedStackStaysFoldedWhenItsTopIsLeftOut() async throws {
        pulls = [Pull(number: 11, created: true, stack: 1), Pull(number: 12, created: true, stack: 2),
                 Pull(number: 13, draft: true, review: true, stack: 3)]
        let made = LiveFolders.shared.add(name: "PRs", source: source([.reviewRequests, .created], hides: false), space: browser.spaceID)
        LiveFolders.shared.update(made.id)
        await settle(made.id)
        browser.syncLive()
        let group = try #require(browser.tabGroups.first { $0.id == made.id })
        let top = try #require(browser.stackTops(in: group).first?.key)
        browser.toggleStack(top, in: made.id)
        let foldedBefore = browser.stackTops(in: try #require(browser.tabGroups.first { $0.id == made.id }))

        LiveFolders.shared.setHidesDraftReviews(made.id, true)
        await settle(made.id)
        browser.syncLive()
        let now = try #require(browser.tabGroups.first { $0.id == made.id })
        let foldedAfter = browser.stackTops(in: now)
        let shown = Browser.unfoldedStacks(browser.drawnTabs(in: now), in: now, front: nil).compactMap(\.liveItem?.key)

        #expect(foldedBefore.values.map { $0 } == [true])
        #expect(LiveFolders.shared.folder(made.id)?.items.map { $0.stack?.said ?? "" } == ["2/2", "1/2"])
        #expect(foldedAfter.count == 1)
        #expect(foldedAfter.values.allSatisfy { $0 })
        #expect(shown == [key(12)])
    }

    @Test func theMenuItemSitsUnderListsOnlyWhenTheFolderAsksForReview() {
        let lists = LiveFolders.shared.add(name: "PRs", source: .pullRequests, space: browser.spaceID)
        let noReview = LiveFolders.shared.add(name: "Mine", source: source([.created, .assigned], hides: false), space: browser.spaceID)
        let address = LiveFolders.shared.add(name: "Reviews", source: .reviewRequests, space: browser.spaceID)
        let mine = LiveFolders.shared.add(name: "Pulls", source: .myPullRequests, space: browser.spaceID)
        let linear = LiveFolders.shared.add(name: "Issues", source: .linear(.assigned), space: browser.spaceID)
        let title = "Hide Draft Review Requests"

        let titles = menu(lists.id).map(\.title)
        let at = titles.firstIndex(of: title)
        let item = menu(lists.id).first { $0.title == title }
        let addressTitles = menu(address.id).map(\.title)

        #expect(at != nil && at == titles.firstIndex(of: "Lists").map { $0 + 1 })
        #expect(item?.state == .off)
        #expect(item?.isEnabled == true)
        #expect(!menu(noReview.id).map(\.title).contains(title))
        #expect(addressTitles.firstIndex(of: title) == addressTitles.firstIndex(of: "Stop Updating").map { $0 + 1 })
        #expect(!menu(mine.id).map(\.title).contains(title))
        #expect(!menu(linear.id).map(\.title).contains(title))
        #expect(menu(lists.id).first(where: { $0.title == "Lists" })?.submenu?.items.contains { $0.title == title } == false)
    }

    @Test func theMenuItemTurnsTheSwitchAndShowsItsCheck() async {
        let made = LiveFolders.shared.add(name: "PRs", source: .pullRequests, space: browser.spaceID)
        let title = "Hide Draft Review Requests"
        func pick() {
            let shown = FolderMenus.menu(browser: browser, group: TabGroup(id: made.id, name: "PRs", collapsed: true, live: true))
            guard let at = shown.items.firstIndex(where: { $0.title == title }) else { Issue.record("no item"); return }
            shown.performActionForItem(at: at)
        }

        pick()
        await settle(made.id)
        let on = LiveFolders.shared.folder(made.id)?.source.hidesDraftReviews
        let checked = menu(made.id).first { $0.title == title }?.state
        pick()
        await settle(made.id)

        #expect(on == true)
        #expect(checked == .on)
        #expect(LiveFolders.shared.folder(made.id)?.source.hidesDraftReviews == nil)
        #expect(menu(made.id).first { $0.title == title }?.state == .off)
    }

    @Test func liveShowAndLiveDraftsSayAndSetTheSwitch() async throws {
        let made = LiveFolders.shared.add(name: "PRs", source: .pullRequests, space: browser.spaceID)
        let mine = LiveFolders.shared.add(name: "Pulls", source: .myPullRequests, space: browser.spaceID)
        let box = BrowserToolbox()
        box.browser = browser
        let id = String(made.id.uuidString.prefix(8)).lowercased()
        let other = String(mine.id.uuidString.prefix(8)).lowercased()
        let show = try #require(PersonCommands.find("live", "show"))
        let drafts = try #require(PersonCommands.find("live", "drafts"))
        func call(_ verb: String, _ arguments: [String: Any]) -> PersonCall {
            PersonCall(noun: "live", verb: verb, arguments: arguments, browser: browser, box: box)
        }

        let before = try await show.run(call("show", ["id": id]))
        let set = try await drafts.run(call("drafts", ["id": id, "choice": "hide"]))
        let after = try await show.run(call("show", ["id": id]))
        let plain = try await show.run(call("show", ["id": other]))

        #expect(drafts.kind == .arrange)
        #expect(before["hidesDraftReviewRequests"] as? Bool == false)
        #expect(set["hidesDraftReviewRequests"] as? Bool == true)
        #expect(set["message"] as? String == "Leaves out draft review requests")
        #expect(after["hidesDraftReviewRequests"] as? Bool == true)
        #expect(plain["hidesDraftReviewRequests"] == nil)
        await #expect(throws: PersonRefusal.self) { try await drafts.run(call("drafts", ["id": other, "choice": "hide"])) }
        await #expect(throws: PersonRefusal.self) { try await drafts.run(call("drafts", ["id": id, "choice": "maybe"])) }
        _ = try await drafts.run(call("drafts", ["id": id, "choice": "show"]))
        #expect(LiveFolders.shared.folder(made.id)?.source.hidesDraftReviews == nil)
        await settle(made.id)
    }
}
