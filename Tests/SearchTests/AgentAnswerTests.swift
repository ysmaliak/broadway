import Foundation
import Testing
@testable import Search

struct AgentAnswerTests {
    private let teas = AgentChange.Page(url: "https://shop.example/teas", title: "Lumen Tea Co.")
    private let add = AgentChange.Element(ref: "e10", role: "button", name: "Add to basket")

    private var basket: AgentChange {
        AgentChange(tab: "a8b6db94", did: "click", target: add, ms: 620, page: teas,
                    appeared: [.init(ref: "e61", role: "status", name: "Added Glenmoor Breakfast")],
                    changed: [.init(.init(ref: "e6", role: "combobox", name: "Sort by", value: "price"), was: .init(value: "name"))],
                    text: [.init(was: "Basket: 0 items", now: "Basket: 1 item")])
    }

    @Test func theObjectCarriesEveryKeyOfTheAnswer() {
        let object = basket.object()
        #expect(Set(object.keys) == ["tab", "did", "target", "settled", "ms", "page", "headings", "appeared", "went", "changed",
                                     "text", "dialog", "tabs", "download", "more", "website", "message"])
        #expect(object["tab"] as? String == "a8b6db94")
        #expect(object["did"] as? String == "click")
        #expect(object["settled"] as? String == "quiet")
        #expect(object["ms"] as? Int == 620)
        #expect(object["more"] as? Int == 0)
        #expect(object["website"] as? Bool == true)
        #expect(object["dialog"] is NSNull)
        #expect(object["download"] is NSNull)
        #expect(object["message"] as? String == "Clicked button \"Add to basket\" @e10 in a8b6db94")
        let target = object["target"] as? [String: Any]
        #expect(target?["ref"] as? String == "e10")
        #expect(target?["role"] as? String == "button")
        #expect(target?["name"] as? String == "Add to basket")
        let page = object["page"] as? [String: Any]
        #expect(Set(page.map { Array($0.keys) } ?? []) == ["url", "title", "navigated"])
        #expect(page?["navigated"] as? Bool == false)
        let changed = (object["changed"] as? [[String: Any]])?.first
        #expect(changed?["value"] as? String == "price")
        #expect((changed?["was"] as? [String: Any])?["value"] as? String == "name")
        let text = (object["text"] as? [[String: Any]])?.first
        #expect(text?["was"] as? String == "Basket: 0 items")
        #expect(text?["now"] as? String == "Basket: 1 item")
        let tabs = object["tabs"] as? [String: Any]
        #expect(Set(tabs.map { Array($0.keys) } ?? []) == ["opened", "closed", "working"])
        #expect(tabs?["working"] as? String == "a8b6db94")
        #expect(JSONSerialization.isValidJSONObject(object))
    }

    @Test func optionalPartsAppearOnlyWhenThere() {
        var change = basket
        change.settled = .capped
        change.busy = .init(requests: 2)
        change.page.loaded = true
        change.same = ["2c4d6e8f"]
        change.dialog = .init(id: "d1", kind: "confirm", message: "Empty the basket?", site: "shop.example")
        change.download = .init(name: "price-list.pdf", state: "done", path: "/tmp/price-list.pdf")
        change.tabs.opened = [.init(id: "2c4d6e8f", title: "Gift cards", url: "https://shop.example/gift")]
        change.tabs.count = 2
        change.tabs.blocked = ["blocked.example"]
        let object = change.object()
        #expect((object["busy"] as? [String: Any])?["requests"] as? Int == 2)
        #expect(object["settled"] as? String == "capped")
        #expect(object["same"] as? [String] == ["2c4d6e8f"])
        #expect((object["page"] as? [String: Any])?["loaded"] as? Bool == true)
        #expect(Set((object["dialog"] as? [String: Any]).map { Array($0.keys) } ?? []) == ["id", "kind", "message", "site"])
        #expect((object["download"] as? [String: Any])?["path"] as? String == "/tmp/price-list.pdf")
        let tabs = object["tabs"] as? [String: Any]
        #expect(tabs?["count"] as? Int == 2)
        #expect(tabs?["blocked"] as? [String] == ["blocked.example"])
        #expect((tabs?["opened"] as? [[String: Any]])?.first?["popup"] as? Bool == true)
        #expect(JSONSerialization.isValidJSONObject(object))
    }

    @Test func keptKeysFromOldAnswersNeverOverrideNewOnes() {
        var change = basket
        change.kept = ["id": "a8b6db94", "message": "old", "url": "https://shop.example/teas"]
        let object = change.object()
        #expect(object["id"] as? String == "a8b6db94")
        #expect(object["url"] as? String == "https://shop.example/teas")
        #expect(object["message"] as? String == "Clicked button \"Add to basket\" @e10 in a8b6db94")
    }

    @Test func aClickOnTheSamePageSaysWhatChanged() {
        var change = basket
        change.changed = []
        #expect(change.lines() == [
            "Clicked button \"Add to basket\" @e10 in a8b6db94",
            "Same page: Lumen Tea Co.",
            "+ @e61 status \"Added Glenmoor Breakfast\"",
            "~ \"Basket: 0 items\" → \"Basket: 1 item\"",
        ])
    }

    @Test func aChangedElementShowsBeforeAndAfter() {
        #expect(basket.lines().contains("~ @e6 combobox \"Sort by\" \"name\" → \"price\""))
        let upload = AgentChange(tab: "a8b6db94", did: "upload", page: teas,
                                 changed: [.init(.init(ref: "e7", role: "file", name: "Résumé", state: "has 1"), was: .init())])
        #expect(upload.lines().contains("~ @e7 file \"Résumé\" has 1"))
        let box = AgentChange(tab: "a8b6db94", did: "click", page: teas,
                              changed: [.init(.init(ref: "e9", role: "checkbox", name: "Gift wrap", state: "checked"), was: .init(state: "unchecked"))])
        #expect(box.lines().contains("~ @e9 checkbox \"Gift wrap\" unchecked → checked"))
    }

    @Test func aNavigationNamesTheNewPage() {
        let change = AgentChange(tab: "a8b6db94", did: "click", target: .init(ref: "e2", role: "link", name: "Checkout"),
                                 settled: .navigated, page: .init(url: "https://shop.example/checkout", title: "Checkout", navigated: true),
                                 headings: ["Checkout", "Your details", "Payment"])
        #expect(change.lines() == [
            "Clicked link \"Checkout\" @e2 in a8b6db94",
            "Went to: Checkout  shop.example/checkout   (new page: refs start again)",
            "Headings: Checkout · Your details · Payment",
            "Next: broadway snapshot",
        ])
    }

    @Test func aDialogSaysHowToAnswerIt() {
        let change = AgentChange(tab: "a8b6db94", did: "click", target: .init(ref: "e8", role: "button", name: "Empty basket"),
                                 settled: .dialog, page: teas,
                                 dialog: .init(id: "d1", kind: "confirm", message: "Empty the basket?", site: "shop.example"))
        #expect(change.lines() == [
            "Clicked button \"Empty basket\" @e8 in a8b6db94",
            "A confirm dialog is open: \"Empty the basket?\"",
            "Answer it: broadway dialog accept, or broadway dialog dismiss",
        ])
    }

    @Test func aNewTabFromThePageIsNamedAndNotTaken() {
        let change = AgentChange(tab: "a8b6db94", did: "click", target: .init(ref: "e3", role: "link", name: "Gift cards"), page: teas,
                                 tabs: .init(opened: [.init(id: "2c4d6e8f", title: "Gift cards", url: "https://shop.example/gift")], working: "a8b6db94"))
        #expect(change.lines() == [
            "Clicked link \"Gift cards\" @e3 in a8b6db94",
            "New tab 2c4d6e8f: Gift cards  shop.example/gift. Switch to it: broadway tab 2c4d6e8f",
        ])
        var taken = change
        taken.tabs.working = "2c4d6e8f"
        #expect(taken.lines()[1] == "New tab 2c4d6e8f: Gift cards  shop.example/gift. It is now your current tab")
    }

    @Test func downloadsGoneElementsAndABusyPage() {
        let change = AgentChange(tab: "a8b6db94", did: "click", target: add, settled: .capped, busy: .init(requests: 2), ms: 5000, page: teas,
                                 went: [.init(ref: "e40", role: "dialog", name: "Cookies")], download: .init(name: "price-list.pdf", state: "started"))
        #expect(change.lines() == [
            "Clicked button \"Add to basket\" @e10 in a8b6db94",
            "Same page: Lumen Tea Co.",
            "Download started: price-list.pdf. Wait for it: broadway wait --download.",
            "- @e40 dialog \"Cookies\"",
            "Still busy after 5 s: 2 requests open. broadway wait to wait longer.",
        ])
    }

    @Test func linesAreCappedWithACountOfTheRest() {
        let many = (1...12).map { AgentChange.Element(ref: "e\($0)", role: "button", name: "B\($0)") }
        let change = AgentChange(tab: "a8b6db94", did: "click", page: teas, appeared: many, went: many,
                                 text: (1...7).map { .init(was: "a\($0)", now: "b\($0)") }, more: 3)
        let marks = change.marks()
        #expect(marks.filter { $0.hasPrefix("+ ") }.count == 8)
        #expect(marks.filter { $0.hasPrefix("- ") }.count == 5)
        #expect(marks.filter { $0.hasPrefix("~ ") }.count == 5)
        #expect(marks.last == "… 16 more: broadway snapshot --since")
    }

    @Test func openAndGoAnswerWithTheTabLine() {
        let open = AgentChange(tab: "a8b6db94", did: "open", page: teas, tabs: .init(working: "a8b6db94", count: 1))
        #expect(open.lines() == ["a8b6db94  Lumen Tea Co.  shop.example/teas", "New tab, now your current tab"])
        #expect(open.object()["message"] as? String == "a8b6db94  Lumen Tea Co.  shop.example/teas")
        var twice = open
        twice.same = ["2c4d6e8f"]
        #expect(twice.lines().last == "You already have this address in tab 2c4d6e8f. Use it: broadway tab 2c4d6e8f")
        let go = AgentChange(tab: "a8b6db94", did: "go", page: .init(url: "https://shop.example/", title: "Lumen Tea Co.", navigated: true))
        #expect(go.lines() == ["a8b6db94  Lumen Tea Co.  shop.example", "Went there"])
    }

    @Test func aWaitAndAnOwnFirstLine() {
        let wait = AgentChange(tab: "a8b6db94", did: "wait", ms: 1400, page: teas)
        #expect(wait.lines().first == "Waited 1.4 s in a8b6db94")
        var said = wait
        said.said = "Waited 1.4 s: \"Order placed\" is on the page in a8b6db94"
        #expect(said.lines().first == "Waited 1.4 s: \"Order placed\" is on the page in a8b6db94")
        let skipped = AgentChange(tab: "a8b6db94", did: "press", said: "Pressed Tab 3 times. Focus: @e14 button \"Apply code\"",
                                  settled: .skipped, page: teas)
        #expect(skipped.lines() == ["Pressed Tab 3 times. Focus: @e14 button \"Apply code\" in a8b6db94"])
    }

    @Test func pageWordsCannotBreakALine() {
        let change = AgentChange(tab: "a8b6db94", did: "click", page: teas,
                                 appeared: [.init(ref: "e5", role: "status", name: "one\ntwo")])
        #expect(change.lines().contains("+ @e5 status \"one two\""))
    }

    @Test func theTextComesBackFromTheObjectAlone() throws {
        var change = basket
        change.settled = .capped
        change.busy = .init(requests: 1)
        change.ms = 5000
        change.same = ["2c4d6e8f"]
        change.went = [.init(ref: "e40", role: "dialog", name: "Cookies")]
        change.dialog = .init(id: "d1", kind: "prompt", message: "Your name?", site: "shop.example")
        change.download = .init(name: "list.pdf", state: "done", path: "/tmp/list.pdf")
        change.tabs = .init(opened: [.init(id: "2c4d6e8f", title: "Gift", url: "https://shop.example/gift")], closed: ["11112222"],
                            working: "a8b6db94", count: 3, blocked: ["blocked.example"])
        change.more = 2
        let wire = try JSONSerialization.data(withJSONObject: change.object())
        let back = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let rebuilt = try #require(AgentChange(object: back))
        #expect(rebuilt.lines() == change.lines())
        #expect(NSDictionary(dictionary: rebuilt.object()) == NSDictionary(dictionary: change.object()))
    }

    @Test func aFailureCarriesItsCodeHintAndData() {
        let outcome = ToolOutcome.failure("\"Add to basket\" fits 30 elements", code: .ambiguous, hint: "Pick one", data: ["candidates": [["ref": "e10"]]])
        let reply = ToolReply.wire(outcome, tool: "click", tab: "a8b6db94")
        let error = reply["error"] as? [String: Any]
        #expect(reply["ok"] as? Bool == false)
        #expect(error?["code"] as? String == "ambiguous")
        #expect(error?["hint"] as? String == "Pick one")
        #expect(error?["retry_safe"] as? Bool == true)
        #expect(((reply["data"] as? [String: Any])?["candidates"] as? [[String: Any]])?.first?["ref"] as? String == "e10")
    }

    @Test func aCodeSetAtTheSourceWinsOverTheWords() {
        let outcome = ToolOutcome.failure("That element is from an older snapshot", code: "ref_changed")
        let error = ToolReply.wire(outcome, tool: "click", tab: nil)["error"] as? [String: Any]
        #expect(error?["code"] as? String == "ref_changed")
        #expect(error?["hint"] as? String == ToolCode.refChanged.hint)
        let landed = ToolReply.wire(.failure("Something odd", code: .failed), tool: "click", tab: nil)["error"] as? [String: Any]
        #expect(landed?["retry_safe"] as? Bool == false)
        let forced = ToolReply.wire(.failure("Something odd", code: "failed", retrySafe: true), tool: "click", tab: nil)["error"] as? [String: Any]
        #expect(forced?["retry_safe"] as? Bool == true)
    }

    @Test func anOldFailureStillGetsItsCodeFromTheWordsAndAHint() {
        let reply = ToolReply.wire(.failure("No such tab. Call tabs for the list."), tool: "click", tab: nil)
        let error = reply["error"] as? [String: Any]
        #expect(error?["code"] as? String == "no_tab")
        #expect(error?["hint"] as? String == ToolCode.noTab.hint)
        #expect(reply["data"] == nil)
        let unknown = ToolFailure.error("made_up", "Odd")
        #expect((unknown["error"] as? [String: Any])?["hint"] == nil)
    }

    @Test func everyCodeHasAPlainHintAndAnExit() {
        for code in ToolCode.allCases {
            #expect(!code.hint.isEmpty, "\(code.rawValue)")
            #expect(!code.hint.contains(";"), "\(code.rawValue)")
            #expect([1, 2, 3, 4].contains(code.exit), "\(code.rawValue)")
        }
        #expect(ToolCode.needsYou.exit == 3)
        #expect(ToolCode.usage.exit == 2)
    }
}
