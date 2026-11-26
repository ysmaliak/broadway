import AppKit
import Testing
import WebKit
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

    @Test func theFadeIsAsWideAsTheTitlesLineIsTall() {
        #expect(RowTitleFade.width == SideLook.titleLine)
        #expect(TitleFadeWidth.width == RowTitleFade.width)
    }

    @Test(arguments: [Metrics.sideRowHeight, Metrics.sideRowHeight + 10])
    func atRestTheFadeEndsAtTheCloseSquaresFarEdge(height: CGFloat) {
        let edge = RowTitleFade.edge(height: height)

        #expect(edge == Metrics.closeInset(height))
        #expect(RowTitleFade.spill(height: height) == RowTitleFade.whole - edge)
    }

    @Test func aTitleThatEndsAtTheRowsPadIsWhole() {
        let spill = RowTitleFade.spill(height: Metrics.sideRowHeight)

        #expect(!RowTitleFade.fades(natural: 160 - spill, room: 160, reserve: 0, spill: spill))
        #expect(RowTitleFade.fades(natural: 160 - spill + 1, room: 160, reserve: 0, spill: spill))
    }

    @Test func roomKeptForAMarkCountsBeforeTheRowsPad() {
        let spill = RowTitleFade.spill(height: Metrics.sideRowHeight)

        #expect(RowTitleFade.fades(natural: 140, room: 160, reserve: 28, spill: spill))
        #expect(!RowTitleFade.fades(natural: 132, room: 160, reserve: 28, spill: spill))
    }

    @Test func theCloseButtonKeepsTheSameGapWhereverTheTitleEnds() {
        let height = Metrics.sideRowHeight
        let close = Metrics.closeSquare(height) + Metrics.closeInset(height)

        let reserve = RowTitleFade.reserve(closeFromEnd: close, toEnd: RowTitleFade.edge(height: height))

        #expect(RowTitleFade.edge(height: height) + reserve == close + 2)
    }

    @Test func aLongTitleAtRestHasToClearTheCloseButtonsPlace() {
        let spill = RowTitleFade.spill(height: Metrics.sideRowHeight)

        #expect(RowTitleFade.clears(natural: 300, room: 160, kept: 0, reserve: 28, spill: spill))
    }

    @Test func aTitleThatEndsBeforeTheCloseButtonHasNothingToClear() {
        let spill = RowTitleFade.spill(height: Metrics.sideRowHeight)

        #expect(!RowTitleFade.clears(natural: 120, room: 160, kept: 0, reserve: 28, spill: spill))
    }

    @Test func aTitleAlreadyKeptClearOfAMarkHasNothingToClear() {
        let spill = RowTitleFade.spill(height: Metrics.sideRowHeight)

        #expect(!RowTitleFade.clears(natural: 300, room: 160, kept: 28, reserve: 28, spill: spill))
        #expect(!RowTitleFade.clears(natural: 300, room: 160, kept: 0, reserve: 0, spill: spill))
    }

    private final class Staged {
        let row: TabRowView
        let window: NSWindow
        let tab: Tab
        let browser: Browser

        init(row: TabRowView, window: NSWindow, tab: Tab, browser: Browser) {
            self.row = row
            self.window = window
            self.tab = tab
            self.browser = browser
        }
    }

    private func staged(_ name: String, width: CGFloat = 246, height: CGFloat = Metrics.sideRowHeight, live: Bool = false) -> Staged {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: false, configuration: configuration)
        tab.setAddressOptimistically(URL(string: "https://example.com/")!)
        tab.name = name
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView?.addSubview(row)
        var state = RowState()
        state.live = live
        state.height = height
        let browser = Browser(record: WindowRecord())
        row.show(tab, in: browser, state: state)
        row.layoutSubtreeIfNeeded()
        return Staged(row: row, window: window, tab: tab, browser: browser)
    }

    private func ends(_ stage: Staged) throws -> (whole: CGFloat, gone: CGFloat, ink: CGFloat) {
        let row = stage.row
        row.layoutSubtreeIfNeeded()
        let read = try #require(row.benchEnd)
        let model = try #require(read["model"] as? [Double])
        try #require(model.count == 2)
        let x = try #require(read["x"] as? Double), natural = try #require(read["natural"] as? Double)
        return (row.bounds.width - CGFloat(model[0]), row.bounds.width - CGFloat(model[1]), row.bounds.width - CGFloat(x + natural))
    }

    private func point(_ stage: Staged, over: Bool) {
        let row = stage.row
        KitHoverView.pointerStandIn = (stage.window, over ? NSPoint(x: 40, y: row.bounds.midY) : NSPoint(x: -400, y: -400))
        row.settleHover()
        KitHoverView.pointerStandIn = nil
        row.layoutSubtreeIfNeeded()
    }

    @Test func theCloseButtonTakesAClickAsSoonAsALongTitledRowIsUnderThePointer() throws {
        let stage = staged(Self.long)
        let zone = try #require(stage.row.kitSubviews(of: RowCloseZone.self).first)

        point(stage, over: true)

        #expect(stage.row.isHovering)
        #expect(zone.ready())
    }

    private static let long = "A title long enough to run well past the end of any row the column can show it in"

    @Test(arguments: [false, true])
    func aLongTitleAtRestRunsToTheCloseSquaresFarEdge(live: Bool) throws {
        let stage = staged(Self.long, live: live)

        let at = try ends(stage)

        #expect(abs(at.gone - Metrics.closeInset(Metrics.sideRowHeight)) < 0.01)
        #expect(abs(at.whole - at.gone - RowTitleFade.width) < 0.01)
    }

    @Test(arguments: [200, 246, 428] as [CGFloat])
    func theRestingEndIsTheSameInANarrowAndAWideColumn(width: CGFloat) throws {
        let stage = staged(Self.long, width: width)

        let at = try ends(stage)

        #expect(abs(at.gone - 4) < 0.01)
        #expect(abs(at.whole - 20) < 0.01)
    }

    @Test func aTallerRowKeepsItsOwnCloseInset() throws {
        let height = Metrics.sideRowHeight + 10
        let stage = staged(Self.long, height: height)

        let at = try ends(stage)

        #expect(abs(at.gone - Metrics.closeInset(height)) < 0.01)
    }

    @Test func aShortTitleIsWholeAtRest() throws {
        let stage = staged("Notes")

        let at = try ends(stage)

        #expect(at.whole == at.gone)
        #expect(at.ink >= RowTitleFade.whole)
    }

    @Test func underThePointerTheTitleEndsTwoPointsBeforeTheCloseButton() throws {
        let stage = staged(Self.long)
        let close = Metrics.closeSquare(Metrics.sideRowHeight) + Metrics.closeInset(Metrics.sideRowHeight)

        point(stage, over: true)
        let over = try ends(stage)
        point(stage, over: false)
        let rest = try ends(stage)

        #expect(abs(over.gone - close - 2) < 0.01)
        #expect(abs(over.whole - over.gone - RowTitleFade.width) < 0.01)
        #expect(abs(rest.gone - Metrics.closeInset(Metrics.sideRowHeight)) < 0.01)
    }

    @Test func theTitlesFrameIsTheSameAtRestAndUnderThePointer() throws {
        let stage = staged(Self.long)
        let title = try #require(stage.row.kitSubviews(of: RowTitleView.self).first)
        let rest = title.frame

        point(stage, over: true)

        #expect(title.frame == rest)
        #expect(stage.row.bounds.width - title.frame.maxX == Metrics.closeInset(Metrics.sideRowHeight))
    }
}
