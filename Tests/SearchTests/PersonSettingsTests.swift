import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PersonSettingsTests {
    private var browser: Browser!
    private var box: BrowserToolbox!

    init() async throws {
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

    @Test func readingOneSettingSaysTheSameAsTheList() async throws {
        let entry = try #require(PersonCommands.find("settings", "get"))

        let found = try await entry.run(call("get", ["setting": "live.folders"]))

        #expect(found["changes"] as? String == "nothing to set here")
        #expect(found["instead"] as? String == "broadway live list")
    }
}
