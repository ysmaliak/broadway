import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class CodexDesktopTests {
    private let working = "01a1c0de-0000-7000-8000-00000000000a"
    private let done = "01a1c0de-0000-7000-8000-00000000000b"
    private var home: URL!
    private var day: URL!
    private var links: AgentLinks!
    private var desktop: CodexDesktop!
    private var running = true
    private var allowed = true
    private var opened: [URL] = []

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/codex")
    }

    init() {
        addTeardownBlock { self.tearDown() }
        home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-home-\(UUID().uuidString)")
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        day = home.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
        try? FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        links = AgentLinks()
        running = true
        allowed = true
        opened = []
        desktop = CodexDesktop()
        desktop.home = home
        desktop.links = links
        desktop.running = { [unowned self] in running }
        desktop.allowed = { [unowned self] in allowed }
        desktop.opener = { [unowned self] in opened.append($0) }
    }

    private func tearDown() {
        desktop.reset()
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func place(_ fixture: String, as name: String? = nil, age: TimeInterval = 0) throws -> URL {
        let target = day.appendingPathComponent(name ?? "rollout-2026-11-04T08-00-00-\(fixture)")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(fixture), to: target)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: target.path)
        return target
    }

    private func placeIndex() throws {
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("session_index.jsonl"), to: home.appendingPathComponent("session_index.jsonl"))
    }

    private func link(_ id: String) -> AgentLink? {
        links.links.last { $0.key == .codex(id) }
    }

    @Test func theHeadTellsTheDesktopAppFromTheCliAndSubagents() throws {
        let lines = try ["desktop-working.jsonl", "cli.jsonl", "subagent.jsonl"].map { name in
            try #require(CodexRollout.firstLine(of: fixtures.appendingPathComponent(name)))
        }

        let heads = lines.map(CodexRollout.head)

        #expect(heads[0] == CodexRollout.Head(id: working, folder: "/tmp/project-a", desktop: true))
        #expect(heads[1]?.desktop == false)
        #expect(heads[2]?.desktop == false)
    }

    @Test func theTailReadsWhatTheTurnIsDoingAndHowItEnded() throws {
        let busy = try #require(CodexRollout.tail(of: fixtures.appendingPathComponent("desktop-working.jsonl"), bytes: 1 << 20))
        let ended = try #require(CodexRollout.tail(of: fixtures.appendingPathComponent("desktop-done.jsonl"), bytes: 1 << 20))

        let now = CodexRollout.turn(busy.data, whole: busy.whole)
        let then = CodexRollout.turn(ended.data, whole: ended.whole)

        #expect(now.working)
        #expect(now.doing == "Running swift test --filter")
        #expect(now.started == Date(timeIntervalSince1970: 1_793_700_000))
        #expect(!then.working)
        #expect(then.finished)
        #expect(then.said == "Fixed the failing test. All green.")
    }

    @Test func aCutTailStillKnowsATurnIsUnderWay() throws {
        let url = fixtures.appendingPathComponent("desktop-working.jsonl")
        let whole = try Data(contentsOf: url)
        let cut = whole.suffix(600)

        let turn = CodexRollout.turn(Data(cut), whole: false)

        #expect(turn.working)
        #expect(turn.started == nil)
    }

    @Test func eachLiveDesktopThreadGetsACardNamedForItsTitleOrFolder() throws {
        try placeIndex()
        try place("desktop-working.jsonl")
        try place("desktop-done.jsonl")
        try place("cli.jsonl")
        try place("subagent.jsonl")

        desktop.update()

        #expect(desktop.watching)
        #expect(links.links.count == 2)
        let busy = try #require(link(working))
        let finished = try #require(link(done))
        #expect(busy.name == "Codex · Fix the build")
        #expect(finished.name == "Codex · project-b")
        #expect(busy.accent == AgentLinks.accent(for: "Codex"))
        #expect(busy.announced)
        #expect(AgentLinkState.codex(try #require(busy.codex), ended: busy.ended) == .working("Running swift test --filter"))
        #expect(AgentLinkState.codex(try #require(finished.codex), ended: finished.ended) == .done("Fixed the failing test. All green."))
    }

    @Test func aThreadQuietForTwentyMinutesStaysAway() throws {
        try place("desktop-working.jsonl", age: 21 * 60)

        desktop.update()

        #expect(links.links.isEmpty)
    }

    @Test func aTurnSilentForTenMinutesIsNoLongerWorking() throws {
        try place("desktop-working.jsonl", age: 11 * 60)

        desktop.update()

        let found = try #require(link(working))
        #expect(found.codex?.working == false)
        #expect(AgentLinkState.codex(try #require(found.codex), ended: nil) == .quiet(nil))
    }

    @Test func aWriteToTheRolloutUpdatesTheSameCard() throws {
        let file = try place("desktop-working.jsonl")
        desktop.update()
        let before = try #require(link(working))
        let finish = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"Build fixed.","started_at":1793700000}}"# + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(finish.utf8))
        try handle.close()

        desktop.changed([file.path])

        let after = try #require(link(working))
        #expect(after.id == before.id)
        #expect(after.codex?.finished == true)
        #expect(after.codex?.said == "Build fixed.")
        #expect(links.links.count == 1)
    }

    @Test func quittingCodexEndsItsCardsWhichLingerTwoMinutes() throws {
        try place("desktop-done.jsonl")
        desktop.update()
        let now = Date()

        running = false
        desktop.update(at: now)

        #expect(!desktop.watching)
        let ended = try #require(link(done))
        #expect(ended.ended == .done("Fixed the failing test. All green."))
        #expect(CodexDesktop.holding(ended, at: now.addingTimeInterval(60)))
        #expect(!CodexDesktop.holding(ended, at: now.addingTimeInterval(CodexDesktop.hold + 1)))
    }

    @Test func aThreadThatWentQuietKeepsItsLastAnswer() throws {
        try place("desktop-done.jsonl")
        desktop.update()
        let found = try #require(link(done))

        links.sweep(at: Date().addingTimeInterval(links.idleLimit + 1))

        let ended = try #require(link(found.codex?.id ?? ""))
        #expect(ended.ended == .left)
        #expect(AgentLinkState.codex(try #require(ended.codex), ended: ended.ended) == .done("Fixed the failing test. All green."))
    }

    @Test func turningAgentsOffTakesTheCardsAwayAndStopsWatching() throws {
        try place("desktop-working.jsonl")
        desktop.update()

        allowed = false
        desktop.update()

        #expect(!desktop.watching)
        #expect(links.links.isEmpty)
    }

    @Test func nothingIsReadWhileCodexIsClosed() throws {
        running = false
        try place("desktop-working.jsonl")

        desktop.update()

        #expect(!desktop.watching)
        #expect(links.links.isEmpty)
    }

    @Test func clickingACardOpensItsThreadInCodex() throws {
        try place("desktop-working.jsonl")
        desktop.update()
        let found = try #require(link(working))

        desktop.reveal(found)

        #expect(opened == [URL(string: "codex://threads/\(working)")!])
    }

    @Test func aHiddenThreadComesBackOnlyForANewTurn() throws {
        let file = try place("desktop-working.jsonl")
        desktop.update()
        desktop.hide(try #require(link(working)))

        desktop.changed([file.path])
        let stillHidden = link(working)
        let later = Int(Date().addingTimeInterval(5).timeIntervalSince1970)
        let next = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t2","started_at":\#(later)}}"# + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(next.utf8))
        try handle.close()
        desktop.changed([file.path])

        #expect(stillHidden == nil)
        #expect(link(working)?.codex != nil)
    }

    @Test func testRunsNeverReadTheRealCodexFolder() {
        let asked = ProcessInfo.processInfo.environment["BROADWAY_CODEX_HOME"]

        let found = CodexDesktop.defaultHome

        #expect(found?.path == asked.map { URL(fileURLWithPath: $0).path })
        #expect(found?.path != FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
    }
}
