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
        let tooMany = failure(click, ["@e1", "@e2"])
        let unknown = failure(click, ["--finnal", "send"])
        let choice = failure(click, ["@e1", "--final", "buy"])
        let number = failure(scroll, ["--by", "lots"])

        #expect(missing?.message == "click needs TARGET: broadway click TARGET")
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

    private var shot: Command {
        command("shot", positional: [], flags: [parameter("ref"), parameter("full", type: "boolean")]).withTool("screenshot")
    }

    private var drag: Command {
        let ref = parameter("ref", required: true)
        let to = parameter("to", required: true)
        return command("drag", positional: [ref, to], flags: [ref, to])
    }

    @Test func wordsAreATargetAndARefStaysARef() throws {
        let words = try CommandLineInput.parse(click, ["Add to basket"])
        let ref = try CommandLineInput.parse(click, ["@e12"])

        #expect(words["target"] as? [String: String] == ["words": "Add to basket"])
        #expect(words["ref"] == nil)
        #expect(ref["ref"] as? String == "e12")
        #expect(ref["target"] as? [String: String] == ["ref": "e12"])
    }

    @Test func nthAndInNarrowWords() throws {
        let found = try CommandLineInput.parse(click, ["Add to basket", "--nth", "2", "--in=@e30"])

        let target = try #require(found["target"] as? [String: Any])
        #expect(target["words"] as? String == "Add to basket")
        #expect(target["nth"] as? Int == 2)
        #expect(target["in"] as? String == "e30")
        #expect(failure(click, ["Save", "--nth", "0"])?.code == "usage")
        #expect(failure(click, ["Save", "--in", "main"])?.code == "usage")
        #expect(failure(click, ["--nth", "2"])?.code == "usage")
    }

    @Test func roleAndNameNeedNoWords() throws {
        let found = try CommandLineInput.parse(click, ["--role", "button", "--name", "Search", "--final", "send"])

        #expect(found["target"] as? [String: String] == ["role": "button", "name": "Search"])
        #expect(found["final"] as? String == "send")
    }

    @Test func aLabelPicksTheFieldAndTheTextStillFollows() throws {
        let labelled = try CommandLineInput.parse(type, ["--label", "Email", "sam@example.com", "--submit"])
        let worded = try CommandLineInput.parse(type, ["Email", "sam@example.com"])

        #expect(labelled["target"] as? [String: String] == ["label": "Email"])
        #expect(labelled["text"] as? String == "sam@example.com")
        #expect(labelled["submit"] as? Bool == true)
        #expect(worded["target"] as? [String: String] == ["words": "Email"])
        #expect(worded["text"] as? String == "sam@example.com")
    }

    @Test func aFrameRefTakesEitherSpelling() throws {
        #expect(CommandLineInput.ref("@f1e3") == "f1.e3")
        #expect(CommandLineInput.ref("@f1.e3") == "f1.e3")
        #expect(CommandLineInput.ref("f12e345") == "f12.e345")
        #expect(CommandLineInput.ref("@fe3") == nil)
        #expect(try CommandLineInput.parse(click, ["@f2e7"])["ref"] as? String == "f2.e7")
    }

    @Test func theOldRefFlagAndShotInBothNameAnElement() throws {
        let old = try CommandLineInput.parse(shot, ["--ref", "@e7"])
        let new = try CommandLineInput.parse(shot, ["--in", "@e7"])
        let words = try CommandLineInput.parse(shot, ["Price list"])

        #expect(old["ref"] as? String == "e7")
        #expect(new["ref"] as? String == "e7")
        #expect(new["target"] as? [String: String] == ["ref": "e7"])
        #expect(words["target"] as? [String: String] == ["words": "Price list"])
    }

    @Test func aPointOfTheLastShotIsATarget() throws {
        let found = try CommandLineInput.parse(click, ["--at", "412,230"])

        let point = try #require((found["target"] as? [String: Any])?["at"] as? [String: Double])
        #expect(point == ["x": 412, "y": 230])
        #expect(failure(click, ["--at", "412"])?.code == "usage")
    }

    @Test func dragDropsOnARefAfterWords() throws {
        let found = try CommandLineInput.parse(drag, ["Card A", "@e9"])

        #expect(found["target"] as? [String: String] == ["words": "Card A"])
        #expect(found["to"] as? String == "@e9")
    }

    @Test func scrollKeepsPointsAndItsOwnIn() throws {
        #expect(try CommandLineInput.parse(scroll, ["600"])["by"] as? Double == 600)
        #expect(try CommandLineInput.parse(scroll, ["@e12"])["ref"] as? String == "e12")
        #expect(failure(scroll, ["--in", "@e40"])?.message == "scroll has no option --in")
    }

    @Test func aCommandWithoutRefsKeepsItsOwnRoleFlag() throws {
        let find = command("find", positional: [parameter("text")], flags: [parameter("text"), parameter("role"), parameter("limit", type: "number")])

        let found = try CommandLineInput.parse(find, ["basket", "--role", "button"])

        #expect(found["text"] as? String == "basket")
        #expect(found["role"] as? String == "button")
        #expect(found["target"] == nil)
    }

    @Test func locateAndFindReachEachOther() {
        let old = Catalog([["name": "locate", "tool": "locate"]])
        let new = Catalog([["name": "find", "tool": "locate", "aliases": ["locate"]]])

        #expect(old.find("find")?.tool == "locate")
        #expect(new.find("locate")?.tool == "locate")
        #expect(new.find("find")?.tool == "locate")
    }

    @Test func answerFlagsComeOffBeforeTheApp() throws {
        let asked = try Browse.arguments(click, ["Save", "--quiet-answer", "--no-look"], tab: "a8b6db94", tabFlag: true)

        #expect(asked.short)
        #expect(!asked.look)
        #expect(asked.arguments["tab"] as? String == "a8b6db94")
        #expect(asked.arguments["target"] as? [String: String] == ["words": "Save"])
    }

    @Test func severalAddressesNeedAnAppThatTakesThem() throws {
        let url = parameter("url", required: true)
        let one = command("open", positional: [url], flags: [url], tabbed: false)
        let many = command("open", positional: [url], flags: [url, parameter("urls", type: "array")], tabbed: false)

        let sent = try Browse.arguments(many, ["https://a.example", "https://b.example"], tab: nil, tabFlag: false)

        #expect(sent.arguments["urls"] as? [String] == ["https://a.example", "https://b.example"])
        #expect(sent.arguments["url"] as? String == "https://a.example")
        #expect((try? Browse.arguments(one, ["https://a.example", "https://b.example"], tab: nil, tabFlag: false)) == nil)
        #expect(try Browse.arguments(one, ["https://a.example"], tab: nil, tabFlag: false).arguments["url"] as? String == "https://a.example")
    }

    @Test func anActionCarriesOneExpectation() throws {
        let text = try Browse.arguments(click, ["Apply", "--expect", "Code applied"], tab: nil, tabFlag: false)
        let gone = try Browse.arguments(click, ["Apply", "--expect-gone=Loading"], tab: nil, tabFlag: false)
        let url = try Browse.arguments(click, ["Next", "--expect-url", "/checkout"], tab: nil, tabFlag: false)
        let reads = Command(["name": "snapshot", "tool": "snapshot", "tabbed": true, "reads": true])

        #expect(text.arguments["expect"] as? [String: String] == ["kind": "text", "want": "Code applied"])
        #expect(gone.arguments["expect"] as? [String: String] == ["kind": "gone", "want": "Loading"])
        #expect(url.arguments["expect"] as? [String: String] == ["kind": "url", "want": "/checkout"])
        #expect((try? Browse.arguments(click, ["Apply", "--expect", "a", "--expect-gone", "b"], tab: nil, tabFlag: false)) == nil)
        #expect((try? Browse.arguments(reads, ["--expect", "a"], tab: nil, tabFlag: false)) == nil)
        #expect((try? Browse.arguments(click, ["Apply", "--expect"], tab: nil, tabFlag: false)) == nil)
    }

    @Test func theTabInTheEnvironmentIsTheDefaultAndAFlagWins() throws {
        let (fromEnvironment, _) = try Globals.extract(["click", "Save"], environment: ["BROADWAY_TAB": "2c4d6e8f"])
        let (flagged, _) = try Globals.extract(["click", "Save", "--tab", "a8b6db94"], environment: ["BROADWAY_TAB": "2c4d6e8f"])

        #expect(fromEnvironment.tab == "2c4d6e8f")
        #expect(!fromEnvironment.tabFlag)
        #expect(flagged.tab == "a8b6db94")
        #expect(try Browse.arguments(click, ["Save"], tab: fromEnvironment.tab, tabFlag: false).arguments["tab"] as? String == "2c4d6e8f")
    }

    @Test func usageShowsWhichFlagsTakeAValue() {
        let command = Command(["name": "wait", "tool": "wait", "tabbed": true,
                               "positional": [["name": "text", "type": "string"]],
                               "flags": [["name": "text", "type": "string"], ["name": "seconds", "type": "number"], ["name": "download", "type": "boolean"],
                                         ["name": "state", "type": "string", "choices": ["visible", "gone"]]]])

        #expect(command.usage == "broadway wait [text] [--seconds N] [--download] [--state visible|gone] [--tab ID]")
    }

    @Test func handoffTakesItsReasonAsWords() throws {
        let command = Command(["name": "handoff", "tool": "handoff", "tabbed": true,
                               "positional": [["name": "reason", "type": "string", "required": true]],
                               "flags": [["name": "reason", "type": "string"], ["name": "seconds", "type": "number"], ["name": "optional", "type": "boolean"]]])

        let asked = try Browse.arguments(command, ["Solve the captcha", "--seconds", "600", "--optional"], tab: "a8b6db94", tabFlag: true)

        #expect(asked.arguments["reason"] as? String == "Solve the captcha")
        #expect(asked.arguments["seconds"] as? Double == 600)
        #expect(asked.arguments["optional"] as? Bool == true)
        #expect(asked.arguments["tab"] as? String == "a8b6db94")
    }

    @Test func everyCallNamesTheCommandsVersion() throws {
        let (globals, _) = try Globals.extract(["read"], environment: [:])
        let place = Place(socket: "/nonexistent/broadway.sock", wakes: false, world: nil, bundle: nil, named: false)
        let context = Context(globals: globals, console: Console(json: true, quiet: true, noColor: true, environment: [:]), place: place, environment: [:], binary: "/nonexistent/broadway")

        let request = context.call("text", ["tab": "a8b6db94"])

        #expect(request["op"] as? String == "call")
        #expect(request["tool"] as? String == "text")
        #expect(request["cli"] as? String == "dev")
        #expect(request["agent"] != nil)
    }

    @Test func unlistedFlagsStayOutOfUsageHelpAndCompletionsButStillParse() throws {
        let command = Command(["name": "click", "tool": "click", "tabbed": true,
                               "positional": [["name": "ref", "type": "string"]],
                               "flags": [["name": "ref", "type": "string"], ["name": "final", "type": "string", "choices": ["send", "pay"]],
                                         ["name": "settle", "type": "number", "unlisted": true], ["name": "expect_gone", "type": "string", "unlisted": true],
                                         ["name": "role", "type": "string", "unlisted": true]]])

        let page = Help.page(command, style: Style(color: false))

        #expect(command.usage == "broadway click WORDS|@ref [--role ROLE] [--name NAME] [--final send|pay] [--tab ID]")
        #expect(!page.contains("--settle") && !page.contains("--expect_gone"))
        #expect(page.contains("--role ROLE") && page.contains("--expect TEXT"))
        #expect(try CommandLineInput.parse(command, ["@e3", "--settle", "0"])["settle"] as? Double == 0)
    }

    @Test func aClickNeedsSomethingToClick() {
        let command = Command(["name": "click", "tool": "click", "tabbed": true,
                               "positional": [["name": "ref", "type": "string"]], "flags": [["name": "ref", "type": "string"]]])

        #expect((try? CommandLineInput.parse(command, [])) == nil)
        #expect((try? CommandLineInput.parse(command, ["--role", "button", "--name", "Save"])) != nil)
        #expect((try? CommandLineInput.parse(command, ["Save"])) != nil)
    }

    @Test func aMissingValueSaysTheWholeForm() {
        let ref = parameter("ref")
        let value = parameter("value", required: true)
        let choose = command("choose", positional: [ref, value], flags: [ref, value])
        let url = parameter("url", required: true)
        let go = command("go", positional: [url], flags: [url])

        #expect(failure(choose, ["Colour"])?.message == "choose needs VALUE: broadway choose TARGET VALUE")
        #expect(failure(type, ["@e4"])?.message == "type needs TEXT: broadway type TARGET TEXT")
        #expect(failure(go, [])?.message == "go needs URL: broadway go URL")
        #expect(failure(choose, ["Colour"])?.hint?.hasPrefix("Usage: broadway choose") == true)
    }

    @Test func wordsAndARoleAimTogether() throws {
        let ref = parameter("ref")
        let value = parameter("value", required: true)
        let choose = command("choose", positional: [ref, value], flags: [ref, value])
        let button = try CommandLineInput.parse(click, ["Sign in", "--role", "button"])["target"] as? [String: Any]
        let named = try CommandLineInput.parse(click, ["Send", "--role", "button", "--name", "Send"])["target"] as? [String: Any]
        let typed = try CommandLineInput.parse(type, ["Email", "sam@example.com", "--role", "textbox"])
        let labelled = try CommandLineInput.parse(type, ["--label", "Email", "sam@example.com"])
        let chosen = try CommandLineInput.parse(choose, ["Assignee", "Sam Lee", "--role", "combobox"])
        let byRole = try CommandLineInput.parse(choose, ["Sam Lee", "--role", "combobox"])

        #expect(button?["words"] as? String == "Sign in" && button?["role"] as? String == "button")
        #expect(named?["words"] as? String == "Send" && named?["name"] as? String == "Send")
        #expect((typed["target"] as? [String: Any])?["words"] as? String == "Email" && typed["text"] as? String == "sam@example.com")
        #expect((labelled["target"] as? [String: Any])?["words"] == nil && labelled["text"] as? String == "sam@example.com")
        #expect((chosen["target"] as? [String: Any])?["words"] as? String == "Assignee" && chosen["value"] as? String == "Sam Lee")
        #expect((byRole["target"] as? [String: Any])?["words"] == nil && byRole["value"] as? String == "Sam Lee")
        #expect(failure(click, ["Sign in", "Now", "--role", "button"])?.message == "click doesn't take Now")
    }

    @Test func aUsageLineShowsTheTargetForms() {
        let ref = parameter("ref")
        let value = parameter("value", required: true)
        let choose = command("choose", positional: [ref, value], flags: [ref, value, parameter("role"), parameter("nth", type: "number")])
        let shot = command("screenshot", positional: [ref], flags: [ref, parameter("full", type: "boolean")])

        #expect(click.usage == "broadway click WORDS|@ref [--role ROLE] [--name NAME] [--final send|pay] [--tab ID]")
        #expect(choose.usage == "broadway choose WORDS|@ref <value> [--role ROLE] [--name NAME] [--tab ID]")
        #expect(shot.usage == "broadway screenshot [WORDS|@ref] [--role ROLE] [--name NAME] [--full] [--tab ID]")
    }

    @Test func readFindsLinesEvenBeforeTheAppDoes() throws {
        let old = Command(["name": "read", "tool": "text", "tabbed": true, "reads": true])
        let new = Command(["name": "read", "tool": "text", "tabbed": true, "reads": true, "flags": [["name": "find", "type": "string", "description": "Lines holding the words"]]])

        #expect(try CommandLineInput.parse(old, ["--find", "price"])["find"] as? String == "price")
        #expect(old.findsHere && !new.findsHere)
        #expect(try CommandLineInput.parse(new, ["--find", "price"])["find"] as? String == "price")
        #expect(old.usage.contains("[--find FIND]"))
        #expect(Browse.holding("Total\nPrice: 4 EUR\nShipping price free\nThanks", "price") == "Price: 4 EUR\nShipping price free")
        #expect(Browse.holding("Price: 4 EUR\nold price", "4 price") == "Price: 4 EUR")
    }

    @Test func theWebsiteNoteIsSaidOnce() {
        let console = Console(json: false, quiet: true, noColor: true, environment: [:])

        #expect(!console.warnedWebsite)
        console.website()
        console.website()
        #expect(console.warnedWebsite)
    }

    @Test func agentsDoneSaysItsLineAndNoRow() {
        #expect(Person.spoken.contains("agents done"))
        #expect(Person.spoken.contains("agents disconnect"))
        #expect(!Person.spoken.contains("agents list"))
    }

    @Test func aRefWithoutItsAtIsStillARef() throws {
        let ref = parameter("ref")
        let value = parameter("value", required: true)
        let choose = command("choose", positional: [ref, value], flags: [ref, value])
        let clicked = try CommandLineInput.parse(click, ["e2"])
        let typed = try CommandLineInput.parse(type, ["e2", "hello agent"])
        let chosen = try CommandLineInput.parse(choose, ["e4", "blue"])
        let framed = try CommandLineInput.parse(click, ["f1e3"])
        let dotted = try CommandLineInput.parse(click, ["f1.e3"])
        let inside = try CommandLineInput.parse(click, ["Save", "--in", "e30"])
        let named = try CommandLineInput.parse(click, ["--role", "button", "--name", "e2"])
        let worded = try CommandLineInput.parse(click, ["e2x"])

        #expect(clicked["ref"] as? String == "e2" && (clicked["target"] as? [String: Any])?["words"] == nil)
        #expect(typed["ref"] as? String == "e2" && typed["text"] as? String == "hello agent")
        #expect(chosen["ref"] as? String == "e4" && chosen["value"] as? String == "blue")
        #expect(framed["ref"] as? String == "f1.e3" && dotted["ref"] as? String == "f1.e3")
        #expect((inside["target"] as? [String: Any])?["in"] as? String == "e30" && (inside["target"] as? [String: Any])?["words"] as? String == "Save")
        #expect((named["target"] as? [String: Any])?["name"] as? String == "e2" && named["ref"] == nil)
        #expect(worded["ref"] == nil && (worded["target"] as? [String: Any])?["words"] as? String == "e2x")
        #expect(try CommandLineInput.parse(type, ["@e1", "e2"])["text"] as? String == "e2")
    }

    @Test func aHiddenLookAsksTheAppForNone() throws {
        let reads = Command(["name": "snapshot", "tool": "snapshot", "tabbed": true, "reads": true])

        #expect(try Browse.arguments(click, ["Save", "--no-look"], tab: nil, tabFlag: false).arguments["look"] as? Bool == false)
        #expect(try Browse.arguments(click, ["Save", "--quiet-answer"], tab: nil, tabFlag: false).arguments["look"] as? Bool == false)
        #expect(try Browse.arguments(click, ["Save"], tab: nil, tabFlag: false).arguments["look"] == nil)
        #expect(try Browse.arguments(reads, ["--no-look"], tab: nil, tabFlag: false).arguments["look"] == nil)
    }

    @Test func aBareTabsAsksForTheSessionsOwn() {
        #expect(Person.bare(["tabs"]))
        #expect(Person.bare(["tabs", "--all"]))
        #expect(!Person.bare(["tabs", "list"]))
        #expect(!Person.bare(["tabs", "close", "a8b6db94"]))
    }
}

extension Command {
    func withTool(_ tool: String) -> Command {
        var found = self
        found.tool = tool
        return found
    }
}
