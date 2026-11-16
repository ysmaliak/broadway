import AppKit
import Testing
@testable import Search

@Suite
@MainActor
struct SpaceTitleChipTests {
    private func made() -> (NSView, SpaceTitleLineView) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 40))
        let line = SpaceTitleLineView()
        line.kind = .space(TabIcon(symbol: "house"), "Work", muted: false)
        line.act = {}
        line.frame = NSRect(x: 10, y: 4, width: 240, height: 30)
        host.addSubview(line)
        line.layoutSubtreeIfNeeded()
        return (host, line)
    }

    @Test func onlyTheNameTakesThePress() {
        let (host, line) = made()
        let chip = line.convert(line.chip, to: host)

        #expect(chip.width < 120, "The chip hugs the icon and the name")
        #expect(host.hitTest(NSPoint(x: chip.midX, y: chip.midY)) === line)
        #expect(host.hitTest(NSPoint(x: chip.maxX + 30, y: chip.midY)) !== line)
        #expect(host.hitTest(NSPoint(x: line.frame.maxX - 4, y: chip.midY)) !== line)
    }

    @Test func onlyTheNameLights() {
        let (_, line) = made()

        line.point(NSPoint(x: line.chip.midX, y: line.chip.midY))
        let inside = line.over
        line.point(NSPoint(x: line.chip.maxX + 30, y: line.chip.midY))
        let beside = line.over
        line.point(nil)

        #expect(inside)
        #expect(!beside)
        #expect(!line.over)
    }
}
