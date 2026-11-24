import Foundation
import Testing
@testable import BroadwayCLI
@testable import Search

@Suite(.timeLimit(.minutes(5)))
@MainActor
struct PersonHintsTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let scanned = ["Sources/BroadwayCLI/Nouns.swift"]

    private static func sources() throws -> [(name: String, text: String)] {
        let folder = root.appendingPathComponent("Sources/Search")
        let people = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("Person") && $0.hasSuffix(".swift") }
            .map { "Sources/Search/" + $0 }
        return try (people + scanned).map { ($0, try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)) }
    }

    private static var texts: [String] {
        let nouns = Nouns.all.flatMap { noun in [noun.summary] + noun.verbs.flatMap { [$0.summary, $0.about] + $0.examples } }
        let settings = PersonSettings.table.values.flatMap { [$0.takes] + ($0.instead.map { [$0] } ?? []) }
        return nouns + settings + Array(PersonRefusal.looks.values)
    }

    private static let command = try! NSRegularExpression(pattern: #"broadway ([a-z]+)(?: ([a-z][a-z.\-]*))?(?: ([A-Za-z][A-Za-z0-9.\-]*))?"#)

    static func commands(in text: String) -> [[String]] {
        command.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-")) }
                .filter { !$0.isEmpty }
        }
    }

    static func problem(_ words: [String]) -> String? {
        let said = "broadway " + words.joined(separator: " ")
        let pair = Array(words.prefix(2))
        if pair.count == 1, Nouns.noun(pair[0]) != nil { return nil }
        let routed: (noun: Noun, verb: Verb, rest: [String])?
        do {
            routed = try Nouns.route(pair)
        } catch {
            return "\(said) is no command"
        }
        guard let routed else { return nil }
        guard PersonCommands.find(routed.noun.name, routed.verb.name) != nil else { return "\(said) is not in PersonCommands.table" }
        if routed.noun.name == "settings", routed.verb.name == "set", words.count > 2, words[2] != words[2].uppercased(), SettingsIndex.item(words[2]) == nil {
            return "\(said) names no setting"
        }
        return nil
    }

    @Test func everyCommandAHintNamesIsReal() throws {
        let written = try Self.sources().flatMap { source in Self.commands(in: source.text).map { (source.name, $0) } }
        let shown = Self.texts.flatMap { text in Self.commands(in: text).map { ("text", $0) } }

        let wrong = (written + shown).compactMap { place, words in Self.problem(words).map { "\(place): \($0)" } }

        #expect(wrong == [])
        #expect(written.count > 40)
    }

    @Test func theWalkCatchesASettingThatIsGone() {
        #expect(Self.problem(["settings", "set", "tabs.give"]) != nil)
        #expect(Self.problem(["settings", "set", "spaces"]) != nil)
        #expect(Self.problem(["settings", "set", "look"]) == nil)
        #expect(Self.problem(["settings", "set", "ID"]) == nil)
    }

    @Test func theWalkCatchesAVerbThatIsGone() {
        #expect(Self.problem(["live", "on"]) != nil)
        #expect(Self.problem(["find"]) == nil)
        #expect(Self.problem(["space"]) == nil)
        #expect(Self.problem(["zoom", "125"]) == nil)
    }

    @Test func anUnknownSettingPointsAtSettingsFind() {
        let reply = PersonCommands.failure(PersonRefusal.missing("setting", "nope"))
        let error = reply["error"] as? [String: Any]

        #expect((error?["code"] as? String) == "not_found")
        #expect((error?["hint"] as? String) == "Look for it with broadway settings find WORDS")
    }

    @Test func everyThingThatCanBeMissingNamesItsOwnList() throws {
        let missing = try NSRegularExpression(pattern: #"(?:\.missing\(|named: [^)]*, what: )"([^"]+)""#)
        let kinds = try Set(Self.sources().flatMap { source in
            missing.matches(in: source.text, range: NSRange(source.text.startIndex..., in: source.text)).compactMap { match in
                Range(match.range(at: 1), in: source.text).map { String(source.text[$0]) }
            }
        })

        #expect(kinds.count > 10)
        for kind in kinds {
            let hint = PersonRefusal.looks[kind]
            #expect(hint != nil, "\(kind)")
            #expect(hint.map { $0.contains(" list") || $0.contains(" find") || $0.contains(" hidden") } == true, "\(kind)")
        }
    }

    @Test func aNameThatFitsSeveralAsksForMoreOfIt() {
        let reply = PersonCommands.failure(PersonRefusal.ambiguous("id", "1a", 2))
        let error = reply["error"] as? [String: Any]

        #expect((error?["hint"] as? String) == "Give more of the id")
    }
}
