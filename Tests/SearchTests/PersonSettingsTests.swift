import AppKit
import BroadwayCLI
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PersonSettingsTests {
    private var browser: Browser!
    private var box: BrowserToolbox!

    init() async throws {
        keepSetting(Shared.prefs, \.look, "look")
        keepSetting(Shared.prefs, \.pageZoom, "pageZoom")
        keepSetting(Shared.prefs, \.floatingNewTab, "newtab.floating")
        keepSetting(Shared.prefs, \.sidePosition, "sidebar.position")
        keepSetting(Shared.prefs, \.darkensPages, "pages.dusk")
        keepSetting(Shared.prefs, \.bookmarksBar, "bookmarks.bar")
        keepSetting(Shared.prefs, \.confirmsQuit, "quit.confirm")
        keepSetting(OpenAtLogin.standIn, \.on)
        keepSetting(OpenAtLogin.standIn, \.refuses)
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        box = BrowserToolbox()
        box.browser = browser
    }

    private func tearDown() async {
        browser?.closeAll()
        browser = nil
    }

    private func call(_ verb: String, _ arguments: [String: Any] = [:]) -> PersonCall {
        PersonCall(noun: "settings", verb: verb, arguments: arguments, browser: browser, box: box)
    }

    private func run(_ verb: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let entry = try #require(PersonCommands.find("settings", verb))
        return try await entry.run(call(verb, arguments))
    }

    @Test func noRowWithoutAControlLeavesTheAgentGuessing() {
        for (id, access) in PersonSettings.table where access.bar == .noControl {
            let instead = PersonSettings.instead(id) ?? ""
            #expect(!instead.isEmpty, "\(id)")
            #expect(instead != "nothing to set", "\(id)")
        }
    }

    @Test func aRowWithNoCommandNamesItsPlaceInBroadway() {
        #expect(PersonSettings.instead("general.import") == "In Settings › General: broadway settings open general.import")
    }

    @Test func everyFreeSettingCanBeWritten() {
        for (id, access) in PersonSettings.table where access.bar == .free {
            #expect(access.write != nil, "\(id)")
            #expect(!access.takes.isEmpty, "\(id)")
        }
    }

    @Test func theListSaysWhatEachSettingTakesAndWhoMayChangeIt() async throws {
        let rows = try #require(try await run("list")["settings"] as? [[String: Any]])

        let look = try #require(rows.first { $0["id"] as? String == "look" })
        let agents = try #require(rows.first { $0["id"] as? String == "ai.agents" })
        let history = try #require(rows.first { $0["id"] as? String == "clear.history" })

        #expect(rows.count == SettingsIndex.items.count)
        #expect((look["takes"] as? String)?.contains("dark") == true)
        #expect(look["changes"] as? String == "this command")
        #expect(agents["changes"] as? String == "only the person, in Broadway")
        #expect(agents["takes"] as? String == "")
        #expect(history["instead"] as? String == "broadway history clear")
        for row in rows { #expect(row["takes"] is String && row["changes"] is String, "\(row["id"] ?? "")") }
    }

    @Test func canSetListsOnlyWhatTheCommandCanChange() async throws {
        let rows = try #require(try await run("list", ["can-set": true])["settings"] as? [[String: Any]])
        let ids = Set(rows.compactMap { $0["id"] as? String })

        #expect(ids.contains("look"))
        #expect(ids.contains("shield"))
        #expect(!ids.contains("ai.agents"))
        #expect(!ids.contains("clear.history"))
        #expect(rows.allSatisfy { !($0["takes"] as? String ?? "").isEmpty })
    }

    @Test func aRowWithNoControlRefusesWithWhatDoesItsJob() {
        let refused = PersonSettings.refusal("clear.history", value: "true")

        #expect(refused?.code == "refused")
        #expect(refused?.hint == "broadway history clear")
    }

    @Test func readingGroupingSaysWhatItsRowSays() async throws {
        let entry = try #require(PersonCommands.find("settings", "get"))
        let key = OpenRouterKey.shared
        key.use("sk-or-example-1")
        defer { key.use(nil) }

        let groups = try await entry.run(call("get", ["setting": "ai.groups"]))
        let openRouter = try await entry.run(call("get", ["setting": "groups.openrouter"]))

        #expect(groups["detail"] as? String == AIGroups.shared.sends)
        #expect(openRouter["detail"] as? String == AIGroupWords.keyLine(state: key.state, trouble: key.trouble, remoteDecides: AIGroups.shared.remoteDecides))
        #expect(groups["detail"] as? String != SettingsIndex.item("ai.groups")?.detail)
        #expect(openRouter["detail"] as? String != SettingsIndex.item("groups.openrouter")?.detail)
    }

    @Test func readingOneSettingSaysTheSameAsTheList() async throws {
        let entry = try #require(PersonCommands.find("settings", "get"))

        let found = try await entry.run(call("get", ["setting": "live.folders"]))

        #expect(found["changes"] as? String == "nothing to set here")
        #expect(found["instead"] as? String == "broadway live list")
    }

    private func setting(_ words: [String]) -> PersonCall {
        var arguments: [String: Any] = ["setting": words[0], "value": words[1]]
        if words.count > 2 { arguments["values"] = Array(words.dropFirst(2)) }
        return call("set", arguments)
    }

    private func set(_ words: [String]) async throws -> [String: Any] {
        let entry = try #require(PersonCommands.find("settings", "set"))
        let given = setting(words)
        try await entry.first?(given)
        return try await entry.run(given)
    }

    @Test func severalSettingsChangeInOneCall() async throws {
        Shared.prefs.look = .light
        Shared.prefs.pageZoom = 1
        Shared.prefs.floatingNewTab = false

        let answer = try await set(["look", "dark", "pageZoom", "110", "newtab.floating", "true"])
        let rows = try #require(answer["settings"] as? [[String: Any]])

        #expect(Shared.prefs.look == .dark)
        #expect(Shared.prefs.pageZoom == 1.1)
        #expect(Shared.prefs.floatingNewTab)
        #expect(rows.map { $0["id"] as? String } == ["look", "pageZoom", "newtab.floating"])
        #expect(rows[0]["was"] as? String == "light")
        #expect(rows[0]["value"] as? String == "dark")
        #expect(rows[1]["was"] as? Int == 100)
        #expect(rows[1]["value"] as? Int == 110)
        #expect(answer["message"] as? String == "Changed 3 settings")
    }

    @Test func oneRefusedPairChangesNothing() async throws {
        Shared.prefs.floatingNewTab = false

        await #expect(throws: PersonRefusal.self) { try await self.set(["newtab.floating", "true", "ai.agents", "true"]) }

        #expect(!Shared.prefs.floatingNewTab)
        #expect(throws: PersonRefusal.self) { try PersonSettings.planned(self.setting(["newtab.floating", "true", "ai.agents", "true"])) }
        do {
            _ = try PersonSettings.planned(setting(["newtab.floating", "true", "ai.agents", "true"]))
        } catch let refused as PersonRefusal {
            #expect(refused.code == "person_only")
            #expect(refused.message.hasSuffix("Nothing was changed."))
        }
    }

    @Test func aWrongValueAnywhereChangesNothing() async throws {
        Shared.prefs.look = .light

        do {
            _ = try await set(["look", "dark", "pageZoom", "9000"])
            Issue.record("a zoom of 9000 was taken")
        } catch let refused as PersonRefusal {
            #expect(refused.code == "usage")
            #expect(refused.message.hasPrefix("pageZoom takes"))
        }

        #expect(Shared.prefs.look == .light)
    }

    @Test func aSettingWithoutAValueIsRefused() {
        #expect(throws: PersonRefusal.self) { try PersonSettings.planned(self.setting(["look", "dark", "pageZoom"])) }
    }

    @Test func aSettingNamedTwiceIsRefused() {
        #expect(throws: PersonRefusal.self) { try PersonSettings.planned(self.setting(["look", "dark", "look", "light"])) }
    }

    @Test func aSinglePairAnswersAsBefore() async throws {
        let answer = try await set(["look", "dark"])

        #expect(Set(answer.keys) == ["id", "value", "message"])
        #expect(answer["id"] as? String == "look")
        #expect(answer["message"] as? String == "Changed")
    }

    @Test func theQuestionQuotesTheWholeLineOnce() {
        let given = setting(["look", "dark", "pageZoom", "110"])

        #expect(given.line == "broadway settings set look dark pageZoom 110")
        #expect(PersonAsk.title(for: given, site: nil) == "Change 2 settings?")
        #expect(PersonAsk.title(for: setting(["look", "dark"]), site: nil) == "Change a setting?")
    }

    @Test func theUsageLineTakesMorePairs() throws {
        let line = try #require(NounSchema.lines.first { $0.noun == "settings" && $0.verb == "set" })

        #expect(line.arguments.map(\.name) == ["setting", "value", "values"])
        #expect(line.arguments.last?.many == true)
        #expect(line.arguments.last?.required == false)
    }

    @Test func everySettingThatChangesChecksBeforeItWrites() {
        for (id, access) in PersonSettings.table where access.write != nil {
            #expect(access.check != nil, "\(id)")
        }
    }

    @Test func theMenuChoicesAreFreeToSet() {
        for (id, value) in [("tabs.layout", "right"), ("pages.dusk", "true"), ("bookmarks.bar", "true"), ("quit.confirm", "true"), ("app.openAtLogin", "true")] {
            #expect(PersonSettings.refusal(id, value: value) == nil, "\(id)")
        }
    }

    @Test func theSidebarSideMovesTheSidebarTheMenuMoves() async throws {
        Shared.prefs.sidePosition = .left

        _ = try await set(["tabs.layout", "right"])

        #expect(Shared.prefs.sidePosition == .right)
        #expect(PersonSettings.table["tabs.layout"]?.read(Shared.prefs) as? String == "right")
        #expect(PersonSettings.table["tabs.layout"]?.check?("middle") == false)
    }

    @Test func darkenBrightPagesIsTheMenusSwitch() async throws {
        Shared.prefs.darkensPages = false

        _ = try await set(["pages.dusk", "true"])

        #expect(Shared.prefs.darkensPages)
    }

    @Test func theBookmarksBarIsTheMenusSwitch() async throws {
        Shared.prefs.bookmarksBar = false

        _ = try await set(["bookmarks.bar", "true"])

        #expect(Shared.prefs.bookmarksBar)
    }

    @Test func askBeforeQuittingIsTheMenusSwitch() async throws {
        Shared.prefs.confirmsQuit = false

        _ = try await set(["quit.confirm", "true"])

        #expect(Shared.prefs.confirmsQuit)
    }

    @Test func openAtLoginIsTheMenusSwitch() async throws {
        OpenAtLogin.standIn.on = false

        _ = try await set(["app.openAtLogin", "true"])

        #expect(OpenAtLogin.standIn.on)
        #expect(PersonSettings.table["app.openAtLogin"]?.read(Shared.prefs) as? Bool == true)
    }

    @Test func openAtLoginThatMacOSRefusesChangesNothingElse() async throws {
        OpenAtLogin.standIn.on = false
        OpenAtLogin.standIn.refuses = true
        Shared.prefs.look = .light

        do {
            _ = try await set(["look", "dark", "app.openAtLogin", "true"])
            Issue.record("a refused login item was taken")
        } catch let refused as PersonRefusal {
            #expect(refused.code == "failed")
            #expect(refused.message == "Open at login couldn't be changed, so nothing was")
        }

        #expect(Shared.prefs.look == .light)
        #expect(!OpenAtLogin.standIn.on)
    }
}
