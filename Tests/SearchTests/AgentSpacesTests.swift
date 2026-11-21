import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentSpacesTests {
    private var browser: Browser!
    private var work = UUID()
    private var home = UUID()
    private var made: [UUID] = []
    private var questions: [UUID] = []
    private var others: [Browser] = []
    private let here = AgentLinks.shared.here

    init() {
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        keepSetting(Shared.prefs, \.splitView, "splitView")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.closeAll()
        browser.prefs.usesSpaces = true
        browser.prefs.splitView = false
        work = browser.spaceID
        browser.spaces = [Space(id: work, name: "Work", colour: 0, icon: TabIcon(emoji: "💼")),
                          Space(id: home, name: "Home", colour: 1, icon: TabIcon(emoji: "🏠"))]
        AgentBoard.note(browser)
    }

    private func tearDown() {
        for id in questions { AgentDesk.shared.take(id, .dropped) }
        for id in made { AgentLinks.shared.forget(id) }
        AgentLinks.shared.here = here
        for other in others { other.closeAll() }
        others = []
        browser?.switchSpace(to: work)
        browser?.closeAll()
        browser = nil
    }

    private func link(_ name: String, in space: UUID?) -> AgentLink {
        AgentLinks.shared.here = { space }
        let made = AgentLinks.shared.join(.named(UUID().uuidString), name: name)
        AgentLinks.shared.announce(made.id)
        self.made.append(made.id)
        return AgentLinks.shared.link(made.id) ?? made
    }

    private func page(_ name: String, in space: UUID, for link: AgentLink? = nil) -> Tab {
        let tab = Tab(configuration: Web.configuration(space: space))
        tab.space = space
        tab.restore(url: URL(string: "about:blank#\(name)")!, title: name)
        if let link {
            tab.agent = true
            tab.bench = true
            tab.agentTask = link.id
        }
        return tab
    }

    private func rows(_ work: [Tab], _ home: [Tab]) {
        browser.switchSpace(to: self.work)
        browser.showRow(work, active: work.first?.id)
        browser.switchSpace(to: self.home)
        browser.showRow(home, active: home.first?.id)
    }

    private var card: [AgentSession] {
        browser.agentSessions(links: AgentLinks.shared.links.filter { made.contains($0.id) }, front: true)
    }

    private func listed(_ sessions: [AgentSession]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: sessions.map { ($0.link.name, $0.tabs.map(\.title)) })
    }

    private func ask(_ title: String, of link: AgentLink, on tab: Tab?) async -> AgentQuestion? {
        var question = AgentQuestion(kind: .choice(["Yes", "No"]), title: title)
        question.task = link.id
        question.tab = tab?.id
        questions.append(question.id)
        Task { _ = await AgentDesk.shared.ask(question) }
        for _ in 0..<200 {
            if AgentDesk.shared.pending.contains(where: { $0.id == question.id }) { return question }
            await Task.yield()
        }
        return nil
    }

    @Test func aCardListsOnlyTheAgentTabsOfTheSpaceItsWindowShows() {
        let both = link("Both", in: work)
        let away = link("Away", in: work)
        let mail = page("Mail", in: home, for: both)
        let inbox = page("Inbox", in: home, for: away)
        let report = page("Report", in: work, for: both)
        rows([page("Notes", in: work), report], [page("Music", in: home), mail, inbox])

        let atHome = listed(card)
        browser.switchSpace(to: work)
        let atWork = listed(card)

        #expect(atHome == ["Both": ["Mail"], "Away": ["Inbox"]])
        #expect(atWork == ["Both": ["Report"]])
        #expect(browser.linkedTabs == [report.id])
    }

    @Test func theCardsWordsSizeAndPressFollowWhatItLists() {
        let both = link("Both", in: work)
        let away = link("Away", in: work)
        let mail = page("Mail", in: home, for: both)
        let calendar = page("Calendar", in: home, for: both)
        let report = page("Report", in: work, for: both)
        let deck = page("Deck", in: work, for: away)
        deck.agentActing = "Reading"
        rows([page("Notes", in: work), report, deck], [page("Music", in: home), mail, calendar])
        let sessions = card
        let pending = AgentDesk.shared.pending

        let voice = AgentsLayout.voice(sessions.map { ($0.link.title, $0.state(pending: pending)) })
        let sections = browser.agentSections(sessions)
        browser.pressAgent(sessions[0])

        #expect(sessions.map(\.link.name) == ["Both"])
        #expect(voice == AgentsLayout.Voice(title: "Agents", line: "Both · Thinking"))
        #expect(sections == [AgentsLayout.Section(rows: 2, headed: false)])
        #expect(browser.spaceID == home)
        #expect(browser.activeID == mail.id)
    }

    @Test func keepTabsAndCloseTabsTouchOnlyTheTabsTheCardLists() {
        let both = link("Both", in: work)
        let mail = page("Mail", in: home, for: both)
        let calendar = page("Calendar", in: home, for: both)
        let report = page("Report", in: work, for: both)
        rows([page("Notes", in: work), report], [page("Music", in: home), mail, calendar])
        let session = card[0]

        let menu = browser.agentMenu(session)
        menu?.items.first { $0.title == "Keep Tabs" }.map { item in _ = item.target?.perform(item.action, with: item) }
        let kept = !mail.agent && !calendar.agent && report.agent
        browser.switchSpace(to: work)
        let atWork = card
        browser.closeAgentTabs(atWork[0])

        #expect(kept)
        #expect(atWork.map { $0.tabs.map(\.id) } == [[report.id]])
        #expect(!browser.tabs.contains { $0.id == report.id })
        #expect(browser.parked[home]?.tabs.contains { $0.id == mail.id } == true)
    }

    @Test func anAgentWithNoTabYetShowsInTheSpaceItConnectedIn() {
        _ = link("At work", in: work)
        _ = link("At home", in: home)
        rows([page("Notes", in: work)], [page("Music", in: home)])

        let atHome = card.map(\.link.name)
        browser.switchSpace(to: work)
        let atWork = card.map(\.link.name)
        let behind = browser.agentSessions(links: AgentLinks.shared.links.filter { made.contains($0.id) }, front: false).map(\.link.name)

        #expect(atHome == ["At home"])
        #expect(atWork == ["At work"])
        #expect(behind.isEmpty)
    }

    @Test func aLinkWithNoSpaceOrAGoneSpaceShowsAsBefore() {
        _ = link("Nowhere", in: nil)
        _ = link("Gone", in: UUID())
        rows([page("Notes", in: work)], [page("Music", in: home)])

        let atHome = card.map(\.link.name)
        browser.switchSpace(to: work)
        let atWork = card.map(\.link.name)

        #expect(atHome == ["Nowhere", "Gone"])
        #expect(atWork == ["Nowhere", "Gone"])
    }

    @Test func aSpaceRemovedLeavesItsWaitingAgentOnEveryCard() {
        let other = UUID()
        browser.spaces.append(Space(id: other, name: "Other", colour: 2))
        _ = link("Lost", in: other)
        rows([page("Notes", in: work)], [page("Music", in: home)])
        let before = card.map(\.link.name)

        browser.spaces.removeAll { $0.id == other }
        let after = card.map(\.link.name)

        #expect(before.isEmpty)
        #expect(after == ["Lost"])
    }

    @Test func onceItHasTabsItsSpaceAtConnectingNoLongerCounts() {
        let both = link("Both", in: work)
        rows([page("Notes", in: work)], [page("Music", in: home), page("Mail", in: home, for: both)])

        let atHome = card.map(\.link.name)
        browser.switchSpace(to: work)
        let atWork = card.map(\.link.name)

        #expect(atHome == ["Both"])
        #expect(atWork.isEmpty)
    }

    @Test func aTabMovedToAnotherSpaceGoesToThatSpacesCardAtOnce() {
        let both = link("Both", in: work)
        let mail = page("Mail", in: home, for: both)
        let report = page("Report", in: work, for: both)
        rows([page("Notes", in: work), report], [page("Music", in: home), mail])
        browser.switchSpace(to: work)

        let moved = browser.finishMove(report, toSpace: home, quietly: true)
        let atWork = card.map(\.link.name)
        browser.switchSpace(to: home)
        let atHome = listed(card)

        #expect(moved)
        #expect(atWork.isEmpty)
        #expect(atHome["Both"]?.sorted() == ["Mail", "Report"])
    }

    @Test func aTabMovedToAnotherSpaceTakesItsSessionAndTeachesItsFolder() {
        let places = AgentLinks.shared.places
        AgentLinks.shared.places = AgentPlaces(store: nil)
        defer { AgentLinks.shared.places = places }
        let both = link("Both", in: work)
        AgentLinks.shared.give(both.id, folder: "/Users/sam/code/app")
        let report = page("Report", in: work, for: both)
        let notes = page("Notes", in: work)
        rows([notes, report], [page("Music", in: home)])
        browser.switchSpace(to: work)

        let moved = browser.finishMove(report, toSpace: home, quietly: true)
        let after = AgentLinks.shared.link(both.id)

        #expect(moved)
        #expect(after?.space == home)
        #expect(after?.placed == .moved)
        #expect(AgentLinks.shared.places.learned("/Users/sam/code/app") == home)
    }

    @Test func anAgentOpensInItsSessionsSpaceAndAnExplicitSpaceMovesItsHome() async {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        browser.prefs.agentMode = .auto
        let places = AgentLinks.shared.places
        AgentLinks.shared.places = AgentPlaces(store: nil)
        defer { AgentLinks.shared.places = places }
        let box = BrowserToolbox()
        box.browser = browser
        let both = link("Both", in: home)
        AgentLinks.shared.give(both.id, folder: "/Users/sam/code/app")
        rows([page("Notes", in: work)], [page("Music", in: home)])
        browser.switchSpace(to: work)

        let first = ToolReply.data(await box.call("open", ["url": "https://example.com/one"], task: both.id))
        let second = ToolReply.data(await box.call("open", ["url": "https://example.com/two"], task: both.id))
        let asked = ToolReply.data(await box.call("open", ["url": "https://example.com/three", "space": "work"], task: both.id))
        let wrong = await box.call("open", ["url": "https://example.com/four", "space": "Garden"], task: both.id)
        let parked = browser.parked[home]?.tabs.filter(\.agent).map { AgentWorkTabs.short($0.id) } ?? []
        let shown = browser.tabs.filter(\.agent).map { AgentWorkTabs.short($0.id) }
        let placed = first["space"] as? [String: Any]

        #expect(parked.sorted() == [first["id"] as? String, second["id"] as? String].compactMap { $0 }.sorted())
        #expect(shown == [asked["id"] as? String].compactMap { $0 })
        #expect(placed?["name"] as? String == "Home")
        #expect(placed?["why"] as? String == "the space on screen when you connected")
        #expect(placed?["first"] as? Bool == true)
        #expect((second["space"] as? [String: Any])?["first"] as? Bool == false)
        #expect((asked["space"] as? [String: Any])?["name"] as? String == "Work")
        #expect((asked["space"] as? [String: Any])?["kept"] as? Bool == true)
        #expect(AgentLinks.shared.link(both.id)?.space == work)
        #expect(AgentLinks.shared.places.learned("/Users/sam/code/app") == work)
        #expect(wrong.failed)
        #expect(wrong.text?.contains("No space is named Garden") == true)
    }

    @Test func anAgentAskingInAnotherSpaceMarksThatSpaceUntilAnswered() {
        let both = link("Both", in: work)
        let mail = page("Mail", in: home, for: both)
        let report = page("Report", in: work, for: both)
        rows([page("Notes", in: work), report], [page("Music", in: home), mail])
        browser.switchSpace(to: work)
        let still = browser.agentAskingSpaces

        mail.agentMood = .waving
        let asking = browser.agentAskingSpaces
        let workCard = card.map { $0.state(pending: AgentDesk.shared.pending).attention }
        mail.agentMood = .reading
        let answered = browser.agentAskingSpaces

        #expect(still.isEmpty)
        #expect(asking == [home])
        #expect(workCard == [false])
        #expect(answered.isEmpty)
    }

    @Test func theMarkGoesWhenHeEntersTheAskingSpace() {
        let both = link("Both", in: work)
        let mail = page("Mail", in: home, for: both)
        rows([page("Notes", in: work)], [page("Music", in: home), mail])
        browser.switchSpace(to: work)
        mail.agentMood = .waving
        let away = browser.agentAskingSpaces

        browser.switchSpace(to: home)
        let there = browser.agentAskingSpaces
        let homeCard = card.map { $0.state(pending: AgentDesk.shared.pending).attention }

        #expect(away == [home])
        #expect(there.isEmpty)
        #expect(homeCard == [true])
    }

    @Test func aQuestionOnATabInAnotherSpaceAsksOnlyThere() async throws {
        let both = link("Both", in: work)
        let mail = page("Mail", in: home, for: both)
        let report = page("Report", in: work, for: both)
        rows([page("Notes", in: work), report], [page("Music", in: home), mail])
        browser.switchSpace(to: work)

        let asked = try #require(await ask("Which account?", of: both, on: mail))
        let pending = AgentDesk.shared.pending
        let workState = card.map { $0.state(pending: pending) }
        let marked = browser.agentAskingSpaces
        AgentDesk.shared.take(asked.id, .picked(0))
        let answered = browser.agentAskingSpaces

        #expect(workState.map(\.attention) == [false])
        #expect(marked == [home])
        #expect(answered.isEmpty)
    }

    @Test func aWaitingAgentsQuestionMarksTheSpaceItConnectedIn() async throws {
        let waiting = link("Waiting", in: home)
        rows([page("Notes", in: work)], [page("Music", in: home)])
        browser.switchSpace(to: work)

        let asked = try #require(await ask("Which day?", of: waiting, on: nil))
        let marked = browser.agentAskingSpaces
        let workCard = card.map(\.link.name)
        AgentDesk.shared.take(asked.id, .picked(0))

        #expect(marked == [home])
        #expect(workCard.isEmpty)
    }

    @Test func theSpaceIconsMarkComesAndGoesWithTheAsk() async {
        let both = link("Both", in: work)
        let mail = page("Mail", in: home, for: both)
        rows([page("Notes", in: work)], [page("Music", in: home), mail])
        browser.switchSpace(to: work)
        let spot = SpaceSpotView(browser: browser, kind: .space(home), icon: TabIcon(emoji: "🏠"), here: false, next: false)
        let quiet = spot.asking

        mail.agentMood = .waving
        for _ in 0..<100 where !spot.asking { try? await Task.sleep(for: .milliseconds(5)) }
        let lit = spot.asking
        let said = spot.accessibilityValue() as? String
        mail.agentMood = .reading
        for _ in 0..<100 where spot.asking { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(!quiet)
        #expect(lit)
        #expect(said == "An agent needs you")
        #expect(!spot.asking)
    }

    @Test func anotherWindowStillShowsOnlyItsOwnTabs() {
        let both = link("Both", in: work)
        let mail = page("Mail", in: home, for: both)
        rows([page("Notes", in: work)], [page("Music", in: home), mail])
        let other = Browser(record: WindowRecord())
        others.append(other)
        other.closeAll()
        other.spaces = browser.spaces
        AgentBoard.note(other)
        let elsewhere = page("Elsewhere", in: other.spaceID, for: both)
        other.showRow([page("Desk", in: other.spaceID), elsewhere], active: elsewhere.id)

        let mine = listed(card)
        let theirs = listed(other.agentSessions(links: AgentLinks.shared.links.filter { made.contains($0.id) }, front: true))

        #expect(mine == ["Both": ["Mail"]])
        #expect(theirs == ["Both": ["Elsewhere"]])
    }

    @Test func whatAgentsReadStillNamesEveryTabTheAgentHolds() {
        let both = link("Both", in: work)
        let mail = page("Mail", in: home, for: both)
        let report = page("Report", in: work, for: both)
        rows([page("Notes", in: work), report], [page("Music", in: home), mail])

        let held = Set(AgentBoard.allTabs(of: both.id).map(\.tab.id))
        let row = AgentLinks.shared.row(both)

        #expect(held == [mail.id, report.id])
        #expect(row["tabs"] as? Int == 2)
    }
}
