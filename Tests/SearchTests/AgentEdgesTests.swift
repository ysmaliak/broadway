import AppKit
import Testing
@testable import Search
@testable import BroadwayCLI

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AgentEdgesTests {
    private final class RetinaWindow: NSWindow {
        override var backingScaleFactor: CGFloat { 2 }
    }
    private func command(_ name: String) throws -> BroadwayCLI.Command {
        let spec = try #require(BrowserToolbox().tools.first { $0.name == name })
        return BroadwayCLI.Command(try #require(AgentCatalog.command(spec)))
    }

    @Test func snapshotTakesFramesOnTheCommandLineAsItsToolDoes() throws {
        let snapshot = try command("snapshot")

        let found = try CommandLineInput.parse(snapshot, ["--frames"])

        #expect(found["frames"] as? Bool == true)
        #expect(snapshot.flags.first { $0.name == "frames" }?.unlisted == true)
    }

    @Test func scrollTakesLeftAndRightWithTheSameAnswerAsDownAndUp() throws {
        let scroll = try command("scroll")

        let page = try CommandLineInput.parse(scroll, ["right", "500"])
        let box = try CommandLineInput.parse(scroll, ["Orders", "left"])
        let boxBy = try CommandLineInput.parse(scroll, ["@e3", "left", "200"])

        #expect(page["by"] as? String == "right 500")
        #expect((box["target"] as? [String: Any])?["words"] as? String == "Orders")
        #expect(box["by"] as? String == "left")
        #expect(boxBy["by"] as? String == "left 200")
        #expect(AgentScrolling.amount("left 300") == AgentScrolling.Amount(mode: "left", points: 300))
        #expect(AgentScrolling.amount("right") == AgentScrolling.Amount(mode: "right", points: 0))
        #expect(AgentScrolling.sideways(mode: "right", moved: 500, end: false, left: 1220) == "Scrolled right 500 points, 1220 more to the right")
        #expect(AgentScrolling.sideways(mode: "left", moved: -300, end: true, left: 0) == "Scrolled left 300 points, at the left end")
        #expect(AgentScrolling.sideways(mode: "left", moved: 0, end: true, left: 0) == "Already at the left end")
    }

    @Test func aBlockedWindowIsToldOnceWithItsAddressShownSafely() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.noteBlocked(URL(string: "https://sam:pw@ads.example/landing?from=timer"))

        let first = AgentPopupNews.take(tab)
        let again = AgentPopupNews.take(tab)
        tab.noteBlocked(URL(string: "https://ads.example/two"))
        let next = AgentPopupNews.take(tab)

        #expect(first == "The page tried to open a window and Broadway blocked it: ads.example/landing?from=timer")
        #expect(again == nil)
        #expect(next == "The page tried to open a window and Broadway blocked it: ads.example/two")
        #expect(AgentPopupNews.line([nil, nil]) == "The page tried to open 2 windows and Broadway blocked them")
    }

    @Test func rowsInANewOrderAreOneLine() {
        var change = AgentChange(tab: "t1", did: "click", page: .init(url: "http://127.0.0.1/reorder", title: "Ledger"))
        change.reordered = [AgentChange.reorderLine(["kind": "rows", "name": "Ledger", "table": true])]
        let back = AgentChange(object: change.object())

        #expect(!change.nothing)
        #expect(change.marks() == ["~ the rows of \"Ledger\" are in a new order"])
        #expect(back?.reordered == change.reordered)
        #expect(AgentChange.reorderLine(["kind": "items", "name": "", "table": false]) == "the items of the list are in a new order")
    }

    @Test func aPointWithNoShotTakenIsInThePixelsOfADefaultShot() {
        _ = NSApplication.shared
        let box = BrowserToolbox()
        let tab = Tab(configuration: Web.configuration())
        let window = RetinaWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(tab.web)

        let agent = UUID(), other = UUID()

        let scale = box.pictureScale(tab, task: agent)
        box.tookShot(tab, task: agent, scale: 2)
        tab.web.pageZoom = 0.5

        #expect(tab.web.window?.backingScaleFactor == 2)
        #expect(scale == Double(ShotSize.pixels(points: CGSize(width: 800, height: 600), scale: nil, width: nil).width) / 800)
        #expect(box.pictureScale(tab, task: agent) == 2)
        #expect(box.pictureScale(tab, task: other) == 1)
        #expect(box.pixelScale(tab, task: agent) == 1)
        #expect(box.pixelScale(tab, task: other) == 0.5)
        #expect(BrowserToolbox.zoomLine(tab)?.contains("50 %") == true)
    }

    @Test func stylesGiveTheBoxInThePixelsOfAShot() {
        let found: [String: Any] = ["ref": "e2", "role": "button", "element": "button#b", "box": ["x": 300.0, "y": 200.0, "width": 160.0, "height": 50.0, "inView": true], "styles": [:]]

        let half = AgentChecks.styles(found, scale: 0.5, zoom: "The page is zoomed to 50 %")
        let box = ToolReply.data(half)["box"] as? [String: Any]

        #expect(box?["x"] as? Double == 150 && box?["y"] as? Double == 100 && box?["width"] as? Double == 80 && box?["height"] as? Double == 25)
        #expect(half.text?.contains("80×25 at 150,100 in the pixels of broadway shot") == true)
        #expect(half.text?.contains("zoomed to 50 %") == true)
        #expect(AgentChecks.styles(found).text?.contains("zoomed") == false)
    }
}
