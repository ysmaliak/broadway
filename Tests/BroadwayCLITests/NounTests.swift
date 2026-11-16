import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(5)))
struct NounTests {
    private func routed(_ words: [String]) throws -> (noun: String, verb: String, rest: [String]) {
        let found = try #require(try Nouns.route(words))
        return (found.noun.name, found.verb.name, found.rest)
    }

    private func command(_ noun: String, _ verb: String) throws -> Command {
        try #require(Nouns.noun(noun)?.verb(verb)).command
    }

    @Test func aVerbIsFoundAfterItsNoun() throws {
        let found = try routed(["tabs", "move", "1a2b", "--space", "Work"])

        #expect(found.noun == "tabs")
        #expect(found.verb == "move")
        #expect(found.rest == ["1a2b", "--space", "Work"])
    }

    @Test func aNounAloneRunsItsFirstVerb() throws {
        #expect(try routed(["tabs"]).verb == "list")
        #expect(try routed(["page"]).verb == "info")
        #expect(try routed(["agents"]).verb == "status")
    }

    @Test func aFlagAfterANounStaysWithItsFirstVerb() throws {
        let found = try routed(["tabs", "--all"])

        #expect(found.verb == "list")
        #expect(found.rest == ["--all"])
    }

    @Test func historyTakesLooseWords() throws {
        let found = try routed(["history", "github"])

        #expect(found.verb == "list")
        #expect(found.rest == ["github"])
    }

    @Test func spaceTakesAName() throws {
        let found = try routed(["space", "Work"])

        #expect(found.noun == "space")
        #expect(found.verb == "show")
        #expect(found.rest == ["Work"])
    }

    @Test func aliasesGoToPage() throws {
        for word in ["find", "zoom", "pdf", "translate"] {
            let found = try routed([word, "x"])

            #expect(found.noun == "page")
            #expect(found.verb == word)
            #expect(found.rest == ["x"])
        }
    }

    @Test func openWithASpaceIsTheHiddenVerb() throws {
        let found = try routed(["open", "--space", "Work", "https://example.com"])

        #expect(found.noun == "tabs")
        #expect(found.verb == "open")
        #expect(try Nouns.route(["open", "https://example.com"]) == nil)
    }

    @Test func aVerbTypoSuggestsTheVerb() {
        let error = #expect(throws: (any Error).self) { try Nouns.route(["tabs", "clsoe"]) }

        let failure = error as? Failure
        #expect(failure?.code == "usage")
        #expect(failure?.hint == "Did you mean tabs close?")
    }

    @Test func fillNeedsAVerb() {
        let error = #expect(throws: (any Error).self) { try Nouns.route(["fill"]) }
        #expect((error as? Failure)?.code == "usage")
    }

    @Test func anUnknownWordIsNotANoun() throws {
        #expect(try Nouns.route(["click", "@e1"]) == nil)
    }

    @Test func aRetiredNounIsUnknown() throws {
        #expect(try Nouns.route(["brief"]) == nil)
        #expect(try Nouns.route(["brief", "read"]) == nil)
        #expect(Nouns.noun("brief") == nil)
    }

    @Test func noVerbIsListedTwice() {
        let names = Nouns.all.flatMap { $0.verbs.map(\.fullName) }
        #expect(names.count == Set(names).count)
    }

