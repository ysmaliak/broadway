import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AddressMoveTests {
    private let space = UUID()
    private let first = UUID()
    private let second = UUID()

    private func move(_ old: AddressMove.Mark, _ new: AddressMove.Mark, step: AddressMove.TabStep? = nil,
                      back: Bool = false, reduced: Bool = false) -> AddressMove {
        let cause = AddressMove.cause(from: old, to: new, step: step, back: back)
        return AddressMove.between(old.text, new.text, cause: cause, reduced: reduced)
    }

    @Test func aTabBelowRollsDown() {
        let old = AddressMark(tab: first, space: space, text: "example.com")
        let new = AddressMark(tab: second, space: space, text: "wikipedia.org")
        let step = AddressMove.TabStep(to: second, fromPlace: 1, toPlace: 2)

        let chosen = move(old, new, step: step)

        #expect(chosen == .roll(down: true))
    }

    @Test func aTabAboveRollsUp() {
        let old = AddressMark(tab: second, space: space, text: "wikipedia.org")
        let new = AddressMark(tab: first, space: space, text: "example.com")
        let step = AddressMove.TabStep(to: first, fromPlace: 3, toPlace: 0)

        let chosen = move(old, new, step: step)

        #expect(chosen == .roll(down: false))
    }

    @Test func aTabWhosePlaceIsUnknownRollsDown() {
        let old = AddressMark(tab: first, space: space, text: "example.com")
        let new = AddressMark(tab: second, space: space, text: "wikipedia.org")
        let stale = AddressMove.TabStep(to: first, fromPlace: 4, toPlace: 0)

        let chosen = move(old, new, step: stale)

        #expect(chosen == .roll(down: true))
    }

    @Test func followingALinkSlidesForward() {
        let old = AddressMark(tab: first, space: space, text: "wikipedia.org")
        let new = AddressMark(tab: first, space: space, text: "swift.org")

        let chosen = move(old, new, back: false)

        #expect(chosen == .slide(back: false))
    }

    @Test func goingBackSlidesTheOtherWay() {
        let old = AddressMark(tab: first, space: space, text: "swift.org")
        let new = AddressMark(tab: first, space: space, text: "wikipedia.org")

        let chosen = move(old, new, back: true)

        #expect(chosen == .slide(back: true))
    }

    @Test func aPageOnTheSameSiteChangesNothing() {
        let old = AddressMark(tab: first, space: space, text: "swift.org")
        let new = AddressMark(tab: first, space: space, text: "swift.org")

        let chosen = move(old, new)

        #expect(chosen == .still)
    }

    @Test func twoTabsOnTheSameSiteChangeNothing() {
        let old = AddressMark(tab: first, space: space, text: "github.com")
        let new = AddressMark(tab: second, space: space, text: "github.com")
        let step = AddressMove.TabStep(to: second, fromPlace: 0, toPlace: 1)

        let chosen = move(old, new, step: step)

        #expect(chosen == .still)
    }

    @Test func aSpaceChangeIsLeftToTheSpaceSlide() {
        let old = AddressMark(tab: first, space: space, text: "example.com")
        let new = AddressMark(tab: second, space: UUID(), text: "news.ycombinator.com")
        let step = AddressMove.TabStep(to: second, fromPlace: 0, toPlace: 3)

        let chosen = move(old, new, step: step)

        #expect(chosen == .still)
    }

    @Test func typingInTheFieldLeavesThePillAsItIs() {
        let resting = AddressMark(tab: first, space: space, text: "example.com")
        let typing = AddressMark(tab: first, space: space, text: "example.com")

        let chosen = move(resting, typing)

        #expect(chosen == .still)
    }

    @Test func changingTheAddressStyleIsInstant() {
        let site = AddressMark(tab: first, space: space, text: "swift.org")
        let full = AddressMark(tab: first, space: space, text: "swift.org/documentation", full: true)

        let chosen = move(site, full)

        #expect(chosen == .still)
    }

    @Test func reduceMotionChangesAtOnce() {
        let old = AddressMark(tab: first, space: space, text: "example.com")
        let new = AddressMark(tab: second, space: space, text: "wikipedia.org")
        let step = AddressMove.TabStep(to: second, fromPlace: 0, toPlace: 1)

        let tab = move(old, new, step: step, reduced: true)
        let link = move(old, AddressMark(tab: first, space: space, text: "swift.org"), reduced: true)

        #expect(tab == .still)
        #expect(link == .still)
    }
}

private typealias AddressMark = AddressMove.Mark
