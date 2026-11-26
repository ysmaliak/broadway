import Foundation
import Testing
@testable import Search

/// Settings › General › The floating video: Search's window unless picture
/// in picture is chosen, and the choice kept (idea 376). Entering picture
/// in picture puts a system window on screen, so that part is by eye.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct NativePiPTests {
    @Test func theCutFixesSearchsWindow() {
        let saved = Store.settings.object(forKey: "float.style")
        defer { Store.settings.set(saved, forKey: "float.style") }
        Store.settings.set(FloatStyle.system.rawValue, forKey: "float.style")

        let prefs = Preferences()

        #expect(prefs.floatStyle == .search)
    }

    @Test func scriptsAskOnlyForPictureInPicture() {
        let held = NativePiP.held(toggle: false)
        #expect(held.contains("var toggle = false"))
        #expect(NativePiP.held(toggle: true).contains("var toggle = true"))
        #expect(NativePiP.pick.contains("webkitSetPresentationMode('picture-in-picture')"))
        #expect(NativePiP.paused.contains("webkitSetPresentationMode('picture-in-picture')"))
        #expect(!(held + NativePiP.pick + NativePiP.paused).contains("fullscreen"))
        #expect(NativePiP.off.contains("webkitSetPresentationMode('inline')"))
    }

    @Test func pictureInPictureTakesTheVideoTheFloatingWindowsFinderPicked() {
        #expect(FloatFind.look(strict: true).contains("window.__officeFloatPick = best"))
        #expect(NativePiP.pick.contains("var v = window.__officeFloatPick"))
    }
}
