import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PersonCommandsTests {
    private var browser: Browser!
    private var box: BrowserToolbox!

    init() async throws {
        keepSetting(Shared.prefs, \.tabsGive, "tabs.give")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        let mine = Tab(configuration: Web.configuration(space: browser.spaceID))
        mine.restore(url: URL(string: "https://example.com/mine")!, title: "Mine")
        browser.showRow([mine], active: mine.id)
        box = BrowserToolbox()
        box.browser = browser
    }

    private func tearDown() async {
        browser?.closeAll()
        browser = nil
    }

    private func call(_ arguments: [String: Any] = [:]) -> PersonCall {
        PersonCall(noun: "tabs", verb: "list", arguments: arguments, browser: browser, box: box)
    }

    @Test func noVerbIsListedTwice() {
        let names = PersonCommands.table.map(\.name)
        #expect(names.count == Set(names).count)
    }

    @Test func everyVerbThatLosesSomethingIsAnErase() {
        let words: Set<String> = ["delete", "clear", "forget", "cancel", "remove", "close"]

        let losing = PersonCommands.table.filter { words.contains($0.verb) && !["folders remove", "folders delete", "shortcuts clear"].contains($0.name) }

        for verb in losing { #expect(verb.kind == .erase, "\(verb.name)") }
        #expect(losing.count > 10)
    }

    @Test func onlyTheseVerbsRunWithoutTheSwitch() {
        let open = Set(PersonCommands.table.filter { $0.kind == .open }.map(\.name))

        #expect(open == ["settings list", "settings find", "extensions private", "shields off", "permissions allow"])
    }

    @Test func verbsThatFillGoThroughThePersonEveryTime() {
        #expect(PersonCommands.find("fill", "login")?.kind == .person(.signIn))
        #expect(PersonCommands.find("fill", "details")?.kind == .person(.address))
        #expect(PersonCommands.find("fill", "card")?.kind == .person(.address))
        #expect(PersonCommands.find("tabs", "keep")?.kind == .person(.tab))
    }

    @Test func aReadNeedsATaskInAskMode() {
        #expect(PersonCommands.decide(.look, mode: .ask, rule: nil) == .needsTask)
        #expect(PersonCommands.decide(.look, mode: .auto, rule: nil) == .go)
        #expect(PersonCommands.decide(.look, mode: .bypass, rule: nil) == .go)
    }

    @Test func anArrangementAsksOnlyInAskMode() {
        #expect(PersonCommands.decide(.arrange, mode: .ask, rule: nil) == .person(.tab))
        #expect(PersonCommands.decide(.arrange, mode: .auto, rule: nil) == .go)
        #expect(PersonCommands.decide(.arrange, mode: .bypass, rule: nil) == .go)
    }

    @Test func anEraseAsksUnlessBypassed() {
        #expect(PersonCommands.decide(.erase, mode: .ask, rule: nil) == .person(.delete))
        #expect(PersonCommands.decide(.erase, mode: .auto, rule: nil) == .person(.delete))
        #expect(PersonCommands.decide(.erase, mode: .bypass, rule: nil) == .go)
    }

    @Test func aPersonVerbAsksEvenInBypass() {
        for mode in AgentMode.allCases {
            #expect(PersonCommands.decide(.person(.signIn), mode: mode, rule: nil) == .person(.signIn))
            #expect(PersonCommands.decide(.person(.address), mode: mode, rule: .always) == .person(.address))
        }
    }

    @Test func aSiteRuledOutIsRefusedWhateverTheMode() {
        for mode in AgentMode.allCases {
            for kind: PersonClass in [.look, .arrange, .erase, .person(.signIn)] {
                #expect(PersonCommands.decide(kind, mode: mode, rule: .never) == .refuse)
            }
        }
    }

    @Test func toolVerbsLeaveTheGateToTheTool() {
        #expect(PersonCommands.decide(.tool, mode: .ask, rule: .never) == .go)
        #expect(PersonCommands.find("history", "list")?.kind == .tool)
    }

    @Test func everySettingHasAnAnswer() {
        let known = Set(SettingsIndex.items.map(\.id))

        let table = Set(PersonSettings.table.keys)

        #expect(known.subtracting(table) == [])
        #expect(table.subtracting(known) == [])
    }

    @Test func whatWeakensSafetyIsRefused() {
        let refused: [(String, String)] = [
            ("ai.agents", "true"), ("ai.agents", "false"), ("agents.mode", "bypass"), ("agents.sites", "x"),
            ("agents.mode", "ask"), ("passwords.fill", "false"), ("passwords.open", "x"), ("autofill.cards", "x"), ("groups.openrouter", "sk-or-typed"),
            ("codes.gmail", "true"), ("history.pageText", "true"),
            ("downloads.folder", "/tmp"),
            ("shield", "false"), ("sites.keep", "no"),
            ("notifications.ask", "true"), ("search.suggest", "on"),
            ("search.engine", "custom"), ("links.tracking", "false"), ("links.unwrap", "false"),
        ]

        for (id, value) in refused {
            #expect(PersonSettings.refusal(id, value: value)?.code == "person_only", "\(id) \(value)")
        }
        #expect(PersonSettings.refusal("passwords.apple", value: "true")?.code == (AppleHelper.available ? "person_only" : "refused"))
    }

    @Test func theSwitchesThatLeftSettingsAreNoLongerSettings() {
        let gone = ["ai.on", "ai.plans", "ai.memory", "ai.routines", "ai.watch", "ai.commands", "ai.skills", "ai.getToKnow", "ai.actions", "ai.ask", "ai.plan"]

        let codes = gone.map { PersonSettings.refusal($0, value: "false")?.code }

        #expect(codes == gone.map { _ in "not_found" })
        #expect(PersonSettings.refusal("ai.groups", value: "false") == nil)
        #expect(PersonSettings.refusal("ai.agents", value: "true")?.code == "person_only")
    }

    @Test func turningSafetyBackUpIsAllowed() {
        for (id, value) in [("shield", "true"), ("sites.keep", "true"), ("search.suggest", "false")] {
            #expect(PersonSettings.refusal(id, value: value) == nil, "\(id)")
        }
    }

    @Test func anEverydaySettingIsAllowed() {
        for (id, value) in [("newtab.floating", "true"), ("look", "dark"), ("search.engine", Engine.allCases.first { $0 != .custom }?.rawValue ?? "")] {
            #expect(PersonSettings.refusal(id, value: value) == nil, "\(id)")
        }
    }

    @Test func whatHasNoControlSaysSo() {
        #expect(PersonSettings.refusal("clear.history", value: "true")?.code == "refused")
        #expect(PersonSettings.refusal("nope", value: "true")?.code == "not_found")
    }

    @Test func everySettingThatChangesCanBeRead() {
        for (id, access) in PersonSettings.table where access.write != nil {
            #expect(access.read(browser.prefs) != nil, "\(id)")
        }
    }

    @Test func aFreeSettingWritesAndReadsBack() throws {
        let access = try #require(PersonSettings.table["newtab.floating"])
        let was = browser.prefs.floatingNewTab

        #expect((access.write?(browser.prefs, was ? "false" : "true")) == true)

        #expect((access.read(browser.prefs) as? Bool) == (!was))
        browser.prefs.floatingNewTab = was
    }

    @Test func aMadeUpValueIsNotWritten() throws {
        #expect((PersonSettings.table["look"]?.write?(browser.prefs, "plaid")) == false)
        #expect((PersonSettings.table["pageZoom"]?.write?(browser.prefs, "9000")) == false)
    }

    @Test func privateTabsAreAbsent() throws {
        let hidden = Tab(shy: true, configuration: Web.configuration(shy: true))
        let row = browser.tabs + [hidden]

        browser.showRow(row, active: row.first?.id)
        let found = PersonTabs.everyTab(call()).map(\.tab)

        #expect(!found.contains { $0 === hidden })
        #expect(throws: (any Error).self) { try PersonTabs.find(call(), hidden.id.uuidString) }
    }

    @Test func anyPartOfAnIDFindsATab() throws {
        let tab = try #require(browser.tabs.first)

        let found = try PersonTabs.find(call(), String(tab.id.uuidString.prefix(6)))

        #expect(found.tab === tab)
    }

    @Test func findCountsThePagesWordsOnly() {
        let text = "The price is 12\nno match\nprice and price"

        let rows = PersonPages.lines(of: text, matching: "price", matchCase: false, words: false)

        #expect(rows.map { $0["line"] as? Int } == [1, 3])
        #expect(rows.map { $0["count"] as? Int } == [1, 2])
    }

    @Test func findKeepsCaseAndWordsWhenAsked() {
        #expect(PersonPages.lines(of: "Price", matching: "price", matchCase: true, words: false).isEmpty)
        #expect(PersonPages.lines(of: "prices", matching: "price", matchCase: false, words: true).isEmpty)
        #expect(!PersonPages.lines(of: "a price.", matching: "price", matchCase: false, words: true).isEmpty)
    }

    @Test func findTakesPunctuationLiterally() {
        #expect(PersonPages.lines(of: "abc", matching: "a.c", matchCase: false, words: false).isEmpty)
        #expect(PersonPages.lines(of: "a.c", matching: "a.c", matchCase: false, words: true).count == 1)
    }

    @Test func aSelectorThatReadsAFieldIsRefused() {
        #expect(PersonPages.safeSelector(".banner"))
        #expect(!PersonPages.safeSelector(""))
        #expect(!PersonPages.safeSelector("p { color: red }"))
        #expect(!PersonPages.safeSelector("<script>"))
        #expect(!PersonPages.safeSelector("input[value^=\"h\"]"))
    }

    @Test func printingTouchesOnlyWhatTheShieldMarked() {
        #expect(PersonPages.hideForPrint.contains("data-broadway-secret"))
        #expect(PersonPages.hideForPrint.contains("shadowRoot"))
        #expect(PersonPages.showAfterPrint.contains("removeProperty"))
    }

    @Test func aFinishedDownloadKeepsItsIDBetweenRuns() {
        #expect(PersonStuff.stableID("/tmp/file.bin") == PersonStuff.stableID("/tmp/file.bin"))
        #expect(PersonStuff.stableID("/tmp/file.bin") != PersonStuff.stableID("/tmp/other.bin"))
        #expect(PersonStuff.stableID("/tmp/file.bin").count == 8)
    }

    @Test func aRefusalKeepsItsHintInTheError() {
        let refused = PersonRefusal.person("Only the person.", where: "Settings › AI")

        let reply = PersonCommands.failure(refused)
        let error = reply["error"] as? [String: Any]

        #expect((error?["code"] as? String) == "person_only")
        #expect((error?["hint"] as? String) == "The person can do this in Broadway: Settings › AI")
    }

    @Test func theCommandsAddNoToolForAModel() {
        let tools = Set(BrowserToolbox().tools.map(\.name))

        let added = PersonCommands.table.map(\.verb).filter { ["spaces", "bookmarks", "downloads", "settings", "shortcuts", "extensions", "shields", "permissions"].contains($0) }

        #expect(added.isEmpty)
        for name in ["settings", "bookmarks_add", "spaces_new", "downloads", "fill"] { #expect(!tools.contains(name), "\(name)") }
    }

    @Test func theQuestionShowsTheCommandInTheLine() {
        var given = call(["tab": "abc", "name": "Work", "front": true])
        given.noun = "tabs"
        given.verb = "new"

        let line = given.line

        #expect(line.hasPrefix("broadway tabs new"))
        #expect(line.contains("--front"))
        #expect(line.contains("Work"))
    }

    @Test func fillingAsksWithWhatItFills() {
        #expect(PersonAsk.title(noun: "fill", verb: "login", site: "shop.example") == "Fill your saved sign-in on shop.example?")
        #expect(PersonAsk.title(noun: "fill", verb: "details", site: "shop.example") == "Fill your name, address and phone on shop.example?")
        #expect(PersonAsk.title(noun: "fill", verb: "card", site: "shop.example") == "Fill your saved card on shop.example?")
        #expect(PersonAsk.title(noun: "fill", verb: "login", site: nil) == "Fill your saved sign-in on this page?")
    }

    @Test func commonCommandsAskInTheirOwnWords() {
        #expect(PersonAsk.title(noun: "tabs", verb: "close", site: nil) == "Close tabs?")
        #expect(PersonAsk.title(noun: "history", verb: "clear", site: nil) == "Clear your history?")
        #expect(PersonAsk.title(noun: "nothing", verb: "known", site: nil) == PersonAsk.generic)
        let verbs = PersonCommands.table.map { "\($0.noun) \($0.verb)" }
        for key in PersonAsk.titles.keys { #expect(verbs.contains(key), "\(key) is not a person command") }
        for title in PersonAsk.titles.values {
            #expect(title.hasSuffix("?") && !title.contains(";") && !title.contains("Run this"), "\(title)")
        }
    }

    @Test func fillingStillAsksThePersonInEveryMode() {
        for mode in AgentMode.allCases {
            #expect(PersonCommands.decide(.person(.signIn), mode: mode, rule: nil) == .person(.signIn), "\(mode)")
            #expect(PersonCommands.decide(.person(.address), mode: mode, rule: nil) == .person(.address), "\(mode)")
        }
    }
}
