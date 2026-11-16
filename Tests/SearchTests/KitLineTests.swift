import AppKit
import Combine
import Observation
import Testing
@testable import Search

@MainActor @Observable private final class KitTrackModel {
    var count = 0
}

@Suite(.timeLimit(.minutes(5)))
@MainActor
struct KitLineTests {
    @Test func aLineIsAsTallAsItsTallestPart() {
        let button = KitBroadwayButton("Edit…")
        let line = KitFormLine("Settings…", controls: [button])

        let height = line.kitHeight(width: 500)

        #expect(height == 28)
    }

    @Test func aLongDetailWrapsAndTheLineGrows() {
        let detail = String(repeating: "Your extensions from Chrome, Arc or Brave. ", count: 4)
        let line = KitFormLine("From another browser", detail: detail, callout: true, controls: [KitBroadwayButton("Bring them over…")])

        let wide = line.kitHeight(width: 2000)
        let narrow = line.kitHeight(width: 400)

        #expect(narrow > wide)
    }

    @Test func controlsSitAtTheTrailingEdge() {
        let button = KitBroadwayButton("Choose…")
        let line = KitFormLine("Load", controls: [button])
        line.frame = NSRect(x: 0, y: 0, width: 400, height: line.kitHeight(width: 400))

        line.layoutSubtreeIfNeeded()

        #expect(abs(button.frame.maxX - 400) < 1)
        #expect(button.frame.width >= 64)
    }

    @Test func aGroupedCardStacksRowsWithHairlinesBetween() {
        let rows = (0..<3).map { _ in KitField(placeholder: "x") }
        let card = KitFormCard(rows: rows)

        let height = card.kitHeight(width: 400)

        #expect(height == CGFloat(3 * 50 + 2))
    }

    @Test func aFieldSaysWhatWasTypedAndSubmits() {
        let field = KitField(placeholder: "Link")
        var said = ""
        var submitted = false
        field.onChange = { said = $0 }
        field.onSubmit = { submitted = true }

        field.field.stringValue = "abc"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let took = field.control(field.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))

        #expect(said == "abc")
        #expect(submitted)
        #expect(took)
    }

    @Test func aTrackRunsOnceForManyChanges() async {
        let model = KitTrackModel()
        var runs = 0
        let watch = kitTrack {
            _ = model.count
            runs += 1
        }
        runs = 0

        model.count = 1
        model.count = 2
        model.count = 3
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(runs == 1)
        _ = watch
    }

    @Test func aBroadwayButtonKeepsItsMinimumWidth() {
        let small = KitBroadwayButton("Add", small: true)
        let regular = KitBroadwayButton("Add")

        #expect(regular.intrinsicContentSize.width == 64)
        #expect(regular.intrinsicContentSize.height == 28)
        #expect(small.intrinsicContentSize.height == 22)
        #expect(small.intrinsicContentSize.width < 64)
    }
}
