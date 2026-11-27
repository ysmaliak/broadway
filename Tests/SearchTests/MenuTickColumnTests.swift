import AppKit
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class MenuTickColumnTests {
    private var browser: Browser!

    init() {
        _ = NSApplication.shared
        keepSetting(Shared.prefs, \.liveFolders, "live.on")
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.liveFolders = true
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        LiveFolders.shared.reader = { _ in .failed }
    }

    private func tearDown() async {
        LiveFolders.shared.reader = { await LiveReader.read($0) }
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    private static func symbol(_ image: NSImage?) -> Bool {
        guard let image, image !== MenuIcons.blank else { return false }
        return image.representations.contains { String(describing: type(of: $0)).contains("Symbol") }
    }

    private static func levels(_ menu: NSMenu) -> [NSMenu] {
        [menu] + menu.items.compactMap(\.submenu).flatMap(levels)
    }

    private static func symbolsBesideTicks(_ menu: NSMenu) -> [String] {
        levels(menu).filter { $0.items.contains { $0.state != .off } }.flatMap { level in
            level.items.filter { symbol($0.image) && $0.preferredImageVisibility != .hidden }.map(\.title)
        }
    }

    private func liveMenu(hides: Bool) -> NSMenu {
        var source = LiveSource.pullRequests
        source.hidesDraftReviews = hides ? true : nil
        let made = LiveFolders.shared.add(name: "Reviews", source: source, space: browser.spaceID)
        return FolderMenus.menu(browser: browser, group: TabGroup(id: made.id, name: "Reviews", collapsed: true, live: true))
    }

    @Test func theTestKnowsASymbolFromAPicture() {
        #expect(Self.symbol(KitGlyph.plain(MenuSymbol.reload)))
        #expect(!Self.symbol(MenuIcons.blank))
        #expect(!Self.symbol(browser.space.menuMark))
    }

    @Test func theLiveFolderMenusTickSitsInTheColumnItsSymbolsUse() {
        let menu = liveMenu(hides: true)
        let ticked = menu.items.first { $0.title == "Hide Draft Review Requests" }
        let symboled = menu.items.filter { ["Update Now", "Rename Folder", "Remove Folder…"].contains($0.title) }

        #expect(ticked?.state == .on)
        #expect(ticked?.image == nil)
        #expect(ticked?.offStateImage == nil)
        #expect(symboled.count == 3)
        #expect(symboled.allSatisfy { $0.image == nil && Self.symbol($0.offStateImage) })
        #expect(Self.symbolsBesideTicks(menu) == [])
    }

    @Test func theLiveFolderMenuKeepsItsShapeWithTheTickOff() {
        let menu = liveMenu(hides: false)
        let unticked = menu.items.first { $0.title == "Hide Draft Review Requests" }
        let update = menu.items.first { $0.title == "Update Now" }

        #expect(unticked?.state == .off)
        #expect(unticked?.image == nil && unticked?.offStateImage == nil)
        #expect(update?.image == nil && Self.symbol(update?.offStateImage))
    }

    @Test func aKitMenuWithARowThatCanBeTickedPutsItsSymbolsInTheTicksColumn() {
        let menu = KitMenu.make([
            .action("Reload", symbol: MenuSymbol.reload) {},
            .action("Follow", on: false) {},
            .action("Pinned", symbol: MenuSymbol.pin, on: true) {},
            .submenu("Move", symbol: MenuSymbol.move, [.action("Up") {}]),
        ])
        let plain = KitMenu.make([.action("Reload", symbol: MenuSymbol.reload) {}])

        #expect(menu.items[0].image == nil && Self.symbol(menu.items[0].offStateImage))
        #expect(menu.items[1].image == nil && menu.items[1].offStateImage == nil)
        #expect(menu.items[2].state == .on && menu.items[2].image == nil && menu.items[2].offStateImage == nil)
        #expect(menu.items[3].image == nil && Self.symbol(menu.items[3].offStateImage))
        #expect(Self.symbol(plain.items[0].image) && plain.items[0].offStateImage == nil)
    }

    @Test func everyMenuWithATickKeepsItsSymbolsInTheTicksColumn() throws {
        let tab = Tab(shy: true, configuration: Web.configuration(shy: true))
        tab.restore(url: URL(string: "https://example.fr/")!, title: "Example")
        tab.translation = TranslationMark(from: "fr", to: "en", phase: .done)
        tab.setAlwaysTranslates("fr", true)
        let pins = [Extensions.Button(id: "a", name: "Alpha", label: "Alpha", icon: nil, badge: "", enabled: true, pinned: true)]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = Tab(configuration: configuration)
        page.setAddressOptimistically(URL(string: "https://example.com/")!)
        browser.prepare(page)
        browser.insert(page, at: browser.tabs.count)
        let group = browser.newFolder(with: [page], editing: false)
        let linear = LiveFolders.shared.add(name: "Issues", source: .linear(.assigned), space: browser.spaceID)
        let song = MiniPlayer.Item(id: UUID(), title: "Born To Fly", detail: "A Singer", site: "music.example", art: nil, playing: true,
                                   pair: .seconds, previous: true, next: true,
                                   position: MiniPosition(time: 71, duration: 10800, rate: 1, playing: true, at: Date()),
                                   live: false, rate: 1, speed: true, seekable: true, muted: false, skip: 15)
        let menus: [(String, NSMenu)] = [
            ("live folder", liveMenu(hides: true)),
            ("translate", TranslateMenu(tab: tab) {}.menu),
            ("space", SpaceMenu.menu(for: browser, icon: true)),
            ("extensions", ExtensionsMenu.menu(for: .shared, buttons: pins)),
            ("site card", SiteCard(browser: browser, tab: tab).menu),
            ("linear folder", FolderMenus.menu(browser: browser, group: TabGroup(id: linear.id, name: "Issues", collapsed: true, live: true))),
            ("folder", FolderMenus.menu(browser: browser, group: try #require(browser.tabGroups.first { $0.id == group }))),
            ("tab", TabMenuItems.menu(browser: browser, tab: page, close: {})),
            ("plus", PlusMenu.menu(for: browser)),
            ("column", PlusMenu.column(for: browser)),
            ("mini player", KitMenu.make(MiniPlayerView.menuItems(song, mini: MiniPlayer(surface: song)))),
        ]

        for (_, menu) in menus { MenuIcons.show(menu) }

        #expect(menus.allSatisfy { !$0.1.items.isEmpty })
        #expect(menus.flatMap { name, menu in Self.symbolsBesideTicks(menu).map { name + ": " + $0 } } == [])
    }

    @Test func theTranslateMenusTickAndItsSymbolShareOneColumn() {
        let tab = Tab(bench: true)
        tab.restore(url: URL(string: "https://example.fr/")!, title: "Example")
        tab.translation = TranslationMark(from: "fr", to: "en", phase: .done)

        let menu = TranslateMenu(tab: tab) {}.menu
        let original = menu.items.first { $0.title == "Show Original" }
        let always = menu.items.first { $0.title == "Always Translate French" }

        #expect(original?.image == nil && Self.symbol(original?.offStateImage))
        #expect(always?.state == .off && always?.image == nil && always?.offStateImage == nil)
    }
}
