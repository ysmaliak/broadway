import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(5)))
struct ParsingTests {
    private func parameter(_ name: String, type: String = "string", required: Bool = false, choices: [String]? = nil) -> [String: Any] {
        var found: [String: Any] = ["name": name, "type": type, "required": required]
        if let choices { found["choices"] = choices }
        return found
    }

    private func command(_ name: String, positional: [[String: Any]] = [], flags: [[String: Any]] = [], tabbed: Bool = true) -> Command {
        Command(["name": name, "tool": name, "tabbed": tabbed, "positional": positional, "flags": flags, "examples": ["broadway \(name)"]])
    }

    private var click: Command {
        let ref = parameter("ref", required: true)
        return command("click", positional: [ref], flags: [ref, parameter("final", choices: ["send", "pay"])])
    }

    private var type: Command {
        let ref = parameter("ref", required: true)
        let text = parameter("text", required: true)
        return command("type", positional: [ref, text], flags: [ref, parameter("submit", type: "boolean"), text])
    }

    private var scroll: Command {
        let by = parameter("by", type: "number")
        return command("scroll", positional: [by], flags: [by, parameter("ref")])
    }

    private func failure(_ command: Command, _ words: [String]) -> Failure? {
        do {
            _ = try CommandLineInput.parse(command, words)
            return nil
        } catch {
            return error as? Failure
        }
    }

    @Test func globalFlagsComeOutWhereverTheyAre() throws {
        let (globals, rest) = try Globals.extract(["click", "--json", "@e3", "--tab=abc", "-o", "file", "--world", "w"], environment: [:])

        #expect(globals.json)
        #expect(globals.tab == "abc")
        #expect(globals.tabFlag)
        #expect(globals.output == "file")
        #expect(globals.world == "w")
        #expect(rest == ["click", "@e3"])
    }

    @Test func aDoubleDashKeepsFlagsAsWords() throws {
        let (globals, rest) = try Globals.extract(["type", "@e1", "--", "--json"], environment: [:])

        #expect(!globals.json)
        #expect(rest == ["type", "@e1", "--", "--json"])
    }

    @Test func aMissingValueIsACommandMistake() {
        let error = #expect(throws: (any Error).self) { try Globals.extract(["read", "--tab"], environment: [:]) }
        #expect((error as? Failure)?.exit == .mistake)
    }

    @Test func theTabFromTheEnvironmentIsNotAFlag() throws {
        let (globals, _) = try Globals.extract(["history"], environment: ["BROADWAY_TAB": "abc"])

        #expect(globals.tab == "abc")
        #expect(!globals.tabFlag)
    }

    @Test func aRefLosesItsAt() throws {
        let found = try CommandLineInput.parse(click, ["@e12"])

        #expect((found["ref"] as? String) == "e12")
    }

    @Test func aRefCanNameAnEmbeddedFrame() throws {
        let framed = try CommandLineInput.parse(click, ["@f2.e12"])

        #expect((framed["ref"] as? String) == "f2.e12")
        #expect(throws: (any Error).self) { try CommandLineInput.parse(click, ["@f.e12"]) }
        #expect(throws: (any Error).self) { try CommandLineInput.parse(click, ["@f1.x2"]) }
        #expect(throws: (any Error).self) { try CommandLineInput.parse(click, ["@f1.f2.e3"]) }
        #expect(throws: (any Error).self) { try CommandLineInput.parse(click, ["@g1.e3"]) }
    }

    @Test func positionalsFillInTheOrderTheSpecRequires() throws {
        let found = try CommandLineInput.parse(type, ["@e4", "hello there", "--submit"])

        #expect((found["ref"] as? String) == "e4")
        #expect((found["text"] as? String) == "hello there")
        #expect((found["submit"] as? Bool) == true)
    }

    @Test func aFlagCanStandInForAPositional() throws {
        let found = try CommandLineInput.parse(type, ["--text", "hi", "@e4"])

        #expect((found["ref"] as? String) == "e4")
        #expect((found["text"] as? String) == "hi")
    }

