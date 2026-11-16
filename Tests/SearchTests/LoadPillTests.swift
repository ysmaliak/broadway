import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct LoadPillTests {
    private let pane = CGRect(x: 100, y: 0, width: 400, height: 600)

    @Test func withCardsThePillSitsInTheMarginAboveTheCard() {
        let at = LoadPillView.origin(in: pane, cards: true)

        #expect(at.x == pane.midX - LoadPillView.width / 2)
        #expect(at.y >= -Metrics.cardGap)
        #expect(at.y + LoadPillView.height <= 0)
        #expect(-at.y - LoadPillView.height == Metrics.cardGap + at.y)
    }

    @Test func withCardsTheMarginPlaceDoesNotFollowThePageTop() {
        let below = pane.offsetBy(dx: 0, dy: 40)

        let at = LoadPillView.origin(in: below, cards: true)

        #expect(at.y == LoadPillView.origin(in: pane, cards: true).y)
    }

    @Test func withoutCardsThePillSitsJustInsideTheTop() {
        let lower = pane.offsetBy(dx: 0, dy: 30)

        let at = LoadPillView.origin(in: lower, cards: false)

        #expect(at.x == lower.midX - LoadPillView.width / 2)
        #expect(at.y == lower.minY + 2)
    }

    @Test func theMovingFillHasRoundEndsThatStayInsideThePill() throws {
        let pill = LoadPillView(frame: NSRect(x: 0, y: 0, width: LoadPillView.width, height: LoadPillView.height))

        pill.layoutSubtreeIfNeeded()
        pill.layout()

        let track = try #require(pill.layer?.sublayers?.first)
        let fill = try #require(track.sublayers?.first as? CAShapeLayer)
        let line = try #require(fill.path?.boundingBoxOfPath)
        #expect(fill.lineCap == .round)
        #expect(track.cornerRadius == LoadPillView.height / 2)
        #expect(line.minX == LoadPillView.height / 2)
        #expect(line.maxX == LoadPillView.width - LoadPillView.height / 2)
    }

    @Test func onThePageItTakesTheAccentAndOnTheGroundTheInk() {
        #expect(LoadPillView.tone(cards: true, onPage: true) == .ink)
        #expect(LoadPillView.tone(cards: true, onPage: false) == .ink)
        #expect(LoadPillView.tone(cards: false, onPage: false) == .ink)
        #expect(LoadPillView.tone(cards: false, onPage: true) == .accent)
    }

    @Test func aLoadShorterThanTheWaitNeverShows() async throws {
        let pill = LoadPillView()

        pill.loading = true
        try await Task.sleep(for: .milliseconds(80))
        pill.loading = false
        try await Task.sleep(for: .milliseconds(300))

        #expect(!pill.shown)
        #expect(pill.trackOpacity == 0)
    }

    @Test func aLongerLoadShowsAfterTheWaitAndGoesWhenItLands() async throws {
        let pill = LoadPillView()

        pill.loading = true

        #expect(!pill.shown)

        try await Task.sleep(for: .milliseconds(Int(LoadPillView.wait * 1000) + 150))

        #expect(pill.shown)
        #expect(pill.trackOpacity == 1)

        pill.loading = false

        #expect(!pill.shown)
        #expect(pill.trackOpacity == 0)
    }
}
