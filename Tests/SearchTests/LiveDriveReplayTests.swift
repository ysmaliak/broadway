import Foundation
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LiveDriveReplayTests {
    private let now = LiveDriveTests.now
    private var server: LocalPageServer!

    init() throws {
        setenv("SEARCH_PROBE", "live-drive-replay-\(getpid())", 1)
        addTeardownBlock { await self.tearDown() }
        func html(_ body: String) -> LocalPageServer.Page { .init(type: "text/html", body: "<!doctype html><title>Recent - Google Drive</title>" + body) }
        server = try LocalPageServer([
            "/stage/drive.google.com/drive/recent": html("<script>" + LiveDriveTests.script(LiveDriveTests.three) + "</script><div id=drive></div>"),
            "/stage/drive.google.com/drive/u/1/recent": .init(status: "302 Found", type: "text/html", body: "",
                                                               headers: ["Location": "/stage/accounts.google.com/v3/signin/identifier?continue=x"]),
            "/stage/accounts.google.com/v3/signin/identifier": .init(type: "text/html",
                                                                     body: "<!doctype html><form><input type=email name=identifier><button>Next</button></form>"),
            "/stage/drive.google.com/drive/u/2/recent": html("<script>var other = {files: []};</script><div id=drive></div>"),
            "/stage/drive.google.com/drive/u/3/recent": .init(status: "429 Too Many Requests", type: "text/html",
                                                               body: "<!doctype html><p>Too many requests</p>", headers: ["Retry-After": "120"]),
        ])
    }

    private func tearDown() async {
        server.stop()
        server = nil
    }

    private func read(_ address: String) async -> LiveReader.Answer {
        let source = LiveSource(kind: .page, address: address)
        return await LiveDrive.read(URL(string: address)!, root: server.url("/stage"), source: source, store: .nonPersistent(), now: now)
    }

    private func folder(_ titles: [String]) -> LiveFolder {
        var made = LiveFolder(space: UUID(), name: "Recent Files", source: LiveDrive.source)
        let stem = "1KeptRowNumber000000000000"
        made.items = titles.enumerated().map { LiveItem(key: "https://docs.google.com/document/d/\(stem)\($0.offset)/edit",
                                                        title: $0.element, label: "Doc", updated: now) }
        made.state = .fine
        made.noticing = true
        return made
    }

    @Test func aGoodListReadsThreeRowsNewestFirst() async {
        let answer = await read("https://drive.google.com/drive/recent")
        guard case .read(let read) = answer else { Issue.record("not a read: \(answer)"); return }
        #expect(read.items.map(\.title) == ["Harbour lights budget", "Tide tables for the spit", "Ferry timetable, winter"])
        let after = LiveTrust.after(folder(["Kept"]), answer, now: now)
        #expect(after.state == .fine)
        #expect(after.items.map(\.title) == read.items.map(\.title))
        #expect(server.requests.allSatisfy { $0.hasPrefix("/stage/drive.google.com/") })
    }

    @Test func aSignInPageIsSignedOutAndKeepsTheRows() async {
        let answer = await read("https://drive.google.com/drive/u/1/recent")
        #expect(answer == .signIn)
        let after = LiveTrust.after(folder(["Kept", "Also kept"]), answer, now: now)
        #expect(after.state == .signIn)
        #expect(after.items.count == 2)
    }

    @Test func anUnknownShapeIsCouldntReadAndKeepsTheRows() async {
        let answer = await read("https://drive.google.com/drive/u/2/recent")
        #expect(answer == .failed)
        let after = LiveTrust.after(folder(["Kept", "Also kept"]), answer, now: now)
        #expect(after.state == .failed)
        #expect(after.note == .failed)
        #expect(after.items.count == 2)
    }

    @Test func aLimitWaitsAndKeepsTheRows() async {
        let answer = await read("https://drive.google.com/drive/u/3/recent")
        #expect(answer == .missed(LiveMiss(cause: .limited, wait: 120)))
        let after = LiveTrust.after(folder(["Kept"]), answer, now: now)
        #expect(after.status == "Limited")
        #expect(after.items.count == 1)
    }
}
