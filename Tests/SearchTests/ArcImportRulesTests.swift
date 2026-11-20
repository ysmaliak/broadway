import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5)))
struct ArcImportRulesTests {
    private func routing(_ rules: [Any]) throws -> ArcRouting {
        let data = try JSONSerialization.data(withJSONObject: ["rules": rules])
        return try #require(Arc.parse(routing: data))
    }

    private func rule(_ kind: Any, _ text: Any, to destination: [String: Any], conditions: Int = 1) -> [String: Any] {
        let condition: [String: Any] = ["componentType": ["urlMatch": ["_0": kind, "_1": text]]]
        return ["sourceComponents": Array(repeating: condition, count: conditions), "destination": destination]
    }

    private func space(_ id: String) -> [String: Any] {
        ["space": ["_0": ["space": ["_0": id]]]]
    }

    private func sidebar(_ spaces: [Any]) throws -> ArcSidebar {
        let main: [String: Any] = ["items": [Any](), "spaces": spaces, "topAppsContainerIDs": [Any]()]
        let data = try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": [main]]])
        return try #require(Arc.parse(data, profile: nil))
    }

    @Test func aContainsRuleToASpaceIsRead() throws {
        let read = try routing([rule(["contains": [String: Any]()], "figma.com", to: space("S-1"))])
        #expect(read.rules == [ArcRouting.Rule(kind: .contains, text: "figma.com", space: "S-1")])
        #expect(read.leftOut == 0)
    }

    @Test func everySpellingOfEqualsIsRead() throws {
        let read = try routing([
            rule(["is": [String: Any]()], "a.example", to: space("S")),
            rule(["equals": [String: Any]()], "b.example", to: space("S")),
            rule(["isEqualTo": [String: Any]()], "c.example", to: space("S")),
            rule("is_equal_to", "d.example", to: space("S")),
        ])
        #expect(read.rules.map(\.kind) == [.equals, .equals, .equals, .equals])
        #expect(read.leftOut == 0)
    }

    @Test func littleArcProfileAndMostRecentSpaceRulesAreLeftOutAndCounted() throws {
        let read = try routing([
            rule(["contains": [String: Any]()], "a.example", to: ["littleArc": [String: Any]()]),
            rule(["contains": [String: Any]()], "b.example", to: ["profile": ["_0": ["directoryBasename": "Profile 1"]]]),
            rule(["contains": [String: Any]()], "c.example", to: ["mostRecentSpace": [String: Any]()]),
            rule(["contains": [String: Any]()], "d.example", to: space("S")),
        ])
        #expect(read.rules.map(\.text) == ["d.example"])
        #expect(read.leftOut == 3)
    }

    @Test func aRuleWithSeveralConditionsIsLeftOutAndCounted() throws {
        let read = try routing([rule(["contains": [String: Any]()], "a.example", to: space("S"), conditions: 2)])
        #expect(read.rules.isEmpty)
        #expect(read.leftOut == 1)
    }

    @Test func unreadablePiecesAreLeftOutAndCountedAndIdsBetweenRulesAreSkipped() throws {
        let read = try routing([
            "rule-id-1",
            rule(["startsWith": [String: Any]()], "a.example", to: space("S")),
            rule(["contains": [String: Any]()], 42, to: space("S")),
            rule(["contains": [String: Any]()], "   ", to: space("S")),
            ["destination": space("S")],
            7,
            "rule-id-2",
            rule(["contains": [String: Any]()], "b.example", to: space("S")),
        ])
        #expect(read.rules.map(\.text) == ["b.example"])
        #expect(read.leftOut == 5)
    }

    @Test func aFileWithoutRulesIsNotRead() {
        #expect(Arc.parse(routing: Data("{}".utf8)) == nil)
        #expect(Arc.parse(routing: Data("not json".utf8)) == nil)
    }

    @Test func aBareDomainBecomesASiteRule() {
        #expect(Arc.match("figma.com") == .site("figma.com"))
        #expect(Arc.match("https://www.Figma.com/") == .site("figma.com"))
    }

    @Test func aBareSubdomainBecomesAHostRule() {
        #expect(Arc.match("docs.google.com") == .host("docs.google.com"))
    }

    @Test func anAddressWithAPathOrPortBecomesAContainsRuleWithoutItsScheme() {
        #expect(Arc.match("https://www.GitHub.com/acme/repo") == .contains("github.com/acme/repo"))
        #expect(Arc.match("localhost:3000") == .contains("localhost:3000"))
        #expect(Arc.match("meet") == .contains("meet"))
    }

    @Test func mappedRulesMatchTheLinksArcSentThere() throws {
        let site = try #require(Arc.match("figma.com"))
        #expect(LinkRouter.matches(site, try #require(URL(string: "https://www.figma.com/file/1"))))
        #expect(LinkRouter.matches(site, try #require(URL(string: "https://help.figma.com/"))))
        let host = try #require(Arc.match("docs.google.com"))
        #expect(LinkRouter.matches(host, try #require(URL(string: "https://docs.google.com/document/d/1"))))
        #expect(!LinkRouter.matches(host, try #require(URL(string: "https://mail.google.com/"))))
        let contains = try #require(Arc.match("https://github.com/acme/repo"))
        #expect(LinkRouter.matches(contains, try #require(URL(string: "https://github.com/acme/repo/pull/2"))))
        #expect(!LinkRouter.matches(contains, try #require(URL(string: "https://github.com/other/repo"))))
    }

