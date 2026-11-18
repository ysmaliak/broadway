import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct KitCardsTests {
    @Test func aGlassKeyKeepsGlassKeySizes() {
        let small = KitGlassKey(title: "Allow")
        let regular = KitGlassKey(title: "Go", kind: .primary, size: .regular)
        let circle = KitGlassKey(symbol: "xmark", circle: 26)

        let sizes = [small, regular, circle].map(\.intrinsicContentSize)

        #expect(sizes[0].height == 22)
        #expect(sizes[1].height == 28)
        #expect(sizes[1].width >= 64)
        #expect(sizes[2] == NSSize(width: 26, height: 26))
        #expect(regular.title == "Go")
    }

    @Test func aQuietGlassKeyIsDimUntilLit() throws {
        let key = KitGlassKey(symbol: "xmark", circle: 26, quiet: true)

        let symbol = try #require(key.content as? KitSymbol)

        #expect(symbol.opacity == 0.86)
    }

    @Test func aContinuousRectStaysInItsBoundsAndKeepsItsMiddle() {
        let rect = CGRect(x: 2, y: 3, width: 40, height: 40)

        let path = KitPath.continuous(rect, radius: 10)

        #expect(abs(path.boundingBoxOfPath.minX - rect.minX) < 0.01)
        #expect(abs(path.boundingBoxOfPath.maxY - rect.maxY) < 0.01)
        #expect(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
        #expect(!path.contains(CGPoint(x: rect.minX + 0.5, y: rect.minY + 0.5)))
    }

    @Test func anOklabMixMeetsItsEnds() throws {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

        let start = try #require(KitOklab.mix(red, blue, by: 0).usingColorSpace(.sRGB))
        let end = try #require(KitOklab.mix(red, blue, by: 1).usingColorSpace(.sRGB))

        #expect(abs(start.redComponent - 1) < 0.01 && start.blueComponent < 0.01)
        #expect(abs(end.blueComponent - 1) < 0.01 && end.redComponent < 0.01)
    }

    @Test func aDoorIsItsBoxAndSaysWhatItDoes() {
        let door = KitDoor(icon: "xmark", help: "Leave Device Mode", size: 10, box: 22) {}

        #expect(door.intrinsicContentSize == NSSize(width: 22, height: 22))
        #expect(door.accessibilityLabel() == "Leave Device Mode")
        #expect(door.toolTip == "Leave Device Mode")
    }

    @Test func aMarkShowsItsLetterUntilAnIconComes() throws {
        let mark = MarkView(icon: nil, letter: "A", size: 24)
        mark.frame = NSRect(x: 0, y: 0, width: 24, height: 24)

        mark.layout()
        let letter = try #require(mark.kitSubviews(of: KitLabel.self).first)
        let before = letter.isHidden
        mark.icon = NSImage(size: NSSize(width: 16, height: 16))
        mark.layout()

        #expect(!before)
        #expect(letter.isHidden)
        #expect(mark.intrinsicContentSize == NSSize(width: 24, height: 24))
        #expect(mark.hitTest(NSPoint(x: 12, y: 12)) == nil)
    }

    @Test func anUnlitProviderMarkIsGreyer() throws {
        let lit = try #require(ProviderMarkView.image(.claude, size: 40, lit: true, dark: false, scale: 2))
        let unlit = try #require(ProviderMarkView.image(.claude, size: 40, lit: false, dark: false, scale: 2))

        func spread(_ image: CGImage) -> Int {
            let rep = NSBitmapImageRep(cgImage: image)
            let pad = Int(ProviderMarkView.pad(40) * 2)
            guard let color = rep.colorAt(x: pad + 6, y: pad + 40) else { return 0 }
            let parts = [color.redComponent, color.greenComponent, color.blueComponent].map { Int($0 * 255) }
            return parts.max()! - parts.min()!
        }

        #expect(spread(lit) > 60)
        #expect(spread(unlit) < spread(lit) / 2)
    }

    @Test func theProviderLettersAreDrawnFromTheSystemFont() {
        let marks = [ProviderMarkView.claudeLetter, ProviderMarkView.chatGPTLetter]

        for mark in marks {
            #expect(mark.boundingBoxOfPath.width > 10)
            #expect(mark.boundingBoxOfPath.height > 10)
        }
        #expect(marks[0] != marks[1])
    }
}
