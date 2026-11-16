import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FloatRateCallbackTests {
    private var float: Float!
    private var previous: NSPoint?
    private var reads: [(FloatMediaState) -> Void] = []
    private var writes: [(Double?) -> Void] = []

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        previous = Float.benchAway
        Float.benchAway = NSPoint(x: -20000, y: -20000)
        reads = []
        writes = []
        float = Float()
        float.onProgress = { [weak self] in self?.reads.append($0) }
        float.onRate = { [weak self] _, answer in self?.writes.append(answer) }
        float.lift(NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 247)))
        let firstRead = try #require(reads.first)
        firstRead(state(1))
    }

    private func tearDown() async {
        float.drop()
        float = nil
        reads = []
        writes = []
        Float.benchAway = previous
    }

    private func state(_ rate: Double?) -> FloatMediaState {
        var state = FloatMediaState()
        state.rate = rate
        return state
    }

    private func read(after index: Int) async throws -> (FloatMediaState) -> Void {
        for _ in 0..<100 where reads.count <= index { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(reads.dropFirst(index).first)
    }

    @Test func heldProgressCannotUndoAnAcknowledgedRate() async throws {
        let held = try await read(after: 1)

        _ = float.bench("rate", "1.5")
        let answer = try #require(writes.first)
        answer(1.5)
        let acknowledged = float.bench("chrome", nil)["rate"] as? Double
        held(state(1))

        #expect(acknowledged == 1.5)
        #expect((float.bench("chrome", nil)["rate"] as? Double) == 1.5)
    }

    @Test func readDispatchedDuringWriteCannotUndoItAndFreshPageRateStillAppears() async throws {
        _ = float.bench("rate", "1.5")
        let during = try await read(after: reads.count)

        during(state(nil))
        let availableWhileWriting = float.bench("chrome", nil)["controllable"] as? Bool
        let answer = try #require(writes.first)
        answer(1.5)
        during(state(1))
        let acknowledged = float.bench("chrome", nil)["rate"] as? Double
        let fresh = try await read(after: reads.count)
        fresh(state(0.75))

        #expect(availableWhileWriting == true)
        #expect(acknowledged == 1.5)
        #expect((float.bench("chrome", nil)["rate"] as? Double) == 0.75)
    }

    @Test func olderWriteAcknowledgementCannotUndoANewerChoice() throws {
        _ = float.bench("rate", "1.5")
        _ = float.bench("rate", "2")
        #expect(writes.count == 2)

        let newer = try #require(writes.last)
        let older = try #require(writes.first)
        newer(2)
        older(1.5)

        #expect((float.bench("chrome", nil)["rate"] as? Double) == 2)
    }

    @Test func progressRepliesFollowDispatchOrder() async throws {
        let older = try await read(after: 1)
        let newer = try await read(after: reads.count)

        newer(state(1.25))
        older(state(0.75))

        #expect((float.bench("chrome", nil)["rate"] as? Double) == 1.25)
    }
}
