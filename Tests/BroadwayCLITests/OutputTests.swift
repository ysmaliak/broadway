import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(5)))
struct OutputTests {
    private func parsed(_ line: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    @Test func theExitCodesAreTheDocumentedOnes() {
        #expect(Exit.done.rawValue == 0)
        #expect(Exit.failed.rawValue == 1)
        #expect(Exit.mistake.rawValue == 2)
        #expect(Exit.needsYou.rawValue == 3)
        #expect(Exit.stopped.rawValue == 130)
    }

    @Test func aNestedObjectReadsAsItsPairsInWords() {
        let player: [String: Any] = ["title": "A Quiet Song", "playing": true, "duration": 60]

        let line = Render.cell(player)

        #expect(line == "duration=60 playing=yes title=A Quiet Song")
    }

    @Test func aSuccessEnvelopeHasEveryKey() throws {
        let found = try parsed(Envelope.line(command: "tabs", data: ["tabs": []], failure: nil))

        #expect(Set(found.keys) == ["ok", "command", "data", "error"])
        #expect((found["ok"] as? Bool) == true)
        #expect(found["error"] is NSNull)
    }

    @Test func aFailureEnvelopeSaysTheFixAndWhetherARetryIsSafe() throws {
        let found = try parsed(Envelope.line(command: "click", data: nil, failure: Failure("stale_ref", "Gone.")))

        let error = try #require(found["error"] as? [String: Any])
        #expect((found["ok"] as? Bool) == false)
        #expect(found["data"] is NSNull)
        #expect(Set(error.keys) == ["code", "message", "hint", "retry_safe"])
        #expect((error["hint"] as? String) == "Run broadway snapshot and use the new ref")
        #expect((error["retry_safe"] as? Bool) == true)
    }

    @Test func aMenuAPageWouldOpenAndAnUnseenPageEachSayWhatToDoInstead() {
        #expect(Failure("opens_window", "That list opens a menu of its own.").hint?.contains("broadway choose") == true)
        #expect(Failure("unseen", "This macOS cannot hover over a page nobody is looking at.").hint?.contains("select the agent's tab") == true)
    }

    @Test func aQuestionKeepsItsResumeLineInData() throws {
        let failure = Failure("needs_you", "Which?", exit: .needsYou, data: ["resume": "broadway session resume ab"])

        let found = try parsed(Envelope.line(command: "task", data: nil, failure: failure))

        #expect(((found["data"] as? [String: Any])?["resume"] as? String) == "broadway session resume ab")
    }

    @Test func colourNeedsATerminalAndRespectsNoColor() {
        #expect(Style.wanted(tty: true, environment: ["TERM": "xterm"], flag: false))
        #expect(!Style.wanted(tty: false, environment: ["TERM": "xterm"], flag: false))
        #expect(!Style.wanted(tty: true, environment: ["NO_COLOR": "1"], flag: false))
        #expect(!Style.wanted(tty: true, environment: ["TERM": "dumb"], flag: false))
        #expect(!Style.wanted(tty: true, environment: [:], flag: true))
        #expect(Style(color: false).bad("x") == "x")
        #expect(Style(color: true).bold("x") == "\u{1B}[1mx\u{1B}[0m")
    }

    @Test func pageTextCannotDriveATerminal() {
        #expect(Plain.cell("a\u{1B}[2Jb\tc\nd") == "a [2Jb c d")
        #expect(Plain.safe("a\u{1B}[2Jb\nc") == "a[2Jb\nc")
    }

    @Test func aQuotedWordSurvivesAShell() {
        #expect(Plain.quote("it's") == "'it'\\''s'")
    }

    @Test func anElementLineCarriesItsState() {
        let element: [String: Any] = ["ref": "e3", "role": "textbox", "name": "Name", "value": "Ada", "focused": true]
        let secret: [String: Any] = ["ref": "e4", "role": "textbox", "name": "Password", "hidden": true]

        #expect(Render.elementLine(element) == "@e3 textbox \"Name\" value=\"Ada\" focused")
        #expect(Render.elementLine(secret) == "@e4 textbox \"Password\" value hidden")
    }

    @Test func selectOptionsAreJSONOnOnePlainLineWithDisabledState() throws {
        let element: [String: Any] = ["ref": "e5", "role": "combobox", "name": "Country", "value": "pl", "options": [
            ["value": "pl", "label": "Poland", "disabled": false],
            ["value": "x\n\u{1B}[2J", "label": "Quoted \"label\"\t", "disabled": true]
        ]]

        let line = Render.elementLine(element)
        let json = try #require(line.components(separatedBy: " options=").dropFirst().first)
        let options = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])

