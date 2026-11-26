import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct SpacesUnreadTests {
    private let away = UUID()
    private let source = LiveSource(kind: .feed, address: "https://example.com/feed.xml")

    private func world() throws -> (folder: URL, live: URL, spaces: URL, home: LiveFolder, other: LiveFolder, bytes: Data) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-unread-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let home = LiveFolder(space: Space.firstID, name: "Home News", source: source)
        let other = LiveFolder(space: away, name: "Work News", source: source)
        let bytes = try #require(LiveFile.written([home, other], foreign: []))
        let live = folder.appendingPathComponent("live-folders.json")
        try bytes.write(to: live)
        return (folder, live, folder.appendingPathComponent("spaces.json"), home, other, bytes)
    }

    private func kept(_ file: URL) throws -> [UUID] {
        let data = try Data(contentsOf: file)
        return try #require(LiveFile.read(data, retiredKinds: LiveFolders.retiredKinds)).kept.map(\.id)
    }

    @Test func anUnreadableListOfSpacesLeavesTheLiveFoldersFileAsItWas() throws {
        let made = try world()
        defer { try? FileManager.default.removeItem(at: made.folder) }
        try Data("[{\"id\": \"00000000-0000-0000-0000-0000000".utf8).write(to: made.spaces)

        let live = LiveFolders(file: made.live, housing: Spaces.listed(at: made.spaces))
        Disk.drain()

        #expect(try Data(contentsOf: made.live) == made.bytes)
        #expect(live.folders.map(\.id) == [made.home.id])
        #expect(live.waiting.map(\.id) == [made.other.id])
    }

    @Test func aFolderAddedAfterAnUnreadableListKeepsTheWaitingOnes() throws {
        let made = try world()
        defer { try? FileManager.default.removeItem(at: made.folder) }
        try Data("not a list".utf8).write(to: made.spaces)

        let live = LiveFolders(file: made.live, housing: Spaces.listed(at: made.spaces))
        let added = live.add(name: "More News", source: source, space: Space.firstID)
        Disk.drain()

        #expect(Set(try kept(made.live)) == [made.home.id, made.other.id, added.id])
    }

    @Test func aReadableListWithoutTheSpaceStillDropsItsFolders() throws {
        let made = try world()
        defer { try? FileManager.default.removeItem(at: made.folder) }
        try JSONEncoder().encode([Space.first()]).write(to: made.spaces)

        let live = LiveFolders(file: made.live, housing: Spaces.listed(at: made.spaces))
        Disk.drain()

        #expect(live.folders.map(\.id) == [made.home.id])
        #expect(live.waiting.isEmpty)
        #expect(try kept(made.live) == [made.home.id])
    }

    @Test func aMissingListOfSpacesKeepsTheDefaultSpacesFolders() throws {
        let made = try world()
        defer { try? FileManager.default.removeItem(at: made.folder) }

        let live = LiveFolders(file: made.live, housing: Spaces.listed(at: made.spaces))
        Disk.drain()

        #expect(live.folders.map(\.id) == [made.home.id])
        #expect(try Data(contentsOf: made.live) == made.bytes)
    }

    @Test func signInsOfSpacesNotReadAreKept() {
        let accounts = [Space.firstID.uuidString, away.uuidString]

        #expect(SignInKeeper.outgoing(accounts, keeping: nil).isEmpty)
        #expect(SignInKeeper.outgoing(accounts, keeping: [Space.first()]) == [away.uuidString])
    }

    @Test func aWaitingSpacesTabsAreNeverWrittenOver() {
        defer { Session.erase(space: away) }
        let waiting = Session.Shape(tabs: [Session.Entry(url: "https://example.com/kept", title: "Kept")], active: 0)
        Session.write(now: true, space: away, waiting)

        Browser.keepUnlisted(Session.Shape(tabs: [Session.Entry(url: "https://example.com/other", title: "Other")], active: 0), in: away)
        Browser.keepUnlisted(Session.Shape(tabs: [], active: 0), in: away)
        Disk.drain()

        #expect(Session.read(space: away).tabs.map(\.url) == ["https://example.com/kept"])
    }

    @Test func aWaitingSpaceWithNoTabsTakesTheWindowsRow() {
        defer { Session.erase(space: away) }

        Browser.keepUnlisted(Session.Shape(tabs: [Session.Entry(url: "https://example.com/carried", title: "Carried")], active: 0), in: away)
        Disk.drain()

        #expect(Session.read(space: away).tabs.map(\.url) == ["https://example.com/carried"])
    }

    @Test func oldVisitsAreNotPlacedWhileTheSpacesAreUnread() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let wasRead = Spaces.listRead, used = browser.prefs.usesSpaces
        defer {
            Spaces.listRead = wasRead
            browser.prefs.usesSpaces = used
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-unread-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let visit = "{\"url\":\"https://example.com/\",\"key\":\"https://example.com/\",\"title\":\"Page\",\"count\":3,\"last\":\(Date().timeIntervalSinceReferenceDate)}"
        try Data("[\(visit)]".utf8).write(to: folder.appendingPathComponent("history.json"))
        let history = History(file: folder.appendingPathComponent("history.json"), pages: folder.appendingPathComponent("pagetext.sqlite"))
        browser.prefs.usesSpaces = true
        Spaces.listRead = false

        history.placeOldVisits(for: browser)

        #expect(history.hasUnplaced)
    }

    @Test func anotherWindowKeepsItsRowsOfSpacesNotRead() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.leaveFiles()
        browser.record.rows[away.uuidString] = Session.Shape(tabs: [], active: 0)
        let wasRead = Spaces.listRead
        defer { Spaces.listRead = wasRead }

        Spaces.listRead = false
        let waiting = browser.allRows()[away.uuidString]
        Spaces.listRead = true
        let dropped = browser.allRows()[away.uuidString]

        #expect(waiting != nil)
        #expect(dropped == nil)
    }

    private func asides(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("spaces.unreadable-") }.map { folder.appendingPathComponent($0) }
    }

    @Test func aDamagedListIsSetAsideBeforeANewSpaceIsWrittenAndTheFoldersStillWait() throws {
        let made = try world()
        defer { try? FileManager.default.removeItem(at: made.folder) }
        let damaged = Data("[{\"id\": \"00000000-0000-0000".utf8)
        try damaged.write(to: made.spaces)
        let added = Space(id: UUID(), name: "Added", colour: 0)

        Spaces.put([Space.first(), added], at: made.spaces)

        let aside = asides(in: made.folder)
        #expect(aside.count == 1)
        #expect(try aside.first.map { try Data(contentsOf: $0) } == damaged)
        #expect(Spaces.listed(at: made.spaces) == [Space.firstID, added.id])
        #expect(!Spaces.trusted(at: made.spaces))

        let relaunch = LiveFolders(file: made.live, housing: Spaces.trusted(at: made.spaces) ? Spaces.listed(at: made.spaces) : nil)
        Disk.drain()

        #expect(relaunch.waiting.map(\.id) == [made.other.id])
        #expect(Set(try kept(made.live)) == [made.home.id, made.other.id])
        #expect(try Data(contentsOf: made.live) == made.bytes)
    }

    @Test func aReadableListIsWrittenOverWithNothingSetAside() throws {
        let made = try world()
        defer { try? FileManager.default.removeItem(at: made.folder) }
        try JSONEncoder().encode([Space.first()]).write(to: made.spaces)

        Spaces.put([Space.first(), Space(id: away, name: "Away", colour: 0)], at: made.spaces)

        #expect(asides(in: made.folder).isEmpty)
        #expect(Spaces.trusted(at: made.spaces))
    }

    @Test func aMissingListIsWrittenWithNothingSetAside() throws {
        let made = try world()
        defer { try? FileManager.default.removeItem(at: made.folder) }

        Spaces.put([Space.first()], at: made.spaces)

        #expect(asides(in: made.folder).isEmpty)
        #expect(Spaces.trusted(at: made.spaces))
    }

    @Test func theSpacesComeBackWithEverythingWhenTheSetAsideFileIsPutBack() throws {
        let made = try world()
        defer { try? FileManager.default.removeItem(at: made.folder) }
        try Data("not a list".utf8).write(to: made.spaces)
        Spaces.put([Space.first()], at: made.spaces)
        let aside = try #require(asides(in: made.folder).first)
        try FileManager.default.removeItem(at: aside)
        try JSONEncoder().encode([Space.first(), Space(id: away, name: "Away", colour: 0)]).write(to: made.spaces)

        let relaunch = LiveFolders(file: made.live, housing: Spaces.trusted(at: made.spaces) ? Spaces.listed(at: made.spaces) : nil)
        Disk.drain()

        #expect(Spaces.trusted(at: made.spaces))
        #expect(Set(relaunch.folders.map(\.id)) == [made.home.id, made.other.id])
        #expect(Set(try kept(made.live)) == [made.home.id, made.other.id])
    }
}
