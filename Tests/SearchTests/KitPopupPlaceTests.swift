import AppKit
import Testing
@testable import Search

@Suite
struct KitPopupPlaceTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let size = CGSize(width: 300, height: 200)

    @Test func fromTheSidebarOnTheLeftItOpensToTheRightWithItsTopLevelWithTheAnchors() {
        let row = CGRect(x: 10, y: 600, width: 240, height: 30)

        let placed = KitPopup.place(anchor: row, size: size, edge: .page, sideOnRight: false, screen: screen)

        #expect(placed.edge == .right)
        #expect(placed.frame.minX == row.maxX + 6)
        #expect(placed.frame.maxY == row.maxY)
    }

    @Test func fromTheSidebarOnTheRightItOpensToTheLeft() {
        let row = CGRect(x: 1190, y: 600, width: 240, height: 30)

        let placed = KitPopup.place(anchor: row, size: size, edge: .page, sideOnRight: true, screen: screen)

        #expect(placed.edge == .left)
        #expect(placed.frame.maxX == row.minX - 6)
        #expect(placed.frame.maxY == row.maxY)
    }

    @Test func fromAControlOverThePageItOpensBelowOnTheAnchorsLeadingEdge() {
        let button = CGRect(x: 700, y: 820, width: 26, height: 26)

        let placed = KitPopup.place(anchor: button, size: size, edge: .below, sideOnRight: false, screen: screen)

        #expect(placed.edge == .below)
        #expect(placed.frame.minX == button.minX)
        #expect(placed.frame.maxY == button.minY - 6)
    }

    @Test func withNoRoomBelowItFlipsAbove() {
        let button = CGRect(x: 700, y: 60, width: 26, height: 26)

        let placed = KitPopup.place(anchor: button, size: size, edge: .below, sideOnRight: false, screen: screen)

        #expect(placed.edge == .above)
        #expect(placed.frame.minY == button.maxY + 6)
    }

    @Test func withNoRoomTowardThePageItFlipsToTheOtherSide() {
        let row = CGRect(x: 1200, y: 600, width: 200, height: 30)

        let placed = KitPopup.place(anchor: row, size: size, edge: .page, sideOnRight: false, screen: screen)

        #expect(placed.edge == .left)
        #expect(placed.frame.maxX == row.minX - 6)
    }

    @Test func itSlidesAlongTheAnchorsEdgeToStayEightPointsInsideTheScreen() {
        let low = CGRect(x: 10, y: 40, width: 240, height: 30)
        let right = CGRect(x: 1400, y: 820, width: 26, height: 26)

        let sideways = KitPopup.place(anchor: low, size: size, edge: .page, sideOnRight: false, screen: screen)
        let below = KitPopup.place(anchor: right, size: size, edge: .below, sideOnRight: false, screen: screen)

        #expect(sideways.edge == .right)
        #expect(sideways.frame.minY == 8)
        #expect(below.edge == .below)
        #expect(below.frame.maxX == 1432)
    }

    @Test func besideALowAnchorItStaysInsideItsWindowWhenItFits() {
        let window = CGRect(x: 100, y: 100, width: 1100, height: 700)
        let foot = CGRect(x: 320, y: 108, width: 26, height: 26)
        let tall = CGSize(width: 250, height: 900)

        let fits = KitPopup.place(anchor: foot, size: size, edge: .page, sideOnRight: false, screen: screen, window: window)
        let tooTall = KitPopup.place(anchor: foot, size: tall, edge: .page, sideOnRight: false, screen: screen, window: window)

        #expect(fits.frame.minY == window.minY + 8)
        #expect(fits.frame.minX == foot.maxX + 6)
        #expect(tooTall.frame.minY == 8)
    }

    @Test func itIsNeverTallerThanTheRoomItHas() {
        let button = CGRect(x: 700, y: 500, width: 26, height: 26)
        let tall = CGSize(width: 300, height: 2000)

        let below = KitPopup.place(anchor: button, size: tall, edge: .below, sideOnRight: false, screen: screen)
        let sideways = KitPopup.place(anchor: button, size: tall, edge: .right, sideOnRight: false, screen: screen)

        #expect(below.frame.minY == 8)
        #expect(below.frame.maxY == button.minY - 6)
        #expect(sideways.frame.height == CGFloat(884))
    }
}