    @Test func everyNounIsSoundAndGrouped() {
        for noun in Nouns.all {
            #expect(Nouns.groups.contains(noun.group), "\(noun.name)")
            #expect(!noun.verbs.isEmpty, "\(noun.name)")
            if let first = noun.first { #expect(noun.verb(first) != nil, "\(noun.name)") }
            for verb in noun.verbs {
                #expect(verb.noun == noun.name)
                #expect(!verb.summary.isEmpty, "\(verb.fullName)")
            }
        }
    }

    @Test func variadicWordsAreGatheredInOrder() throws {
        let found = try CommandLineInput.parse(command("tabs", "close"), ["aaa", "bbb", "ccc"])

        #expect((found["tab"] as? [String]) == ["aaa", "bbb", "ccc"])
    }

    @Test func aVariadicNeedsOneAtLeast() throws {
        let error = #expect(throws: (any Error).self) { try CommandLineInput.parse(command("tabs", "close"), []) }
        #expect((error as? Failure)?.code == "usage")
    }

    @Test func flagsAndWordsMix() throws {
        let found = try CommandLineInput.parse(command("tabs", "move"), ["1a2b", "--to", "3", "--no-folder"])

        #expect((found["tab"] as? String) == "1a2b")
        #expect((found["to"] as? Double) == 3)
        #expect((found["no-folder"] as? Bool) == true)
    }

    @Test func tabFlagMakesAVerbTabbed() throws {
        #expect(try command("page", "info").tabbed)
        #expect(try !command("tabs", "move").tabbed)
    }

    @Test func aMistypedFlagIsAMistake() throws {
        let error = #expect(throws: (any Error).self) { try CommandLineInput.parse(command("tabs", "move"), ["1a2b", "--spaec", "Work"]) }
        #expect((error as? Failure)?.code == "usage")
    }

    @Test func aHelpPageNamesEveryShownVerb() throws {
        let noun = try #require(Nouns.noun("shields"))

        let page = Help.page(noun, style: Style(color: false))

        #expect(page.contains("shields list"))
        #expect(page.contains("shields on"))
        #expect(!page.contains("shields off"))
    }

    @Test func aVerbsHelpUsesItsWholeLine() throws {
        let page = Help.page(try command("tabs", "move"), style: Style(color: false))

        #expect(page.contains("broadway tabs move <tab> [--space NAME]"), "\(page)")
    }

    @Test func completionsOfferVerbsAndFlags() {
        let verbs = Completions.candidates(["tabs"], current: "mo", catalog: Catalog(nil)).map(\.0)
        let flags = Completions.candidates(["tabs", "move"], current: "--s", catalog: Catalog(nil)).map(\.0)

        #expect(verbs == ["move"])
        #expect(flags == ["--space"])
    }

    @Test func completionsHideWhatOnlyThePersonCanDo() {
        #expect(!Completions.candidates(["shields"], current: "", catalog: Catalog(nil)).map(\.0).contains("off"))
    }

    @Test func personOptionsPullTheirFlagsOut() throws {
        let found = try PersonOptions.parse(["1a2b", "--wait-person", "2", "--space", "Work"])

        #expect(found.wait == 120)
        #expect(found.words == ["1a2b", "--space", "Work"])
    }

    @Test func aPipeNeverWaitsForAPersonUnlessAsked() throws {
        #expect(try PersonOptions.parse([]).seconds(interactive: false) == 0)
        #expect(try PersonOptions.parse([]).seconds(interactive: true) == 120)
        #expect(try PersonOptions.parse(["--no-person"]).seconds(interactive: true) == 0)
    }

    @Test func noPersonAndWaitPersonConflict() {
        #expect(throws: (any Error).self) { try PersonOptions.parse(["--no-person", "--wait-person", "1"]) }
    }

    @Test func watchTakesItsFlags() throws {
        let found = try Watch.parse(["--only", "tabs,tasks", "--count", "2", "--seconds", "1.5"])

        #expect(found.only == ["tabs", "tasks"])
        #expect(found.count == 2)
        #expect(found.seconds == 1.5)
    }

    @Test func watchRefusesAKindItDoesNotKnow() {
        #expect(throws: (any Error).self) { try Watch.parse(["--only", "cats"]) }
    }

    @Test func aWatchLineIsOneLine() {
        let event: [String: Any] = ["at": "2026-11-02T18:31:06Z", "event": "tab.added", "id": "e878df55", "title": "Two\nlines", "url": ""]

        let line = Watch.line(event)

        #expect(line.hasPrefix("18:31:06  tab.added  e878df55"), "\(line)")
        #expect(!line.contains("\n"))
    }
}
