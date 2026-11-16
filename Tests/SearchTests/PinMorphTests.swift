import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PinMorphTests {
    private let rows = CGRect(x: 0, y: 200, width: 242, height: 400)

    @Test @MainActor func formFollowsWhereTheTabIsGoing() {
        #expect(PinMorph.tile(fromPin: false, crossing: true))
        #expect(!PinMorph.tile(fromPin: false, crossing: false))
        #expect(!PinMorph.tile(fromPin: true, crossing: true))
        #expect(PinMorph.tile(fromPin: true, crossing: false))
    }

    @Test func aRowKeepsItsColumnAndFollowsTheHandByItsGrab() {
        let source = CGRect(x: 0, y: 260, width: 242, height: 0)
        let row = PinShape.row(hand: CGPoint(x: 90, y: 330), fromPin: false, source: source, grab: CGSize(width: 90, height: 10), rows: rows, height: 36)
        #expect(row == CGRect(x: 0, y: 320, width: 242, height: 36))
    }

    @Test func aPinOverTheRowsIsARowUnderTheHand() {
        let row = PinShape.row(hand: CGPoint(x: 90, y: 300), fromPin: true, source: nil, grab: .zero, rows: rows, height: 36)
        #expect(row == CGRect(x: 0, y: 282, width: 242, height: 36))
    }

    @Test func aScriptedRowFollowsTheHandByItsGrab() {
        let row = PinShape.row(hand: CGPoint(x: 90, y: 300), fromPin: false, source: nil, grab: CGSize(width: 90, height: 10), rows: rows, height: 36)
        #expect(row.minY == 290)
        #expect(row.minX == 0)
    }

    @Test func aRowOverThePinsIsATileCentredOnTheHand() {
        let tile = PinShape.tile(hand: CGPoint(x: 100, y: 60), fromPin: false, source: nil, size: CGSize(width: 42, height: 40))
        #expect(tile == CGRect(x: 79, y: 40, width: 42, height: 40))
        let pin = CGRect(x: 5, y: 6, width: 42, height: 40)
        #expect(PinShape.tile(hand: .zero, fromPin: true, source: pin, size: .zero) == pin)
    }

    @Test func theMorphMixesRowIntoTileThenIntoTheGap() {
        let row = CGRect(x: 0, y: 100, width: 240, height: 36)
        let tile = CGRect(x: 100, y: 0, width: 40, height: 40)
        #expect(PinShape.frame(row: row, tile: tile, form: 0, aim: nil, landed: 0) == row)
        #expect(PinShape.frame(row: row, tile: tile, form: 1, aim: nil, landed: 0) == tile)
        let half = PinShape.frame(row: row, tile: tile, form: 0.5, aim: nil, landed: 0)
        #expect(half == CGRect(x: 50, y: 50, width: 140, height: 38))
        let gap = CGRect(x: 150, y: 48, width: 42, height: 40)
        #expect(PinShape.frame(row: row, tile: tile, form: 1, aim: gap, landed: 1) == gap)
        #expect(PinShape.frame(row: row, tile: tile, form: 1, aim: gap, landed: 0) == tile)
    }
}
