import AppKit
import Testing
@testable import Search

struct StackWalkTests {
    private func pull(_ number: Int, repository: String = "acme/rocket", stack: Int? = 21, position: Int?, base: String = "main",
                      head: String? = nil, label: String? = nil, draft: Bool? = nil, checks: LiveChecks? = nil) -> LiveItem {
        LiveItem(key: "https://github.com/\(repository)/pull/\(number)", title: "PR \(number)", label: label, checks: checks,
                 branch: LiveBranch(repository: repository, base: base, head: head ?? "branch-\(number)", stack: stack, position: position),
                 draft: draft)
    }

    private func id(_ number: Int, _ repository: String = "acme/rocket") -> String { "github:\(repository)#\(number)" }

    private var rail: [LiveItem] {
        [pull(61, position: 1), pull(62, position: 2, base: "branch-61"), pull(63, position: 3, base: "branch-62"),
         pull(64, position: 4, base: "branch-63")]
    }

    @Test func mergingTheThirdOfFourWalksDownToTheTrunkNearestFirst() {
        #expect(LiveStackWalk.below(id(63), in: rail) == [id(62), id(61)])
    }

    @Test func theWalkNeverGoesUp() {
        #expect(LiveStackWalk.below(id(61), in: rail).isEmpty)
        #expect(LiveStackWalk.below(id(62), in: rail) == [id(61)])
        #expect(!LiveStackWalk.below(id(63), in: rail).contains(id(64)))
    }

    @Test func branchesBasedOnEachOtherWithoutAGitHubStackAreNotAStack() {
        let chain = [pull(1, stack: nil, position: nil), pull(2, stack: nil, position: nil, base: "branch-1"),
                     pull(3, stack: nil, position: nil, base: "branch-2")]

        #expect(LiveStackWalk.below(id(3), in: chain).isEmpty)
    }

    @Test func aMiddleThatIsInNoFolderDoesNotStopTheWalk() {
        let gap = rail.filter { $0.title != "PR 62" }

        #expect(LiveStackWalk.below(id(63), in: gap) == [id(61)])
    }

    @Test func theSameStackNumberAndBranchesInAnotherRepositoryAreLeftAlone() {
        let other = pull(61, repository: "acme/lander", position: 1)
        let twin = pull(62, repository: "acme/lander", position: 2, base: "branch-61")

        #expect(LiveStackWalk.below(id(63), in: rail + [other, twin]) == [id(62), id(61)])
        #expect(LiveStackWalk.below(id(62, "acme/lander"), in: rail + [other, twin]) == [id(61, "acme/lander")])
    }

    @Test func theRepositoryIsMatchedWhateverItsCase() {
        let shouted = pull(61, repository: "Acme/Rocket", position: 1)

        #expect(LiveStackWalk.below(id(62), in: [shouted, pull(62, position: 2)]) == [id(61)])
    }

    @Test func aLowerOneAlreadyClosedOrMergedIsNotTurned() {
        let items = [pull(61, position: 1, label: PullState.closed), pull(62, position: 2, label: PullState.merged), pull(63, position: 3)]

        #expect(LiveStackWalk.below(id(63), in: items).isEmpty)
    }

    @Test func aLowerDraftOrOneWithFailingChecksTurnsWithTheMerge() {
        let items = [pull(61, position: 1, draft: true), pull(62, position: 2, checks: .failing), pull(63, position: 3)]

        #expect(LiveStackWalk.below(id(63), in: items) == [id(62), id(61)])
    }

    @Test func twoStacksOnOneBaseBranchStayApart() {
        let other = [pull(71, stack: 22, position: 1), pull(72, stack: 22, position: 2, base: "branch-71")]

        #expect(LiveStackWalk.below(id(63), in: rail + other) == [id(62), id(61)])
        #expect(LiveStackWalk.below(id(72), in: rail + other) == [id(71)])
    }

    @Test func aRowListedInTwoFoldersIsWalkedOnce() {
        #expect(LiveStackWalk.below(id(63), in: rail + rail) == [id(62), id(61)])
    }

