import Foundation
import Testing
@testable import Search

/// A pinned square carried across the grid (Side.swift): the cell it lands
/// in and how far it sits from it, on rows of different lengths.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PinCarriedTests {
    // Three squares on the first row, two wider ones on the second.
    private let cells = [
        CGRect(x: 0, y: 0, width: 60, height: 40), CGRect(x: 66, y: 0, width: 60, height: 40),
        CGRect(x: 132, y: 0, width: 60, height: 40),
        CGRect(x: 0, y: 46, width: 93, height: 40), CGRect(x: 99, y: 46, width: 93, height: 40),
    ]

    @Test func staysInItsCellUntilNearerAnother() {
        #expect(PinCarried.target(travel: .zero, from: 0, cells: cells) == 0)
        #expect(PinCarried.target(travel: CGSize(width: 30, height: 0), from: 0, cells: cells) == 0)
        #expect(PinCarried.target(travel: CGSize(width: 40, height: 0), from: 0, cells: cells) == 1)
    }

    @Test func downIntoAWiderRowLandsByCentre() {
        // From the third square straight down: nearest is the second wide cell.
        #expect(PinCarried.target(travel: CGSize(width: 0, height: 46), from: 2, cells: cells) == 4)
        #expect(PinCarried.target(travel: CGSize(width: -120, height: 46), from: 2, cells: cells) == 3)
    }

    @Test func heldSquareStaysUnderTheHandAfterMoving() {
        let travel = CGSize(width: 70, height: 3)
        // Before it changes cell, the offset is the travel itself.
        #expect(PinCarried.offset(travel: travel, from: 0, index: 0, cells: cells) == travel)
        // Once it is in the next cell, only what is left over.
        let after = PinCarried.offset(travel: travel, from: 0, index: 1, cells: cells)
        #expect(abs(after.width - 4) <= 0.001)
        #expect(abs(after.height - 3) <= 0.001)
        #expect(PinCarried.offset(travel: travel, from: 9, index: 0, cells: cells) == .zero)
    }
}
