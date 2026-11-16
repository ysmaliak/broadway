import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(5)))
struct AnswerTests {
    private let teas: [String: Any] = ["url": "https://shop.example/teas", "title": "Lumen Tea Co.", "navigated": false]

    private var basket: [String: Any] {
        ["tab": "a8b6db94", "did": "click", "target": ["ref": "e10", "role": "button", "name": "Add to basket"],
         "settled": "quiet", "ms": 620, "page": teas,
         "appeared": [["ref": "e61", "role": "status", "name": "Added Glenmoor Breakfast"]],
         "went": [], "changed": [], "text": [["was": "Basket: 0 items", "now": "Basket: 1 item"]],
         "dialog": NSNull(), "tabs": ["opened": [], "closed": [], "working": "a8b6db94"], "download": NSNull(), "more": 0, "website": true]
    }

    private func command(_ name: String, tool: String? = nil) -> Command {
        Command(["name": name, "tool": tool ?? name, "tabbed": true])
    }

    @Test func aClickOnTheSamePageSaysWhatChanged() {
        #expect(Answer.lines(basket) == [
            "Clicked button \"Add to basket\" @e10",
            "Same page: Lumen Tea Co.",
            "+ @e61 status \"Added Glenmoor Breakfast\"",
            "~ \"Basket: 0 items\" → \"Basket: 1 item\"",
        ])
    }

    @Test func theAppsOwnFirstLineWins() {
        var data = basket
        data["message"] = "Clicked button \"Add to basket\" @e10 (clicked in script: it has no size to click)"

        #expect(Answer.lines(data).first == "Clicked button \"Add to basket\" @e10 (clicked in script: it has no size to click)")
    }

    @Test func aNavigationNamesTheNewPageAndOffersTheNextStep() {
        let data: [String: Any] = ["tab": "a8b6db94", "did": "click", "target": ["ref": "e2", "role": "link", "name": "Checkout"],
                                   "settled": "navigated", "page": ["url": "https://shop.example/checkout", "title": "Checkout", "navigated": true],
                                   "headings": ["Checkout", "Your details", "Payment"]]

        #expect(Answer.lines(data) == [
            "Clicked link \"Checkout\" @e2",
            "Went to: Checkout  shop.example/checkout   (new page: refs start again)",
            "Headings: Checkout · Your details · Payment",
            "Next: broadway snapshot",
        ])
    }

    @Test func aNavigationWithALookShowsThePageInsteadOfTheHeadings() {
        let look: [String: Any] = ["elements": [["ref": "e1", "role": "heading", "name": "Checkout", "region": "e9"],
                                                ["ref": "e3", "role": "textbox", "name": "Email", "region": "e9"]],
                                   "regions": [["ref": "e9", "role": "main", "name": ""]], "shown": 2, "total": 43]
        let data: [String: Any] = ["tab": "a8b6db94", "did": "click", "target": ["ref": "e2", "role": "link", "name": "Checkout"],
                                   "settled": "navigated", "page": ["url": "https://shop.example/checkout", "title": "Checkout", "navigated": true],
                                   "headings": ["Checkout"], "look": look]

        #expect(Answer.lines(data) == [
            "Clicked link \"Checkout\" @e2",
            "Went to: Checkout  shop.example/checkout   (new page: refs start again)",
            "## main",
            "@e1 heading \"Checkout\"",
            "@e3 textbox \"Email\"",
            "… 41 more: broadway snapshot, or --in @ref, --role, --find",
        ])
        #expect(Answer.lines(data, look: false).contains("Next: broadway snapshot"))
    }

    @Test func aDialogSaysHowToAnswerIt() {
        var data = basket
        data["appeared"] = []
        data["text"] = []
        data["settled"] = "dialog"
        data["dialog"] = ["id": "d1", "kind": "confirm", "message": "Empty the basket?", "site": "shop.example"]

        #expect(Answer.lines(data) == [
            "Clicked button \"Add to basket\" @e10",
            "A confirm dialog is open: \"Empty the basket?\"",
            "Answer it: broadway dialog accept, or broadway dialog dismiss",
        ])
    }

    @Test func anAlertThatAnsweredItselfIsReported() {
        var data = basket
        data["appeared"] = []
        data["text"] = []
        data["dialog"] = ["kind": "alert", "message": "Saved", "accepted": true]

        #expect(Answer.lines(data).contains("The page said (alert, accepted): \"Saved\""))
        #expect(!Answer.lines(data).contains { $0.contains("dialog accept") })
    }

    @Test func aNewTabSaysWhereItIsAndHowToSwitch() {
        var data = basket
        data["appeared"] = []
        data["text"] = []
        data["tabs"] = ["opened": [["id": "2c4d6e8f", "title": "Gift cards", "url": "https://shop.example/gift", "popup": true]], "closed": [], "working": "a8b6db94"]

        #expect(Answer.lines(data) == [
            "Clicked button \"Add to basket\" @e10",
            "New tab 2c4d6e8f: Gift cards  shop.example/gift. Switch to it: broadway tab 2c4d6e8f",
        ])
    }

    @Test func downloadsAndABusyPageAreFacts() {
        var data = basket
        data["appeared"] = []
        data["text"] = []
        data["settled"] = "capped"
        data["ms"] = 5000
        data["busy"] = ["requests": 2]
        data["download"] = ["name": "price-list.pdf", "state": "started"]
        data["went"] = [["ref": "e40", "role": "dialog", "name": "Cookies"]]

        let lines = Answer.lines(data)

        #expect(lines.contains("Download started: price-list.pdf. Wait for it: broadway wait --download."))
        #expect(lines.contains("- @e40 dialog \"Cookies\""))
        #expect(lines.last == "Still busy after 5 s: 2 requests open. broadway wait to wait longer.")
    }

    @Test func marksStopAtTheirCapsAndCountTheRest() {
        var data = basket
        data["appeared"] = (1...11).map { ["ref": "e\($0)", "role": "row", "name": "Row \($0)"] }
        data["went"] = (20...26).map { ["ref": "e\($0)", "role": "row", "name": "Old \($0)"] }
        data["text"] = []
        data["more"] = 4

        let lines = Answer.lines(data)

        #expect(lines.filter { $0.hasPrefix("+ ") }.count == 8)
        #expect(lines.filter { $0.hasPrefix("- ") }.count == 5)
        #expect(lines.last == "… 9 more: broadway snapshot --since")
    }

    @Test func nothingChangedIsSaidPlainly() {
        var data = basket
        data["appeared"] = []
        data["text"] = []
        data["nothing"] = true

        #expect(Answer.lines(data).last == "Nothing on the page changed")
    }

    @Test func openPrintsTheBareIdOffATerminalAndTheRestAsNotes() {
        let data: [String: Any] = ["tab": "a8b6db94", "did": "open", "page": ["url": "https://shop.example/teas", "title": "Lumen Tea Co.", "navigated": true, "loaded": true],
                                   "settled": "quiet", "tabs": ["opened": [], "closed": [], "working": "a8b6db94", "count": 2], "same": ["2c4d6e8f"], "id": "a8b6db94"]

        let piped = Render.answer(data, tty: false, short: false, look: true)
        let shown = Render.answer(data, tty: true, short: false, look: true)

        #expect(piped.out == ["a8b6db94"])
        #expect(piped.err.first == "a8b6db94  Lumen Tea Co.  shop.example/teas")
        #expect(shown.out == [
            "a8b6db94  Lumen Tea Co.  shop.example/teas",
            "New tab, now your current tab",
            "tabs: 2",
            "You already have this address in tab 2c4d6e8f. Use it: broadway tab 2c4d6e8f",
        ])
        #expect(shown.err.isEmpty)
    }

    @Test func aQuietAnswerIsTheFirstLineOnly() {
        #expect(Render.answer(basket, tty: true, short: true, look: true).out == ["Clicked button \"Add to basket\" @e10"])
    }

    @Test func anOldAppsAnswersStillPrint() {
        #expect(Render.lines(command("click"), ["message": "Clicked", "tab": "a8b6db94"]) == ["Clicked"])
        #expect(Render.lines(command("choose"), ["ok": true]) == ["Chose the option"])
        #expect(Render.lines(command("scroll"), ["height": 800, "y": 0]) == ["height: 800", "y: 0"])
    }

    @Test func numbersStayNumbersAndOnlyTrueAndFalseReadAsYesAndNo() throws {
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(#"{"y":0,"one":1,"on":true,"off":false}"#.utf8)) as? [String: Any])

        #expect(Render.cell(decoded["y"]) == "0")
        #expect(Render.cell(decoded["one"]) == "1")
        #expect(Render.cell(decoded["on"]) == "yes")
        #expect(Render.cell(decoded["off"]) == "no")
        #expect(Render.cell(0) == "0")
        #expect(Render.cell(true) == "yes")
    }

    @Test func aSnapshotHasItsHeaderRegionsAndWhatIsLeft() {
        let data: [String: Any] = [
            "title": "Lumen Tea Co.", "url": "https://shop.example/teas", "shown": 3, "total": 64, "scope": "page",
            "regions": [["ref": "e30", "role": "navigation", "name": ""], ["ref": "e31", "role": "main", "name": ""]],
            "elements": [["ref": "e2", "role": "link", "name": "Checkout", "path": "/checkout", "region": "e30"],
                         ["ref": "e1", "role": "heading", "name": "Lumen Tea Co.", "region": "e31"],
                         ["role": "text", "name": "Basket: 1 item", "region": "e31"]],
        ]

        #expect(Render.snapshotLines(command("snapshot"), data) == [
            "Lumen Tea Co.  shop.example/teas",
            "## navigation",
            "@e2 link \"Checkout\" -> /checkout",
            "## main",
            "@e1 heading \"Lumen Tea Co.\"",
            "text \"Basket: 1 item\"",
            "… 61 more: --all, --in @ref, --role, --find, --view",
        ])
    }

    @Test func aModalSnapshotSaysItShowsOnlyTheDialog() {
        let data: [String: Any] = ["title": "Shop", "url": "https://shop.example/", "scope": "dialog", "regions": [["ref": "e88", "role": "dialog", "name": "Cookies"]],
                                   "elements": [["ref": "e89", "role": "button", "name": "Accept", "region": "e88"]]]

        #expect(Render.snapshotLines(command("snapshot"), data) == [
            "Shop  shop.example",
            "A dialog is open, so only it is shown (the whole page: --all)",
            "## dialog \"Cookies\"",
            "@e89 button \"Accept\"",
        ])
    }

    @Test func aPageThatNeedsThePersonSaysSoFirst() {
        let data: [String: Any] = ["title": "Sign in", "url": "https://shop.example/login", "needs": "password", "ways": ["Google"],
                                   "elsewhere": [["space": "Work"]], "elements": [["ref": "e1", "role": "textbox", "name": "Email"]]]

        let lines = Render.snapshotLines(command("snapshot"), data)

        #expect(lines[1] == "needs: a password, so run broadway fill login (Broadway fills it after the person's yes, you never see it)")
        #expect(lines[2] == "signs in with: Google")
        #expect(lines[3] == "signed in elsewhere: space \"Work\" has a sign-in for shop.example. broadway open https://shop.example/login --space 'Work'")
    }

    @Test func findGivesEachMatchItsPlaceAndCountsTheRest() {
        let data: [String: Any] = ["count": 30, "elements": [
            ["ref": "e10", "role": "button", "name": "Add to basket", "near": "list item \"Glenmoor Breakfast\""],
            ["ref": "e11", "role": "button", "name": "Add to basket", "near": "Harbour Green £4"],
        ]]

        #expect(Render.snapshotLines(command("find", tool: "locate"), data) == [
            "@e10 button \"Add to basket\"   in list item \"Glenmoor Breakfast\"",
            "@e11 button \"Add to basket\"   near \"Harbour Green £4\"",
            "… 28 more: --limit, --in @ref",
        ])
    }

    @Test func zeroSnapshotsLinesKeepTheOldFormatForGrep() {
        let data: [String: Any] = ["title": "", "url": "", "elements": [["ref": "e12", "role": "button", "name": "Save", "disabled": true]]]

        #expect(Render.snapshotLines(command("snapshot"), data) == ["@e12 button \"Save\" disabled"])
    }

    @Test func anExpectationSaysWhetherItCame() {
        var met = basket
        met["expect"] = ["kind": "text", "want": "1 item", "met": true, "after": 0.4]
        var missed = basket
        missed["expect"] = ["kind": "gone", "want": "Loading", "met": false, "after": 5.0]

        #expect(Answer.lines(met)[1] == "Expected \"1 item\": there after 0.4 s")
        #expect(Answer.lines(missed)[1] == "Expected \"Loading\" to go: still there after 5 s")
    }

    @Test func severalOpenedTabsAreALineEach() {
        let lines = Render.openedLines([["id": "2c4d6e8f", "title": "Gift cards", "url": "https://shop.example/gift", "loading": true],
                                        ["id": "a8b6db94", "title": "Teas", "url": "https://shop.example/teas", "loading": false]])

        #expect(lines == ["2c4d6e8f  Gift cards  shop.example/gift  still loading", "a8b6db94  Teas  shop.example/teas"])
    }

    @Test func aLongAnswerIsCutAtALine() {
        let text = (1...4000).map { "@e\($0) button \"Row \($0)\"" }.joined(separator: "\n") + "\n"

        let split = Render.cut(text)

        #expect(split.rest)
        #expect(split.shown.utf8.count <= Render.most)
        #expect(split.shown.hasSuffix("\"\n"))
        #expect(!Render.cut("short\n").rest)
    }
}
