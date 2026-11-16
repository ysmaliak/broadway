import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FavoritesTests {
    private var folder: URL!

    init() async throws {
        keepSetting(Shared.prefs, \.floatingNewTab, "newtab.floating")
        addTeardownBlock { await self.tearDown() }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("favorites-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        clearShared()
        Shared.prefs.floatingNewTab = true
    }

    private func tearDown() async {
        clearShared()
        try? FileManager.default.removeItem(at: folder)
    }

    private func clearShared() {
        for favorite in Favorites.shared.list { Favorites.shared.remove(favorite.id) }
    }

    private func store() -> Favorites { Favorites(file: folder.appendingPathComponent("favorites.json")) }

    private func place(_ address: String, _ title: String) -> Suggestion {
        Suggestion(key: address, title: title, url: URL(string: "https://" + address)!, kind: .visited)
    }

    private func favorite(_ address: String, _ title: String) -> Favorite {
        Favorites.make(from: place(address, title))!
    }

    @Test func aPageIsKeptWithItsNameAndAddress() throws {
        let row = place("example.com/page", "Example")

        let kept = try #require(Favorites.make(from: row))

        #expect(kept.title == "Example")
        #expect(kept.id == "https://example.com/page")
        #expect(kept.action == nil)
    }

    @Test func aCommandIsKeptByItsAction() throws {
        let command = try #require(Command.named("tabs.duplicate"))

        let kept = try #require(Favorites.make(from: FieldCommands.row(command)))

        #expect(kept.action == "command:tabs.duplicate")
        #expect(kept.address == nil)
    }

    @Test func nowAndPageRowsCannotBeFavorites() {
        let now = Suggestion(key: "Done", title: "", url: FieldAction.nowhere, kind: .action("now:x"))
        let page = Suggestion(key: "Copy", title: "", url: FieldAction.nowhere, kind: .action("page:copy"))

        #expect(Favorites.make(from: now) == nil)
        #expect(Favorites.make(from: page) == nil)
    }

    @Test func toggleAddsThenRemovesAndKeepsAcrossLaunches() {
        let list = store()
        let kept = favorite("a.example/", "A")

        list.toggle(kept)
        Disk.drain()

        #expect(store().list.map(\.title) == ["A"])
        list.toggle(kept)
        Disk.drain()
        #expect(store().list.isEmpty)
    }

    @Test func movingStopsAtTheEnds() {
        let list = store()
        let a = favorite("a.example/", "A")
        let b = favorite("b.example/", "B")
        list.toggle(a)
        list.toggle(b)

        #expect(list.move(b.id, by: -1))
        #expect(list.list.map(\.title) == ["B", "A"])
        #expect(!list.move(b.id, by: -1))
        #expect(!list.move(a.id, by: 1))
    }

    @Test func theEmptyFieldListsFavoritesAndLightsNoRow() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        browser.active?.go(to: URL(string: "https://first.example/")!)
        let first = try #require(browser.active)
        browser.newTab()
        Favorites.shared.toggle(favorite("kept.example/", "Kept"))

        browser.retype()

        #expect(browser.fieldSections.first?.title == "Favorites")
        let recent = try #require(browser.fieldSections.first { $0.title == "Recent Tabs" })
        #expect(browser.offers[recent.range.lowerBound].tab == first.id)
        #expect(browser.picked == nil)
    }

    @Test func aFavoriteAlreadyOpenSwitchesToItsTab() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        browser.active?.go(to: URL(string: "https://open.example/")!)
        let open = try #require(browser.active)
        browser.newTab()
        Favorites.shared.toggle(favorite("open.example/", "Open"))

        let row = try #require(browser.favoriteRows().first)

        #expect(row.tab == open.id)
    }

    @Test func theKeyPinsThePickedRowAndKeepsItPicked() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        browser.active?.go(to: URL(string: "https://first.example/")!)
        browser.newTab()
        browser.retype()
        browser.walk(1)

        browser.toggleFavorite()

        #expect(Favorites.shared.list.count == 1)
        #expect(browser.fieldSections.first?.title == "Favorites")
        #expect(browser.pickedOffer != nil)
        browser.toggleFavorite()
        #expect(Favorites.shared.list.isEmpty)
    }

    @Test func reorderingKeepsThePickOnTheMovedRow() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        Favorites.shared.toggle(favorite("a.example/", "A"))
        Favorites.shared.toggle(favorite("b.example/", "B"))
        browser.retype()
        browser.picked = 1

        browser.moveFavorite(by: -1)

        #expect(Favorites.shared.list.map(\.title) == ["B", "A"])
        #expect(browser.picked == 0)
    }

    @Test func aFavoriteCommandRunsAndShowsItsKey() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        browser.active?.go(to: URL(string: "https://example.com/")!)
        let command = try #require(Command.named("tabs.duplicate"))
        Favorites.shared.toggle(try #require(Favorites.make(from: FieldCommands.row(command))))
        let count = browser.tabs.count

        let row = try #require(browser.favoriteRows().first)
        browser.take(row)

        #expect(row.keys == "⌘D")
        #expect(browser.tabs.count == (count + 1))
    }

    @Test func aPrivateFieldShowsNoFavorites() {
        let browser = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { browser.closeAll() }
        Favorites.shared.toggle(favorite("a.example/", "A"))

        browser.retype()

        #expect(browser.offers.isEmpty)
    }

    @Test func theMenuOffersFavoritesAndReorderingOnceThereAreTwo() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let row = place("a.example/", "A")
        #expect(browser.fieldMenuItems(for: row).map { $0.title }.contains("Add to Favorites"))

        Favorites.shared.toggle(favorite("a.example/", "A"))
        Favorites.shared.toggle(favorite("b.example/", "B"))
        let titles = browser.fieldMenuItems(for: row).map(\.title)

        #expect(titles.contains("Remove from Favorites"))
        #expect(titles.contains("Move Up"))
        #expect(titles.contains("Move Down"))
    }
}
