import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SettingsIndexTests {
    private func store() -> (UserDefaults, String) {
        let name = "settings-cut-\(UUID().uuidString)"
        let made = UserDefaults(suiteName: name) ?? .standard
        made.removePersistentDomain(forName: name)
        return (made, name)
    }

    @Test func idsAreUniqueAndEveryGroupIsReal() {
        #expect(Set(SettingsIndex.items.map { $0.id }).count == SettingsIndex.items.count)
        for item in SettingsIndex.items {
            #expect(SettingsIndex.group(item.group) != nil, "\(item.id)")
            #expect(item.detail.count <= 90, "\(item.id)")
            if let parent = item.parent { #expect(SettingsIndex.item(parent) != nil, "\(item.id)") }
        }
    }

    @Test func oneSiteNeverAskedIsOneSite() {
        #expect(SettingsIndex.neverLine(1) == "1 site told to stop offering")
        #expect(SettingsIndex.neverLine(3) == "3 sites told to stop offering")
    }

    @Test func everyRowOnTheAgentsPageHasAControl() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let shell = SettingsShell()
        shell.go(to: .agents)
        let view = SettingsPageView(browser: browser, shell: shell)

        view.rebuild()

        let rows = view.kitSubviews(of: SettingsRowView.self)
        #expect(rows.contains { $0.rowID == "ai.agents" })
        #expect(rows.contains { $0.rowID == "agents.mode" })
        #expect(rows.allSatisfy { $0.control != nil })
        #expect(view.kitSubviews(of: SettingsFooter.self).count == 1)
    }

    @Test func theSidebarOffersAgentsAndNoAIPage() {
        let pages = SettingsPage.allCases

        let titles = pages.map(\.title)

        #expect(titles == ["General", "Field", "Appearance", "Websites", "Links", "Tabs", "Shortcuts", "Agents", "Live Folders",
                           "Passwords", "Privacy", "Extensions"])
        #expect(SettingsPage.blocks[1] == [.agents, .liveFolders, .passwords, .privacy, .extensions])
        #expect(SettingsPage.agents.icon == "person.2")
        #expect(SettingsPage.named("ai") == .agents)
        #expect(SettingsDetail.allCases == [.linkRule, .liveFolder, .languages])
        #expect(!SettingsIndex.groups.contains { $0.title == "AI" })
        #expect(SettingsIndex.groups(of: .agents).map(\.id) == ["agents", "agents.broadway"])
    }

    @Test func whatLeftTheAgentsPageIsNotInTheIndex() {
        let gone = ["ai.on", "ai.plans", "ai.commands", "ai.memory", "ai.skills", "ai.getToKnow", "ai.routines", "ai.watch"]

        let found = gone.filter { SettingsIndex.item($0) != nil }
        let stillSet = gone.filter { PersonSettings.table[$0] != nil }

        #expect(found == [])
        #expect(stillSet == [])
        #expect(SettingsIndex.find("routine").isEmpty)
        #expect(SettingsIndex.find("get to know").isEmpty)
        #expect(SettingsIndex.find("keep an eye").isEmpty)
        #expect(SettingsIndex.find("default plan").isEmpty)
        #expect(SettingsIndex.items(in: "agents").map(\.id) == ["ai.agents", "agents.mode"])
        #expect(Set(SettingsIndex.items.filter { $0.group == "agents" }.map(\.id))
            == ["ai.agents", "agents.mode", "agents.connected", "agents.sites", "ai.command", "ai.replies"])
    }

    @Test func noSettingsWordingHasASemicolon() {
        var said: [(String, String)] = []
        for item in SettingsIndex.items {
            said += [(item.id, item.title), (item.id, item.detail), (item.id, item.more ?? "")]
        }
        said += SettingsIndex.groups.map { ($0.id, $0.title) }
        said += SettingsPage.allCases.map { ($0.rawValue, $0.title) }
        said += SettingsDetail.allCases.map { ($0.rawValue, $0.summary) }
        said += LivePreset.all.flatMap { [($0.id, $0.title), ($0.id, $0.detail)] }
        said += [("live.footer", LiveFolderRows.opened(in: nil, offered: false)), ("live.added", LiveFolderRows.allAdded(in: nil, offered: false))]
        said += [("extensions", ExtensionsLogic.privateNote),
                 ("quick", QuickActionsLogic.footer), ("agents", SettingsPageView.agentsNote)]

        let found = said.filter { $0.1.range(of: #";(\s|$)"#, options: .regularExpression) != nil }.map { "\($0.0): \($0.1)" }

        #expect(found == [])
    }

    @Test func codesFromMessagesIsGoneAndGmailIsTheOneCodeRow() {
        let typed = ["sms", "text message", "full disk access"]

        let section = SettingsIndex.items.filter { $0.group == "codes" }.map(\.id)
        let texted = typed.flatMap(SettingsIndex.find)

        #expect(section == ["codes.gmail"])
        #expect(SettingsIndex.item("codes.messages") == nil)
        #expect(SettingsIndex.item("codes.messages.access") == nil)
        #expect(PersonSettings.table["codes.messages"] == nil)
        #expect(texted.allSatisfy { $0.group != "codes" })
        #expect(SettingsIndex.find("one-time code").first?.id == "codes.gmail")
        #expect(SettingsIndex.find("otp").contains { $0.id == "codes.gmail" })
        #expect(SettingsIndex.find("2fa").contains { $0.id == "codes.gmail" })
    }

    @Test(arguments: [true, false])
    func groupTabsAutomaticallyIsOnTheTabsPage(available: Bool) throws {
        _ = NSApplication.shared
        let groups = AIGroups.shared
        let was = (groups.standIn, groups.macAvailable, groups.openRouter)
        keepSetting(groups, \.on, AIGroups.onKey)
        defer {
            groups.standIn = was.0
            groups.macAvailable = was.1
            groups.openRouter = was.2
        }
        groups.standIn = nil
        groups.openRouter = OpenRouterKey(store: OpenRouterMemoryStore())
        groups.macAvailable = { available }
        groups.on = true
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let shell = SettingsShell()
        shell.go(to: .tabs)
        let view = SettingsPageView(browser: browser, shell: shell)

        view.rebuild()

        let item = try #require(SettingsIndex.item("ai.groups"))
        #expect(item.page == .tabs && !item.findOnly && item.kind == .control)
        #expect(SettingsIndex.find("group tabs").contains { $0.id == "ai.groups" })
        #expect(SettingsIndex.find("apple intelligence").contains { $0.id == "ai.groups" })
        let row = try #require(view.kitSubviews(of: SettingsRowView.self).first { $0.rowID == "ai.groups" })
        let toggle = try #require(row.kitSubviews(of: KitSwitch.self).first)
        #expect(toggle.isEnabled == available)
        #expect(toggle.isOn == available)
        #expect(row.alphaValue == (available ? 1 : 0.5))
        #expect(row.detail.stringValue == (available ? "Related tabs find each other as you open them. Runs on this Mac. Nothing leaves it."
                                                     : "Needs Apple Intelligence on this Mac or an OpenRouter key"))
        #expect(groups.sends == (available ? "Related tabs find each other as you open them. Runs on this Mac. Nothing leaves it."
                                           : "Needs Apple Intelligence on this Mac or an OpenRouter key"))
        #expect(groups.deciding == (available ? .thisMac : nil))
    }

    @Test func turningGroupingOnBringsFolderEmojisBack() {
        keepSettings(AIGroups.onKey, AIGroups.emojiKey)
        let groups = AIGroups.shared
        let was = (groups.on, groups.emoji)
        defer {
            groups.on = was.0
            groups.emoji = was.1
        }
        groups.on = false
        groups.emoji = false

        groups.on = true

        #expect(groups.emoji)
    }

    @Test func aPlanNoLongerGroupsTabs() async {
        let groups = AIGroups.shared
        let was = (groups.standIn, groups.macAvailable, groups.engine)
        defer {
            groups.standIn = was.0
            groups.macAvailable = was.1
            groups.engine = was.2
        }
        groups.standIn = nil
        groups.macAvailable = { false }
        let plans = Plans()
        plans.standIn(FakeProvider(plan: .claude), for: .claude)
        await plans.refresh()

        groups.engine = .claude

        #expect(plans.connected(.claude))
        #expect(groups.deciding == nil)
        #expect(groups.naming == nil)
        #expect(groups.decider() == nil)
    }

    @Test func agentsAndGroupingNoLongerWaitForUseAI() {
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let groups = AIGroups.shared
        let was = (groups.standIn, groups.macAvailable, prefs.agentsOn)
        keepSetting(prefs, \.ai, "ai")
        keepSetting(groups, \.on, AIGroups.onKey)
        defer {
            groups.standIn = was.0
            groups.macAvailable = was.1
            prefs.agentsOn = was.2
            browser.closeAll()
        }
        groups.standIn = nil
        groups.macAvailable = { true }
        groups.on = true
        prefs.agentsOn = true

        prefs.ai = false

        #expect(prefs.agentsAllowed)
        #expect(groups.active(browser))
        #expect(SettingsStageWords.scene(SettingsPlace(page: .agents), browser: browser, space: browser.spaceID).agents)
    }

    @Test(arguments: [false, true])
    func removingASitesAnswerAsksFirst(yes: Bool) throws {
        _ = NSApplication.shared
        let sites = AgentSites.shared
        let site = "confirm-\(UUID().uuidString.prefix(8).lowercased()).example"
        sites.set(.always, for: site)
        Ask.testing = yes
        defer {
            Ask.testing = nil
            sites.set(nil, for: site)
        }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let shell = SettingsShell()
        shell.go(to: .agents)
        let view = SettingsPageView(browser: browser, shell: shell)
        view.rebuild()
        let row = try #require(view.kitSubviews(of: SettingsRowView.self).first { $0.rowID == "agents.site." + site })
        let remove = try #require(row.kitSubviews(of: SettingsPill.self).first)

        let pressed = remove.accessibilityPerformPress()

        #expect(pressed)
        #expect(remove.title == "Remove…")
        #expect((sites.rules[site] == nil) == yes)
    }

    @Test(arguments: [false, true])
    func disconnectingAnAgentAsksFirst(yes: Bool) throws {
        _ = NSApplication.shared
        let links = AgentLinks.shared
        let link = links.join(.connection(UUID()), name: "Confirm \(UUID().uuidString.prefix(6))")
        Ask.testing = yes
        defer {
            Ask.testing = nil
            links.end(link.id, .done(nil))
        }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let shell = SettingsShell()
        shell.go(to: .agents)
        let view = SettingsPageView(browser: browser, shell: shell)
        view.rebuild()
        let row = try #require(view.kitSubviews(of: SettingsRowView.self).first { $0.rowID == "agents.link.\(link.id)" })
        let disconnect = try #require(row.kitSubviews(of: SettingsPill.self).first)

        let pressed = disconnect.accessibilityPerformPress()

        #expect(pressed)
        #expect(disconnect.title == "Disconnect…")
        #expect((links.link(link.id)?.live == false) == yes)
    }

    @Test func whatTheMacAsksIsFoundUnderAskFirst() {
        let typed = ["terminal", "your mac", "files"]

        let found = typed.map { SettingsIndex.find($0) }

        #expect(SettingsIndex.item("agents.mac") == nil)
        for hits in found { #expect(hits.contains { $0.id == "agents.mode" }) }
    }

    @Test(arguments: [false, true])
    func theAskFirstRowFollowsTheAgentsSwitch(on: Bool) throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let was = (browser.prefs.agentsOn, browser.prefs.agentMode)
        defer {
            browser.prefs.agentsOn = was.0
            browser.prefs.agentMode = was.1
            browser.closeAll()
        }
        browser.prefs.agentMode = .auto
        let shell = SettingsShell()
        shell.go(to: .agents)
        let view = SettingsPageView(browser: browser, shell: shell)
        browser.prefs.agentsOn = !on
        view.rebuild()

        browser.prefs.agentsOn = on
        view.refresh()

        let row = try #require(view.kitSubviews(of: SettingsRowView.self).first { $0.rowID == "agents.mode" })
        let choice = try #require(row.kitSubviews(of: KitChoice.self).first)
        #expect(choice.isEnabled == on)
        #expect(choice.alphaValue == 1)
        #expect(row.alphaValue == (on ? 1 : 0.5))
        let ask = try #require(choice.subviews.first { $0.accessibilityLabel() == "Ask" })
        #expect(ask.accessibilityPerformPress() == on)
        #expect(browser.prefs.agentMode == (on ? .ask : .auto))
    }

    @Test func oldSectionNamesLandOnTheirPages() {
        #expect(SettingsPage.named("shortcuts") == .shortcuts)
        #expect(SettingsPage.named("downloads") == .general)
        #expect(SettingsPage.named("appearance") == .appearance)
        #expect(SettingsPage.named("websites") == .websites)
        #expect(SettingsPage.named("tabs") == .tabs)
        #expect(SettingsPage.named("spaces") == .tabs)
        #expect(SettingsPage.named("integrations") == .liveFolders)
        #expect(SettingsPage.named("live") == .liveFolders)
        #expect(SettingsPage.named("livefolders") == .liveFolders)
        #expect(SettingsPage.named("LiveFolders") == .liveFolders)
        #expect(SettingsPage.named("privacy") == .privacy)
        #expect(SettingsPage.named("keyboard") == .shortcuts)
        #expect(SettingsPage.named("quickactions") == .field)
        #expect(SettingsPage.named("permissions") == .websites)
        #expect(SettingsDetail.named("keyboard") == nil)
        #expect(SettingsDetail.named("quickactions") == nil)
        #expect(SettingsDetail.named("permissions") == nil)
    }

    @Test func everyPageIsNamedByItsOwnName() {
        for page in SettingsPage.allCases {
            #expect(SettingsPage.named(page.rawValue) == page, "\(page)")
            #expect(SettingsPage.named(page.title) == page, "\(page)")
        }
    }

    @Test func theCutRemovesFixedKeysAndKeepsWhatYouChose() {
        let (defaults, name) = store()
        for key in SettingsCut.fixed { defaults.set(true, forKey: key) }
        defaults.set("dark", forKey: "look")
        defaults.set(false, forKey: "passwords.save")
        defaults.set(true, forKey: "meetings.alerts")
        defaults.set(true, forKey: SettingsCut.lowPowerKey)

        SettingsCut.migrate(defaults, testing: false)

        let kept = defaults.persistentDomain(forName: name) ?? [:]
        for key in SettingsCut.fixed { #expect(kept[key] == nil, "\(key)") }
        #expect(defaults.string(forKey: "look") == "dark")
        #expect(defaults.object(forKey: "passwords.save") as? Bool == false)
        #expect(defaults.object(forKey: "passwords.fill") as? Bool == false)
        #expect(defaults.bool(forKey: "meetings.next"))
        #expect(defaults.bool(forKey: "meetings.alerts"))
        #expect(defaults.object(forKey: SettingsCut.lowPowerKey) as? Bool == false)
    }

    @Test(arguments: [false, true])
    func useAISwitchedOffKeepsAgentsAndGroupingOff(groupsWereOn: Bool) {
        let (defaults, name) = store()
        defaults.set(false, forKey: "ai")
        defaults.set(true, forKey: "agents.on")
        if groupsWereOn { defaults.set(true, forKey: "ai.groups") }

        SettingsCut.migrate(defaults, testing: false)
        SettingsCut.migrate(defaults, testing: false)

        let kept = defaults.persistentDomain(forName: name) ?? [:]
        #expect(kept["ai"] == nil)
        #expect(defaults.object(forKey: "ai.groups") as? Bool == false)
        #expect(defaults.object(forKey: "ai.groups.emoji") as? Bool == false)
        #expect(defaults.object(forKey: "agents.on") as? Bool == false)
    }

    @Test func useAILeftOnChangesNothingElse() {
        let (defaults, name) = store()
        defaults.set(true, forKey: "ai")
        defaults.set(true, forKey: "agents.on")

        SettingsCut.migrate(defaults, testing: false)

        let kept = defaults.persistentDomain(forName: name) ?? [:]
        #expect(kept["ai"] == nil)
        #expect(kept["ai.groups"] == nil)
        #expect(defaults.bool(forKey: "agents.on"))
    }

    @Test func theCutLeavesTestWorldsAlone() {
        let (defaults, _) = store()
        defaults.set(false, forKey: "tabs.give")

        SettingsCut.migrate(defaults, testing: true)

        #expect(defaults.object(forKey: "tabs.give") as? Bool == false)
    }

    @Test func fixedKeysHaveNoRows() {
        for key in SettingsCut.fixed {
            #expect(!SettingsIndex.items.contains { !$0.findOnly && $0.keys.contains(key) }, "\(key)")
        }
        #expect(SettingsIndex.item("tabs.give") == nil)
        #expect(SettingsIndex.item("newtab.floating")?.page == .appearance)
    }

    @Test func findByWords() {
        #expect(SettingsIndex.find("vertical tabs").contains { $0.id == "tabs.layout" })
        #expect(SettingsIndex.find("spelling").contains { $0.id == "autocorrect" })
        #expect(SettingsIndex.find("split").contains { $0.id == "note.split" })
        #expect(SettingsIndex.find("floating").contains { $0.id == "newtab.floating" })
        #expect(SettingsIndex.find("").isEmpty)
        #expect(SettingsIndex.find("zzzz nothing").isEmpty)
    }

    @Test func findReachesTheAlwaysThereFeatures() {
        #expect(SettingsIndex.find("calculator").contains { $0.id == "note.answers" })
        #expect(SettingsIndex.find("json").contains { $0.id == "note.json" })
        #expect(SettingsIndex.find("video speed").contains { $0.id == "note.floatkeys" })
        #expect(SettingsIndex.find("idle").contains { $0.id == "tabs.close.after" })
        for id in ["note.answers", "note.json", "note.floatkeys"] {
            #expect(SettingsIndex.item(id)?.findOnly == true, "\(id)")
        }
    }
}
