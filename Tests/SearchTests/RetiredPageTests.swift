import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct RetiredPageTests {
    private let old: [String: Any] = [
        "brief.on": true, "brief.from": 5, "brief.until": 12, "brief.off": ["weather"], "brief.shown": "2026-11-14",
        "brief.sources": ["mail", "slack"], "brief.jira.site": "acme.atlassian.net", "brief.slack.workspace": "acme.slack.com",
        "weather.api": "http://127.0.0.1:1",
    ]

    private func scratch() throws -> (defaults: UserDefaults, folder: URL) {
        let name = "retired-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: folder)
        }
        return (defaults, folder)
    }

    @Test func aMacThatHadTheBriefKeepsNothingOfIt() throws {
        let (defaults, folder) = try scratch()
        for (key, value) in old { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: "meetings.alerts")
        defaults.set(false, forKey: IntegrationNow.key)
        let later = Date().addingTimeInterval(3600)
        let marks: [String: Date] = ["brief.done:mail:1@a": later, "brief.snooze:slack:2": later, "now:download:3": later]
        try JSONEncoder().encode(marks).write(to: folder.appendingPathComponent("now.json"))
        for name in ["brief-weather.json", "brief-place.json"] {
            try Data("{}".utf8).write(to: folder.appendingPathComponent(name))
        }

        SettingsCut.retire(defaults, folder: folder)

        let left = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("brief.") || $0 == "weather.api" }
        #expect(left.isEmpty)
        #expect(defaults.bool(forKey: "meetings.alerts"))
        #expect(defaults.object(forKey: IntegrationNow.key) as? Bool == false)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == ["now.json"])
        let kept = try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: folder.appendingPathComponent("now.json")))
        #expect(Array(kept.keys) == ["now:download:3"])
    }

    @Test func retiringTwiceChangesNothingMore() throws {
        let (defaults, folder) = try scratch()
        let marks: [String: Date] = ["now:download:3": Date().addingTimeInterval(3600)]
        let written = try JSONEncoder().encode(marks)
        try written.write(to: folder.appendingPathComponent("now.json"))

        SettingsCut.retire(defaults, folder: folder)
        SettingsCut.retire(defaults, folder: folder)

        #expect(try Data(contentsOf: folder.appendingPathComponent("now.json")) == written)
    }

    @Test func theOldAddressIsNoPageOfOurs() throws {
        let gone = try #require(URL(string: "broadway://brief"))

        #expect(InternalPage(url: gone) == nil)
        #expect(InternalPage.retired(gone))
        #expect(!InternalPage.retired(InternalPage(.history).url))
        #expect(!InternalPage.retired(try #require(URL(string: "https://example.com/"))))
        #expect(!PinDef(id: UUID(), letter: "B", home: gone.absoluteString, title: "Morning Brief").lasting)
        #expect(PinDef(id: UUID(), letter: "G", home: "https://github.com/", title: "GitHub").lasting)
    }

    @Test func aSessionWithTheOldTabComesBackWithoutIt() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        addTeardownBlock { browser.closeAll() }
        let before = browser.tabs.count
        browser.writeRow(Space.firstID, Session.Shape(tabs: [
            Session.Entry(url: "broadway://brief", title: "Morning Brief"),
            Session.Entry(url: "https://kept.example/", title: "Kept"),
            Session.Entry(url: "broadway://brief", title: "Morning Brief", pin: "B", home: "broadway://brief", pinID: UUID()),
        ], active: 0), now: false)

        browser.restoreSession()

        let added = Array(browser.tabs.dropFirst(before))
        #expect(added.map { $0.address?.absoluteString } == ["https://kept.example/"])
        #expect(!browser.tabs.contains { $0.address?.scheme == InternalPage.scheme })
        #expect(!browser.tabs.contains { $0.failure != nil })
    }

    @Test func aKeyOnceGivenToTheOldCommandIsForgotten() throws {
        keepSettings("shortcuts")
        let saved: [String: [String: String]] = ["view.brief": [:], "file.reopen": [:]]
        Store.settings.set(try JSONEncoder().encode(saved), forKey: "shortcuts")

        let store = ShortcutStore()

        #expect(store.changedCount == 1)
        #expect(store.isChanged("file.reopen"))
        let written = try #require(Store.settings.data(forKey: "shortcuts"))
        let ids = try JSONDecoder().decode([String: [String: String]].self, from: written).keys
        #expect(Array(ids) == ["file.reopen"])
    }

    @Test func nothingOffersTheOldPage() {
        #expect(Command.named("view.brief") == nil)
        #expect(PersonCommands.find("brief", "show") == nil)
        #expect(PersonCommands.find("brief", "read") == nil)
        #expect(SettingsDetail.named("brief") == nil)
        #expect(!SettingsIndex.items.contains { $0.id.hasPrefix("brief") })
        #expect(SettingsIndex.find("morning brief").isEmpty)
        #expect(SettingsIndex.find("weather").isEmpty)
        #expect(!InternalPage.Kind.allCases.map(\.rawValue).contains("brief"))
    }
}
