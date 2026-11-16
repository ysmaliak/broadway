import AppKit
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5))) struct KitFlexTests {
    @Test func everyItemGetsItsWidthWhenThereIsRoom() {
        let items: [KitFlex.Item] = [.fixed(40), .spacer(), .init(least: 10, most: 60)]

        let widths = KitFlex.widths(items, spacing: 8, in: 300)

        #expect(widths == [40, 184, 60])
    }

    @Test func boundedItemsTakeTheirWidthBeforeASpacerGrows() {
        let items: [KitFlex.Item] = [.init(least: 9, most: 87), .init(least: 64, most: 134), .fixed(64), .spacer(), .init(least: 64, most: 103)]

        let widths = KitFlex.widths(items, spacing: 8, in: 556)

        #expect(widths == [87, 134, 64, 136, 103])
    }

    @Test func theLeastFlexibleAreOfferedSpaceFirstAndTheRestShrink() {
        let items: [KitFlex.Item] = [.init(least: 10, most: 100), .fixed(64), .init(least: 10, most: 100)]

        let widths = KitFlex.widths(items, spacing: 0, in: 164)

        #expect(widths == [50, 64, 50])
    }

    @Test func aSpacerKeepsItsMinimumWhenNothingFits() {
        let items: [KitFlex.Item] = [.init(least: 0, most: 200), .spacer(8)]

        let widths = KitFlex.widths(items, spacing: 8, in: 100)

        #expect(widths == [84, 8])
    }
}
