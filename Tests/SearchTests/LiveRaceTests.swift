import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LiveRaceTests {
    private let live = LiveFolders.shared
    private let feed = LiveSource(kind: .feed, address: "https://example.com/feed")
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var calls = 0

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        for folder in live.folders { live.remove(folder.id) }
        live.reader = { [weak self] folder in
            guard let self else { return .failed }
            calls += 1
            await withCheckedContinuation { self.gates.append($0) }
            return .items([LiveItem(key: "https://example.com/\(folder.name)", title: folder.name)], nil)
        }
    }

    private func tearDown() async {
        for gate in gates { gate.resume() }
        gates = []
        live.reader = { await LiveReader.read($0) }
        for folder in live.folders { live.remove(folder.id) }
    }

    private func waitForCalls(_ count: Int) async {
        for _ in 0..<200 where calls < count || gates.count < count { await Task.yield() }
    }

    private func open() {
        let held = gates
        gates = []
        for gate in held { gate.resume() }
    }

    @Test func anAnswerToAFolderChangedSinceTheReadBeganIsDropped() async {
        let made = live.add(name: "old", source: feed, space: UUID())
        let reading = Task { await live.readNow(made.id) }
        await waitForCalls(1)

        live.move(made.id, to: "https://example.com/other")
        open()
        await reading.value

        #expect(live.folder(made.id)?.items.isEmpty == true)
    }

    @Test func anAnswerToAFolderPausedAndResumedSinceTheReadBeganIsDropped() async {
        let made = live.add(name: "old", source: feed, space: UUID())
        let reading = Task { await live.readNow(made.id) }
        await waitForCalls(1)

        live.pause(made.id, true)
        live.pause(made.id, false)
        open()
        await reading.value

        #expect(live.folder(made.id)?.items.isEmpty == true)
    }

    @Test func anOlderAnswerNeverReplacesANewerOne() async {
        let made = live.add(name: "old", source: feed, space: UUID())
        let reading = Task { await live.readNow(made.id) }
        await waitForCalls(1)

        live.apply(.items([LiveItem(key: "https://example.com/newer", title: "Newer")], nil), to: made.id)
        open()
        await reading.value

        #expect(live.folder(made.id)?.items.map(\.key) == ["https://example.com/newer"])
    }

    @Test func aSecondAskWaitsForTheRunningRead() async {
        let made = live.add(name: "one", source: feed, space: UUID())
        let first = Task { await live.readNow(made.id) }
        await waitForCalls(1)

        let second = Task { await live.readNow(made.id) }
        live.update(made.id)
        await Task.yield()
        open()
        await first.value
        await second.value

        #expect(calls == 1)
        #expect(live.folder(made.id)?.items.map(\.key) == ["https://example.com/one"])
        #expect(!live.reading.contains(made.id))
    }

    @Test func twoFoldersOfOneSourceInASpaceShareOneRequest() async {
        let space = UUID()
        let one = live.add(name: "one", source: feed, space: space)
        let two = live.add(name: "two", source: feed, space: space)
        let elsewhere = live.add(name: "far", source: feed, space: UUID())
        let asked = live.shared.asked

        let first = Task { await live.readNow(one.id) }
        let second = Task { await live.readNow(two.id) }
        let third = Task { await live.readNow(elsewhere.id) }
        await waitForCalls(2)
        for _ in 0..<50 { await Task.yield() }
        open()
        await first.value
        await second.value
        await third.value

        #expect(live.shared.asked - asked == 2)
        #expect(calls == 2)
        #expect(live.folder(one.id)?.items.count == 1)
        #expect(live.folder(two.id)?.items.count == 1)
    }
}
