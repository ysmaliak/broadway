import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(5)))
struct BatchTests {
    private let catalog: Catalog = {
        let ref: [String: Any] = ["name": "ref", "type": "string", "required": true]
        let url: [String: Any] = ["name": "url", "type": "string", "required": true]
        let text: [String: Any] = ["name": "text", "type": "string"]
        return Catalog([
            ["name": "click", "tool": "click", "tabbed": true, "positional": [ref], "flags": [ref]],
            ["name": "go", "tool": "navigate", "aliases": ["navigate"], "tabbed": true, "positional": [url], "flags": [url]],
            ["name": "wait", "tool": "wait", "tabbed": true, "positional": [text], "flags": [text]],
            ["name": "history", "tool": "history", "positional": [text], "flags": [text]],
        ])
    }()

    private func failure(_ body: () throws -> Any) -> Failure? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? Failure
        }
    }

    @Test func aBatchLineCannotGiveAPassword() {
        let line = Batch.Line(n: 1, text: "logins give example.com --password-only", words: ["logins", "give", "example.com", "--password-only"])
        let refused = failure { try Batch.step(line, catalog: catalog) }

        #expect(refused?.code == "person_only")
        #expect(refused?.message.contains("never as a step") == true, "\(String(describing: refused?.message))")
    }

    @Test func stepsSplitLikeAShell() throws {
        #expect(try Batch.words(#"click "Add to basket" --nth 1"#) == ["click", "Add to basket", "--nth", "1"])
        #expect(try Batch.words(#"type 'It'\''s' x"#) == ["type", "It's", "x"])
        #expect(try Batch.words(#"wait "say \"hi\"""#) == ["wait", #"say "hi""#])
        #expect(try Batch.words(#"type Email """#) == ["type", "Email", ""])
        #expect(failure { try Batch.words(#"click "open"#) }?.code == "usage")
    }

    @Test func blankLinesAndCommentsAreSkippedAndBroadwayIsDropped() throws {
        let lines = try Batch.lines(["", "# a note", "broadway go https://shop.example/teas", "  click Save  "])

        #expect(lines.map(\.n) == [1, 2])
        #expect(lines[0].words == ["go", "https://shop.example/teas"])
        #expect(lines[1].text == "click Save")
    }

    @Test func twentyFiveStepsAtMost() {
        let many = Array(repeating: "click Save", count: Batch.most + 1)

        #expect(failure { try Batch.lines(many) }?.message == "batch takes 25 steps at most, not 26")
        #expect(failure { try Batch.lines(["", "#"]) }?.code == "usage")
    }

    @Test func aBatchStepTakesARefWithoutItsAt() throws {
        let step = try Batch.step(Batch.Line(n: 1, text: "click e2", words: ["click", "e2"]), catalog: catalog)

        #expect((step["arguments"] as? [String: Any])?["ref"] as? String == "e2")
        #expect(ScriptRun.words("click", ["e2"]) == ["@e2"])
    }

    @Test func aStepIsParsedAsTheSameCommandAlone() throws {
        let step = try Batch.step(Batch.Line(n: 2, text: "click \"Add to basket\" --nth 1 --tab 2c4d", words: ["click", "Add to basket", "--nth", "1", "--tab", "2c4d"]), catalog: catalog)
        let go = try Batch.step(Batch.Line(n: 1, text: "navigate https://shop.example", words: ["navigate", "https://shop.example"]), catalog: catalog)

        #expect(step["tool"] as? String == "click")
        #expect(step["n"] as? Int == 2)
        let arguments = try #require(step["arguments"] as? [String: Any])
        #expect(arguments["tab"] as? String == "2c4d")
        #expect((arguments["target"] as? [String: Any])?["nth"] as? Int == 1)
        #expect(go["tool"] as? String == "navigate")
    }

    @Test func nounsTasksAndOtherCommandsAreRefusedBeforeAnythingRuns() {
        for words in [["bookmarks", "delete", "x"], ["history", "x"], ["batch", "click x"], ["agents", "done"], ["mcp"], ["setup"], ["\"buy tea\""]] {
            let refused = failure { try Batch.step(Batch.Line(n: 3, text: words.joined(separator: " "), words: words), catalog: catalog) }
            #expect(refused?.code == "usage", "\(words) was not refused")
            #expect(refused?.data?["step"] as? Int == 3)
        }
        let unknown = failure { try Batch.step(Batch.Line(n: 1, text: "back", words: ["back"]), catalog: catalog) }
        #expect(unknown?.message == "Step 1: Broadway has no back command here")
        let json = failure { try Batch.step(Batch.Line(n: 1, text: "click Save --json", words: ["click", "Save", "--json"]), catalog: catalog) }
        #expect(json?.code == "usage")
    }

    @Test func optionsTakeFromAndKeepGoing() throws {
        let options = try Batch.options(["--from", "3", "--keep-going", "click Save"])

        #expect(options.from == 3)
        #expect(options.keepGoing)
        #expect(options.lines == ["click Save"])
        #expect(failure { try Batch.options(["--from", "0"]) }?.code == "usage")
        #expect(failure { try Batch.options(["--fast"]) }?.code == "usage")
    }

    @Test func theAnswerListsWhatLandedAndHowToGoOn() throws {
        let all = try Batch.lines(["go https://shop.example/teas", "click \"Add to basket\" --nth 1", "click \"Checkout\"", "wait \"Your details\""])
        let page: [String: Any] = ["url": "https://shop.example/teas", "title": "Lumen Tea Co.", "navigated": false]
        let clicked: [String: Any] = ["tab": "a8b6db94", "did": "click", "target": ["ref": "e10", "role": "button", "name": "Add to basket"], "page": page,
                                      "appeared": [["ref": "e61", "role": "status", "name": "Added Glenmoor Breakfast"]]]
        let data: [String: Any] = [
            "ran": 3, "of": 4, "landed": [1, 2], "page": page, "tab": "a8b6db94",
            "steps": [
                ["n": 1, "line": all[0].text, "ok": true, "data": ["tab": "a8b6db94", "did": "go", "page": ["url": "https://shop.example/teas", "title": "Lumen Tea Co.", "navigated": true]]],
                ["n": 2, "line": all[1].text, "ok": true, "data": clicked],
                ["n": 3, "line": all[2].text, "ok": false, "error": ["code": "needs_you", "message": "Your card in Broadway asks the person", "retry_safe": true]],
                ["n": 4, "line": all[3].text, "ran": false],
            ],
        ]
        let failure = Failure("needs_you", "Step 3 waits for the person's yes", exit: .needsYou)

        let text = Batch.text(data, all: all, from: 1, piped: true, failure: failure)

        #expect(text == [
            "1 ok    go shop.example/teas: Lumen Tea Co.",
            "2 ok    click button \"Add to basket\" @e10",
            "3 FAIL  click \"Checkout\": needs_you. Your card in Broadway asks the person",
            "4 --    wait \"Your details\"",
            "Landed 1–2. Nothing from 3 on was done. After the person answers: broadway batch --from 3 < steps",
            "Now: Lumen Tea Co.  shop.example/teas",
            "+ @e61 status \"Added Glenmoor Breakfast\"",
        ])
    }

    @Test func aRefusalStopsWithoutOfferingAnotherTry() throws {
        let all = try Batch.lines(["click Delete"])
        let data: [String: Any] = ["ran": 1, "of": 1, "landed": [], "steps": [["n": 1, "line": "click Delete", "ok": false, "error": ["code": "said_no", "message": "The person said not now"]]]]

        let text = Batch.text(data, all: all, from: 1, piped: false, failure: Failure("said_no", "Step 1 failed"))

        #expect(text.last == "Nothing was done")
    }

    @Test func aRunFromALaterStepShowsOnlyThoseSteps() throws {
        let all = try Batch.lines(["click One", "click Two", "click Three"])
        let data: [String: Any] = ["ran": 2, "of": 3, "landed": [2, 3], "steps": [["n": 2, "line": "click Two", "ok": true, "data": [:]], ["n": 3, "line": "click Three", "ok": true, "data": [:]]]]

        let text = Batch.text(data, all: all, from: 2, piped: true, failure: nil)

        #expect(text == ["2 ok    click Two", "3 ok    click Three"])
    }

    @Test func theStepsABatchTakesAreTheOnesItAlwaysTook() {
        #expect(Batch.allowed == ["open", "go", "back", "forward", "reload", "tab", "click", "type", "fill", "choose", "press", "scroll",
                                 "hover", "drag", "select", "upload", "download", "wait", "dialog", "find", "snapshot", "read", "shot", "close"])
    }
}
