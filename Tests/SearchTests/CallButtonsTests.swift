import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct CallButtonsTests {
    @Test func theSiteSpeaksFirst() {
        let text = #"{"mic":false,"camera":true,"leave":true}"#

        let status = CallButtons.status(text, mic: .active, camera: .muted)

        #expect(status == CallButtons.Status(mic: false, camera: true, leaves: true))
    }

    @Test func webKitFillsInWhatTheSiteDoesNotSay() {
        let text = #"{"mic":null,"camera":null,"leave":false}"#

        let status = CallButtons.status(text, mic: .muted, camera: .active)

        #expect(status == CallButtons.Status(mic: false, camera: true, leaves: false))
    }

    @Test func noCaptureMeansNoButton() {
        let text: String? = nil

        let status = CallButtons.status(text, mic: .none, camera: .none)

        #expect(status.mic == nil)
        #expect(status.camera == nil)
        #expect(!status.leaves)
    }

    @Test func pressNamesTheButtons() {
        let selectors = CallButtons.leave

        let script = CallButtons.press(selectors)

        #expect(script.contains("#hangup-button"))
        #expect(script.contains("Leave call"))
    }
}
