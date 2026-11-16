import Foundation
import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class TabIconTests {
    private var browser: Browser!
    private let site = URL(string: "https://example.com/a")!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesTabGroups = true
    }

    private func tearDown() async {
        browser.closeAll()
        browser = nil
    }

    private func page() -> Tab {
        browser.newTab()
        let tab = browser.active!
        tab.restore(url: site, title: "Page")
        return tab
    }

    @Test func aCustomIconWinsAndAFaviconArrivingDoesNotReplaceIt() {
        let tab = page()
        let favicon = NSImage(size: NSSize(width: 8, height: 8))

        tab.customIcon = TabIcon(emoji: "🎉")
        let custom = tab.icon
        tab.icon = favicon

        #expect(custom != nil)
        #expect(tab.icon === custom)
        #expect(!(tab.icon === favicon))
    }

    @Test func restoringBringsTheFaviconBack() {
        let tab = page()
        let favicon = NSImage(size: NSSize(width: 8, height: 8))
        tab.customIcon = TabIcon(symbol: "star")
        tab.icon = favicon

        tab.customIcon = nil

        #expect(tab.icon === favicon)
    }

    @Test func aSymbolIsATemplateAndAnEmojiIsNot() {
        let symbol = TabIcon(symbol: "star").image
        let emoji = TabIcon(emoji: "🎉").image

        #expect(symbol?.isTemplate == true)
        #expect(emoji?.isTemplate == false)
    }

    @Test func aSymbolThatDoesNotExistFallsBackToTheSite() {
        let tab = page()
        let favicon = NSImage(size: NSSize(width: 8, height: 8))
        tab.icon = favicon

        tab.customIcon = TabIcon(symbol: "no.such.symbol.at.all")

        #expect(tab.icon === favicon)
    }

    @Test func aSessionEntryKeepsItsIcon() throws {
        var entry = Session.Entry(url: "https://example.com", title: "Page")
        entry.icon = TabIcon(emoji: "🎉")

        let back = try JSONDecoder().decode(Session.Entry.self, from: JSONEncoder().encode(entry))

        #expect(back.icon == TabIcon(emoji: "🎉"))
    }

    @Test func anOldSessionEntryDecodes() throws {
        let old = #"{"url":"https://example.com","title":"Old","muted":false}"#

        let entry = try JSONDecoder().decode(Session.Entry.self, from: Data(old.utf8))

        #expect(entry.icon == nil)
    }

    @Test func aFolderKeepsItsIconWhenDecoded() throws {
        var group = TabGroup(id: UUID(), name: "Work", collapsed: false)
        group.icon = TabIcon(symbol: "star")

        let back = try JSONDecoder().decode(TabGroup.self, from: JSONEncoder().encode(group))

        #expect(back.icon == TabIcon(symbol: "star"))
    }

    @Test func anOldPinDefDecodes() throws {
        let id = UUID().uuidString
        let old = #"{"id":"\#(id)","letter":"E","home":"https://example.com","title":"Example"}"#

        let def = try JSONDecoder().decode(PinDef.self, from: Data(old.utf8))

        #expect(def.icon == nil)
    }

    @Test func aPinsIconReachesItsDefAndComesBackFromIt() throws {
        let tab = page()
        browser.pin(tab)
        tab.customIcon = TabIcon(emoji: "🎉")

        browser.writeSession(now: true)
        let def = try #require(Pins.defs(browser.spaceID).first { $0.id == tab.pinID })
        tab.customIcon = nil
        let row = browser.reconcilePins(browser.tabs, space: browser.spaceID)

        #expect(def.icon == TabIcon(emoji: "🎉"))
        #expect(row.first { $0.id == tab.id }?.customIcon == TabIcon(emoji: "🎉"))
    }

    @Test func settingAnIconThroughTheBrowserCoversTabsAndFolders() throws {
        let tab = page()
        let id = try #require(browser.newFolder(with: [tab], named: "Work", editing: false))

        browser.setIcon(TabIcon(symbol: "star"), of: .tab(tab.id))
        browser.setIcon(TabIcon(emoji: "🎉"), of: .folder(id))

        #expect(browser.icon(of: .tab(tab.id)) == TabIcon(symbol: "star"))
        #expect(browser.icon(of: .folder(id)) == TabIcon(emoji: "🎉"))
    }

    @Test func choicesAreSearchable() {
        let party = IconChoices.found(IconChoices.emoji, "party popper")
        let travel = IconChoices.found(IconChoices.symbols, "travel")

        #expect(party.first?.icon.emoji == "🎉")
        #expect(travel.first?.icon.symbol == "airplane")
        #expect(IconChoices.emoji.count > 900)
    }

    @Test func aSymbolIsFoundByItsOwnName() {
        let house = IconChoices.found(IconChoices.symbols, "house")
        let home = IconChoices.found(IconChoices.symbols, "home")

        #expect(house.first?.icon.symbol == "house")
        #expect(home.first?.icon.symbol == "house")
    }

    @Test func theSpaceMenuKeepsThePlainNameAndShowsTheIcon() throws {
        browser.spaces[0].icon = TabIcon(emoji: "🌈")
        let space = try #require(browser.spaces.first)

        let entry = try #require(SpaceMenu.menu(for: browser).items.first)

        #expect(entry.title == space.name)
        #expect(entry.attributedTitle == nil)
        #expect(entry.accessibilityTitle() == space.name)
        #expect(entry.accessibilityLabel() == space.name)
        #expect(entry.preferredImageVisibility == .visible)
        #expect(entry.image?.size == NSSize(width: 20, height: 16))
    }

    @Test func theSpaceMenuKeepsTheCheckForSpacesAndPutsEachActionsSymbolInItsPlace() throws {
        browser.spaces[0].downloads = "/tmp/Invoices"
        browser.spaces.append(Space(id: UUID(), name: "Work", colour: 0))

        let rows = SpaceMenu.menu(for: browser).items.filter { !$0.isSeparatorItem }
        let spaces = rows.prefix(browser.spaces.count)
        let actions = rows.dropFirst(browser.spaces.count)

        #expect(spaces.map(\.title) == browser.spaces.map(\.name))
        #expect(spaces.allSatisfy { $0.image != nil && $0.offStateImage == nil })
        #expect(spaces.filter { $0.state == .on }.map(\.title) == [browser.space.name])
        #expect(actions.map(\.title) == [
            "New Space…", "Rename “\(browser.space.name)”…", "Edit Look…", "Move Right",
            "Downloads to “Invoices”…", "Downloads to the Folder in Settings", "Languages: Same as Settings…",
        ])
        #expect(actions.allSatisfy { $0.image == nil && $0.offStateImage != nil && $0.state == .off })
    }

    @Test func everySymbolOnOfferExists() {
        let missing = IconChoices.symbols.filter { $0.icon.image == nil }

        #expect(missing.map(\.words) == [])
    }

    @Test(arguments: [true, false])
    func symbolsComeBeforeEmojiInEveryPicker(space: Bool) {
        let all = IconChoices.sections("", space: space)
        let moon = IconChoices.sections("moon", space: space)

        #expect(all.map(\.0) == [space ? "Icons" : "Symbols", "Emoji"])
        #expect(moon.map(\.0) == [space ? "Icons" : "Symbols", "Emoji"])
        #expect(IconChoices.first("moon", space: space)?.symbol == "moon")
        #expect(IconChoices.first("party popper", space: space)?.emoji == "🎉")
        #expect(IconChoices.sections("🎉", space: space).first?.0 == "Typed")
    }

    @Test func anEmojiTypedIntoTheFieldIsOffered() {
        #expect(IconChoices.typed("🇫🇷")?.emoji == "🇫🇷")
        #expect(IconChoices.typed("a") == nil)
        #expect(IconChoices.typed("hello") == nil)
    }
}
