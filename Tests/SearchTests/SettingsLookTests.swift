import AppKit
import Testing
@testable import Search

@MainActor
@Suite("Settings look and words", .serialized, .timeLimit(.minutes(5)))
struct SettingsLookTests {
    @Test("every row, group and detail names a symbol this Mac has")
    func everySymbolResolves() {
        let rows = SettingsIndex.items.map { ($0.id, $0.icon) }
        let groups = SettingsIndex.groups.map { ($0.id, $0.icon) }
        let details = SettingsDetail.allCases.map { ($0.rawValue, $0.symbol) }

        let missing = (rows + groups + details).filter { NSImage(systemSymbolName: $0.1, accessibilityDescription: nil) == nil }

        #expect(missing.isEmpty, "\(missing)")
    }

    @Test("the rail lists every page exactly once")
    func railHoldsEveryPage() {
        let rail = SettingsPage.blocks.flatMap { $0 }

        let pages = Set(rail)

        #expect(rail.count == SettingsPage.allCases.count)
        #expect(pages == Set(SettingsPage.allCases))
        #expect(rail == SettingsPage.allCases)
        #expect(SettingsPage.blocks.first == [.general, .field, .appearance, .websites, .links, .tabs, .shortcuts])
        #expect(SettingsPage.blocks.count == 2)
        #expect(SettingsPage.blocks.last == [.agents, .liveFolders, .passwords, .privacy, .extensions])
    }

    @Test("every group and every row lands on the page the split gave it", arguments: [
        ("general.default", SettingsPage.general),
        ("general.import", .general),
        ("quit.confirm", .general),
        ("downloads.folder", .general),
        ("calendars", .general),
        ("meetings.calendars", .general),
        ("routes", .links),
        ("links.open", .links),
        ("links.unwrap", .links),
        ("search.engine", .field),
        ("search.suggest", .field),
        ("search.shortcuts", .field),
        ("search.keywords", .field),
        ("search.quickactions", .field),
        ("field.snippets", .field),
        ("look", .appearance),
        ("newtab.floating", .appearance),
        ("sidebar.button", .appearance),
        ("pages.dusk", .appearance),
        ("tabs.layout", .appearance),
        ("spaces.stacked", .tabs),
        ("space.look", .appearance),
        ("notifications.ask", .websites),
        ("privacy.permissions", .websites),
        ("privacy.forget", .websites),
        ("pageZoom", .websites),
        ("tabs.close.after", .tabs),
        ("note.groups", .tabs),
        ("shortcuts", .shortcuts),
        ("shield", .privacy),
        ("history.pageText", .privacy),
        ("clear.cache", .privacy),
    ])
    func rowsLandOnTheirPage(id: String, page: SettingsPage) {
        let item = SettingsIndex.item(id)

        #expect(item?.page == page)
    }

    @Test("rows that moved to a menu are still found, and say where")
    func movedRowsAreFound() {
        let moved = ["quit.confirm", "pages.dusk", "tabs.layout", "bookmarks.bar", "autocorrect"]

        let items = moved.compactMap(SettingsIndex.item)

        #expect(items.count == moved.count)
        for item in items {
            #expect(item.findOnly, "\(item.id)")
            #expect(SettingsIndex.find(item.title).contains { $0.id == item.id }, "\(item.id)")
        }
    }

    @Test("old names still find the rows they named", arguments: [
        ("open links from other apps", "general.default"),
        ("bring things over", "general.import"),
        ("confirm before quitting", "quit.confirm"),
        ("close tabs you leave alone", "tabs.close.after"),
        ("suggestions from your search engine", "search.suggest"),
        ("new tabs show", "newtab.floating"),
        ("look", "space.look"),
        ("local network", "privacy.forget"),
    ])
    func oldNamesStillFind(words: String, id: String) {
        let found = SettingsIndex.find(words)

        #expect(found.contains { $0.id == id })
    }

    @Test("titles stay short enough for the narrowest window")
    func titlesAreShort() {
        let shown = SettingsIndex.items.filter { !$0.findOnly }

        let long = shown.filter { $0.title.count > 40 }

        #expect(long.isEmpty, "\(long.map(\.title))")
    }

    @Test("every page says what it is in one short line")
    func summariesAreShort() {
        for page in SettingsPage.allCases {
            #expect(page.summary.count <= 80, "\(page): \(page.summary.count)")
            #expect(!page.summary.hasSuffix("."), "\(page)")
        }
    }
}
