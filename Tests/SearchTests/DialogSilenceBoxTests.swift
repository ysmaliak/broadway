import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct DialogSilenceBoxTests {
    @Test func theWholeBoxTakesItsOwnClicksOnTheTickAndOnTheWords() {
        let box = DialogSilenceBox(isOn: true, font: .systemFont(ofSize: 13), color: .labelColor)
        let size = box.intrinsicContentSize
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        box.frame = NSRect(x: 20, y: 40, width: size.width, height: size.height)
        host.addSubview(box)
        host.layoutSubtreeIfNeeded()
        box.layout()
        let middle = 40 + size.height / 2
        let tick = NSPoint(x: 20 + DialogSilenceBox.side / 2, y: middle)
        let words = NSPoint(x: 20 + DialogSilenceBox.side + DialogSilenceBox.gap + 30, y: middle)
        let beside = NSPoint(x: 20 + size.width + 10, y: middle)

        #expect(box.hitTest(tick) === box)
        #expect(box.hitTest(words) === box)
        #expect(box.hitTest(beside) == nil)
        #expect(box.acceptsFirstMouse(for: nil))
    }
}
