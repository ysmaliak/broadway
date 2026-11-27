import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentLeadTabTests {
    private var windows: [NSWindow] = []
    private var browser: Browser!

    init() {
        addTeardownBlock { try await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        AgentLinks.shared.reset()
        keepSetting(AgentsFolds.shared, \.folded, AgentsFolds.key)
        keepSettings("motion.testReduced")
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        Store.settings.set(false, forKey: "motion.testReduced")
        AgentsFolds.shared.open = []
        AgentsFolds.shared.whole = []
        AgentsFolds.shared.folded = false
        browser = Browser(record: WindowRecord())
        let mine = Search.Tab(configuration: Web.configuration(space: browser.spaceID))
        mine.restore(url: URL(string: "https://example.com/mine")!, title: "Mine")
        browser.showRow([mine], active: mine.id)
        AgentBoard.note(browser)
    }

    private func tearDown() async throws {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
        if let first = browser?.spaces.first?.id { browser?.switchSpace(to: first) }
        browser?.closeAll()
        browser = nil
        AgentLinks.shared.reset()
        AgentsFolds.shared.open = []
        AgentsFolds.shared.whole = []
        try await Task.sleep(for: .milliseconds(100))
    }

    private func agentTab(_ link: AgentLink, _ title: String, acting: String? = nil, mood: AgentMood? = .reading) -> Search.Tab {
        let tab = Search.Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.restore(url: URL(string: "https://example.com/\(UUID().uuidString)")!, title: title)
        tab.agent = true
        tab.agentTask = link.id
        tab.agentMood = mood
        tab.agentActing = acting
        browser.showRow(browser.tabs + [tab], active: browser.activeID ?? tab.id)
        return tab
    }

    private func session(_ link: AgentLink) throws -> AgentSession {
        try #require(browser.agentSessions(links: AgentLinks.shared.links, front: true).first { $0.id == link.id })
    }

    private func shownArea() -> AgentsAreaView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 700))
        root.wantsLayer = true
        let area = AgentsAreaView(browser: browser)
        area.column = 700
        area.aim(AgentsAreaView.height(of: browser, column: 700))
        area.frame = NSRect(x: 0, y: 0, width: 280, height: area.room)
        root.addSubview(area)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 280, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        window.contentView = root
        window.orderFrontRegardless()
        windows.append(window)
        area.layoutSubtreeIfNeeded()
        return area
    }

    private func settle(_ area: AgentsAreaView) async throws {
        try await Task.sleep(for: .milliseconds(80))
        area.aim(AgentsAreaView.height(of: browser, column: 700))
        area.frame.size.height = area.room
        area.layoutSubtreeIfNeeded()
    }

    private func listed(_ area: AgentsAreaView) -> [NSView] {
        area.kitSubviews(of: NSScrollView.self).first?.documentView?.subviews ?? []
    }

    private func head(_ title: String, in area: AgentsAreaView) throws -> AgentHeadView {
        try #require(listed(area).compactMap { $0 as? AgentHeadView }.first { $0.look.title == title })
    }

    private func rows(_ area: AgentsAreaView) -> [AgentRowView] {
        listed(area).compactMap { $0 as? AgentRowView }
    }

    @Test func everyAgentStartsFoldedUnderItsHeading() throws {
        let links = AgentLinks.shared
        let claude = links.join(.named("claude"), name: "Claude Code")
        let codex = links.join(.named("codex"), name: "Codex")
        for title in ["Pull requests", "Issue 42", "Release notes"] { _ = agentTab(claude, title) }
        _ = agentTab(codex, "Inbox")

        let area = shownArea()
        let sections = browser.agentSections(browser.agentSessions(links: links.links, front: true))

        #expect(sections == [AgentsLayout.Section(rows: 2, headed: true), AgentsLayout.Section(rows: 0, headed: true)])
        #expect(sections.allSatisfy { !$0.open })
        #expect(listed(area).compactMap { $0 as? AgentHeadView }.count == 2)
        #expect(rows(area).isEmpty)
        #expect(AgentsAreaView.height(of: browser, column: 700) == AgentsLayout.row + 2 * AgentsLayout.step + AgentsLayout.margin)
    }

    @Test func theHeadingNamesTheTabTheAgentIsOnAndFollowsIt() async throws {
        let links = AgentLinks.shared
        let claude = links.join(.named("claude"), name: "Claude Code")
        let codex = links.join(.named("codex"), name: "Codex")
        let pulls = agentTab(claude, "Pull requests", acting: "Reading")
        let notes = agentTab(claude, "Release notes")
        _ = agentTab(codex, "Inbox")
        let area = shownArea()
        let heading = try head("Claude Code", in: area)

        let first = heading.look.line
        let firstLead = browser.agentLead(try session(claude), pending: [])?.id
        pulls.agentActing = nil
        notes.agentActing = "Typing"
        try await settle(area)
        let second = heading.look.line
        notes.agentActing = nil
        try await settle(area)
        let resting = heading.look.line
        let restingLead = browser.agentLead(try session(claude), pending: [])?.id

        #expect(first == "Reading · Pull requests")
        #expect(firstLead == pulls.id)
        #expect(second == "Typing · Release notes")
        #expect(resting == "Thinking · Release notes")
        #expect(restingLead == notes.id)
        #expect(heading.look.title == "Claude Code")
    }

    @Test func theSecondLineRollsWhenTheAgentMovesToAnotherTabAndNotOtherwise() async throws {
        let links = AgentLinks.shared
        let claude = links.join(.named("claude"), name: "Claude Code")
        let codex = links.join(.named("codex"), name: "Codex")
        let pulls = agentTab(claude, "Pull requests", acting: "Reading")
        let notes = agentTab(claude, "Release notes")
        _ = agentTab(codex, "Inbox")
        let area = shownArea()
        let heading = try head("Claude Code", in: area)
        heading.layoutSubtreeIfNeeded()
        func rolls() -> Int? { heading.benchState["rolls"] as? Int }
        let fresh = rolls()

        pulls.agentActing = "Typing"
        try await settle(area)
        let sameTab = (rolls(), heading.look.line)
        pulls.agentActing = nil
        notes.agentActing = "Reading"
        try await settle(area)
        let moved = (rolls(), heading.look.line)
        Store.settings.set(true, forKey: "motion.testReduced")
        notes.agentActing = nil
        pulls.agentActing = "Reading"
        try await settle(area)
        let reduced = (rolls(), heading.look.line)

        #expect(fresh == 0)
        #expect(sameTab.0 == 0 && sameTab.1 == "Typing · Pull requests")
        #expect(moved.0 == 1 && moved.1 == "Reading · Release notes")
        #expect(reduced.0 == 1 && reduced.1 == "Reading · Pull requests")
        #expect(Motion.kitRoll == .none)
    }

    @Test func theLeadIsTheTabThatAsksThenTheOneActingThenTheLastOneLed() {
        let first = UUID(), second = UUID(), third = UUID()
        let fresh = [(id: first, stamp: 0), (id: second, stamp: 0), (id: third, stamp: 0)]
        let led = [(id: first, stamp: 1), (id: second, stamp: 3), (id: third, stamp: 2)]

        #expect(AgentsLayout.lead(asking: third, acting: second, stamps: led) == third)
        #expect(AgentsLayout.lead(asking: nil, acting: first, stamps: led) == first)
        #expect(AgentsLayout.lead(asking: nil, acting: nil, stamps: led) == second)
        #expect(AgentsLayout.lead(asking: nil, acting: nil, stamps: fresh) == first)
        #expect(AgentsLayout.lead(asking: nil, acting: nil, stamps: []) == nil)
    }

    @Test func theSecondLineSaysWhatTheAgentDoesAndWhere() {
        let working = AgentsLayout.headline(.working("Reading example.org"), tab: "Release notes", acting: "Reading")
        let thinking = AgentsLayout.headline(.idle, tab: "Release notes", acting: nil)
        let asking = AgentsLayout.headline(.needsYou("Send on example.org?"), tab: "Inbox", acting: nil)
        let done = AgentsLayout.headline(.done("Sent it"), tab: "Inbox", acting: nil)
        let tabless = AgentsLayout.headline(.working("Running the tests"), tab: nil, acting: nil)
        let quiet = AgentsLayout.headline(.quiet("Opening example.org"), tab: "Inbox", acting: nil)
        let finished = AgentsLayout.headline(.finished("Finished after reading example.org"), tab: "Inbox", acting: nil)

        #expect(working == "Reading · Release notes")
        #expect(thinking == "Thinking · Release notes")
        #expect(asking == "Needs you: Send on example.org?")
        #expect(done == "Sent it")
        #expect(tabless == "Running the tests")
        #expect(quiet == "Idle · Inbox")
        #expect(finished == "Finished after reading example.org")
    }

    @Test func theCountIsTheTabsInTheFoldWithNoPlusAndNoneWhenEmptyOrOpen() async throws {
        let links = AgentLinks.shared
        let claude = links.join(.named("claude"), name: "Claude Code")
        let codex = links.join(.named("codex"), name: "Codex")
        for title in ["Pull requests", "Issue 42", "Release notes"] { _ = agentTab(claude, title) }
        _ = agentTab(codex, "Inbox")
        let area = shownArea()
        let full = try head("Claude Code", in: area)
        let lone = try head("Codex", in: area)

        let shut = (full.look.count, full.count.text, full.count.showing)
        let empty = (lone.look.count, lone.count.showing, lone.look.chevron)
        AgentsFolds.shared.toggle(claude.id)
        try await settle(area)
        let open = (full.look.count, full.count.showing, rows(area).count)

        #expect(shut.0 == 2 && shut.1 == "2" && shut.2)
        #expect(empty.0 == nil && !empty.1 && !empty.2)
        #expect(open.0 == nil && !open.1 && open.2 == 2)
        #expect(AgentsLayout.count(AgentsLayout.Section(rows: 2, headed: true)) == 2)
        #expect(AgentsLayout.count(AgentsLayout.Section(rows: 0, headed: true)) == nil)
        #expect(AgentsLayout.count(AgentsLayout.Section(rows: 2, headed: true, open: true)) == nil)
        #expect(AgentsLayout.count(AgentsLayout.Section(rows: 2)) == nil)
    }

    @Test func theCountIsTheFoldersOwnChipAtTheFoldersPlace() throws {
        let folders: KeyPath<GroupHeadingView, SideCountView> = \.chipFold
        let links = AgentLinks.shared
        let claude = links.join(.named("claude"), name: "Claude Code")
        let codex = links.join(.named("codex"), name: "Codex")
        for title in ["Pull requests", "Issue 42", "Release notes"] { _ = agentTab(claude, title) }
        _ = agentTab(codex, "Inbox")
        let area = shownArea()
        let heading = try head("Claude Code", in: area)
        heading.layoutSubtreeIfNeeded()

        let chip = heading.count.frame

        #expect(folders == \GroupHeadingView.chipFold)
        #expect(SideCountView.font == NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium))
        #expect(chip.height == 17)
        #expect(chip.maxX == heading.bounds.maxX - SideGrid.lead)
        #expect(chip.width == heading.count.width)
        #expect(abs(chip.midY - heading.bounds.midY) <= 0.5)
    }

    @Test func onHoverTheCountGivesWayToTheSidebarsCloseButton() throws {
        let links = AgentLinks.shared
        let claude = links.join(.named("claude"), name: "Claude Code")
        let codex = links.join(.named("codex"), name: "Codex")
        for title in ["Pull requests", "Issue 42", "Release notes"] { _ = agentTab(claude, title) }
        _ = agentTab(codex, "Inbox")
        let area = shownArea()
        let heading = try head("Claude Code", in: area)

        let rest = (heading.close.isHidden, heading.count.showing)
        heading.benchPillHover(true)
        heading.layoutSubtreeIfNeeded()
        let over = (heading.close.isHidden, heading.count.showing, heading.count.yields, heading.close.frame)
        heading.benchPillHover(false)
        let after = (heading.close.isHidden, heading.count.showing)
        let slots = AgentsLayout.rowSlots(width: heading.bounds.width, height: heading.bounds.height)

        #expect(rest.0 && rest.1)
        #expect(!over.0 && !over.1 && over.2)
        #expect(over.3 == slots.close)
        #expect(after.0 && after.1)
        #expect(heading.close.accessibilityLabel() == "Close Claude Code's tabs")
    }

    @Test func theHeadingsCloseClosesAllOfThatAgentsTabsAndARowsClosesOne() async throws {
        let links = AgentLinks.shared
        let claude = links.join(.named("claude"), name: "Claude Code")
        let codex = links.join(.named("codex"), name: "Codex")
        let claudes = ["Pull requests", "Issue 42", "Release notes"].map { agentTab(claude, $0) }
        let codexes = ["Inbox", "Calendar", "Drafts"].map { agentTab(codex, $0) }
        AgentsFolds.shared.toggle(codex.id)
        let area = shownArea()
        let row = try #require(rows(area).first { $0.tab.id == codexes[2].id })

        _ = row.close.accessibilityPerformPress()
        let afterRow = Set(browser.tabs.map(\.id))
        _ = try head("Claude Code", in: area).close.accessibilityPerformPress()
        let afterHeading = Set(browser.tabs.map(\.id))

        #expect(!afterRow.contains(codexes[2].id))
        #expect(afterRow.isSuperset(of: claudes.map(\.id) + [codexes[0].id, codexes[1].id]))
        #expect(afterHeading.isDisjoint(with: claudes.map(\.id)))
        #expect(afterHeading.isSuperset(of: [codexes[0].id, codexes[1].id]))
        #expect(browser.tabs.contains { !$0.agent })
    }

    @Test func aFinishedAgentsHeadingStillClosesItsTabsOnHover() throws {
        let links = AgentLinks.shared
        let claude = links.join(.named("claude"), name: "Claude Code")
        let codex = links.join(.named("codex"), name: "Codex")
        let done = ["Pull requests", "Issue 42"].map { agentTab(claude, $0) }
        _ = agentTab(codex, "Inbox")
        links.end(claude.id, .done("Merged both"))
        let area = shownArea()
        let heading = try head("Claude Code", in: area)

        let rest = heading.close.isHidden
        heading.benchPillHover(true)
        let over = heading.close.isHidden
        _ = heading.close.accessibilityPerformPress()

        #expect(rest && !over)
        #expect(heading.look.line == "Merged both")
        #expect(heading.look.count == 1)
        #expect(Set(browser.tabs.map(\.id)).isDisjoint(with: done.map(\.id)))
    }

    @Test func needsYouOpensNothingAndAPressGoesToTheTabThatAsks() async throws {
        let links = AgentLinks.shared
        let claude = links.join(.named("claude"), name: "Claude Code")
        let codex = links.join(.named("codex"), name: "Codex")
        _ = agentTab(claude, "Pull requests")
        _ = agentTab(codex, "Inbox", acting: "Reading")
        let asking = agentTab(codex, "Drafts")
        let area = shownArea()
        let heading = try head("Codex", in: area)
        let calm = heading.look

        asking.agentMood = .waving
        try await settle(area)
        let asked = heading.look
        let opened = AgentsFolds.shared.open
        let listedRows = rows(area).count
        heading.press?()

        #expect(!calm.attention && calm.line == "Reading · Inbox")
        #expect(asked.attention && asked.line == "Needs you")
        #expect(asked.roll != calm.roll)
        #expect(opened.isEmpty && listedRows == 0)
        #expect(!AgentsFolds.shared.folded)
        #expect(browser.activeID == asking.id)
        #expect(AgentsFolds.shared.open.isEmpty)
    }

    @Test func thePartThatSelectsAndThePartThatFoldsAreTheTabListsOwn() async throws {
        let links = AgentLinks.shared
        let claude = links.join(.named("claude"), name: "Claude Code")
        let codex = links.join(.named("codex"), name: "Codex")
        let lead = agentTab(claude, "Pull requests", acting: "Reading")
        let rest = ["Issue 42", "Release notes"].map { agentTab(claude, $0) }
        _ = agentTab(codex, "Inbox")
        let area = shownArea()
        let heading = try head("Claude Code", in: area)
        heading.layoutSubtreeIfNeeded()
        let zone = heading.zone

        heading.press?()
        let selected = browser.activeID
        let stillShut = AgentsFolds.shared.open.isEmpty
        heading.fold?()
        try await settle(area)
        let inside = rows(area).map(\.tab.id)

        #expect(heading.folds(at: NSPoint(x: zone.midX, y: zone.midY)))
        #expect(!heading.folds(at: NSPoint(x: 8, y: heading.bounds.midY)))
        #expect(!heading.folds(at: NSPoint(x: zone.midX, y: heading.bounds.maxY - 2)))
        #expect(zone.width >= StackFoldButton.width && zone.height >= StackFoldButton.width)
        #expect(selected == lead.id && stillShut)
        #expect(AgentsFolds.shared.open == [claude.id])
        #expect(inside == rest.map(\.id))
        #expect(heading.look.selected && heading.look.open)
        #expect(try !head("Codex", in: area).look.chevron)
    }

    @Test func fourFoldedAgentsStayUnderTheCap() throws {
        let links = AgentLinks.shared
        for name in ["Claude Code", "Codex", "Nightly check", "Mail sorter"] {
            let link = links.join(.named(name), name: name)
            for title in ["One", "Two", "Three"] { _ = agentTab(link, "\(name) \(title)") }
        }
        let folded = Array(repeating: AgentsLayout.Section(rows: 2, headed: true), count: 4)
        let open = folded.map { AgentsLayout.Section(rows: $0.rows, headed: true, open: true) }

        let height = AgentsAreaView.height(of: browser, column: 700)
        let cap = 700 * AgentsLayout.share + AgentsLayout.margin

        #expect(height == AgentsLayout.row + 4 * AgentsLayout.step + AgentsLayout.margin)
        #expect(height < cap)
        #expect(AgentsLayout.height(folded, folded: false, column: 700) == height)
        #expect(AgentsLayout.height(open, folded: false, column: 700) == cap)
        #expect(AgentsLayout.content(open) == 12 * AgentsLayout.step)
    }

    @Test func theCardsEntranceAndExitTravelAndFadeOnlyWhenTheSameSceneIsReady() {
        #expect(AgentsLayout.presence(from: 0, to: 118, ready: true, reduced: false) == .travels)
        #expect(AgentsLayout.presence(from: 118, to: 0, ready: true, reduced: false) == .travels)
        #expect(AgentsLayout.presence(from: 118, to: 192, ready: true, reduced: false) == .travels)
        #expect(AgentsLayout.presence(from: 0, to: 118, ready: false, reduced: false) == .still)
        #expect(AgentsLayout.presence(from: 0, to: 118, ready: true, reduced: true) == .fades)
        #expect(AgentsLayout.presence(from: 118, to: 0, ready: true, reduced: true) == .fades)
        #expect(AgentsLayout.presence(from: 118, to: 192, ready: true, reduced: true) == .still)
        #expect(AgentsLayout.presence(from: 118, to: 118, ready: true, reduced: false) == .still)
    }

    @Test func theCardEntersAndLeavesOnTheCoverSpringWithAFade() async throws {
        let links = AgentLinks.shared
        let area = shownArea()
        let empty = (area.room, area.moving)

        let claude = links.join(.named("claude"), name: "Claude Code")
        _ = agentTab(claude, "Pull requests")
        let goal = AgentsAreaView.height(of: browser, column: 700)
        area.aim(goal)
        let entering = (area.room, area.moving, area.fading, area.veiled)
        try await Task.sleep(for: .milliseconds(900))
        let entered = (area.room, area.moving, area.presence)

        links.reset()
        area.aim(AgentsAreaView.height(of: browser, column: 700))
        let leaving = (area.room, area.moving, area.fading, area.veiled)
        try await Task.sleep(for: .milliseconds(900))
        let left = (area.room, area.moving)

        #expect(empty.0 == 0 && !empty.1)
        #expect(goal > 0)
        #expect(entering.0 < goal && entering.1 && entering.2)
        #expect(entering.3 == AgentsAreaView.Veil(from: 0, to: 1, lag: SideLook.growLag, length: SideLook.growFade))
        #expect(entered.0 == goal && !entered.1 && entered.2 == 1)
        #expect(leaving.0 == goal && leaving.1 && leaving.2)
        #expect(leaving.3 == AgentsAreaView.Veil(from: 1, to: 0, lag: 0, length: AgentsAreaView.crossfade))
        #expect(left.0 == 0 && !left.1)
        #expect(Motion.kitCover == .spring(.cover))
    }

    @Test func withReduceMotionTheCardOnlyFades() async throws {
        Store.settings.set(true, forKey: "motion.testReduced")
        let links = AgentLinks.shared
        let area = shownArea()

        let claude = links.join(.named("claude"), name: "Claude Code")
        _ = agentTab(claude, "Pull requests")
        let goal = AgentsAreaView.height(of: browser, column: 700)
        area.aim(goal)
        let entering = (area.room, area.moving, area.fading, area.veiled)
        try await Task.sleep(for: .milliseconds(400))

        links.reset()
        area.aim(AgentsAreaView.height(of: browser, column: 700))
        let leaving = (area.room, area.moving, area.fading, area.veiled)
        try await Task.sleep(for: .milliseconds(500))
        let left = (area.room, area.moving)

        #expect(entering.0 == goal && !entering.1 && entering.2)
        #expect(entering.3 == AgentsAreaView.Veil(from: 0, to: 1, lag: 0, length: Motion.reducedFade))
        #expect(leaving.0 == goal && !leaving.1 && leaving.2)
        #expect(leaving.3 == AgentsAreaView.Veil(from: 1, to: 0, lag: 0, length: AgentsAreaView.reducedLeave))
        #expect(left.0 == 0 && !left.1)
        #expect(area.trace.isEmpty)
        #expect(AgentsAreaView.reducedLeave <= Motion.reducedFade && SideLook.growFade <= Motion.reducedFade)
    }

    @Test func aSwitchOfSpaceDrawsTheCardAtOnce() async throws {
        browser.prefs.usesSpaces = true
        let work = browser.spaceID, home = UUID()
        browser.spaces = [Space(id: work, name: "Work", colour: 0, icon: TabIcon(emoji: "💼")),
                          Space(id: home, name: "Home", colour: 1, icon: TabIcon(emoji: "🏠"))]
        let claude = AgentLinks.shared.join(.named("claude"), name: "Claude Code")
        browser.switchSpace(to: home)
        let tab = Search.Tab(configuration: Web.configuration(space: home))
        tab.space = home
        tab.restore(url: URL(string: "about:blank#mail")!, title: "Mail")
        tab.agent = true
        tab.agentTask = claude.id
        browser.showRow([tab], active: tab.id)
        browser.switchSpace(to: work)
        let area = shownArea()
        let atWork = area.room

        browser.switchSpace(to: home)
        let goal = AgentsAreaView.height(of: browser, column: 700)
        area.aim(goal)
        let atHome = (area.room, area.moving, area.fading, area.presence)
        browser.switchSpace(to: work)
        area.aim(AgentsAreaView.height(of: browser, column: 700))
        let back = (area.room, area.moving, area.fading)

        #expect(atWork == 0 && goal > 0)
        #expect(atHome.0 == goal && !atHome.1 && !atHome.2 && atHome.3 == 1)
        #expect(back.0 == 0 && !back.1 && !back.2)
    }

    @Test func aChangeOfColumnDrawsTheCardAtOnce() {
        let links = AgentLinks.shared
        let area = shownArea()
        let claude = links.join(.named("claude"), name: "Claude Code")
        _ = agentTab(claude, "Pull requests")
        let goal = AgentsAreaView.height(of: browser, column: 700)

        area.column = 640
        area.aim(goal)

        #expect(area.room == goal)
        #expect(!area.moving && !area.fading)
        #expect(area.presence == 1)
    }
}
