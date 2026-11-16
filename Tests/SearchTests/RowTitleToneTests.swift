import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct RowTitleToneTests {
    private func title(dark: Bool, ink: KitInk = .flat) -> RowTitleView {
        let view = RowTitleView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.label = "Hillside walk"
        view.ink = ink
        return view
    }

    private func close(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.002 && abs(a.greenComponent - b.greenComponent) < 0.002
            && abs(a.blueComponent - b.blueComponent) < 0.002 && abs(a.alphaComponent - b.alphaComponent) < 0.002
    }

    @Test(arguments: [false, true])
    func aFreshRowTitleDrawsLikeOneThatWasHoveredAndLeft(dark: Bool) {
        let fresh = title(dark: dark)
        let touched = title(dark: dark)
        touched.tone = .ink
        touched.tone = .title
        let meant = KitTone.title.resolved(.flat, dark: dark)

        #expect(close(touched.benchDrawn, meant))
        #expect(close(fresh.benchDrawn, meant))
    }

    @Test(arguments: [false, true])
    func aRowTitleOnLiftedInkDrawsTheLiftedTitle(dark: Bool) {
        let lifted = KitInk(lift: 0.6)
        let fresh = title(dark: dark, ink: lifted)
        let touched = title(dark: dark, ink: lifted)
        touched.tone = .strong
        touched.tone = .title
        let meant = KitTone.title.resolved(lifted, dark: dark)

        #expect(close(fresh.benchDrawn, meant))
        #expect(close(touched.benchDrawn, meant))
    }

    @Test func theTitleToneIsTheColourLabelsKnowAsATitle() {
        #expect(KitColor.kind(of: KitTone.title.base) == .title)
    }
}