    @Test func aPullRequestWithoutAKnownStackWalksNowhere() {
        #expect(LiveStackWalk.below(id(9), in: rail).isEmpty)
        #expect(LiveStackWalk.below(id(63), in: [pull(63, stack: 21, position: nil)] + rail.prefix(2)).isEmpty)
    }

    @Test func thePagesOwnStateIsReadFromItsHeaderOrItsData() {
        let header = #"<div class="h" data-component="PH_LeadingVisual"><span class="x" data-component="StateLabel" data-size="medium" data-status="pullMerged">Merged</span></div>"#
        let data = #"{"pullRequest":{"mergedTime":null,"number":4,"relayId":"PR_a","state":"OPEN","title":"A"}}"#

        #expect(LiveRefs.state(in: header) == .merged)
        #expect(LiveRefs.state(in: data, number: 4) == .open)
        #expect(LiveRefs.state(in: #"<div data-component="PageHeader.Description"><span data-component="StateLabel" data-status="draft">Draft</span></div>"#) == .draft)
        #expect(LiveRefs.state(in: #"{"state" : "CLOSED", "number": 4}"#, number: 4) == .closed)
        #expect(LiveRefs.state(in: "<p>nothing here</p>", number: 4) == nil)
        #expect(LiveRefs.page(in: header + data, repository: "acme/rocket", number: 4).state == .merged)
    }

