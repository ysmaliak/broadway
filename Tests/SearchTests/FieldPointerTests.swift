import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FieldPointerTests {
    private func offer(_ key: String) -> Suggestion {
        Suggestion(key: key, title: key, url: URL(string: "https://\(key)")!, kind: .visited)
    }

    @Test func aPointerAtRestDoesNotCount() {
        var watch = PointerWatch()
        watch.rest(at: NSPoint(x: 10, y: 10))

        let still = watch.moved(to: NSPoint(x: 10, y: 10))
        let moved = watch.moved(to: NSPoint(x: 11, y: 10))

        #expect(!still)
        #expect(moved)
    }

    @Test func pointedRowIsTheOnlyRowShown() {
        let browser = Browser(record: WindowRecord())
        browser.offers = [offer("a.test"), offer("b.test")]
        browser.picked = 0

        browser.pointed = 1

        #expect(browser.fieldRow == 1)
        #expect(browser.pickedOffer?.key == "b.test")
        #expect(browser.picked == 0)
    }

    @Test func pointerLeavingGivesTheRowBackToTheKeys() {
        let browser = Browser(record: WindowRecord())
        browser.offers = [offer("a.test"), offer("b.test")]
        browser.picked = 0
        browser.pointed = 1

        browser.pointed = nil

        #expect(browser.fieldRow == 0)
    }

    @Test func arrowKeysWalkOnFromThePointedRow() {
        let browser = Browser(record: WindowRecord())
        browser.offers = [offer("a.test"), offer("b.test"), offer("c.test")]
        browser.picked = 0
        browser.pointed = 1

        browser.walk(1)

        #expect(browser.pointed == nil)
        #expect(browser.picked == 2)
    }

    @Test func menuHoverNeedsARealMove() {
        let menu = FieldMenu()
        var pointer = NSPoint(x: 10, y: 10)
        menu.location = { pointer }
        menu.open(heading: "Page", items: [
            FieldMenuItem(id: "a", title: "A", symbol: "star") {},
            FieldMenuItem(id: "b", title: "B", symbol: "star") {},
        ])

        menu.point(at: 1)
        let still = menu.picked
        pointer = NSPoint(x: 11, y: 10)
        menu.point(at: 1)

        #expect(still == 0)
        #expect(menu.picked == 1)
    }
}
