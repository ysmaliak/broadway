import Foundation
import Testing
@testable import Search

private actor Heard {
    private(set) var words: [[String]] = []

    func add(_ said: [String]) { words.append(said) }
}

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct AgentSetupTests {
    private func made(open: Bool = true, available: Bool = true, refreshes: Bool = false, linkTaken: Bool = true, staying: Bool = true) -> (AgentSetup, Heard, UserDefaults) {
        let name = "agent-setup-tests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let heard = Heard()
        let setup = AgentSetup(store: store)
        setup.runner = { words in
            await heard.add(words)
            return true
        }
        setup.open = { open }
        setup.available = { available }
        setup.refreshes = { refreshes }
        setup.linkTaken = { linkTaken }
        setup.staying = { staying }
        return (setup, heard, store)
    }

    @Test func turningOnSetsUpAndNothingElseDoes() {
        #expect(AgentCommand.setsUp(.turned(wasOn: false), isOn: true, marked: false, open: true))
        #expect(AgentCommand.setsUp(.turned(wasOn: false), isOn: true, marked: true, open: true))
        #expect(!AgentCommand.setsUp(.turned(wasOn: true), isOn: true, marked: false, open: true))
        #expect(!AgentCommand.setsUp(.turned(wasOn: true), isOn: false, marked: false, open: true))
        #expect(!AgentCommand.setsUp(.turned(wasOn: false), isOn: false, marked: false, open: true))
        #expect(!AgentCommand.setsUp(.turned(wasOn: false), isOn: true, marked: false, open: false))
    }

    @Test func aLaunchSetsUpOnlyWhereAgentsAreOnAndNoMarkIsKept() {
        #expect(AgentCommand.setsUp(.launch, isOn: true, marked: false, open: true))
        #expect(!AgentCommand.setsUp(.launch, isOn: true, marked: true, open: true))
        #expect(!AgentCommand.setsUp(.launch, isOn: false, marked: false, open: true))
        #expect(!AgentCommand.setsUp(.launch, isOn: true, marked: false, open: false))
    }

    @Test func theGuardOpensForThePersonAndForATestWorldWithItsOwnHome() {
        #expect(AgentCommand.opensSetup(world: nil, testing: false, unitTests: false, environment: [:]))
        #expect(!AgentCommand.opensSetup(world: "test", testing: true, unitTests: false, environment: [:]))
        #expect(!AgentCommand.opensSetup(world: "test", testing: true, unitTests: false, environment: ["BROADWAY_HOME": ""]))
        #expect(AgentCommand.opensSetup(world: "probe", testing: true, unitTests: false, environment: ["BROADWAY_HOME": "/tmp/invented-home"]))
        #expect(!AgentCommand.opensSetup(world: "swift-tests", testing: true, unitTests: true, environment: ["BROADWAY_HOME": "/tmp/invented-home"]))
        #expect(!AgentCommand.opensSetup(world: nil, testing: true, unitTests: false, environment: ["BROADWAY_HOME": "/tmp/invented-home"]))
    }

    @Test func theWordsAreOnlyClaudeAndCodexAndTheCommandWhenNothingIsThere() {
        #expect(AgentCommand.setupWords == ["setup", "claude", "codex"])
        #expect(AgentCommand.setupAndLinkWords == ["setup", "command", "claude", "codex"])
        #expect(AgentCommand.setupWords(somethingAtLink: true, staying: true) == ["setup", "claude", "codex"])
        #expect(AgentCommand.setupWords(somethingAtLink: false, staying: true) == ["setup", "command", "claude", "codex"])
        #expect(AgentCommand.setupWords(somethingAtLink: false, staying: false) == ["setup", "claude", "codex"])
        #expect(AgentCommand.setupWords(somethingAtLink: true, staying: false) == ["setup", "claude", "codex"])
        #expect(!AgentCommand.setsUpAgents)
        #expect(!AgentSetup.shared.open())
    }

    @Test func theLinkIsLookedForInTheSameHomeAsTheCommandUses() {
        #expect(AgentCommand.link(home: AgentCommand.home(["BROADWAY_HOME": "/tmp/invented-home"])) == "/tmp/invented-home/.local/bin/broadway")
        #expect(AgentCommand.home(["BROADWAY_HOME": ""]) == NSHomeDirectory())
        #expect(AgentCommand.home([:]) == NSHomeDirectory())
    }

    @Test func withNothingAtTheLinkTheRunAlsoLinksTheCommand() async {
        let (setup, heard, _) = made(refreshes: true, linkTaken: false)

        setup.turned(wasOn: false, isOn: true)
        setup.launched(agentsOn: true)
        await setup.settled()

        #expect(await heard.words == [AgentCommand.setupAndLinkWords, AgentCommand.refreshWords])
    }

    @Test func fromADiskImageOrADownloadFolderTheRunLinksNothing() async {
        let (setup, heard, _) = made(linkTaken: false, staying: false)

        setup.turned(wasOn: false, isOn: true)
        await setup.settled()

        #expect(await heard.words == [AgentCommand.setupWords])
    }

    @Test func withSomethingAtTheLinkTheRunLeavesIt() async {
        let (setup, heard, _) = made(linkTaken: true)

        setup.turned(wasOn: false, isOn: true)
        await setup.settled()

        #expect(await heard.words == [AgentCommand.setupWords])
    }

    @Test func turningOnRunsSetupOnceAndKeepsTheMark() async {
        let (setup, heard, store) = made()

        setup.turned(wasOn: false, isOn: true)
        setup.turned(wasOn: true, isOn: true)
        await setup.settled()

        #expect(await heard.words == [AgentCommand.setupWords])
        #expect(store.bool(forKey: AgentCommand.setUpKey))
        #expect(setup.runs == 1)
    }

    @Test func offThenOnRunsItAgainThoughTheMarkIsThere() async {
        let (setup, heard, _) = made()

        setup.turned(wasOn: false, isOn: true)
        setup.turned(wasOn: true, isOn: false)
        setup.turned(wasOn: false, isOn: true)
        await setup.settled()

        #expect(await heard.words == [AgentCommand.setupWords, AgentCommand.setupWords])
        #expect(setup.runs == 2)
    }

    @Test func aLaunchWithAgentsOnAndNoMarkRunsItOnceThenRefreshes() async {
        let (setup, heard, store) = made(refreshes: true)

        setup.launched(agentsOn: true)
        await setup.settled()
        setup.launched(agentsOn: true)
        await setup.settled()

        #expect(await heard.words == [AgentCommand.setupWords, AgentCommand.refreshWords, AgentCommand.refreshWords])
        #expect(store.bool(forKey: AgentCommand.setUpKey))
        #expect(setup.runs == 1)
    }

    @Test func aLaunchWithAgentsOffAddsNothing() async {
        let (setup, heard, store) = made(refreshes: true)

        setup.launched(agentsOn: false)
        await setup.settled()

        #expect(await heard.words == [AgentCommand.refreshWords])
        #expect(!store.bool(forKey: AgentCommand.setUpKey))
        #expect(setup.runs == 0)
    }

    @Test func aClosedGuardRunsNothing() async {
        let (setup, heard, store) = made(open: false)

        setup.turned(wasOn: false, isOn: true)
        setup.launched(agentsOn: true)
        await setup.settled()

        #expect(await heard.words.isEmpty)
        #expect(!store.bool(forKey: AgentCommand.setUpKey))
    }

    @Test func withNoHelperNothingRunsAndNoMarkIsKept() async {
        let (setup, heard, store) = made(available: false)

        setup.turned(wasOn: false, isOn: true)
        setup.launched(agentsOn: true)
        await setup.settled()

        #expect(await heard.words.isEmpty)
        #expect(!store.bool(forKey: AgentCommand.setUpKey))
    }

    @Test func theSwitchRunsSetupOnlyWhenItGoesOn() async {
        keepSettings("agents.on")
        let prefs = Preferences()
        let (setup, heard, _) = made()
        prefs.agentSetup = setup

        prefs.agentsOn = false
        prefs.agentsOn = true
        prefs.agentsOn = true
        await setup.settled()
        #expect(await heard.words == [AgentCommand.setupWords])

        prefs.agentsOn = false
        prefs.agentsOn = true
        await setup.settled()
        #expect(await heard.words == [AgentCommand.setupWords, AgentCommand.setupWords])
    }
}
