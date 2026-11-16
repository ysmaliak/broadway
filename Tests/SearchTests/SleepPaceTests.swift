import Foundation
import Testing
@testable import Search

/// What each choice in Settings › Tabs › How soon tabs sleep waits for.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SleepPaceTests {
    @Test func soonerWaitsLess() {
        let paces: [SleepPace] = [.later, .normal, .sooner]
        for (slower, faster) in zip(paces, paces.dropFirst()) {
            #expect(slower.wait > faster.wait)
        }
    }

    @Test func normalWaitsLongerOnAMacWithMoreMemory() {
        let gigabyte: UInt64 = 1_073_741_824
        let hour: TimeInterval = 60 * 60

        #expect(SleepPace.normalWait(memory: 8 * gigabyte) == 2 * hour)
        #expect(SleepPace.normalWait(memory: 16 * gigabyte) == 4 * hour)
        #expect(SleepPace.normalWait(memory: 48 * gigabyte) == 12 * hour)
        #expect(SleepPace.normalWait(memory: 128 * gigabyte) == 12 * hour)
        #expect(SleepPace.normalWait(memory: 4 * gigabyte) == 2 * hour)
    }

    @Test func onlyCriticalMemoryShortensTheWait() {
        let usual = Browser.sleepAfter

        #expect(Browser.idleWait(critical: false) == usual)
        #expect(Browser.idleWait(critical: true) == min(5 * 60, usual))
    }
}