    @Test func anAtWordFindsTheRefEvenWhenItIsNotPositional() throws {
        let down = try CommandLineInput.parse(scroll, ["-300"])
        let to = try CommandLineInput.parse(scroll, ["@e9"])

        #expect((down["by"] as? Double) == -300)
        #expect((to["ref"] as? String) == "e9")
    }

    @Test func textThatLooksLikeARefAfterTheRefIsText() throws {
        let found = try CommandLineInput.parse(type, ["@e4", "@handle"])

        #expect((found["text"] as? String) == "@handle")
    }

    @Test func afterADoubleDashADashIsText() throws {
        let found = try CommandLineInput.parse(type, ["@e4", "--", "--submit"])

        #expect((found["text"] as? String) == "--submit")
        #expect(found["submit"] == nil)
    }

    @Test func mistakesSayWhatToDo() {
        let missing = failure(click, [])
        let notRef = failure(click, ["button"])
        let tooMany = failure(click, ["@e1", "@e2"])
        let unknown = failure(click, ["--finnal", "send"])
        let choice = failure(click, ["@e1", "--final", "buy"])
        let number = failure(scroll, ["--by", "lots"])

        #expect(missing?.message == "click needs ref")
        #expect(notRef?.hint?.contains("broadway snapshot") == true)
        #expect(tooMany?.hint?.contains("Usage") == true)
        #expect(unknown?.hint == "Did you mean --final?")
        #expect(choice?.message == "--final is one of send, pay, not buy")
        #expect(number?.exit == .mistake)
    }

    @Test func aNewToolParsesWithNoCodeForIt() throws {
        let search = Command(["name": "memory-search", "tool": "memory_search", "positional": [parameter("query", required: true)],
                              "flags": [parameter("query", required: true), parameter("limit", type: "integer"), parameter("tags", type: "array")]])

        let found = try CommandLineInput.parse(search, ["lisbon", "--limit", "3", "--tags", "a, b"])

        #expect((found["query"] as? String) == "lisbon")
        #expect((found["limit"] as? Int) == 3)
        #expect((found["tags"] as? [String]) == ["a", "b"])
    }

    @Test func taskFlags() throws {
        let found = try TaskOptions.parse(["--cli", "codex", "do", "this", "-m", "gpt", "--effort", "high", "--no-person"])

        #expect(found.words == ["do", "this"])
        #expect((found.request["cli"] as? String) == "codex")
        #expect((found.request["model"] as? String) == "gpt")
        #expect((found.request["effort"] as? String) == "high")
        #expect((found.request["person"] as? String) == "none")
    }

    @Test func taskMistakes() {
        #expect(throws: (any Error).self) { try TaskOptions.parse(["x", "--cli", "gemini"]) }
        #expect(throws: (any Error).self) { try TaskOptions.parse(["x", "--effort", "huge"]) }
        #expect(throws: (any Error).self) { try TaskOptions.parse(["x", "--wait-person", "soon"]) }
        #expect(throws: (any Error).self) { try TaskOptions.parse(["x", "--no-person", "--wait-person", "1"]) }
        let error = #expect(throws: (any Error).self) { try TaskOptions.parse(["x", "--detatch"]) }
        #expect((error as? Failure)?.hint == "Did you mean --detach?")
    }

    @Test func didYouMean() {
        #expect(Near.best("clikc", in: ["click", "close", "tabs"]) == "click")
        #expect(Near.best("sesion", in: ["session", "serve"]) == "session")
        #expect(Near.best("snap", in: ["snapshot", "shot"]) == "snapshot")
        #expect(Near.best("zebra", in: ["click", "close", "tabs"]) == nil)
    }

    @Test func addresses() {
        #expect(Address.looksLike("https://example.com/a"))
        #expect(Address.looksLike("example.com"))
        #expect(!Address.looksLike("summarize this"))
        #expect(!Address.looksLike("click"))
    }
}
