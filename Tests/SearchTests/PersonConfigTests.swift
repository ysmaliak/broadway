import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PersonConfigTests {
    private var browser: Browser!
    private var box: BrowserToolbox!
    private var rules: [LinkRule] = []
    private var linkSettings = LinkSettings()
    private var snippets: [UUID] = []
    private var actions = QuickActions.Saved()

    init() async throws {
        rules = LinkRules.shared.rules
        linkSettings = LinkRules.shared.settings
        snippets = SnippetStore.shared.snippets.map(\.id)
        actions = QuickActions.shared.saved
        keepSetting(Shared.prefs, \.keywords, "search.keywords")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        Browsers.register(browser)
        box = BrowserToolbox()
        box.browser = browser
        Shared.prefs.keywords = []
    }

    private func tearDown() async {
        LinkRules.shared.replaceAll(rules, settings: linkSettings)
        for snippet in SnippetStore.shared.snippets where !snippets.contains(snippet.id) { SnippetStore.shared.delete(snippet.id) }
        for action in QuickActions.shared.saved.custom where !actions.custom.contains(where: { $0.id == action.id }) { QuickActions.shared.remove(action.id) }
        if let browser { Browsers.forget(browser) }
        browser?.closeAll()
        browser = nil
    }

    private var space: Space { browser.spaces[0] }

    private func call(_ noun: String, _ verb: String, _ arguments: [String: Any]) -> PersonCall {
        PersonCall(noun: noun, verb: verb, arguments: arguments, browser: browser, box: box)
    }

    @discardableResult
    private func run(_ noun: String, _ verb: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let entry = try #require(PersonCommands.find(noun, verb))
        let given = call(noun, verb, arguments)
        try await entry.first?(given)
        return try await entry.run(given)
    }

    private func refused(_ noun: String, _ verb: String, _ arguments: [String: Any]) async -> PersonRefusal? {
        do {
            try await run(noun, verb, arguments)
            return nil
        } catch {
            return error as? PersonRefusal
        }
    }

    @Test func aLinkRuleSendsASiteToASpace() async throws {
        let made = try await run("links", "add", ["match": "example.com", "space": space.name])

        let rule = try #require(LinkRules.shared.rules.first { PersonCommands.short($0.id) == made["id"] as? String })
        #expect(rule.match == .site("example.com"))
        #expect(rule.target == .space(space.id, folder: nil))
        #expect(rule.from == .anywhere)
    }

    @Test func theKindOfMatchIsReadFromItUnlessGiven() async throws {
        try await run("links", "add", ["match": "example.com/docs", "space": space.name])
        try await run("links", "add", ["match": "/pull/", "kind": "contains", "space": space.name])

        #expect(LinkRules.shared.rules.contains { $0.match == .starts("example.com/docs") })
        #expect(LinkRules.shared.rules.contains { $0.match == .contains("/pull/") })
    }

    @Test func aRuleThatHandsLinksToAnotherAppIsThePersons() async {
        let refusal = await refused("links", "add", ["match": "example.com", "app": "Safari"])

        #expect(refusal?.code == "person_only")
        #expect(refusal?.hint?.contains("Settings › Links › Rules") == true)
        #expect(LinkRules.shared.rules == rules)
    }

    @Test func aRuleNeedsASpace() async {
        #expect(await refused("links", "add", ["match": "example.com"])?.code == "usage")
        #expect(await refused("links", "add", ["match": "example.com", "space": "Nowhere"])?.code == "not_found")
    }

    @Test func aBrokenExpressionIsRefused() async {
        #expect(await refused("links", "add", ["match": "(", "kind": "regex", "space": space.name])?.code == "usage")
        #expect(await refused("links", "add", ["match": "x", "kind": "plaid", "space": space.name])?.code == "usage")
    }

    @Test func theSameMatchTwiceIsRefused() async throws {
        try await run("links", "add", ["match": "twice.example", "space": space.name])

        #expect(await refused("links", "add", ["match": "twice.example", "space": space.name])?.code == "refused")
    }

    @Test func aRuleMovesAndGoes() async throws {
        let first = try await run("links", "add", ["match": "/one/", "kind": "contains", "space": space.name])
        let second = try await run("links", "add", ["match": "/two/", "kind": "contains", "space": space.name])
        let id = try #require(second["id"] as? String)

        try await run("links", "move", ["id": id, "position": "1"])
        #expect(PersonCommands.short(LinkRules.shared.rules[0].id) == id)
        try await run("links", "delete", ["id": first["id"] ?? ""])

        #expect(!LinkRules.shared.rules.contains { PersonCommands.short($0.id) == first["id"] as? String })
    }

    @Test func theListSaysWhereEachRuleSendsLinks() async throws {
        try await run("links", "add", ["match": "listed.example", "space": space.name])

        let rows = try #require(try await run("links", "list")["rules"] as? [[String: Any]])
        let row = try #require(rows.first { $0["match"] as? String == "listed.example" })

        #expect(row["space"] as? String == space.name)
        #expect(row["kind"] as? String == "site")
    }

    @Test func linksFromOutsideCanGoToASpaceByName() throws {
        let access = try #require(PersonSettings.table["links.open"])

        #expect(access.check?(space.name) == true)
        #expect(access.check?("Nowhere at all") == false)
        #expect(access.write?(Shared.prefs, space.name) == true)

        #expect(LinkRules.shared.settings.outsideDefault == .space(space.id))
        #expect(access.read(Shared.prefs) as? String == space.name)
    }

    @Test func aNewSiteShortcutIsAdded() async throws {
        try await run("keywords", "add", ["keyword": "ex", "address": "https://example.com/search?q=%s"])

        #expect(Shared.prefs.keywords.map(\.keyword) == ["ex"])
        let rows = try #require(try await run("keywords", "list")["keywords"] as? [[String: Any]])
        #expect(rows.first?["site"] as? String == "example.com")
    }

    @Test func pointingAShortcutElsewhereIsThePersons() async throws {
        try await run("keywords", "add", ["keyword": "ex", "address": "https://example.com/search?q=%s"])

        let refusal = await refused("keywords", "add", ["keyword": "EX", "address": "https://other.example/?q=%s"])

        #expect(refusal?.code == "person_only")
        #expect(Shared.prefs.keywords.first?.template == "https://example.com/search?q=%s")
    }

    @Test func aShortcutThatCouldSendTheWordsAnywhereIsRefused() async {
        #expect(await refused("keywords", "add", ["keyword": "ex", "address": "https://%s.example.com/"])?.code == "usage")
        #expect(await refused("keywords", "add", ["keyword": "two words", "address": "https://example.com/?q=%s"])?.code == "usage")
    }

    @Test func aShortcutIsDeleted() async throws {
        try await run("keywords", "add", ["keyword": "ex", "address": "https://example.com/search?q=%s"])

        try await run("keywords", "delete", ["keyword": "ex"])

        #expect(Shared.prefs.keywords.isEmpty)
        #expect(await refused("keywords", "delete", ["keyword": "ex"])?.code == "not_found")
    }

    @Test func aQuickActionIsAddedRenamedAndDeleted() async throws {
        let made = try await run("actions", "add", ["short": "zzpr", "address": "example.com/pulls", "name": "Pulls"])
        let id = try #require(made["id"] as? String)

        try await run("actions", "rename", ["action": "zzpr", "name": "My pulls"])
        let rows = try #require(try await run("actions", "list")["actions"] as? [[String: Any]])
        #expect(rows.first { $0["id"] as? String == id }?["name"] as? String == "My pulls")

        try await run("actions", "delete", ["action": id])
        #expect(!QuickActions.shared.saved.custom.contains { $0.address == "example.com/pulls" })
    }

    @Test func aQuickActionsShortNameIsThePersonsToRepoint() async throws {
        try await run("actions", "add", ["short": "zzpr", "address": "example.com/pulls"])

        #expect(await refused("actions", "add", ["short": "zzpr", "address": "other.example"])?.code == "person_only")
        #expect(await refused("actions", "add", ["short": "zzpr", "address": "example.com/pulls"])?.code == "refused")
    }

    @Test func aQuickActionMovesToAPosition() async throws {
        let made = try await run("actions", "add", ["short": "zzmove", "address": "example.com/move"])

        try await run("actions", "move", ["action": made["id"] ?? "", "position": "1"])

        #expect(QuickActions.shared.shown(history: browser.history).first?.short == "zzmove")
    }

    @Test func aSnippetIsAddedAndOfferedByItsKeyword() async throws {
        try await run("snippets", "add", ["keyword": ";zzsig", "text": "Best, Sam", "title": "Signature"])

        let found = try #require(SnippetStore.shared.snippets.first { $0.keyword == "zzsig" })
        #expect(found.title == "Signature")
        #expect(found.text == "Best, Sam")
        #expect(SnippetStore.shared.matches(";zzsig").first?.id == found.id)
    }

    @Test func aSnippetWithoutATitleTakesItsKeyword() async throws {
        try await run("snippets", "add", ["keyword": "zzbare", "text": "Plain"])

        #expect(SnippetStore.shared.snippets.first { $0.keyword == "zzbare" }?.title == "zzbare")
    }

    @Test func aSnippetsKeywordIsItsOwn() async throws {
        try await run("snippets", "add", ["keyword": "zzone", "text": "One"])

        #expect(await refused("snippets", "add", ["keyword": "zzone", "text": "Two"])?.code == "usage")
    }

    @Test func aSnippetIsRenamedAndDeleted() async throws {
        try await run("snippets", "add", ["keyword": "zzgone", "text": "Soon gone"])

        try await run("snippets", "rename", ["keyword": "zzgone", "title": "Gone"])
        #expect(SnippetStore.shared.snippets.first { $0.keyword == "zzgone" }?.title == "Gone")
        try await run("snippets", "delete", ["keyword": "zzgone"])

        #expect(!SnippetStore.shared.snippets.contains { $0.keyword == "zzgone" })
    }

    @Test func aSpaceTakesAColourByIdOrName() async throws {
        let was = space.look
        defer { browser.setSpaceLook(space.id, to: was ?? SpaceLook()) }

        try await run("spaces", "colour", ["space": space.name, "colour": "Sage"])

        #expect(space.look?.colour == "sage")
        let rows = try #require(try await run("spaces", "list")["spaces"] as? [[String: Any]])
        #expect(rows.first { $0["name"] as? String == space.name }?["colour"] as? String == "sage")
    }

    @Test func aColourThatIsNoPresetIsRefused() async {
        #expect(await refused("spaces", "colour", ["space": space.name, "colour": "plaid"])?.code == "usage")
    }

    @Test func theColoursTheHelpNamesAreThePresets() {
        let named = "graphite, gray, paper, coral, peach, sage, sky, lavender or rose"
            .replacingOccurrences(of: " or ", with: ", ").components(separatedBy: ", ")

        #expect(named == SpaceLook.presets.map(\.id))
    }

    @Test func aNameThatIsNoneOfThemIsNotFound() async {
        #expect(await refused("links", "move", ["id": "zzzzzzzz", "position": "1"])?.code == "not_found")
        #expect(await refused("links", "delete", ["id": "zzzzzzzz"])?.code == "not_found")
        #expect(await refused("actions", "rename", ["action": "zznone", "name": "X"])?.code == "not_found")
        #expect(await refused("snippets", "delete", ["keyword": "zznone"])?.code == "not_found")
        #expect(await refused("spaces", "colour", ["space": "Nowhere", "colour": "sage"])?.code == "not_found")
    }

    @Test func theNewVerbsAreGatedLikeTheOthers() {
        for name in ["links list", "keywords list", "actions list", "snippets list"] {
            #expect(PersonCommands.table.first { $0.name == name }?.kind == .look, "\(name)")
        }
        for name in ["links add", "links move", "keywords add", "actions add", "actions rename", "actions move", "snippets add", "snippets rename", "spaces colour"] {
            #expect(PersonCommands.table.first { $0.name == name }?.kind == .arrange, "\(name)")
        }
        for name in ["links delete", "keywords delete", "actions delete", "snippets delete"] {
            #expect(PersonCommands.table.first { $0.name == name }?.kind == .erase, "\(name)")
        }
    }
}
