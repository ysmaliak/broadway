import Foundation
import Testing
@testable import BroadwayCLI

struct ScriptRunTests {
    final class Fake {
        var sent: [(String, [String])] = []
        var answer: (String, [String], Int) -> [String: Any]

        init(_ answer: @escaping (String, [String], Int) -> [String: Any] = { _, _, _ in ["ok": true, "data": ["page": ["title": "Shop"]]] }) {
            self.answer = answer
        }

        func send(_ name: String, _ words: [String]) -> [String: Any] {
            sent.append((name, words))
            return answer(name, words, sent.count)
        }
    }

    static func failed(_ code: String, _ message: String = "That didn't work") -> [String: Any] {
        ["ok": false, "error": ["code": code, "message": message, "retry_safe": true]]
    }

    @Test func aScriptCannotGiveAPassword() {
        for code in [#"logins_give("example.com")"#, #"give("example.com")"#] {
            let fake = Fake()
            let outcome = ScriptRun.run(code: "try { " + code + " } catch (e) { print(e.code) }\nprint(\"after\")", send: fake.send)

            #expect(fake.sent.isEmpty, "\(code)")
            #expect(outcome.error?["code"] as? String == "person_only", "\(code): \(String(describing: outcome.error))")
            #expect(!outcome.printed.contains("after"), "\(code)")
        }
    }

    @Test func aScriptLoopsAndBranchesOnAnswers() {
        let fake = Fake { name, _, n in
            if name == "find" { return ["ok": true, "data": ["count": n >= 5 ? 1 : 0, "elements": n >= 5 ? [["ref": "e42", "name": "Moss Oolong"]] : []]] }
            return ["ok": true, "data": ["page": ["title": "Teas"]]]
        }

        let outcome = ScriptRun.run(code: """
        go("https://shop.example/teas")
        for (let page = 1; page <= 5; page++) {
          const hit = find("Moss Oolong", {role: "link"})
          if (hit.count) { click(hit.elements[0].ref); break }
          click("Next")
        }
        print("done after", 1)
        """, send: fake.send)

        #expect(outcome.error == nil)
        #expect(fake.sent.map { $0.0 } == ["go", "find", "click", "find", "click", "find", "click"])
        #expect(fake.sent[1].1 == ["Moss Oolong", "--role", "link"])
        #expect(fake.sent.last?.1 == ["@e42"])
        #expect(outcome.steps == 7)
        #expect(outcome.landed == Array(1...7))
        #expect(outcome.printed == "done after 1\n")
        #expect(ScriptRun.text(outcome) == ["done after 1", "(7 steps)"])
    }

    @Test func argumentsBecomeTheCommandsWords() {
        #expect(ScriptRun.words("click", ["e12"]) == ["@e12"])
        #expect(ScriptRun.words("click", ["f1.e3"]) == ["@f1.e3"])
        #expect(ScriptRun.words("click", ["Add to basket", ["nth": 2, "expectGone": "Loading"]]) == ["Add to basket", "--expect-gone", "Loading", "--nth", "2"])
        #expect(ScriptRun.words("scroll", [20]) == ["20"])
        #expect(ScriptRun.words("wait", [["gone": "Loading", "seconds": 2.5, "idle": false, "download": true]]) == ["--download", "--gone", "Loading", "--seconds", "2.5"])
        #expect(ScriptRun.words("fill", [["Email": "sam@example.com"]]) == [#"{"Email":"sam@example.com"}"#])
        #expect(ScriptRun.words("click", ["Save", ["in": "e7"]]) == ["Save", "--in", "@e7"])
        #expect(ScriptRun.words("type", ["e4", "e5"]) == ["@e4", "@e5"])
    }

    @Test func anOrdinaryFailureThrowsAndCanBeCaught() {
        let fake = Fake { _, words, _ in words == ["Gone"] ? Self.failed("not_found", "Nothing called Gone") : ["ok": true, "data": [:]] }

        let outcome = ScriptRun.run(code: """
        try { click("Gone") } catch (e) { print(e.code, e.retrySafe, e.step) }
        click("Here")
        """, send: fake.send)

        #expect(outcome.error == nil)
        #expect(outcome.printed == "not_found true 1\n")
        #expect(outcome.landed == [2])
    }

    @Test func thePersonsNoEndsTheScriptWhateverItCatches() {
        for code in ["needs_you", "said_no", "never_here", "driving", "person_only", "secret_field", "refused"] {
            let fake = Fake { _, words, _ in words == ["Pay"] ? Self.failed(code) : ["ok": true, "data": [:]] }

            let outcome = ScriptRun.run(code: """
            click("Basket")
            try { click("Pay") } catch (e) { print("caught") }
            try { click("Pay another way") } catch (e) {}
            print("still going")
            """, send: fake.send)

            #expect(fake.sent.map { $0.1 } == [["Basket"], ["Pay"]], "\(code)")
            #expect(outcome.error?["code"] as? String == code)
            #expect(outcome.printed == "")
            #expect(outcome.landed == [1])
            #expect(ScriptRun.text(outcome) == ["Error at step 2: \(code), That didn't work", "Landed 1"])
        }
    }

