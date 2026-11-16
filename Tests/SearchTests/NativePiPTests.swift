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
        let on = NativePiP.script(toggle: false)
        #expect(on.contains("var toggle = false"))
        #expect(NativePiP.script(toggle: true).contains("var toggle = true"))
        #expect(on.contains("webkitSetPresentationMode('picture-in-picture')"))
        #expect(!on.contains("fullscreen"))
        #expect(NativePiP.off.contains("webkitSetPresentationMode('inline')"))
    }
}
