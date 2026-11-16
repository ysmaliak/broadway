import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SpeakerSwapTests {
    @Test func speakerSymbolFollowsMutedBothWays() {
        let tab = Tab()
        #expect(tab.speakerSymbol == "speaker.wave.2")

        tab.toggleMute()

        #expect(tab.muted)
        #expect(tab.speakerSymbol == "speaker.slash")

        tab.toggleMute()

        #expect(!tab.muted)
        #expect(tab.speakerSymbol == "speaker.wave.2")
    }

    @Test func theSpeakerLeavesTheMomentTheSoundStops() {
        let tab = Tab()
        tab.noisy = true
        #expect(tab.speaks)

        tab.noisy = false

        #expect(!tab.speaks)
    }

    @Test func theSpeakerStaysThroughASpeedChange() async throws {
        let tab = Tab()
        tab.noisy = true

        tab.heardTempo()
        tab.noisy = false

        #expect(tab.speaks, "a speed change pauses the sound for a moment")

        tab.noisy = true
        try await Task.sleep(for: .seconds(SideLook.speakerHold + 0.4))

        #expect(tab.speaks, "sound that came back cancels the wait")

        tab.noisy = false

        #expect(!tab.speaks, "silence long after the speed change drops it at once")
    }

    @Test func aSpeedChangeHoldsOnlyForWhatIsLeftOfTheHold() async throws {
        let tab = Tab()
        tab.noisy = true
        tab.heardTempo()
        try await Task.sleep(for: .seconds(SideLook.speakerHold * 0.5))

        tab.noisy = false
        try await Task.sleep(for: .seconds(SideLook.speakerHold * 0.5 + 0.3))

        #expect(!tab.speaks)
    }

    @Test func aTabPutDownDropsItsSpeakerAtOnce() {
        let tab = Tab()
        tab.noisy = true

        tab.noisy = false
        tab.settleSpeaks()

        #expect(!tab.speaks)
    }
}