    @Test func theStateOfAnotherPullRequestOnThePageIsNotTaken() {
        let siblings = #"<ul><li><span data-component="StateLabel" data-status="pullMerged">Merged</span> #82</li></ul>"#
            + #"{"stack":{"number":22,"position":1,"pullRequests":[{"number":82,"state":"MERGED"},{"number":810,"state":"MERGED"}]}}"#
        let own = #"{"pullRequest":{"number":81,"state":"OPEN"}}"#
        let header = #"<div data-component="PageHeader.Description"><span data-component="StateLabel" data-status="pullOpened">Open</span></div>"#

        #expect(LiveRefs.state(in: siblings + own, number: 81) == .open)
        #expect(LiveRefs.state(in: siblings + header + own, number: 81) == .open)
        #expect(LiveRefs.state(in: siblings, number: 81) == nil)
        #expect(LiveRefs.state(in: #""state":"MERGED""#) == nil)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class MergedStackTests {
    private var browser: Browser!
    private let reader = LiveFolders.shared.reader

    init() async throws {
        _ = NSApplication.shared
        keepSetting(Shared.prefs, \.liveFolders, "live.on")
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.liveFolders = true
        LiveFolders.shared.reader = { _ in .failed }
        LiveFolders.shared.stackStagger = 0
        LiveFolders.shared.settles = 0
        MergedCrowd.forget()
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
    }

    private func tearDown() async {
        MergedCrowd.forget()
        LiveFolders.shared.mergedHold = LiveFolders.hold
        LiveFolders.shared.stackStagger = LiveFolders.stagger
        LiveFolders.shared.settles = LiveFolders.settles
        LiveFolders.shared.reader = reader
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        LiveRefs.known = [:]
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    private func key(_ number: Int, _ repository: String = "acme/rocket") -> String { "https://github.com/\(repository)/pull/\(number)" }

    private func pull(_ number: Int, position: Int? = nil, repository: String = "acme/rocket", label: String? = "Approved") -> LiveItem {
        LiveItem(key: key(number, repository), title: "PR \(number)", label: label, author: "dana", checks: .passing,
                 branch: LiveBranch(repository: repository, base: "base-\(number)", head: "head-\(number)",
                                    stack: position == nil ? nil : 21, position: position, stackRead: true))
    }

    private var rail: [LiveItem] { [pull(61, position: 1), pull(62, position: 2), pull(63, position: 3), pull(64, position: 4), pull(70)] }

    private func prs(_ items: [LiveItem], name: String = "PRs", space: UUID? = nil) -> LiveFolder {
        let made = LiveFolders.shared.add(name: name, source: .pullRequests, space: space ?? browser.spaceID)
        LiveFolders.shared.apply(.items(LiveStacks.arranged(items), nil), to: made.id)
        browser.syncLive()
        return made
    }

    private func item(_ made: LiveFolder, _ number: Int) -> LiveItem? {
        LiveFolders.shared.folder(made.id)?.items.first { $0.key == key(number) }
    }

    private func labels(_ made: LiveFolder) -> [Int: String] {
        Dictionary(uniqueKeysWithValues: (LiveFolders.shared.folder(made.id)?.items ?? []).map {
            (Int($0.key.split(separator: "/").last!)!, $0.label ?? "")
        })
    }

    private func merge(_ number: Int) {
        LiveFolders.shared.pageMerged(URL(string: key(number))!, space: browser.spaceID)
        browser.syncLive()
    }

    private func pageSaid(_ number: Int, _ state: PullPageState) {
        LiveRefs.known[LiveRefs.slot(key(number), space: browser.spaceID)] = LiveRefs.Known(updated: nil, branch: pull(number).branch, read: Date(), state: state)
    }

    @Test func mergingTheThirdOfFourTurnsTheTwoBelowAndLeavesTheTop() {
        let made = prs(rail)

        merge(63)

        #expect(labels(made) == [61: "Merged", 62: "Merged", 63: "Merged", 64: "Approved", 70: "Approved"])
        #expect([61, 62, 63].allSatisfy { LiveFolders.shared.turning(key($0)) })
        #expect(LiveFolders.shared.claimed == ["github:acme/rocket#61", "github:acme/rocket#62"])
        #expect(LiveFolders.shared.leads(key(63)))
        #expect(!LiveFolders.shared.leads(key(62)))
    }

    @Test func theRowsBelowFollowTheFirstOneStepAtATimeDownTheStack() async throws {
        LiveFolders.shared.stackStagger = 0.12
        let made = prs(rail)

        merge(63)
        let first = labels(made)
        try await Task.sleep(for: .milliseconds(180))
        let second = labels(made)
        try await Task.sleep(for: .milliseconds(200))
        let third = labels(made)

        #expect(first[63] == "Merged" && first[62] == "Approved" && first[61] == "Approved")
        #expect(second[62] == "Merged" && second[61] == "Approved")
        #expect(third[61] == "Merged" && third[64] == "Approved")
    }

    @Test func theRowInFrontPlaysTheWashTheRowsBelowFollowItAndEveryTurnedRowGetsTheWord() throws {
        let made = prs([pull(61, position: 1, label: nil)] + rail.dropFirst())
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: 700), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        browser.sightForBench = true
        browser.unfoldFolder(made.id)
        let column = SideColumnView(browser: browser)
        window.contentView = column
        defer {
            window.contentView = nil
            window.close()
        }
        column.layoutSubtreeIfNeeded()
        let rows = [61, 62, 63, 64].map { number in column.kitSubviews(of: TabRowView.self).first { $0.accessibilityLabel() == "PR \(number)" && $0.window != nil } }

        merge(63)
        column.needsLayout = true
        column.layoutSubtreeIfNeeded()

        let shown = try rows.map { try #require($0) }
        #expect(shown.map(\.plays) == [0, 0, 1, 0])
        #expect(shown.map(\.mergedForm) == [.follow, .follow, .full, nil])
        #expect(shown.map(\.mergedLayers) == [2, 2, 2, 0])
        #expect(shown.map(\.arrivals) == [1, 1, 1, 0])
        #expect(browser.tabs(in: made.id).allSatisfy { !$0.arrives })
    }

    @Test func theRowsBelowLeaveTogetherWithTheRowInFront() async throws {
        LiveFolders.shared.stackStagger = 0.15
        LiveFolders.shared.mergedHold = 0.4
        let made = prs(rail)

        merge(63)
        try await Task.sleep(for: .milliseconds(320))
        let held = LiveFolders.shared.folder(made.id)?.items.count
        try await Task.sleep(for: .milliseconds(160))

        #expect(held == 5)
        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.key) == [key(64), key(70)])
    }

