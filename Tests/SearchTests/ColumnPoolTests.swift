import AppKit
import Testing
@testable import Search

@Suite
@MainActor
struct ColumnPoolTests {
    @Test func aSymbolIsBuiltOncePerNameAndStyle() {
        let style = KitSymbol.Style(size: 11.5, weight: .regular)

        let first = KitSymbol.image("plus", style)
        let again = KitSymbol.image("plus", style)
        let larger = KitSymbol.image("plus", KitSymbol.Style(size: 13, weight: .regular))

        #expect(first != nil)
        #expect(first === again)
        #expect(larger !== first)
    }

    @Test func aPaletteSymbolIsNotShared() {
        let style = KitSymbol.Style(size: 12, palette: [.red, .blue])

        let first = KitSymbol.image("circle", style)
        let again = KitSymbol.image("circle", style)

        #expect(first != nil)
        #expect(first !== again)
    }

    @Test func aSymbolViewKeepsItsImageWhenNothingChanged() {
        let view = KitSymbol("flask", style: KitSymbol.Style(size: 9))
        let shown = view.image

        view.tint = KitColor.ink
        view.viewDidChangeEffectiveAppearance()

        #expect(view.image === shown)
    }

    @Test func aRecycledRowWaitsHiddenInItsParentAndReturnsThere() {
        _ = NSApplication.shared
        let drain = NSView()
        for _ in 0..<100 { _ = TabRowView.take(in: drain) }
        let parent = NSView()
        let elsewhere = NSView()
        let row = TabRowView.take(in: parent)
        parent.addSubview(row)
        let other = TabRowView.take(in: elsewhere)
        elsewhere.addSubview(other)

        row.recycle()
        other.recycle()
        let taken = TabRowView.take(in: parent)

        #expect(taken === row)
        #expect(taken.superview === parent)
        #expect(!taken.isHidden)
        #expect(other.isHidden)
        #expect(other.superview === elsewhere)
    }
}
