import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PinPlacesTests {
    @Test func fiveAcrossWhenTheColumnHasRoom() {
        let widest = PinPlaces.across(424)
        let standard = PinPlaces.across(242)

        let narrowest = PinPlaces.across(184)

        #expect(widest == 5)
        #expect(standard == 5)
        #expect(narrowest == 4)
        #expect(PinPlaces.across(204) == 5)
        #expect(PinPlaces.across(203) == 4)
        #expect(PinPlaces.gap == SideGrid.edge)
    }

    @Test func tilesStayWideEnoughToHitAtEveryColumnWidth() {
        let rooms = stride(from: CGFloat(184), through: 424, by: 1)

        let narrowest = rooms.flatMap { room in PinPlaces.cells(10, room: room).map(\.width) }.min() ?? 0

        #expect(narrowest >= PinPlaces.narrowest)
        #expect(narrowest >= (PinPlaces.height - 4))
    }

    @Test func ninePinsMakeAFiveAndAFour() {
        let room: CGFloat = 242

        let cells = PinPlaces.cells(9, room: room)

        #expect(Set(cells.map { $0.minY }).count == 2)
        #expect(cells.filter { $0.minY == 0 }.count == 5)
        #expect(PinPlaces.height == 40)
    }

    @Test func rowsAreAsEvenAsTheyGo() {
        #expect(PinPlaces.rows(5, most: 4) == [3, 2])
        #expect(PinPlaces.rows(7, most: 4) == [4, 3])
        #expect(PinPlaces.rows(9, most: 4) == [3, 3, 3])
        #expect(PinPlaces.rows(10, most: 4) == [4, 3, 3])
        #expect(PinPlaces.rows(9, most: 5) == [5, 4])
        #expect(PinPlaces.rows(6, most: 5) == [3, 3])
        #expect(PinPlaces.rows(11, most: 5) == [4, 4, 3])
        #expect(PinPlaces.rows(2, most: 4) == [2])
        #expect(PinPlaces.rows(0, most: 4) == [])
    }

    @Test func everyRowFillsTheColumn() {
        let cells = PinPlaces.cells(9, room: 242)
        #expect(cells.count == 9)
        #expect(abs(cells[4].maxX - 242) <= 0.001)
        #expect(abs(cells[8].maxX - 242) <= 0.001)
        #expect(cells[5].minX == 0)
        #expect(cells[5].minY == (PinPlaces.height + PinPlaces.gap))
        #expect(cells[5].width > cells[0].width)
        #expect(cells.allSatisfy { $0.height == PinPlaces.height })
    }

    @Test func noneIsEmpty() {
        #expect(PinPlaces.cells(0, room: 242).isEmpty)
    }

    @Test(arguments: [200, 258, 272, 331, 440])
    func pinsFillTheirRowOnWholePixelsWithEvenGaps(_ width: Int) {
        let room = CGFloat(width) - 2 * SideGrid.edge
        for count in 1...10 {
            let cells = PinPlaces.cells(count, room: room, scale: 1)
            var lines: [CGFloat: [CGRect]] = [:]
            for cell in cells { lines[cell.minY, default: []].append(cell) }
            for line in lines.values {
                let sorted = line.sorted { $0.minX < $1.minX }
                #expect(sorted.first?.minX == 0)
                #expect(sorted.last?.maxX == room)
                #expect(sorted.allSatisfy { $0.minX == $0.minX.rounded() && $0.maxX == $0.maxX.rounded() })
                #expect(zip(sorted, sorted.dropFirst()).allSatisfy { $1.minX - $0.maxX == PinPlaces.gap })
                let widths = sorted.map(\.width)
                #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1)
            }
        }
    }
}
