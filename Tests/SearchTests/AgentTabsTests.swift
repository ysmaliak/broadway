import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentTabsTests {
    private var browser: Browser!
    private var box: BrowserToolbox!

    init() {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        let mine = Tab(configuration: Web.configuration(space: browser.spaceID))
        mine.restore(url: URL(string: "https://example.com/mine")!, title: "Mine")
        browser.showRow([mine], active: mine.id)
        box = BrowserToolbox()
        box.browser = browser
        browser.prefs.agentMode = .auto
    }

    private func tearDown() {
        browser?.closeAll()
        browser = nil
    }

    private func opened(_ address: String, task: UUID?) async -> Tab {
        let before = Set(browser.tabs.map(\.id))
        _ = await box.call("open", ["url": address], task: task)
        return browser.tabs.first { !before.contains($0.id) }!
    }

    @Test func anAgentTabStaysBehindAndOutOfTheSession() async {
        let front = browser.activeID

        let tab = await opened("https://example.com/agent", task: UUID())

        #expect(browser.activeID == front)
        #expect(tab.agent)
        #expect(tab.bench)
        #expect(!browser.tabsInSession.contains(tab.id))
    }

    @Test func twoTabsOfATaskGatherInAFolderAndOneDoesNot() async {
        let task = UUID()

        let first = await opened("https://example.com/1", task: task)
        let alone = browser.taskFolders.isEmpty
        let second = await opened("https://example.com/2", task: task)
        let other = await opened("https://example.com/3", task: UUID())

        #expect(alone)
        #expect(browser.taskFolders.count == 1)
        #expect(browser.taskFolders.first?.tabs.map(\.id) == [first.id, second.id])
        #expect(browser.gatheredTabs == [first.id, second.id])
        #expect(!browser.gatheredTabs.contains(other.id))
    }

    @Test func aFolderSaysNeedsYouWhileATabWaves() async {
        let task = UUID()
        let first = await opened("https://example.com/1", task: task)
        _ = await opened("https://example.com/2", task: task)

        let before = browser.taskFolders.first?.needsYou
        first.agentMood = .waving

        #expect(before == false)
        #expect(browser.taskFolders.first?.needsYou == true)
    }

    @Test func finishingATaskMarksItsTabsOnce() async {
        let task = UUID()
        let tab = await opened("https://example.com/1", task: task)
        let early = Date(timeIntervalSinceNow: -100)

        AgentBoard.finish(task, mood: .failed, at: early)
        AgentBoard.finish(task, mood: .done)

        #expect(tab.agentMood == .failed)
        #expect(tab.agentFinished == early)
    }

    @Test func finishingATaskDismissesItsPageDialogOnce() {
        let task = UUID()
        let tab = Tab()
        tab.agent = true
        tab.agentTask = task
        browser.showRow(browser.tabs + [tab], active: browser.activeID)
        AgentBoard.note(browser)
        var answers: [Bool] = []
        let question = PaneQuestion(tab: tab.id, host: "example.com", message: "Continue?", kind: .confirm) { ok, _ in answers.append(ok) }
        tab.agentDialog = question

        AgentBoard.finish(task, mood: .done)
        AgentBoard.finish(task, mood: .done)
        let cleared = tab.agentDialog == nil
        tab.close()

        #expect(cleared)
        #expect(!question.open)
        #expect(answers == [false])
    }

    @Test func closingAnMCPConnectionDismissesItsPageDialogOnce() {
        AgentLinks.wire()
        let connection = UUID()
        let link = AgentLinks.shared.join(.connection(connection), name: "Dialog regression")
        defer { AgentLinks.shared.forget(link.id) }
        let tab = Tab()
        tab.agent = true
        tab.agentTask = link.id
        browser.showRow(browser.tabs + [tab], active: browser.activeID)
        AgentBoard.note(browser)
        var answers: [Bool] = []
        let question = PaneQuestion(tab: tab.id, host: "example.com", message: "Name?", kind: .prompt("")) { ok, _ in answers.append(ok) }
        tab.agentDialog = question

        AgentLinks.shared.endConnection(connection)
        AgentLinks.shared.endConnection(connection)
        let cleared = tab.agentDialog == nil
        tab.close()

        #expect(cleared)
        #expect(tab.agentFinished != nil)
        #expect(!question.open)
        #expect(answers == [false])
    }

    @Test func keepingATabMakesItTheUsersOwn() async {
        let task = UUID()
        let tab = await opened("https://example.com/1", task: task)

        browser.keepAgentTab(tab)

        #expect(!tab.agent)
        #expect(!tab.bench)
        #expect(tab.agentTask == nil)
        #expect(browser.tabsInSession.contains(tab.id))
    }

    @Test func closingYourTabNeverBringsAnAgentTabForward() async {
        let mine = browser.active!
        let agent = await opened("https://example.com/agent", task: UUID())

        browser.close(mine)

        #expect(browser.activeID != agent.id)
        #expect(!(browser.active?.agent ?? true))
        #expect(!agent.agentSeen)
    }

    @Test func draggingFarEnoughLeavesTheFolder() {
        #expect(!DragOutToKeep.leftFolder(CGSize(width: 10, height: 20), reach: 90))
        #expect(DragOutToKeep.leftFolder(CGSize(width: 10, height: 100), reach: 90))
        #expect(DragOutToKeep.leftFolder(CGSize(width: 70, height: 0), reach: 90))
    }

    @Test func aMoodFollowsWhatTheAgentDoes() {
        #expect(AgentMood.doing("Typing") == .typing)
        #expect(AgentMood.doing("Pressing a key") == .typing)
        #expect(AgentMood.doing("Reading") == .reading)
    }

    @Test func aChosenTabCountsAsOpened() async {
        let tab = await opened("https://example.com/1", task: UUID())

        browser.select(tab)

        #expect(tab.agentSeen)
    }
}