    @Test func importedRulesSendLinksFromOtherAppsToTheirSpace() {
        let work = UUID()
        let made = Arc.linkRules(ArcRouting(rules: [.init(kind: .contains, text: "figma.com", space: "S-WORK")], leftOut: 0),
                                 spaces: ["s-work": work], have: [])
        #expect(made.rules.count == 1)
        #expect(made.rules.first?.match == .site("figma.com"))
        #expect(made.rules.first?.from == .otherApps)
        #expect(made.rules.first?.target == .space(work, folder: nil))
        #expect(made.leftOut == 0)
    }

    @Test func rulesNamingASpaceThatWasNotImportedAreLeftOut() {
        let made = Arc.linkRules(ArcRouting(rules: [.init(kind: .contains, text: "a.example", space: "gone"),
                                                    .init(kind: .equals, text: "b.example", space: "here")], leftOut: 2),
                                 spaces: ["here": UUID()], have: [])
        #expect(made.rules.map(\.match) == [.site("b.example")])
        #expect(made.leftOut == 3)
    }

    @Test func aRuleAlreadyThereIsNotAddedAgain() {
        let work = UUID()
        let have = [LinkRule(match: .site("figma.com"), from: .anywhere, target: .space(work, folder: nil))]
        let routing = ArcRouting(rules: [.init(kind: .contains, text: "Figma.com", space: "w"),
                                         .init(kind: .equals, text: "linear.app", space: "w"),
                                         .init(kind: .contains, text: "https://linear.app/", space: "w")], leftOut: 0)
        let made = Arc.linkRules(routing, spaces: ["w": work], have: have)
        #expect(made.rules.map(\.match) == [.site("linear.app")])
        #expect(made.leftOut == 0)
    }

    @Test func aSpaceIdIsReadFromTheSpaceOrTheEntryBeforeIt() throws {
        let read = try sidebar(["A-ID", ["title": "One"], ["id": "B-ID", "title": "Two"]])
        #expect(read.spaces.map(\.id) == ["A-ID", "B-ID"])
    }

    @Test func aSpacesMidToneIsItsColour() throws {
        let theme: [String: Any] = ["primaryColorPalette": ["midTone": ["red": 0.2, "green": 0.4, "blue": 0.6, "alpha": 1]]]
        let read = try sidebar([["id": "A", "title": "One", "customInfo": ["windowTheme": theme]]])
        #expect(read.spaces.first?.colours == ["336699"])
    }

    @Test func aGradientKeepsArcsOrderOverTheMidTone() throws {
        let stops: [Any] = [["red": 1, "green": 0, "blue": 0], ["red": 0, "green": 1, "blue": 0], ["red": 0, "green": 0, "blue": 1]]
        let theme: [String: Any] = [
            "background": ["single": ["_0": ["style": ["color": ["_0": ["blendedGradient": ["_0": ["baseColors": stops]]]]]]]],
            "primaryColorPalette": ["midTone": ["red": 0.5, "green": 0.5, "blue": 0.5]],
            "semanticColorPalettes": ["light": ["shades": [["red": 0.1, "green": 0.1, "blue": 0.1], ["red": 0.9, "green": 0.9, "blue": 0.9]]]],
        ]
        #expect(Arc.colours(theme) == ["FF0000", "00FF00", "0000FF"])
    }

    @Test func aGradientBesideAWrappedColourIsStillFound() {
        let theme: [String: Any] = ["background": ["_0": ["red": 0.5, "green": 0.5, "blue": 0.5],
                                                   "stops": [["red": 1, "green": 0, "blue": 0], ["red": 0, "green": 0, "blue": 1]]]]
        #expect(Arc.colours(theme) == ["FF0000", "0000FF"])
    }

    @Test func aWideColourKeepsItsDisplayP3Value() {
        let theme: [String: Any] = ["primaryColorPalette": ["midTone": ["red": 1, "green": 0, "blue": 0, "colorSpace": "displayP3"]]]
        #expect(Arc.colours(theme) == ["p3:FF0000"])
    }

    @Test func aColourOutOfRangeIsClampedAndAnUnreadableOneIsDropped() {
        #expect(Arc.colours(["primaryColorPalette": ["midTone": ["red": 1.4, "green": -0.2, "blue": 0]]]) == ["FF0000"])
        #expect(Arc.colours(["primaryColorPalette": ["midTone": ["red": "high", "green": 0, "blue": 0]]]).isEmpty)
        #expect(Arc.colours(nil).isEmpty)
    }

    @MainActor @Test func theResultListCountsLinkRules() {
        #expect(ImportModel.ruleLines(added: 12, leftOut: 0).map(\.text) == ["12 link rules"])
        #expect(ImportModel.ruleLines(added: 1, leftOut: 0).map(\.text) == ["1 link rule"])
    }

    @MainActor @Test func theResultListSaysHowManyRulesWereLeftOut() {
        #expect(ImportModel.ruleLines(added: 2, leftOut: 3).map(\.text)
                == ["2 link rules", "3 rules left out because Broadway has no place for them"])
        #expect(ImportModel.ruleLines(added: 0, leftOut: 1).map(\.text) == ["1 rule left out because Broadway has no place for it"])
        #expect(ImportModel.ruleLines(added: 0, leftOut: 0).isEmpty)
    }
}
