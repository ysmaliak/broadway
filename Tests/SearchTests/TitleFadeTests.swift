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

    @Test func aFittingTitleFadesOnceTheCloseButtonCoversIt() {
        let reserve = RowTitleFade.reserve(closeFromEnd: 30, toEnd: 6)

        let fades = RowTitleFade.fades(natural: 150, room: 160, reserve: reserve)

        #expect(fades)
    }
}
