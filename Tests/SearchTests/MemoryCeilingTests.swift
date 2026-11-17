import Foundation
import Testing
@testable import Search

struct MemoryCeilingTests {
    private static let gigabyte: UInt64 = 1 << 30

    final class Stand: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [Int32: UInt64] = [:]
        private var starts: [Int32: UInt64] = [:]
        private var killed: [Int32] = []
        var pages: Set<Int32> = []
        var refuses = false

        func set(_ pid: Int32, _ value: UInt64) {
            lock.lock()
            bytes[pid] = value
            lock.unlock()
        }

        func start(_ pid: Int32, _ value: UInt64) {
            lock.lock()
            starts[pid] = value
            lock.unlock()
        }

        func read(_ pid: Int32) -> MemorySample? {
            lock.lock()
            defer { lock.unlock() }
            return bytes[pid].map { MemorySample(bytes: $0, started: starts[pid] ?? 1) }
        }

        func end(_ pid: Int32) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            killed.append(pid)
            return !refuses
        }

        var ended: [Int32] {
            lock.lock()
            defer { lock.unlock() }
            return killed
        }
    }

    private func watch(_ stand: Stand, physical: UInt64 = 16 << 30) -> MemoryWatch {
        MemoryWatch(physical: physical,
                    read: { stand.read($0) },
                    isPage: { stand.pages.isEmpty || stand.pages.contains($0) },
                    end: { stand.end($0) })
    }

    @Test(arguments: [(16, 8), (32, 16), (64, 24), (8, 8)] as [(UInt64, UInt64)])
    func theCeilingIsHalfTheMacsMemoryWithinEightAndTwentyFourGigabytes(memory: UInt64, ceiling: UInt64) {
        #expect(MemoryCeiling.limit(physical: memory * Self.gigabyte) == ceiling * Self.gigabyte)
    }

    @Test func aPageProcessPastTheCeilingIsEndedOnce() {
        let stand = Stand()
        let watch = watch(stand)
        let tab = UUID()
        watch.pages([41: [tab]])
        stand.set(41, 9 * Self.gigabyte)

        watch.tick()
        watch.tick()
        watch.tick()

        #expect(stand.ended == [41])
        #expect(watch.take(tab)?.bytes == 9 * Self.gigabyte)
    }

    @Test func aPageProcessUnderTheCeilingIsLeft() {
        let stand = Stand()
        let watch = watch(stand)
        watch.pages([41: [UUID()]])
        stand.set(41, 7 * Self.gigabyte)

        watch.tick()
        watch.tick()

        #expect(stand.ended.isEmpty)
        #expect(watch.readings == 2)
        #expect(watch.lastReadings.map(\.bytes) == [7 * Self.gigabyte])
    }

    @Test func aListThatStopsBeingRenewedIsStillWatched() {
        let stand = Stand()
        let watch = watch(stand)
        let tab = UUID()
        watch.pages([41: [tab], 42: [UUID()]])
        stand.set(41, Self.gigabyte)
        stand.set(42, Self.gigabyte)
        watch.tick()
        watch.tick()

        stand.set(41, 12 * Self.gigabyte)
        watch.tick()

        #expect(watch.renewed == 1)
        #expect(stand.ended == [41])
        #expect(watch.holds(tab))
    }

    @Test func aProcessThatIsNotAPageIsNeverEnded() {
        let stand = Stand()
        stand.pages = [42]
        let watch = watch(stand)
        watch.pages([41: [UUID()]])
        stand.set(41, 20 * Self.gigabyte)

        watch.tick()

        #expect(stand.ended.isEmpty)
    }

    @Test func everyTabInTheEndedProcessIsTakenOnceEach() {
        let stand = Stand()
        let watch = watch(stand)
        let (first, second) = (UUID(), UUID())
        watch.pages([41: [first, second]])
        stand.set(41, 9 * Self.gigabyte)
        watch.tick()

        let one = watch.take(first)
        let again = watch.take(first)
        let two = watch.take(second)

        #expect(one?.pid == 41)
        #expect(again == nil)
        #expect(two?.pid == 41)
        #expect(watch.waiting.isEmpty)
    }

    @Test func aTabSeenOnANewProcessIsNoLongerHeldForTheOldOne() {
        let stand = Stand()
        let watch = watch(stand)
        let tab = UUID()
        watch.pages([41: [tab]])
        stand.set(41, 9 * Self.gigabyte)
        watch.tick()

        watch.pages([43: [tab]])

        #expect(!watch.holds(tab))
    }

    @Test func aRenewalTakenBeforeTheEndArrivedStillDoesNotEndItTwice() {
        let stand = Stand()
        let watch = watch(stand)
        let tab = UUID()
        watch.pages([41: [tab]])
        stand.set(41, 9 * Self.gigabyte)
        watch.tick()

        watch.pages([41: [tab]])
        watch.tick()

        #expect(stand.ended == [41])
        #expect(watch.holds(tab))
    }

    @Test func aKillThatFailsLeavesNoRecordBehind() {
        let stand = Stand()
        stand.refuses = true
        let watch = watch(stand)
        let tab = UUID()
        watch.pages([41: [tab]])
        stand.set(41, 9 * Self.gigabyte)

        watch.tick()

        #expect(!watch.holds(tab))
    }

    @Test func aProcessIdTakenByAnotherProcessIsNotEnded() {
        let stand = Stand()
        let watch = watch(stand)
        watch.pages([41: [UUID()]])
        stand.set(41, Self.gigabyte)
        watch.tick()

        stand.start(41, 2)
        stand.set(41, 12 * Self.gigabyte)
        watch.tick()

        #expect(stand.ended.isEmpty)
    }

    @Test func aLoweredCeilingIsTheOneWatched() {
        let stand = Stand()
        let watch = watch(stand)
        watch.lower(to: 300 << 20)
        watch.pages([41: [UUID()]])
        stand.set(41, 400 << 20)

        watch.tick()

        #expect(watch.ceiling == 300 << 20)
        #expect(stand.ended == [41])
    }

    @Test func aRealPageProcessIsReadAndOnlyAWebKitPageCountsAsOne() {
        let own = ProcessInfo.processInfo.processIdentifier

        #expect((MemoryWatch.sample(own)?.bytes ?? 0) > 0)
        #expect(!MemoryWatch.isPageProcess(own))
    }
}
