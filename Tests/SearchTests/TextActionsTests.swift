import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class TextActionsTests {
    private var browser: Browser!
    private var fakes: [Plan: FakeProvider] = [:]
    private let picked = PickedText(text: "Their is a mistake", kind: .page, editable: false, box: .zero, family: "", size: 14)
    private let claudeOwn = ModelChoice(plan: .claude, model: "fake", effort: nil)

    init() async throws {
        keepSetting(Shared.prefs, \.textActions, Preferences.textActionsKey)
        keepSetting(Shared.prefs, \.aiPlan, "ai.plan")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.closeAll()
        browser.newTab()
        browser.tabs[0].restore(url: URL(string: "https://words.example/post")!, title: "A post")
        browser.prefs.textActions = true
        browser.prefs.aiPlan = nil
        await connect(claude: true, codex: true, mac: true)
    }

    private func tearDown() async {
        browser.closeSelection()
        browser.closeAll()
        browser = nil
        Plan.allCases.forEach { Plans.shared.standIn(nil, for: $0) }
    }

    private var tab: Tab { browser.tabs[0] }

    private func privateTab() -> Tab {
        let made = Tab(shy: true, configuration: Web.configuration(shy: true))
        made.restore(url: URL(string: "https://words.example/private")!, title: "Private")
        return made
    }

    private func connect(claude: Bool, codex: Bool, mac: Bool) async {
        for (plan, on) in [(Plan.claude, claude), (.chatGPT, codex), (.thisMac, mac)] {
            let fake = FakeProvider(plan: plan, echoes: true)
            if !on { fake.fakeStatus = PlanStatus() }
            Plans.shared.standIn(fake, for: plan)
            fakes[plan] = fake
        }
        await Plans.shared.refresh()
    }

    private func command(_ id: String) -> TextCommand {
        TextCommand.builtIn.first { $0.id == id }!
    }

    private func choice(_ id: String, blind: Bool = false) -> Plan? {
        Plans.shared.commandChoice(command(id), blind: blind, browser.prefs)?.plan
    }

    private var sent: Int { fakes.values.map(\.requests.count).reduce(0, +) }

    private func settle(_ run: SelectionRun) async {
        for _ in 0..<500 {
            if !run.running { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("still running")
    }

    @Test func thePickedAgentRunsEveryActionEvenWithThisMacThere() {
        browser.prefs.aiPlan = .chatGPT

        let picks = TextCommand.builtIn.map { choice($0.id) }

        #expect(picks.allSatisfy { $0 == .chatGPT })
    }

    @Test func withNothingPickedTheFirstConnectedPlanRunsThem() async {
        #expect(choice("improve") == .claude)

        await connect(claude: false, codex: true, mac: true)

        #expect(choice("improve") == .chatGPT)
        #expect(Plans.shared.agent(browser.prefs) == .chatGPT)
    }

    @Test func aPickThatIsGoneFallsBackToWhatIsConnected() async {
        browser.prefs.aiPlan = .claude
        await connect(claude: false, codex: true, mac: true)

        #expect(choice("summarize") == .chatGPT)
    }

    @Test func thisMacPickedRunsOnlyTheSixItCanDo() {
        browser.prefs.aiPlan = .thisMac

        let mac = TextCommand.builtIn.filter { choice($0.id) == .thisMac }.map(\.id)
        let none = TextCommand.builtIn.filter { choice($0.id) == nil }.map(\.id)

        #expect(Set(mac) == TextCommand.onDevice)
        #expect(Set(none) == Set(TextCommand.builtIn.map(\.id)).subtracting(TextCommand.onDevice))
    }

    @Test func onlyThisMacConnectedIsThePick() async {
        await connect(claude: false, codex: false, mac: true)

        #expect(Plans.shared.agent(browser.prefs) == .thisMac)
        #expect(Plans.shared.agents == [.thisMac])
        #expect(choice("improve") == .thisMac)
        #expect(choice("explain") == nil)
    }

    @Test func nothingConnectedRunsNothing() async {
        await connect(claude: false, codex: false, mac: false)

        #expect(Plans.shared.agent(browser.prefs) == nil)
        #expect(Plans.shared.agents.isEmpty)
        #expect(TextCommand.builtIn.allSatisfy { choice($0.id) == nil })
    }

    @Test func aPrivateWindowRunsOnlyOnThisMac() {
        browser.prefs.aiPlan = .claude

        let mac = TextCommand.builtIn.filter { choice($0.id, blind: true) == .thisMac }.map(\.id)
        let none = TextCommand.builtIn.filter { choice($0.id, blind: true) == nil }.map(\.id)

        #expect(Set(mac) == TextCommand.onDevice)
        #expect(Set(mac + none) == Set(TextCommand.builtIn.map(\.id)))
    }

    @Test func aPrivateWindowWithoutThisMacRunsNothing() async {
        await connect(claude: true, codex: true, mac: false)

        #expect(TextCommand.builtIn.allSatisfy { choice($0.id, blind: true) == nil })
    }

    @Test func aCommandWithAModelOfItsOwnKeepsIt() {
        browser.prefs.aiPlan = .thisMac
        var own = command("explain")
        own.model = ModelChoice(plan: .chatGPT, model: "fake", effort: nil)

        #expect(Plans.shared.commandChoice(own, blind: false, browser.prefs)?.plan == .chatGPT)
    }

    @Test func aPrivateWindowComesBeforeACommandsOwnModel() {
        var own = command("improve")
        own.model = claudeOwn
        var cloudOnly = command("explain")
        cloudOnly.model = claudeOwn

        #expect(Plans.shared.commandChoice(own, blind: true, browser.prefs)?.plan == .thisMac)
        #expect(Plans.shared.commandChoice(cloudOnly, blind: true, browser.prefs) == nil)
    }

    @Test func theMenuOffersThreeActionsAndMoreWhenItCanRun() {
        #expect(browser.textActionRows(on: tab, offered: true) == ["improve", "fix", "summarize", "more"])
    }

    @Test func theMenuOffersNothingWithTheSwitchOff() {
        browser.prefs.textActions = false

        #expect(browser.textActionRows(on: tab, offered: true).isEmpty)
        #expect(!browser.canRunAny(on: tab))
    }

    @Test func theMenuOffersNothingWithNothingConnected() async {
        await connect(claude: false, codex: false, mac: false)

        #expect(browser.textActionRows(on: tab, offered: true).isEmpty)
        #expect(!browser.canRunAny(on: tab))
    }

    @Test func theMenuWithThisMacPickedOffersWhatThisMacCanDo() {
        browser.prefs.aiPlan = .thisMac
        let list = CommandList(picked: picked, tab: tab)

        #expect(browser.textActionRows(on: tab, offered: true) == ["improve", "fix", "summarize", "more"])
        #expect(list.rows.allSatisfy { TextCommand.onDevice.contains($0.id) })
        #expect(!list.rows.contains { $0.id == "explain" })
    }

    @Test func theMenuOffersNothingInAnAgentsTab() {
        tab.agent = true
        defer { tab.agent = false }

        #expect(tab.agentWorking)
        #expect(browser.textActionRows(on: tab, offered: true).isEmpty)
        #expect(!browser.canRunAny(on: tab))
    }

    @Test func theMenuOffersNothingForASecretFieldOrNoSelection() {
        #expect(browser.textActionRows(on: tab, offered: false).isEmpty)
    }

    @Test func theMenuInAPrivateWindowOffersOnlyWhatStaysOnTheMac() async {
        let hidden = privateTab()
        let list = CommandList(picked: picked, tab: hidden)

        #expect(browser.textActionRows(on: hidden, offered: true) == ["improve", "fix", "summarize", "more"])
        #expect(list.rows.allSatisfy { TextCommand.onDevice.contains($0.id) })

        await connect(claude: true, codex: true, mac: false)

        #expect(browser.textActionRows(on: hidden, offered: true).isEmpty)
    }

    @Test func beforePlansAreLookedAtAPrivateWindowOffersNothing() {
        let hidden = privateTab()
        Plans.shared.standIn(fakes[.thisMac], for: .thisMac)
        let list = CommandList(picked: picked, tab: hidden)

        #expect(!Plans.shared.looked)
        #expect(browser.textActionRows(on: hidden, offered: true).isEmpty)
        #expect(list.rows.isEmpty)
        #expect(browser.textActionRows(on: tab, offered: true) == ["improve", "fix", "summarize", "more"])
    }

    @Test func theAgentRowIsDimmedWithNothingConnected() async throws {
        let row = try #require(SettingsIndex.items.first { $0.id == "ai.plan" })
        #expect(SettingsIndex.applies(row, browser.prefs))

        await connect(claude: false, codex: false, mac: false)

        #expect(!SettingsIndex.applies(row, browser.prefs))
        #expect(SettingsIndex.needs(row) == "Install Claude Code or Codex and sign in")
    }

    @Test func findASettingFindsBothRows() {
        #expect(SettingsIndex.find("text actions").contains { $0.id == "ai.actions" })
        #expect(SettingsIndex.find("improve writing").contains { $0.id == "ai.actions" })
        #expect(SettingsIndex.find("which agent").contains { $0.id == "ai.plan" })
        #expect(SettingsIndex.find("codex").contains { $0.id == "ai.plan" })
    }

    @Test func translateStaysOutOfTheRightClickMenuButNotEditOrTheList() {
        let list = CommandList(picked: picked, tab: tab)

        #expect(!TextActions.inMenu.contains("translate"))
        #expect(Command.named("edit.text.translate") != nil)
        #expect(list.rows.contains { $0.id == "translate" })
    }

    @Test func theListSaysOnceAtItsFootWhatRunsIt() async {
        let panel = { CommandListPanel(browser: self.browser, list: CommandList(picked: self.picked, tab: $0)) }

        browser.prefs.aiPlan = .claude
        #expect(panel(tab).footLine == "Claude Code, leaves this Mac")
        browser.prefs.aiPlan = .chatGPT
        #expect(panel(tab).footLine == "Codex, leaves this Mac")
        browser.prefs.aiPlan = .thisMac
        #expect(panel(tab).footLine == "On this Mac")
        browser.prefs.aiPlan = .claude
        #expect(panel(privateTab()).footLine == "On this Mac")
    }

    @Test func aBuiltInRowSaysNothingButItsName() {
        browser.prefs.aiPlan = .claude
        let panel = CommandListPanel(browser: browser, list: CommandList(picked: picked, tab: tab))

        #expect(!panel.entries.isEmpty)
        #expect(panel.entries.allSatisfy { $0.detail.isEmpty })
    }

    @Test func aRowSaysWhereItRunsOnlyWhenThatDiffersFromTheFoot() {
        let usual = ModelChoice(plan: .claude, model: "fake", effort: nil)

        #expect(CommandListPanel.own(usual, usual) == "")
        #expect(CommandListPanel.own(ModelChoice(plan: .chatGPT, model: "fake", effort: nil), usual) == "Codex, leaves this Mac")
        #expect(CommandListPanel.own(ModelChoice(plan: .thisMac, model: "", effort: nil), usual) == "On this Mac")
        #expect(CommandListPanel.own(ModelChoice(plan: .claude, model: "other", effort: .high), usual) == "other · High")
        #expect(CommandListPanel.own(nil, usual) == "")
    }

    @Test func noBuiltInNameIsCutInTheList() {
        let room: CGFloat = 300 - 12 - 20
        for command in TextCommand.builtIn {
            let label = KitLabel(command.name, font: .systemFont(ofSize: 13), color: KitColor.ink)
            #expect(FieldLine.width(label, scale: 2) <= room, "\(command.name)")
        }
    }

    @Test func theResultNamesTheAgentAsSettingsDoes() {
        let codex = ModelChoice(plan: .chatGPT, model: "fake", effort: nil)
        let mac = ModelChoice(plan: .thisMac, model: "", effort: nil)

        #expect(SelectionRun(command: command("improve"), asked: "", picked: picked, tab: tab, choice: claudeOwn).place.hasPrefix("Claude Code · "))
        #expect(SelectionRun(command: command("improve"), asked: "", picked: picked, tab: tab, choice: codex).place.hasPrefix("Codex · "))
        #expect(SelectionRun(command: command("improve"), asked: "", picked: picked, tab: tab, choice: mac).place == "On this Mac")
    }

    @Test func aRunWithTheSwitchOffSendsNothing() {
        browser.prefs.textActions = false

        browser.runCommand(command("improve"), picked: picked, tab: tab)

        #expect(browser.ai.result == nil)
        #expect(sent == 0)
    }

    @Test func aRunInAnAgentsTabSendsNothing() {
        tab.agent = true
        defer { tab.agent = false }

        browser.runCommand(command("improve"), picked: picked, tab: tab)

        #expect(browser.ai.result == nil)
        #expect(sent == 0)
    }

    @Test func aRunInAPrivateWindowWithoutThisMacSendsNothing() async {
        await connect(claude: true, codex: true, mac: false)
        let hidden = privateTab()

        browser.runCommand(command("improve"), picked: picked, tab: hidden)

        #expect(browser.ai.result == nil)
        #expect(sent == 0)
        #expect(browser.announcement == "In a private window, the page isn't sent")
    }

    @Test func aRunGoesToThePickedAgent() async {
        browser.prefs.aiPlan = .chatGPT

        browser.runCommand(command("improve"), picked: picked, tab: tab)
        let run = try? #require(browser.ai.result)
        if let run { await settle(run) }

        #expect(fakes[.chatGPT]?.requests.count == 1)
        #expect(fakes[.thisMac]?.requests.isEmpty == true)
        #expect(fakes[.claude]?.requests.isEmpty == true)
    }

    @Test func aTextActionCanOnlyAnswer() {
        for command in TextCommand.builtIn {
            let run = SelectionRun(command: command, asked: command.prompt(language: "English"), picked: picked, tab: tab, choice: claudeOwn)
            #expect(run.request.tools == ProviderTools.none, "\(command.id)")
            #expect(!run.request.keepOpen, "\(command.id)")
        }
    }

    @Test func whatReachesTheAgentCanOnlyAnswer() async {
        let run = SelectionRun(command: command("improve"), asked: "Improve it", picked: picked, tab: tab, choice: claudeOwn)

        run.start()
        await settle(run)

        let request = try? #require(fakes[.claude]?.requests.last)
        #expect(request?.tools == ProviderTools.none)
        #expect(request?.prompt.contains("Their is a mistake") == true)
    }

    @Test func onlyACommandThatNamesThePageSendsIt() {
        let run = SelectionRun(command: command("improve"), asked: "Improve it", picked: picked, tab: tab, choice: claudeOwn)

        #expect(!command("improve").wantsPage)
        #expect(!run.request.prompt.contains("words.example"))
    }

    @Test func aRunOnThisMacInAPrivateWindowIsNeverRetriedElsewhere() async {
        let hidden = privateTab()
        let mac = ModelChoice(plan: .thisMac, model: "", effort: nil)
        let run = SelectionRun(command: command("improve"), asked: "Improve it", picked: picked, tab: hidden, choice: mac)
        run.start()
        await settle(run)

        run.retry(on: claudeOwn)
        await settle(run)

        #expect(run.choice.plan == .thisMac)
        #expect(fakes[.claude]?.requests.isEmpty == true)
        #expect(fakes[.thisMac]?.requests.count == 1)
    }

    @Test func turningTheSwitchOffClosesWhatIsOpen() {
        browser.openCommands(picked, tab: tab)

        TextActions.set(false, browser.prefs, in: [browser])

        #expect(browser.ai.commands == nil)
        #expect(!browser.prefs.textActions)
    }

    @Test func theCommandsAreHiddenFromTheAddressFieldWithTheSwitchOff() throws {
        let improve = try #require(Command.named("edit.text.improve"))
        browser.select(tab)

        let on = FieldCommands.available(improve, in: browser)
        browser.prefs.textActions = false
        let off = FieldCommands.available(improve, in: browser)

        #expect(on)
        #expect(!off)
    }
}
