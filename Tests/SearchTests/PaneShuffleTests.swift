import Foundation
import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct TabSplitMoveTests {
    @Test func movingTheFirstOfTwoSwapsThemWithTheirSizes() {
        let left = UUID(), right = UUID()
        var split = TabSplit(tabs: [left, right], sizes: [0.3, 0.7], focused: left)

        let moved = split.move(left, to: 1)

        #expect(moved)
        #expect(split.tabs == [right, left])
        #expect(split.sizes == [0.7, 0.3])
        #expect(split.focused == left)
    }

    @Test func movingAmongThreeKeepsTheOthersInOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        var split = TabSplit(tabs: [a, b, c], sizes: [0.2, 0.3, 0.5])

        split.move(c, to: 0)

        #expect(split.tabs == [c, a, b])
        #expect(split.sizes == [0.5, 0.2, 0.3])
    }

    @Test func movingToItsOwnPlaceOrOutsideChangesNothing() {
        let a = UUID(), b = UUID()
        var split = TabSplit(tabs: [a, b])

        let same = split.move(a, to: 0)
        let outside = split.move(a, to: 2)
        let stranger = split.move(UUID(), to: 1)

        #expect(!(same || outside || stranger))
        #expect(split.tabs == [a, b])
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PaneShuffleTests {
    private let gap: CGFloat = 7

    private func two(left: CGFloat = 400, right: CGFloat = 400) -> (UUID, UUID, [UUID: CGRect]) {
        let a = UUID(), b = UUID()
        return (a, b, [a: CGRect(x: 0, y: 36, width: left, height: 600),
                       b: CGRect(x: left + gap, y: 36, width: right, height: 600)])
    }

    @Test func carryingTheLeftPagePastTheMiddleSwapsThem() {
        let (a, b, frames) = two()
        var shuffle = PaneShuffle(carried: a, order: [a, b], frames: frames, gap: gap)!

        shuffle.move(by: 260)

        #expect(shuffle.landing == 1)
        #expect(shuffle.result == [b, a])
        #expect(shuffle.shift(of: a) == 260)
        #expect(shuffle.shift(of: b) == -(400 + gap))
    }

    @Test func shortOfTheMiddleNothingMoves() {
        let (a, b, frames) = two()
        var shuffle = PaneShuffle(carried: a, order: [a, b], frames: frames, gap: gap)!

        shuffle.move(by: 190)

        #expect(!shuffle.moved)
        #expect(shuffle.shift(of: b) == 0)
    }

    @Test func theCarriedPageStaysOnTheStage() {
        let (a, b, frames) = two()
        var shuffle = PaneShuffle(carried: b, order: [a, b], frames: frames, gap: gap)!

        shuffle.move(by: 900)
        let right = shuffle.travel
        shuffle.move(by: -2000)

        #expect(right == 0)
        #expect(shuffle.travel == -(400 + gap))
        #expect(shuffle.result == [b, a])
    }

    @Test func unevenPagesKeepTheirWidthsWhereTheyLand() {
        let (a, b, frames) = two(left: 300, right: 600)
        var shuffle = PaneShuffle(carried: a, order: [a, b], frames: frames, gap: gap)!

        shuffle.move(by: 500)
        shuffle.drop()

        #expect(shuffle.targets[b] == CGRect(x: 0, y: 36, width: 600, height: 600))
        #expect(shuffle.targets[a] == CGRect(x: 600 + gap, y: 36, width: 300, height: 600))
        #expect(shuffle.shift(of: a) == (600 + gap))
    }

    @Test func threePagesReorderAroundTheCarriedOne() {
        let a = UUID(), b = UUID(), c = UUID()
        let frames = [a: CGRect(x: 0, y: 0, width: 300, height: 500),
                      b: CGRect(x: 307, y: 0, width: 300, height: 500),
                      c: CGRect(x: 614, y: 0, width: 300, height: 500)]
        var shuffle = PaneShuffle(carried: c, order: [a, b, c], frames: frames, gap: gap)!

        shuffle.move(by: -320)
        let middle = shuffle.result
        shuffle.move(by: -614)

        #expect(middle == [a, c, b])
        #expect(shuffle.result == [c, a, b])
        #expect(shuffle.shift(of: a) == 307)
        #expect(shuffle.shift(of: b) == 307)
    }

    @Test func cancelSendsEveryPageHome() {
        let (a, b, frames) = two()
        var shuffle = PaneShuffle(carried: a, order: [a, b], frames: frames, gap: gap)!
        shuffle.move(by: 300)

        shuffle.cancel()

        #expect(!shuffle.moved)
        #expect(shuffle.result == [a, b])
        #expect(shuffle.shift(of: a) == 0)
        #expect(shuffle.shift(of: b) == 0)
    }

    @Test func droppingBackWhereItStartedIsNoMove() {
        let (a, b, frames) = two()
        var shuffle = PaneShuffle(carried: a, order: [a, b], frames: frames, gap: gap)!
        shuffle.move(by: 300)

        shuffle.move(by: 20)
        shuffle.drop()

        #expect(!shuffle.moved)
        #expect(shuffle.shift(of: a) == 0)
    }

    @Test func noShuffleWithoutAFrameForEveryPage() {
        let a = UUID(), b = UUID()

        let shuffle = PaneShuffle(carried: a, order: [a, b], frames: [a: .zero], gap: gap)

        #expect(shuffle == nil)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SplitReorderTests {
    private func browser(tabs count: Int) -> Browser {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.splitView = true
        for number in 0..<count {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://\(number).example/")!, title: "\(number)")
        }
        addTeardownBlock { @MainActor in browser.closeAll() }
        return browser
    }

    @Test func reorderingAPairSwapsItsPagesInTheRowAndThePair() {
        let browser = browser(tabs: 3)
        let tabs = Array(browser.tabs.filter { $0.pin == nil }.suffix(3))
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        let pair = browser.split(for: tabs[0])!
        browser.setSplitFraction(pair.id, fraction: 0.35)

        browser.reorderSplit(pair.id, moving: tabs[0].id, to: 1)

        let after = browser.split(for: tabs[0])
        #expect(after?.tabs == [tabs[1].id, tabs[0].id])
        #expect(abs((after?.sizes.first ?? 0) - 0.65) <= 0.0001)
        let row = browser.tabs.map(\.id).filter { [tabs[0].id, tabs[1].id, tabs[2].id].contains($0) }
        #expect(row == [tabs[1].id, tabs[0].id, tabs[2].id])
        #expect(browser.displayedTabs.contains { $0.id == tabs[1].id })
        #expect(!browser.displayedTabs.contains { $0.id == tabs[0].id })
    }

    @Test func swapStillReversesThePair() {
        let browser = browser(tabs: 2)
        let tabs = Array(browser.tabs.filter { $0.pin == nil }.suffix(2))
        browser.pair(tabs[1], with: tabs[0], onLeft: false)

        browser.swapSplit()

        #expect(browser.activeSplit?.tabs == [tabs[1].id, tabs[0].id])
    }

    @Test func reorderingToTheSamePlaceLeavesThePairAlone() {
        let browser = browser(tabs: 2)
        let tabs = Array(browser.tabs.filter { $0.pin == nil }.suffix(2))
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        let pair = browser.split(for: tabs[0])!
        let row = browser.tabs.map(\.id)

        browser.reorderSplit(pair.id, moving: pair.left, to: 0)

        #expect(browser.split(for: tabs[0])?.tabs == pair.tabs)
        #expect(browser.tabs.map(\.id) == row)
    }

    @Test func aReorderedPairIsStoredInItsNewOrder() throws {
        let browser = browser(tabs: 2)
        let tabs = Array(browser.tabs.filter { $0.pin == nil }.suffix(2))
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        let pair = try #require(browser.split(for: tabs[0]))
        browser.setSplitFraction(pair.id, fraction: 0.35)

        browser.reorderSplit(pair.id, moving: pair.left, to: 1)
        browser.writeSession(now: true)

        let data = try JSONEncoder().encode(try #require(browser.record.rows[browser.spaceID.uuidString]))
        let shape = try JSONDecoder().decode(Session.Shape.self, from: data)
        let stored = try #require(shape.splits.first)
        #expect(stored.tabs.map { shape.tabs[$0].url } == ["https://1.example/", "https://0.example/"])
        #expect(abs((stored.sizes.first ?? 0) - 0.65) <= 0.0001)
        #expect(shape.tabs.filter { $0.pin == nil }.map(\.url) == ["https://1.example/", "https://0.example/"])
    }
}
