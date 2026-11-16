import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SoundCommandTests {
    @Test func stopSoundFollowsOnlyTheActiveBuiltNoisyTab() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let quiet = Tab()
        let noisy = Tab()
        _ = noisy.web
        noisy.noisy = true
        browser.showRow([quiet, noisy], active: quiet.id)
        defer { browser.closeAll() }

        #expect(!browser.canPauseMedia)
        #expect(browser.callToMute == nil)

        browser.select(noisy)

        #expect(browser.canPauseMedia)

        noisy.noisy = false

        #expect(!browser.canPauseMedia)
    }

    @Test func pausingABlankTabDoesNotBuildAWebViewOrAnnounceSuccess() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let blank = Tab()
        browser.showRow([blank], active: blank.id)
        defer { browser.closeAll() }

        browser.pauseMedia()

        #expect(!browser.canPauseMedia)
        #expect(blank.built == nil)
        #expect(browser.announcement == nil)
        #expect(browser.callToMute == nil)
    }
}
