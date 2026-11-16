import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct RecordingPillTests {
    private func words(_ pill: RecordingPillView) -> [String] {
        pill.kitSubviews(of: KitLabel.self).map(\.text)
    }

    @Test func thePillFollowsItsModelThroughObservation() throws {
        let indicator = RecordingIndicator()
        let pill = RecordingPillView(indicator: indicator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = pill
        pill.layoutSubtreeIfNeeded()
        #expect(words(pill).isEmpty)

        indicator.update([RecordingLine(id: "loom", name: "Loom", what: "is recording your screen")])
        let invalidated = pill.needsLayout
        pill.layoutSubtreeIfNeeded()

        #expect(invalidated)
        #expect(words(pill) == ["Loom is recording your screen"])
        #expect(pill.intrinsicContentSize.height == 34)
    }

    @Test func eachLineHasAStopNamedForItsExtension() throws {
        let indicator = RecordingIndicator()
        var stopped: [String] = []
        indicator.onStop = { stopped.append($0) }
        indicator.update([RecordingLine(id: "loom", name: "Loom", what: "is recording your screen"),
                          RecordingLine(id: "tella", name: "Tella", what: "is using your camera")])
        let pill = RecordingPillView(indicator: indicator)
        pill.frame = NSRect(origin: .zero, size: pill.intrinsicContentSize)
        pill.layoutSubtreeIfNeeded()

        let stops = pill.kitSubviews(of: KitPushButton.self)
        stops.last?.performClick(nil)

        #expect(stops.map { $0.accessibilityLabel() } == ["Stop Loom", "Stop Tella"])
        #expect(stopped == ["tella"])
        #expect(pill.accessibilityLabel() == "Recording")
        indicator.update([])
    }

    @Test func thePictureIsDrawnOffScreen() throws {
        let indicator = RecordingIndicator()
        indicator.update([RecordingLine(id: "loom", name: "Loom", what: "is recording your screen")])
        defer { indicator.update([]) }

        let rep = try #require(indicator.picture(dark: false))

        let middle = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh - 6))
        #expect(rep.pixelsHigh == 68)
        #expect(middle.alphaComponent > 0.9 && middle.redComponent > 0.95)
    }
}
