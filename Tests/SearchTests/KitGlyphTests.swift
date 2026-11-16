import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct KitGlyphTests {
    private func system(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    private func drawn(_ image: NSImage?) -> Bool {
        image?.representations.contains { $0 is NSCustomImageRep } == true
    }

    @Test func everyNameIsTheSystemsSymbolAtItsSize() throws {
        for name in ["arrow.left", "folder", "pin", "slider.horizontal.3", "sidebar.left", "gearshape"] {
            let style = KitSymbol.Style(size: 14, weight: .medium)

            let image = try #require(KitGlyph.image(name, style))

            #expect(!drawn(image))
            #expect(image.size == system(name, 14, .medium)?.size)
            #expect(image.alignmentRect == system(name, 14, .medium)?.alignmentRect)
        }
    }

    @Test func aFilledStyleTakesTheFilledSymbolWhenThereIsOne() throws {
        let filled = KitSymbol.Style(size: 13, weight: .regular, fill: true)

        let pin = try #require(KitGlyph.made("pin", filled))
        let link = try #require(KitGlyph.made("link", filled))

        #expect(pin.size == system("pin.fill", 13, .regular)?.size)
        #expect(link.size == system("link", 13, .regular)?.size)
    }

    @Test func aPlainImageIsTheBareSystemSymbol() throws {
        let plain = try #require(KitGlyph.plain("tortoise", label: "Weather"))

        #expect(!drawn(plain))
        #expect(plain.size == NSImage(systemSymbolName: "tortoise", accessibilityDescription: nil)?.size)
        #expect(plain.accessibilityDescription == "Weather")
    }

    @Test func aSymbolIsCachedAndALabelledOneIsACopy() throws {
        let style = KitSymbol.Style(size: 15, weight: .semibold)

        let first = KitSymbol.image("folder", style)
        let again = KitSymbol.image("folder", style)
        let labelled = try #require(KitGlyph.image("folder", style, label: "Folder"))

        #expect(first === again)
        #expect(labelled !== first)
        #expect(labelled.accessibilityDescription == "Folder")
        #expect(first?.accessibilityDescription != "Folder")
    }

    @Test func aViewKeepsTheSystemName() {
        let symbol = KitSymbol("sidebar.left")

        #expect(symbol.name == "sidebar.left")
        #expect(!drawn(symbol.image))
    }
}
