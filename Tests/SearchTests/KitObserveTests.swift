import Combine
import Foundation
import Observation
import Testing
@testable import Search

@MainActor @Observable private final class Counter {
    var count = 0
    var other = 0
}

@Suite(.timeLimit(.minutes(5))) @MainActor struct KitObserveTests {
    private func turn() async {
        for _ in 0..<3 { await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } } }
    }

    @Test func itHearsTheValueAtOnceAndThenEachChangeOnTheNextTurn() async {
        let counter = Counter()
        var heard: [Int] = []

        let watch = kitObserve({ counter.count }) { heard.append($0) }
        counter.count = 1
        counter.count = 2
        await turn()

        #expect(heard == [0, 2])
        _ = watch
    }

    @Test func itIgnoresWhatItNeverRead() async {
        let counter = Counter()
        var heard = 0
        let watch = kitObserve(initial: false, { counter.count }) { _ in heard += 1 }

        counter.other = 5
        await turn()

        #expect(heard == 0)
        _ = watch
    }

    @Test func distinctSkipsAWriteOfTheSameValue() async {
        let counter = Counter()
        var heard: [Int] = []
        let watch = kitObserve(initial: false, distinct: true, { counter.count }) { heard.append($0) }

        counter.count = 0
        await turn()
        counter.count = 3
        await turn()

        #expect(heard == [3])
        _ = watch
    }

    @Test func cancellingStopsIt() async {
        let counter = Counter()
        var heard = 0
        var bag: Set<AnyCancellable> = []
        kitObserve(initial: false, { counter.count }) { _ in heard += 1 }.store(in: &bag)

        bag.removeAll()
        counter.count = 9
        await turn()

        #expect(heard == 0)
    }

    @Test func readsHearOnlyTheNewestTrackingOnTheNextTurn() async {
        let counter = Counter()
        var heard = 0
        let reads = KitReads { heard += 1 }
        reads.track { _ = counter.count }
        reads.track { _ = counter.other }

        counter.count = 1
        await turn()
        counter.other = 1
        await turn()

        #expect(heard == 1)
    }

    @Test func readsNowHearBeforeTheNextTurn() {
        let counter = Counter()
        var heard = 0
        let reads = KitReads(now: true) { heard += 1 }
        reads.track { _ = counter.count }

        counter.count = 1

        #expect(heard == 1)
    }

    @Test func stoppedReadsHearNothing() async {
        let counter = Counter()
        var heard = 0
        let reads = KitReads { heard += 1 }
        reads.track { _ = counter.count }

        reads.stop()
        counter.count = 1
        await turn()

        #expect(heard == 0)
    }

    @Test func aTrackRunsAgainForWhatItReadUntilCancelled() async {
        let counter = Counter()
        var seen: [Int] = []
        var watch: AnyCancellable? = kitTrack { seen.append(counter.count) }

        counter.count = 1
        await turn()
        counter.other = 1
        await turn()
        watch = nil
        counter.count = 2
        await turn()

        #expect(seen == [0, 1])
        _ = watch
    }
}
