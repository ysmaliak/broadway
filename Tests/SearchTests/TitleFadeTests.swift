import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct TitleFadeTests {
    @Test func aShortTitleDoesNotFade() {
        let natural: CGFloat = 80

        let fades = RowTitleFade.fades(natural: natural, room: 160, reserve: 0)

        #expect(!fades)
    }

    @Test func aLongTitleFades() {
        let natural: CGFloat = 220

        let fades = RowTitleFade.fades(natural: natural, room: 160, reserve: 0)

        #expect(fades)
    }

    @Test func aTitleThatJustFitsDoesNotFade() {
        let natural: CGFloat = 160.4

        let fades = RowTitleFade.fades(natural: natural, room: 160, reserve: 0)

        #expect(!fades)
    }

    @Test func noReserveWithoutTheCloseButton() {
        let closeFromEnd: CGFloat? = nil

        let reserve = RowTitleFade.reserve(closeFromEnd: closeFromEnd, toEnd: 6)

        #expect(reserve == 0)
    }

    @Test func theCloseButtonPushesTheFadeLeft() {
        let closeFromEnd: CGFloat = 30

        let reserve = RowTitleFade.reserve(closeFromEnd: closeFromEnd, toEnd: 6)

        #expect(reserve == 26)
    }

    @Test func aTitleAlreadyClearOfTheCloseButtonReservesNothing() {
        let closeFromEnd: CGFloat = 30

        let reserve = RowTitleFade.reserve(closeFromEnd: closeFromEnd, toEnd: 40)

        #expect(reserve == 0)
    }

    @Test func aCallSignAloneSitsSevenPointsFromTheEnd() {
        let place = RowTitleFade.call(width: 248, sign: 40, endsLeft: nil, markFromEnd: nil)

        #expect(place.x == 201)
        #expect(place.fromEnd == 53)
    }

    @Test func aCallSignStandsLeftOfTheTabNumber() {
        let place = RowTitleFade.call(width: 248, sign: 40, endsLeft: 200, markFromEnd: nil)

        #expect(place.x == 160)
    }

    @Test func aCallSignStandsLeftOfTheUnseenDot() {
        let place = RowTitleFade.call(width: 248, sign: 40, endsLeft: nil, markFromEnd: 30)

        #expect(place.x == 176)
    }

    @Test func aCallSignWithNoMinutesKeepsNoRoom() {
        let place = RowTitleFade.call(width: 248, sign: 0, endsLeft: nil, markFromEnd: nil)

        #expect(place.fromEnd == nil)
    }

    @Test func theTitleFadesOutAGapBeforeTheCallSign() {
        let place = RowTitleFade.call(width: 248, sign: 40, endsLeft: nil, markFromEnd: nil)

        let reserve = RowTitleFade.reserve(closeFromEnd: place.fromEnd, toEnd: 10)

        #expect(52 + 186 - reserve <= place.x - RowTitleFade.callGap)
    }

    @Test func aFittingTitleFadesOnceTheCloseButtonCoversIt() {
        let reserve = RowTitleFade.reserve(closeFromEnd: 30, toEnd: 6)

        let fades = RowTitleFade.fades(natural: 150, room: 160, reserve: reserve)

        #expect(fades)
    }
}
