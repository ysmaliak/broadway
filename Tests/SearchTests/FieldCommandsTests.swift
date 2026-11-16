import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FieldCommandsTests {
    init() {
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        keepSettings("settings.page")
    }

    private func fresh() -> Browser {
        _ = NSApplication.shared
        return Browser(record: WindowRecord())
    }

    private func actions(_ rows: [Suggestion]) -> [String] {
        rows.compactMap { row in
            if case .action(let id) = row.kind { return id }
            return nil
        }
    }

    @Test func everyMenuCommandIsFoundByItsTitle() {
        let browser = fresh()
        defer { browser.closeAll() }
        browser.prefs.usesSpaces = true
        defer { browser.prefs.usesSpaces = false }
        let commands = Command.all.filter { FieldCommands.available($0, in: browser) }
        #expect(commands.count > 40)

        for command in commands {
            let rows = FieldCommands.rows(for: FieldName.plain(command.title), in: browser, limit: 8)
            #expect(actions(rows).contains("command:" + command.id), "\(command.title)")
        }
    }

    @Test func everySettingsPageIsFoundByItsName() {
        let browser = fresh()
        defer { browser.closeAll() }

        for page in FieldCommands.pages {
            let rows = FieldCommands.rows(for: page.title, in: browser, limit: 8)
            #expect(actions(rows).contains("settings:" + page.rawValue), "\(page.title)")
        }
    }

    @Test func aSettingIsFoundByItsWords() {
        let browser = fresh()
        defer { browser.closeAll() }

        let rows = FieldCommands.rows(for: "remember what", in: browser)

        #expect(actions(rows).first == "setting:history.pageText")
    }

    @Test func namesTheManualUsesReachTheirCommands() {
        let browser = fresh()
        defer { browser.closeAll() }

        let split = FieldCommands.rows(for: "split view", in: browser)
        let pin = FieldCommands.rows(for: "pin tab", in: browser)

        #expect(actions(split).first == "command:tabs.split")
        #expect(actions(pin).first == "command:tabs.pin")
    }

    @Test func rowsCarryTheirKeyAsItStands() {
        let browser = fresh()
        defer { browser.closeAll() }

        let row = FieldCommands.rows(for: "duplicate tab", in: browser).first

        #expect(row?.keys == "⌘D")
    }

    @Test func aFeatureThatIsOffKeepsItsCommandsOutOfTheField() {
        let browser = fresh()
        defer { browser.closeAll() }
        let was = browser.prefs.splitView
        defer { browser.prefs.splitView = was }
        browser.prefs.splitView = false

        let rows = FieldCommands.rows(for: "split current page", in: browser)

        #expect(!actions(rows).contains("command:tabs.split"))
    }

    @Test func onlySpacesThatExistAreListed() {
        let browser = fresh()
        defer { browser.closeAll() }
        let was = browser.prefs.usesSpaces
        defer { browser.prefs.usesSpaces = was }
        browser.prefs.usesSpaces = true

        let rows = FieldCommands.rows(for: "space 9", in: browser)

        #expect(!actions(rows).contains("command:spaces.9"))
    }

    @Test func betterMatchesComeFirst() {
        #expect(FieldName.score("reload page", title: "Reload Page")! > FieldName.score("reload", title: "Reload Page")!)
        #expect(FieldName.score("reload", title: "Reload Page")! > FieldName.score("page", title: "Reload Page")!)
        #expect(FieldName.score("r", title: "Reload Page") == nil)
        #expect(FieldName.score("zebra", title: "Reload Page") == nil)
    }

    @Test func rowsSitBelowTheSearchSoReturnStillSearches() {
        let browser = fresh()
        defer { browser.closeAll() }

        browser.typed = "duplicate tab"

        #expect(browser.offers.first?.kind == .search)
        #expect(actions(browser.offers).contains("command:tabs.duplicate"))
        #expect(browser.picked == nil)
    }

    @Test func anAddressGetsNoCommandRows() {
        let browser = fresh()
        defer { browser.closeAll() }

        let rows = browser.fieldRows(for: "reload.example/page")

        #expect(rows.isEmpty)
    }

    @Test func takingARowRunsTheCommandAndClosesTheField() throws {
        let browser = fresh()
        defer { browser.closeAll() }
        browser.newTab()
        browser.active?.go(to: URL(string: "https://example.com/")!)
        let count = browser.tabs.count
        browser.edit()
        browser.typed = "duplicate tab"
        let row = try #require(browser.offers.first { $0.kind == .action("command:tabs.duplicate") })

        browser.take(row)

        #expect(browser.tabs.count == (count + 1))
        #expect(!browser.editing)
        #expect(browser.typed == "")
    }

    @Test func walkingToARowAndPressingReturnRunsIt() throws {
        let browser = fresh()
        defer { browser.closeAll() }
        browser.typed = "privacy"
        let index = try #require(browser.offers.firstIndex { $0.kind == .action("settings:privacy") })

        browser.picked = index
        browser.submit()

        #expect(browser.settingsPage == .privacy)
        #expect(browser.pageTab(.settings) != nil)
    }

    @Test func pinTabPinsAndUnpins() throws {
        let browser = fresh()
        defer { browser.closeAll() }
        browser.newTab()
        browser.active?.go(to: URL(string: "https://example.com/")!)
        let tab = try #require(browser.active)
        let command = try #require(Command.named("tabs.pin"))

        command.run(browser)

        #expect(tab.pin != nil)
        command.run(browser)
        #expect(browser.active?.pin == nil)
    }
}
