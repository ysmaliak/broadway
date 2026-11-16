import AppKit
import Testing
@testable import Search

private final class KitCountedSection: KitFormSection {
    var count = 1

    override func spec() -> [KitFormLine] {
        (0..<count).map { line("row-\($0)", "Row \($0)", "Detail \($0)", [KitForm.button("Go") {}]) }
    }
}

@Suite(.timeLimit(.minutes(5)))
@MainActor
struct KitFormRowsTests {
    @Test func aFormButtonIsItsCeiledTitlePlusPaddingAndNeverUnder64() {
        let short = KitForm.button("Add") {}
        let long = KitForm.button("Notes About You") {}
        let title = ("Notes About You" as NSString).size(withAttributes: [.font: KitForm.titleFont]).width

        #expect(short.intrinsicContentSize == NSSize(width: 64, height: 28))
        #expect(long.intrinsicContentSize.width == ceil(title) + 24)
    }

    @Test func rowsStackTheirLinesWithOnePixelSeparatorsBetween() {
        let rows = KitFormRows()
        let first = KitFormLine(id: "a", title: "Title")
        let second = KitFormLine(id: "b", title: "Title", detail: "A detail line under the title")

        rows.set([first, second])
        rows.frame = NSRect(x: 0, y: 0, width: 400, height: rows.height(for: 400))
        rows.layoutSubtreeIfNeeded()

        #expect(second.height(for: 400) > first.height(for: 400))
        #expect(rows.height(for: 400) == first.height(for: 400) + 1 + second.height(for: 400))
        #expect(second.frame.minY == first.frame.maxY + 1)
    }

    @Test func aLineIsAsTallAsItsTallestControl() {
        let line = KitFormLine(id: "a", title: "Title")

        let bare = line.height(for: 400)
        line.controls = [KitTrackField(placeholder: "Token", width: 180)]

        #expect(bare == 16)
        #expect(line.height(for: 400) == 30)
    }

    @Test func aSectionsHeightFollowsItsSpec() {
        let section = KitCountedSection()
        let one = section.height(for: 400)

        section.count = 3
        section.refresh()

        #expect(section.height(for: 400) == one * 3 + KitForm.inset * 4 + 2)
        #expect(section.intrinsicContentSize.height == section.height(for: section.bounds.width > 0 ? section.bounds.width : KitForm.fallbackWidth))
    }

    @Test func aSectionGrowsWhenItsLinesChange() {
        let section = KitCountedSection()
        section.refresh()
        section.frame = NSRect(x: 0, y: 0, width: 400, height: section.height(for: 400))
        section.layoutSubtreeIfNeeded()
        let before = section.height(for: 400)

        section.count = 3
        section.refresh()

        #expect(before > 0)
        #expect(section.height(for: 400) > before * 2)
        #expect(section.intrinsicContentSize.height == section.height(for: 400))
    }
}