    @Test func turnedRowsLeaveWithTheHoldButAreNotHiddenUntilARead() async throws {
        LiveFolders.shared.mergedHold = 0.05
        let made = prs(rail)

        merge(63)
        try await Task.sleep(for: .milliseconds(300))
        browser.syncLive()

        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.key) == [key(64), key(70)])
        #expect(LiveFolders.shared.folder(made.id)?.hidden == ["github:acme/rocket#63"])
        #expect(LiveFolders.shared.claimed == ["github:acme/rocket#61", "github:acme/rocket#62"])
        #expect(browser.tabs(in: made.id).compactMap(\.liveKey) == [key(64), key(70)])
    }

    @Test func aReadWithoutThemLetsThemGoWithoutHidingThem() async throws {
        LiveFolders.shared.mergedHold = 0.05
        let made = prs(rail)
        merge(63)
        try await Task.sleep(for: .milliseconds(300))

        LiveFolders.shared.apply(.items([pull(64, position: 4), pull(70)], nil), to: made.id)

        #expect(LiveFolders.shared.claimed.isEmpty)
        #expect(LiveFolders.shared.folder(made.id)?.hidden == ["github:acme/rocket#63"])
        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.key) == [key(64), key(70)])
    }

    @Test func aReadWithoutThemDuringTheHoldLetsThemGoWhenTheyLeave() async throws {
        LiveFolders.shared.mergedHold = 0.2
        let made = prs(rail)
        merge(63)

        LiveFolders.shared.apply(.items([pull(64, position: 4), pull(70)], nil), to: made.id)
        let held = labels(made)
        try await Task.sleep(for: .milliseconds(450))

        #expect(held[61] == "Merged" && held[62] == "Merged")
        #expect(LiveFolders.shared.claimed.isEmpty)
        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.key) == [key(64), key(70)])
        #expect(LiveFolders.shared.folder(made.id)?.hidden == ["github:acme/rocket#63"])
    }

    @Test func anOpenAnswerReadRightAfterTheMergeWaitsForALaterRead() async throws {
        LiveFolders.shared.mergedHold = 0.05
        LiveFolders.shared.settles = 60
        let made = prs(rail)
        merge(63)
        try await Task.sleep(for: .milliseconds(300))
        pageSaid(62, .open)

        LiveFolders.shared.apply(.items(rail.filter { $0.key != key(63) }, nil), to: made.id)

        #expect(item(made, 62) == nil)
        #expect(LiveFolders.shared.claimed.contains("github:acme/rocket#62"))
    }

    @Test func aListThatStillShowsThemOpenWithoutTheirPagesKeepsThemAwayAndWaits() async throws {
        LiveFolders.shared.mergedHold = 0.05
        let made = prs(rail)
        merge(63)
        try await Task.sleep(for: .milliseconds(300))

        LiveFolders.shared.apply(.items(rail.filter { $0.key != key(63) }, nil), to: made.id)

        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.key) == [key(64), key(70)])
        #expect(LiveFolders.shared.claimed == ["github:acme/rocket#61", "github:acme/rocket#62"])
        #expect(LiveFolders.shared.folder(made.id)?.hidden == ["github:acme/rocket#63"])
    }

    @Test func aPageReadAfterTheMergeThatSaysMergedConfirmsThem() async throws {
        LiveFolders.shared.mergedHold = 0.05
        let made = prs(rail)
        merge(63)
        try await Task.sleep(for: .milliseconds(300))
        pageSaid(61, .merged)
        pageSaid(62, .merged)

        LiveFolders.shared.apply(.items(rail.filter { $0.key != key(63) }, nil), to: made.id)

        #expect(LiveFolders.shared.claimed.isEmpty)
        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.key) == [key(64), key(70)])
    }

    @Test func aPageReadThatSaysOpenBringsTheRowBackAsItWas() async throws {
        LiveFolders.shared.mergedHold = 0.05
        let seen = Date(timeIntervalSince1970: 1_000)
        let made = prs([pull(61, position: 1), pull(62, position: 2), pull(63, position: 3), pull(64, position: 4)])
        LiveFolders.shared.opened(key(62), space: browser.spaceID, at: seen)
        merge(63)
        try await Task.sleep(for: .milliseconds(300))
        pageSaid(61, .merged)
        pageSaid(62, .open)

        LiveFolders.shared.apply(.items([pull(61, position: 1), pull(62, position: 2, label: "Changes requested"), pull(64, position: 4)], nil), to: made.id)
        browser.syncLive()

        let back = try #require(item(made, 62))
        #expect(back.label == "Changes requested")
        #expect(back.opened == seen)
        #expect(back.arrived == nil)
        #expect(!LiveFolders.shared.turning(key(62)))
        #expect(LiveFolders.shared.claimed.isEmpty)
        #expect(item(made, 61) == nil)
        #expect(LiveFolders.shared.folder(made.id)?.items.map(\.key) == [key(64), key(62)])
        #expect(browser.tabs(in: made.id).compactMap(\.liveKey).contains(key(62)))
    }

    @Test func itsOwnPageSayingOpenDuringTheHoldPutsItBackQuietly() {
        let made = prs(rail)
        merge(63)

        LiveFolders.shared.pageSays(.open, at: URL(string: key(62))!, space: browser.spaceID)

        #expect(item(made, 62)?.label == "Approved")
        #expect(!LiveFolders.shared.turning(key(62)))
        #expect(item(made, 61)?.label == "Merged")
        #expect(LiveFolders.shared.claimed == ["github:acme/rocket#61"])
    }

    @Test func itsOwnPageSayingMergedConfirmsIt() async throws {
        LiveFolders.shared.mergedHold = 0.05
        let made = prs(rail)
        merge(63)
        try await Task.sleep(for: .milliseconds(300))

        LiveFolders.shared.pageSays(.merged, at: URL(string: key(62))!, space: browser.spaceID)

        #expect(LiveFolders.shared.claimed == ["github:acme/rocket#61"])
        #expect(LiveFolders.shared.folder(made.id)?.hidden.contains("github:acme/rocket#62") == true)
    }

    @Test func aStackAcrossTwoFoldersOfOneSpaceTurnsInBoth() {
        let one = prs([pull(62, position: 2), pull(63, position: 3)])
        let two = prs([pull(61, position: 1), pull(62, position: 2)], name: "Reviews")

        merge(63)

        #expect(labels(one) == [62: "Merged", 63: "Merged"])
        #expect(labels(two) == [61: "Merged", 62: "Merged"])
    }

    @Test func anotherSpaceIsLeftAlone() {
        let mine = prs([pull(62, position: 2), pull(63, position: 3)])
        let theirs = prs([pull(61, position: 1), pull(62, position: 2)], name: "Elsewhere", space: UUID())

        merge(63)

        #expect(labels(mine) == [62: "Merged", 63: "Merged"])
        #expect(labels(theirs) == [61: "Approved", 62: "Approved"])
    }

    @Test func aListReadJudgesEachRowByItsOwnLabel() {
        let made = prs(rail)

        LiveFolders.shared.apply(.items(LiveStacks.arranged([pull(61, position: 1), pull(62, position: 2), pull(63, position: 3, label: "Merged"),
                                                              pull(64, position: 4), pull(70)]), nil), to: made.id)

        #expect(LiveFolders.shared.turning(key(63)))
        #expect(labels(made)[62] == "Approved")
    }

    @Test func underReduceMotionTheStackTurnsAtOnceAndNoRowLeads() {
        keepSettings("motion.testReduced")
        Store.settings.set(true, forKey: "motion.testReduced")
        LiveFolders.shared.stackStagger = 5
        let made = prs(rail)

        merge(63)

        #expect(labels(made)[61] == "Merged")
        #expect(browser.tabs(in: made.id).allSatisfy { !$0.leads && !$0.arrives })
    }
}
