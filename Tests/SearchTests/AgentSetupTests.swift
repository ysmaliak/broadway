import Foundation
import Testing
@testable import BroadwayCLI
@testable import Search

private actor Heard {
    private(set) var words: [[String]] = []

    func add(_ said: [String]) { words.append(said) }
}

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct AgentSetupTests {
    private func invented() throws -> Setup.Paths {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("broadway-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return Setup.Paths(home: folder.path)
    }

    private func earlier(_ store: UserDefaults) {
        store.set(true, forKey: AgentCommand.setUpKey)
    }

    private func made(open: Bool = true, available: Bool = true, refreshes: Bool = false, linkTaken: Bool = true, staying: Bool = true,
                      home: Setup.Paths? = nil) -> (AgentSetup, Heard, UserDefaults) {
        let name = "agent-setup-tests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let heard = Heard()
        let setup = AgentSetup(store: store)
        setup.runner = { words in
            await heard.add(words)
            guard let home else { return true }
            let parts = words.filter { $0 != "setup" && $0 != "--refresh" }
            if words.contains("--refresh") {
                _ = Setup.refresh(parts, paths: home)
            } else {
                _ = Setup.install(parts, paths: home, binary: "/Applications/Broadway.app/Contents/Helpers/broadway")
            }
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

    @Test func theWordsAreEachAgentAndTheCommandWhenNothingIsThere() {
        #expect(AgentCommand.setupWords == ["setup", "claude", "codex", "cursor", "opencode", "gemini"])
        #expect(AgentCommand.setupAndLinkWords == ["setup", "command", "claude", "codex", "cursor", "opencode", "gemini"])
        #expect(AgentCommand.setupWords(somethingAtLink: true, staying: true) == ["setup", "claude", "codex", "cursor", "opencode", "gemini"])
        #expect(AgentCommand.setupWords(somethingAtLink: false, staying: true) == ["setup", "command", "claude", "codex", "cursor", "opencode", "gemini"])
        #expect(AgentCommand.setupWords(somethingAtLink: false, staying: false) == ["setup", "claude", "codex", "cursor", "opencode", "gemini"])
        #expect(AgentCommand.setupWords(somethingAtLink: true, staying: false) == ["setup", "claude", "codex", "cursor", "opencode", "gemini"])
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

    @Test func onlyAMarkFromAnEarlierVersionWithAgentsOnBringsTheNewerAgents() {
        #expect(AgentCommand.newlyCovered(isOn: true, marked: true, open: true, kept: nil) == ["cursor", "opencode", "gemini"])
        #expect(AgentCommand.newlyCovered(isOn: true, marked: true, open: true, kept: AgentCommand.agentNames).isEmpty)
        #expect(AgentCommand.newlyCovered(isOn: true, marked: true, open: true, kept: ["claude", "codex", "cursor"]) == ["opencode", "gemini"])
        #expect(AgentCommand.newlyCovered(isOn: false, marked: true, open: true, kept: nil).isEmpty)
        #expect(AgentCommand.newlyCovered(isOn: true, marked: false, open: true, kept: nil).isEmpty)
        #expect(AgentCommand.newlyCovered(isOn: true, marked: true, open: false, kept: nil).isEmpty)
    }

    @Test func anUpdateBringsTheNewerAgentsOnceAtLaunch() async throws {
        let home = try invented()
        try FileManager.default.createDirectory(atPath: home.opencode, withIntermediateDirectories: true)
        let (setup, heard, store) = made(refreshes: true, home: home)
        earlier(store)

        setup.launched(agentsOn: true)
        await setup.settled()
        setup.launched(agentsOn: true)
        await setup.settled()

        let newer = ["setup", "cursor", "opencode", "gemini"]
        #expect(await heard.words == [newer, AgentCommand.refreshWords, AgentCommand.refreshWords])
        #expect(FileManager.default.fileExists(atPath: home.opencodeSkill))
        #expect(!FileManager.default.fileExists(atPath: home.cursor))
        #expect(!FileManager.default.fileExists(atPath: home.gemini))
        #expect(store.stringArray(forKey: AgentCommand.setUpForKey) == AgentCommand.agentNames)
        #expect(setup.runs == 1)
    }

    @Test func anUpdateWithAgentsOffBringsNothing() async throws {
        let home = try invented()
        try FileManager.default.createDirectory(atPath: home.opencode, withIntermediateDirectories: true)
        let (setup, heard, store) = made(home: home)
        earlier(store)

        setup.launched(agentsOn: false)
        await setup.settled()

        #expect(await heard.words.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.opencodeSkill))
        #expect(store.stringArray(forKey: AgentCommand.setUpForKey) == nil)
        #expect(setup.runs == 0)
    }

    @Test func aClosedGuardBringsNoNewerAgents() async throws {
        let home = try invented()
        try FileManager.default.createDirectory(atPath: home.opencode, withIntermediateDirectories: true)
        let (setup, heard, store) = made(open: false, home: home)
        earlier(store)

        setup.launched(agentsOn: true)
        await setup.settled()

        #expect(await heard.words.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.opencodeSkill))
    }

    @Test func aSkillRemovedByHandAfterTheUpdateIsNotWrittenAgain() async throws {
        let home = try invented()
        try FileManager.default.createDirectory(atPath: home.opencode, withIntermediateDirectories: true)
        let (setup, heard, store) = made(refreshes: true, home: home)
        earlier(store)
        setup.launched(agentsOn: true)
        await setup.settled()
        #expect(FileManager.default.fileExists(atPath: home.opencodeSkill))

        try FileManager.default.removeItem(atPath: home.opencodeSkill)
        setup.launched(agentsOn: true)
        await setup.settled()

        #expect(!FileManager.default.fileExists(atPath: home.opencodeSkill))
        #expect(await heard.words.last == AgentCommand.refreshWords)
        #expect(setup.runs == 1)
    }

    @Test func turningOnTheFirstTimeRecordsEveryAgentSoALaunchOnlyRefreshes() async throws {
        let home = try invented()
        try FileManager.default.createDirectory(atPath: home.opencode, withIntermediateDirectories: true)
        let (setup, heard, store) = made(refreshes: true, home: home)

        setup.turned(wasOn: false, isOn: true)
        await setup.settled()
        setup.launched(agentsOn: true)
        await setup.settled()

        #expect(await heard.words == [AgentCommand.setupWords, AgentCommand.refreshWords])
        #expect(store.stringArray(forKey: AgentCommand.setUpForKey) == AgentCommand.agentNames)
        #expect(FileManager.default.fileExists(atPath: home.opencodeSkill))
        #expect(setup.runs == 1)
    }

    @Test func theRowCallsNoAbsentSkillOfTheNewerAgentsAFault() {
        let ready: [[String: Any]] = [["name": "command", "ok": true, "detail": "/x"], ["name": "fish", "ok": true, "detail": "/f"],
                                    ["name": "claude", "ok": true, "detail": "/c"]]
        for (name, shown) in [("cursor", "Cursor"), ("opencode", "opencode"), ("gemini", "Gemini CLI")] {
            let absent = ready + [["name": name, "ok": false, "absent": true, "detail": "/invented-home/.\(name)/skills/broadway/SKILL.md isn't there"]]
            let stale = ready + [["name": name, "ok": false, "detail": "/invented-home/.\(name)/skills/broadway/SKILL.md is out of date"]]
            let summary = AgentCommand.summary(absent, home: "/invented-home")

            #expect(summary == "On your PATH, set up for fish, Claude Code. Try broadway doctor.")
            #expect(!summary.contains(shown))
            #expect(AgentCommand.summary(stale, home: "/invented-home") == "On your PATH, but ~/.\(name)/skills/broadway/SKILL.md is out of date. Run broadway doctor.")
        }
        let claude = [["name": "command", "ok": true, "detail": "/x"],
                      ["name": "claude", "ok": false, "absent": true, "detail": "/invented-home/.claude/skills/broadway/SKILL.md isn't there"]] as [[String: Any]]
        #expect(AgentCommand.summary(claude, home: "/invented-home") == "On your PATH, but ~/.claude/skills/broadway/SKILL.md isn't there. Run broadway doctor.")
        let later = ready + [["name": "gemini", "ok": false, "absent": true, "detail": "gone"], ["name": "codex", "ok": false, "detail": "/invented-home/.codex/skills/broadway/SKILL.md isn't broadway's"]]
        #expect(AgentCommand.summary(later, home: "/invented-home") == "On your PATH, but ~/.codex/skills/broadway/SKILL.md isn't broadway's. Run broadway doctor.")
    }

    @Test func theRowShowsTheHomeFolderAsATilde() {
        let checks: [[String: Any]] = [["name": "command", "ok": true, "detail": "/x"],
                                       ["name": "zsh", "ok": false, "detail": "/tmp/invented-home/.local/share/broadway/broadway.zsh isn't there"]]

        #expect(AgentCommand.summary(checks, home: "/tmp/invented-home") == "On your PATH, but ~/.local/share/broadway/broadway.zsh isn't there. Run broadway doctor.")
        #expect(AgentCommand.summary(checks, home: "/tmp/invented-home/") == "On your PATH, but ~/.local/share/broadway/broadway.zsh isn't there. Run broadway doctor.")
        #expect(AgentCommand.summary(checks, home: "/tmp/invented") == "On your PATH, but /tmp/invented-home/.local/share/broadway/broadway.zsh isn't there. Run broadway doctor.")
        #expect(AgentCommand.tilde("/tmp/invented-home is gone", home: "/tmp/invented-home") == "~ is gone")
    }
}
