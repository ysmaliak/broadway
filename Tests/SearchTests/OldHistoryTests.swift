import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct OldHistoryTests {
    private let personal = UUID()
    private let work = UUID()
    private let yesterday = Date().addingTimeInterval(-86_400)
    private let lastWeek = Date().addingTimeInterval(-7 * 86_400)

    private func folder() throws -> URL {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("old-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: made) }
        return made
    }

    private func history(in folder: URL) -> History {
        History(file: folder.appendingPathComponent("history.json"), pages: folder.appendingPathComponent("pagetext.sqlite"))
    }

    private func old(_ address: String, _ count: Int, last: Date, extra: String = "") -> String {
        "{\"url\":\"\(address)\",\"key\":\"\(address)\",\"title\":\"Page\",\"count\":\(count),\"last\":\(last.timeIntervalSinceReferenceDate)\(extra)}"
    }

    private func oldFile(in folder: URL, _ visits: [String]) throws -> History {
        try Data(("[" + visits.joined(separator: ",") + "]").utf8).write(to: folder.appendingPathComponent("history.json"))
        return history(in: folder)
    }

    private func standard(in folder: URL) throws -> History {
        try oldFile(in: folder, [
            old("https://github.com/pulls", 82, last: yesterday),
            old("https://www.youtube.com/@numberphile", 19, last: lastWeek),
            old("https://linear.app/acme/issue/ACM-12", 4, last: yesterday),
        ])
    }

    private func lines(_ history: History, in space: UUID) -> [String] {
        LiveSuggestions.from(history.everything(in: space), folders: []).map(\.line)
    }

    private func written(_ folder: URL, containing text: String) async throws {
        let file = folder.appendingPathComponent("history.json")
        for _ in 0..<200 where (try? String(contentsOf: file, encoding: .utf8))?.contains(text) != true {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func withOneSpaceEveryOldVisitIsThatSpacesAsItWas() throws {
        let history = try standard(in: try folder())
        #expect(history.hasUnplaced)

        history.placeOldVisits(in: [personal], held: [:])

        #expect(lines(history, in: personal) == ["82 visits", "19 visits · @numberphile", "4 visits · acme"])
        let pulls = try #require(history.everything(in: personal).first { $0.key == "https://github.com/pulls" })
        #expect(pulls.count == 82)
        #expect(abs(pulls.last.timeIntervalSince(yesterday)) < 0.01)
        #expect(history.trace("https://github.com/pulls")?.count == 82)
        #expect(!history.hasUnplaced)
    }

    @Test func withTwoSpacesASiteHeldByOneGoesToThatOne() throws {
        let history = try standard(in: try folder())
        let held = History.held(in: [personal, work], tabs: [
            work: ["https://github.com/acme/web/pull/3"],
            personal: ["https://m.youtube.com/watch?v=1", "https://www.youtube.com/@veritasium"],
        ])

        history.placeOldVisits(in: [personal, work], held: held)

        #expect(lines(history, in: work) == ["82 visits"])
        #expect(lines(history, in: personal) == ["19 visits · @numberphile"])
        let videos = try #require(history.everything(in: personal).first)
        #expect(abs(videos.last.timeIntervalSince(lastWeek)) < 0.01)
    }

    @Test func aSiteHeldByBothSpacesStaysWithNeither() throws {
        let history = try standard(in: try folder())
        let held = History.held(in: [personal, work], tabs: [
            work: ["https://github.com/acme/web/pull/3"],
            personal: ["https://github.com/mine/dotfiles"],
        ])

        history.placeOldVisits(in: [personal, work], held: held)

        #expect(lines(history, in: work).isEmpty)
        #expect(lines(history, in: personal).isEmpty)
        #expect(history.trace("https://github.com/pulls")?.count == 82)
    }

    @Test func aSiteHeldByNeitherSpaceStaysWithNeither() throws {
        let history = try standard(in: try folder())
        let held = History.held(in: [personal, work], tabs: [
            work: ["https://figma.com/file/1"],
            personal: ["https://news.ycombinator.com/"],
        ])

        history.placeOldVisits(in: [personal, work], held: held)

        #expect(lines(history, in: work).isEmpty)
        #expect(lines(history, in: personal).isEmpty)
        #expect(!history.hasUnplaced)
    }

    @Test func aPinnedTileIsEvidence() throws {
        let history = try standard(in: try folder())
        let held = History.held(in: [personal, work], tabs: [:], pins: [personal: ["https://www.youtube.com/"]])

        history.placeOldVisits(in: [personal, work], held: held)

        #expect(lines(history, in: personal) == ["19 visits · @numberphile"])
        #expect(lines(history, in: work).isEmpty)
    }

    @Test func aPinKeptInEverySpaceIsNoOneSpacesAndATabInWorkStillPlacesTheSite() throws {
        let history = try standard(in: try folder())
        let everywhere = UUID()
        let shared = Session.Entry(url: "https://github.com/", title: "GitHub", pin: "G", home: "https://github.com/", pinID: everywhere)
        let tab = Session.Entry(url: "https://github.com/acme/web/pull/3", title: "PR")
        Session.write(now: true, space: personal, Session.Shape(tabs: [shared], active: -1))
        Session.write(now: true, space: work, Session.Shape(tabs: [shared, tab], active: -1))
        addTeardownBlock { [personal, work] in
            Session.erase(space: personal)
            Session.erase(space: work)
        }

        let rows = LinkRules.rows([personal, work], leaving: [everywhere])
        history.placeOldVisits(in: [personal, work], held: History.held(in: [personal, work], tabs: rows))

        #expect(rows[personal] == [])
        #expect(lines(history, in: work) == ["82 visits"])
        #expect(lines(history, in: personal).isEmpty)
    }

    @Test func aLinkRuleIsEvidenceAndOneSwitchedOffIsNot() throws {
        let history = try standard(in: try folder())
        var off = LinkRule(match: .site("youtube.com"), target: .space(work, folder: nil))
        off.on = false
        let held = History.held(in: [personal, work], tabs: [:], rules: [
            LinkRule(match: .site("linear.app"), target: .space(work, folder: nil)),
            LinkRule(match: .site("github.com"), target: .window(nil)),
            off,
        ])

        history.placeOldVisits(in: [personal, work], held: held)

        #expect(lines(history, in: work) == ["4 visits · acme"])
        #expect(lines(history, in: personal).isEmpty)
    }

    @Test func aLiveFolderReadingTheSiteIsEvidence() throws {
        let history = try standard(in: try folder())
        let held = History.held(in: [personal, work], tabs: [:],
                                folders: [LiveFolder(space: work, name: "PRs", source: .reviewRequests)])

        history.placeOldVisits(in: [personal, work], held: held)

        #expect(lines(history, in: work) == ["82 visits"])
    }

    @Test func aSpaceThatNoLongerExistsIsNoEvidence() throws {
        let history = try standard(in: try folder())
        let gone = UUID()
        let held = History.held(in: [personal, work], tabs: [
            gone: ["https://github.com/acme/web/pull/3"],
            work: ["https://github.com/acme/api"],
        ])

        history.placeOldVisits(in: [personal, work], held: held)

        #expect(lines(history, in: work) == ["82 visits"])
    }

    @Test func itRunsOnceAndNeverAgainForThatFile() async throws {
        let folder = try folder()
        let first = try standard(in: folder)
        first.placeOldVisits(in: [personal, work], held: [:])
        first.record(URL(string: "https://www.youtube.com/@veritasium")!, title: "Veritasium")
        try await written(folder, containing: "veritasium")
        let held = History.held(in: [personal, work], tabs: [work: ["https://github.com/"], personal: ["https://youtube.com/"]])

        let again = history(in: folder)
        again.placeOldVisits(in: [personal, work], held: held)

        #expect(!again.hasUnplaced)
        #expect(again.everything(in: work).isEmpty)
        #expect(again.everything(in: personal).isEmpty)
        #expect(again.trace("https://github.com/pulls")?.count == 82)
    }

    @Test func aFileWrittenWithSpacesKeepsItsSpacesAndOnlyItsOldPagesArePlaced() throws {
        let stamped = ",\"spaces\":{\"\(work.uuidString)\":{\"count\":1,\"last\":\(yesterday.timeIntervalSinceReferenceDate)}}"
        let history = try oldFile(in: try folder(), [
            old("https://github.com/pulls", 83, last: yesterday, extra: stamped),
            old("https://www.youtube.com/@numberphile", 19, last: lastWeek),
        ])
        let held = History.held(in: [personal, work], tabs: [personal: ["https://github.com/", "https://youtube.com/"]])

        history.placeOldVisits(in: [personal, work], held: held)

        #expect(lines(history, in: work) == ["1 visit"])
        #expect(lines(history, in: personal) == ["19 visits · @numberphile"])
        #expect(history.trace("https://github.com/pulls")?.count == 83)
    }

    @Test func spacesSwitchedOffGiveEveryOldVisitToTheFirstSpace() throws {
        let history = try standard(in: try folder())
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let prefs = browser.prefs
        let previous = prefs.usesSpaces
        addTeardownBlock {
            prefs.usesSpaces = previous
            browser.closeAll()
        }
        prefs.usesSpaces = false

        history.placeOldVisits(for: browser)

        #expect(lines(history, in: Space.firstID) == ["82 visits", "19 visits · @numberphile", "4 visits · acme"])
    }

    @Test func aPrivateWindowsTabIsNoEvidence() async throws {
        let server = try LocalPageServer([
            "/hidden": .init(type: "text/html", body: "<!doctype html><title>Hidden</title><p>hidden"),
        ])
        defer { server.stop() }
        let address = server.url("/hidden").absoluteString
        let folder = try folder()
        let history = try oldFile(in: folder, [old(address, 12, last: yesterday), old("https://github.com/pulls", 82, last: yesterday)])
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let quiet = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        let prefs = browser.prefs
        let previous = (prefs.usesSpaces, browser.spaces)
        let home = Space(id: UUID(), name: "Home", colour: 0)
        let office = Space(id: UUID(), name: "Office", colour: 1)
        let folders = LiveFolders.shared
        let reading = folders.add(name: "PRs", source: .reviewRequests, space: office.id)
        addTeardownBlock {
            folders.remove(reading.id)
            prefs.usesSpaces = previous.0
            browser.spaces = previous.1
            quiet.closeAll()
            browser.closeAll()
        }
        prefs.usesSpaces = true
        browser.spaces = [home, office]
        quiet.arrive(server.url("/hidden"))
        let hidden = try #require(quiet.active)
        for _ in 0..<400 where hidden.web.isLoading || hidden.web.url == nil {
            try await Task.sleep(for: .milliseconds(25))
        }

        history.placeOldVisits(for: quiet)
        let waited = history.hasUnplaced
        history.placeOldVisits(for: browser)

        #expect(hidden.address?.absoluteString == address)
        #expect(waited)
        #expect(history.everything(in: home.id).isEmpty)
        #expect(history.everything(in: office.id).map(\.key) == ["https://github.com/pulls"])
        #expect(history.trace(address)?.count == 12)
    }
}