    @Test func aScriptRunsTwoHundredStepsAtMost() {
        let fake = Fake()

        let outcome = ScriptRun.run(code: "for (;;) { try { press(\"Tab\") } catch (e) {} }", send: fake.send)

        #expect(fake.sent.count == ScriptRun.most)
        #expect(outcome.error?["code"] as? String == "too_many")
        #expect(outcome.error?["step"] as? Int == 201)
    }

    @Test func aRefFromBeforeANewPageIsRefusedAndAFreshOneIsNot() {
        let fake = Fake { name, _, _ in
            switch name {
            case "go": return ["ok": true, "data": ["page": ["title": "Checkout", "navigated": true], "look": ["elements": [["ref": "e40", "name": "Pay"]]]]]
            default: return ["ok": true, "data": [:]]
            }
        }

        let fresh = ScriptRun.run(code: "click(\"e3\")\ngo(\"https://shop.example/checkout\")\nclick(\"e40\")", send: fake.send)
        let stale = ScriptRun.run(code: "go(\"https://shop.example/checkout\")\ntry { click(\"e3\") } catch (e) {}\nprint(\"no\")", send: fake.send)

        #expect(fresh.error == nil)
        #expect(stale.error?["code"] as? String == "moved")
        #expect(stale.error?["message"] as? String == "Step 2 didn't run because it names @e3 from before step 1 went to a new page")
        #expect(stale.printed == "")
        #expect(stale.landed == [1])
    }

    @Test func aDialogMustBeAnsweredNext() {
        let fake = Fake { name, _, _ in
            name == "click" ? ["ok": true, "data": ["dialog": ["kind": "confirm", "message": "Sure?"]]] : ["ok": true, "data": [:]]
        }

        let answered = ScriptRun.run(code: "click(\"Delete\")\ndialog(\"accept\")\nread()", send: fake.send)
        let ignored = ScriptRun.run(code: "click(\"Delete\")\nread()", send: fake.send)

        #expect(answered.error == nil)
        #expect(ignored.error?["code"] as? String == "moved")
    }

    @Test func anUnmetExpectationEndsTheScript() {
        let fake = Fake { _, _, _ in ["ok": true, "data": ["expect": ["kind": "text", "want": "1 item", "met": false, "after": 5.0]]] }

        let outcome = ScriptRun.run(code: "try { click(\"Add\", {expect: \"1 item\"}) } catch (e) {}\nclick(\"Checkout\")", send: fake.send)

        #expect(fake.sent.count == 1)
        #expect(outcome.error?["code"] as? String == "unmet")
        #expect(outcome.error?["retry_safe"] as? Bool == false)
        #expect(outcome.landed == [1])
    }

    @Test func aScriptThatNeverEndsIsStoppedAtItsTimeout() {
        let started = Date()

        let outcome = ScriptRun.run(code: "while (true) {}", timeout: 0.5, send: Fake().send)

        #expect(outcome.error?["code"] as? String == "deadline")
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func mistakesInTheScriptSayWhatWentWrong() {
        let syntax = ScriptRun.run(code: "click(", send: Fake().send)
        let unknown = ScriptRun.run(code: "eval_page(\"x\")", send: Fake().send)
        let pending = ScriptRun.run(code: "(async () => 1)()", send: Fake().send)

        #expect(syntax.error?["code"] as? String == "usage")
        #expect(unknown.error?["code"] as? String == "usage")
        #expect((unknown.error?["hint"] as? String)?.contains("click, close") == true)
        #expect(pending.error?["code"] as? String == "usage")
    }

    @Test func printedOutputIsCapped() {
        let outcome = ScriptRun.run(code: "for (let i = 0; i < 1000; i++) print(\"row \" + i)", outputLimit: 256, send: Fake().send)

        #expect(outcome.cut)
        #expect(outcome.printed.count == 256)
        #expect(ScriptRun.text(outcome).suffix(2) == ["… the rest of the output was cut", "(0 steps)"])
    }

    @Test func theScriptComesFromWordsAFileOrStdin() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("script-\(UUID().uuidString).js")
        try "read()".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(try ScriptRun.asked(["print(1)"]) { "" }.code == "print(1)")
        #expect(try ScriptRun.asked(["-"]) { "go(\"x\")\n" }.code == "go(\"x\")")
        #expect(try ScriptRun.asked([]) { "read()" }.code == "read()")
        #expect(try ScriptRun.asked([file.path]) { "" }.code == "read()")
        #expect(try ScriptRun.asked(["--output-limit", "300", "read()"]) { "" }.outputLimit == 300)
        #expect((try? ScriptRun.asked(["--output-limit", "10", "read()"]) { "" }) == nil)
        #expect((try? ScriptRun.asked([]) { "  " }) == nil)
    }
}