        #expect(line.hasPrefix("@e5 combobox \"Country\" value=\"pl\""))
        #expect(options.count == 2)
        #expect((options[0]["value"] as? String) == "pl")
        #expect((options[1]["disabled"] as? Bool) == true)
        #expect(!line.contains("\n"))
        #expect(!line.contains("\u{1B}"))
    }

    @Test func plainSelectOptionsStopAtOneHundredAndSecretOptionsStayHidden() throws {
        let options = (0..<110).map { ["value": String($0), "label": String($0)] }
        let element: [String: Any] = ["ref": "e6", "role": "combobox", "options": options]
        let hidden = element.merging(["hidden": true]) { _, new in new }

        let line = Render.elementLine(element)
        let json = try #require(line.components(separatedBy: " options=").dropFirst().first)
        let shown = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])

        #expect(shown.count == 100)
        #expect(!Render.elementLine(hidden).contains("options="))
    }

    @Test func historyRowsAreVisitsThenPagesThatSayIt() throws {
        let data: [String: Any] = [
            "pagesThatSayIt": [["url": "a", "visited": "old"], ["url": "b", "visited": "new"]],
            "visits": [["url": "a", "last": "today"]],
        ]

        let rows = try #require(Render.rows(in: data))

        #expect(rows.compactMap { $0["url"] as? String } == ["a", "b"])
        #expect(rows.compactMap { $0["last"] as? String } == ["today", "new"])
    }

    @Test func tablesPipeAsTabSeparatedColumns() {
        let command = Command(["name": "tabs", "columns": ["id", "title"]])

        let found = Render.lines(command, ["tabs": [["id": "ab", "title": "One\tTitle", "url": "x"]]])

        #expect(found == ["ab\tOne Title"])
    }

    @Test func aLongTitleLeavesRoomForTheAddress() {
        let both = Render.fitted([8, 90, 80], width: 100)
        let shortAddress = Render.fitted([8, 90, 20], width: 100)
        let fits = Render.fitted([8, 20, 20], width: 100)
        let alone = Render.fitted([200], width: 100)

        #expect(both == [8, 42, 42])
        #expect(shortAddress == [8, 64, 20])
        #expect(fits == [8, 20, 20])
        #expect(alone == [96])
    }

    @Test func helpIsGeneratedFromACommand() {
        let ref: [String: Any] = ["name": "ref", "type": "string", "description": "A ref", "required": true]
        let final: [String: Any] = ["name": "final", "type": "string", "description": "What it does", "choices": ["send", "pay"]]
        let command = Command(["name": "click", "tool": "click", "description": "Click it.", "tabbed": true, "positional": [ref], "flags": [ref, final], "examples": ["broadway click @e3"]])

        let page = Help.page(command, style: Style(color: false))

        #expect(page.contains("usage: broadway click <ref> [--final send|pay] [--tab ID]"))
        #expect(page.contains("--final STRING"))
        #expect(page.contains("(send, pay)"))
        #expect(page.contains("broadway click @e3"))
    }

    @Test func theOverviewListsWhatTheAppServed() {
        let catalog = Catalog([["name": "memory-search", "summary": "Search the notes"]])

        let page = Help.overview(catalog: catalog, style: Style(color: false))

        #expect(page.contains("memory-search"))
        #expect(page.contains("Search the notes"))
        #expect(page.contains("130 stopped"))
    }

    @Test func anUnreachableCatalogSaysSo() {
        let page = Help.overview(catalog: Catalog(nil), style: Style(color: false))

        #expect(page.contains("broadway doctor"))
    }

    @Test func theGuideIsShortAndTeachesTabsAsAChoice() {
        let guide = Help.guideText

        #expect(guide.utf8.count < 4096)
        #expect(!guide.contains(";"))
        for stale in ["one working tab", "--new", "Four tabs", "four at most", "tab=$(", "wait --idle", "| grep"] {
            #expect(!guide.contains(stale), "the guide still says \(stale)")
        }
        for taught in ["go moves the tab you are in. open gives you another tab", "broadway batch", "broadway find", "retry_safe", "needs_you", "--nth"] {
            #expect(guide.contains(taught), "the guide lacks \(taught)")
        }
    }

    @Test func theMcpInstructionsTeachTheSameChoice() {
        #expect(!Help.mcpInstructions.contains("one working tab"))
        #expect(Help.mcpInstructions.contains("open gives you another tab"))
        #expect(!Help.mcpInstructions.contains(";"))
    }

    @Test func batchIsListedOnceUnderTheBrowser() {
        let catalog = Catalog([["name": "click", "summary": "Click"], ["name": "batch", "summary": "From the app"]])

        let page = Help.overview(catalog: catalog, style: Style(color: false))

        #expect(page.components(separatedBy: "\n  batch ").count == 2)
        #expect(!page.contains("From the app"))
    }

    @Test func aTargetCommandsHelpNamesTheTargetFlags() {
        let ref: [String: Any] = ["name": "ref", "type": "string", "required": true]
        let click = Command(["name": "click", "tool": "click", "tabbed": true, "positional": [ref], "flags": [ref]])

        let page = Help.page(click, style: Style(color: false))
        let flags = Completions.candidates(["click"], current: "--", catalog: Catalog([["name": "click", "tool": "click", "flags": [ref]]])).map(\.0)

        #expect(page.contains("--nth N"))
        #expect(page.contains("--label WORDS"))
        #expect(flags.contains("--role"))
        #expect(flags.contains("--in"))
    }

    @Test func completionsFollowTheCatalog() {
        let catalog = Catalog([["name": "wait", "summary": "Wait", "tabbed": true, "flags": [["name": "selector", "type": "string"]]]])

        let commands = Completions.candidates([], current: "wa", catalog: catalog).map(\.0)
        let flags = Completions.candidates(["wait"], current: "--s", catalog: catalog).map(\.0)
        let parts = Completions.candidates(["session"], current: "s", catalog: catalog).map(\.0)

        #expect(commands == ["wait", "watch"])
        #expect(flags == ["--selector"])
        #expect(parts == ["stop", "steer"])
    }

    @Test func aWorldOnlyEverWakesItsOwnBundle() {
        let binary = "/x/build/Broadway.app/Contents/Helpers/broadway"

        let world = Place.resolve(socket: nil, world: "Test1", environment: [:], binary: binary)
        let loose = Place.resolve(socket: nil, world: "test1", environment: [:], binary: "/x/.build/debug/broadway")
        let real = Place.resolve(socket: nil, world: nil, environment: [:], binary: binary)
        let named = Place.resolve(socket: "/tmp/s", world: nil, environment: [:], binary: binary)

        #expect(world.socket.hasSuffix("/Broadway (test1)/broadway.sock"))
        #expect(world.wakeArguments(flag: "--w") == ["-n", "-g", "-j", "--env", "SEARCH_PROBE=test1", "/x/build/Broadway.app", "--args", "--w"])
        #expect(!loose.wakes)
        #expect(real.wakeArguments(flag: "--w") == ["-g", "-j", "/x/build/Broadway.app", "--args", "--w"])
        #expect(!named.wakes)
    }

    @Test func anEmptyHomeOverrideMeansTheRealOne() {
        #expect(Place.home(["BROADWAY_HOME": "/tmp/h"]) == "/tmp/h")
        #expect(Place.home(["BROADWAY_HOME": ""]) == NSHomeDirectory())
    }
}
