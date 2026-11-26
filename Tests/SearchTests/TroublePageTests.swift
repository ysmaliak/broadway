import AppKit
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5))) struct TroubleHostTests {
    @Test func theTabInFrontLeavesItsHostToTheAddressField() {
        let shows = TroubleHost.fieldShows(inFront: true, split: false, folded: false)

        #expect(shows)
    }

    @Test func aFoldedColumnShowsNoAddress() {
        let shows = TroubleHost.fieldShows(inFront: true, split: false, folded: true)

        #expect(!shows)
    }

    @Test func theFocusedPaneOfASplitShowsItsHostInItsBarWithNoAddressInTheColumn() {
        let shows = TroubleHost.fieldShows(inFront: true, split: true, folded: true)

        #expect(shows)
    }

    @Test func theOtherPaneOfASplitShowsNoAddress() {
        let shows = TroubleHost.fieldShows(inFront: false, split: true, folded: false)

        #expect(!shows)
    }

    @Test func aHostTheFieldShowsStaysOffThePage() {
        let host = TroubleHost.onPage("example.test", fieldShows: true)

        #expect(host == nil)
    }

    @Test func aHostTheFieldDoesNotShowGoesOnThePageWithoutItsWWW() {
        let host = TroubleHost.onPage("www.example.test", fieldShows: false)

        #expect(host == "example.test")
    }

    @Test(arguments: [nil, ""] as [String?])
    func noHostPutsNothingOnThePage(_ given: String?) {
        let host = TroubleHost.onPage(given, fieldShows: false)

        #expect(host == nil)
    }

    @Test func aPageThatWaitsForTheNetworkSaysSo() {
        let waits = TroubleHost.waits(now: true, loading: false, before: false)

        #expect(waits)
    }

    @Test func aPageThatWaitedGoesOnSayingSoWhileItTriesAgain() {
        let waits = TroubleHost.waits(now: false, loading: true, before: true)

        #expect(waits)
    }

    @Test func aPageThatStoppedWaitingAndStoppedLoadingSaysSoNoLonger() {
        let waits = TroubleHost.waits(now: false, loading: false, before: true)

        #expect(!waits)
    }

    @Test func aPageThatNeverWaitedDoesNotSaySoWhileItLoads() {
        let waits = TroubleHost.waits(now: false, loading: true, before: false)

        #expect(!waits)
    }
}

@Suite(.timeLimit(.minutes(5)))
@MainActor
struct TroublePageTests {
    private func page(_ kind: TroubleKind, host: String? = nil, waiting: Bool = false, search: (() -> Void)? = {},
                      retry: @escaping () -> Void = {}) -> TroubleView {
        let view = TroubleView(message: kind.message, host: host, waiting: waiting, search: search, retry: retry)
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func paragraphs(_ view: TroubleView) -> [String] {
        view.kitSubviews(of: KitParagraph.self).filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.text)
    }

    private func labels(_ view: TroubleView) -> [String] {
        view.kitSubviews(of: KitLabel.self).filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.text)
    }

    private func buttons(_ view: TroubleView) -> [KitBroadwayButton] {
        view.kitSubviews(of: KitBroadwayButton.self).filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    @Test(arguments: TroubleKind.allCases)
    func thePageShowsItsTitleThenItsLine(_ kind: TroubleKind) {
        let view = page(kind)

        #expect(paragraphs(view) == [kind.message, kind.line()])
    }

    @Test func anOfflinePageThatWaitsSaysItWillLoadByItself() {
        let view = page(.offline, waiting: true)

        #expect(paragraphs(view).last == "This page will load when your Mac is back online")
    }

    @Test func aPageShownAgainTakesItsNewWords() {
        let view = page(.offline, waiting: true)

        view.show(message: TroubleKind.refused.message, host: "example.test")

        #expect(paragraphs(view) == [TroubleKind.refused.message, TroubleKind.refused.line()])
        #expect(view.host == "example.test")
        #expect(!view.waiting)
    }

    @Test func tryAgainIsTheDefaultButton() {
        let view = page(.refused)

        let found = buttons(view)

        #expect(found.map(\.title) == ["Try Again"])
        #expect(found.first?.kind == .primary)
    }

    @Test func searchInsteadIsAnOrdinaryButtonBesideTryAgain() {
        let view = page(.notFound)

        let found = buttons(view)

        #expect(found.map(\.title) == ["Search Instead", "Try Again"])
        #expect(found.map(\.kind) == [.secondary, .primary])
    }

    @Test(arguments: TroubleKind.allCases.filter { $0 != .notFound })
    func searchInsteadShowsOnlyWhereNoSiteWasFound(_ kind: TroubleKind) {
        let view = page(kind)

        #expect(buttons(view).map(\.title) == ["Try Again"])
    }

    @Test func searchInsteadIsLeftOutWhereThereIsNothingToSearchWith() {
        let view = page(.notFound, search: nil)

        #expect(buttons(view).map(\.title) == ["Try Again"])
    }

    @Test func tryAgainRunsWhatThePageWasGiven() {
        var tried = 0
        let view = page(.other, retry: { tried += 1 })

        _ = buttons(view).first { $0.title == "Try Again" }?.accessibilityPerformPress()

        #expect(tried == 1)
    }

    @Test func searchInsteadRunsWhatThePageWasGiven() {
        var searched = 0
        let view = page(.notFound, search: { searched += 1 })

        _ = buttons(view).first { $0.title == "Search Instead" }?.accessibilityPerformPress()

        #expect(searched == 1)
    }

    @Test func aHostGivenToThePageIsShownOnIt() {
        let view = page(.refused, host: "example.test")

        #expect(labels(view).contains("example.test"))
    }

    @Test func aPageGivenNoHostShowsNone() {
        let view = page(.refused)

        #expect(labels(view).sorted() == ["Try Again"])
    }

    @Test(arguments: TroubleKind.allCases)
    func thePageHasOneSmallMutedSymbolForItsKind(_ kind: TroubleKind) {
        let view = page(kind)

        let symbols = view.kitSubviews(of: KitSymbol.self).filter { !$0.isHiddenOrHasHiddenAncestor }

        #expect(symbols.map(\.name) == [kind.symbol])
        #expect(symbols.allSatisfy { $0.style.size <= 24 && $0.tint == KitColor.muted })
    }
}
