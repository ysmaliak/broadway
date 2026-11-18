import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SkillsTests {
    private var folder: URL!
    private var store: SkillStore!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        store = SkillStore(folder: folder)
    }

    private func tearDown() async {
        try? FileManager.default.removeItem(at: folder)
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    @Test func everyBuiltInParsesAndStaysSmall() {
        #expect(store.builtIn.count == BuiltInSkills.texts.count)
        #expect(Set(store.builtIn.map { $0.id }).count == store.builtIn.count)
        for skill in store.builtIn {
            #expect(!skill.sites.isEmpty, "\(skill.name)")
            #expect(skill.text.count < 800, "\(skill.name)")
        }
    }

    @Test func theManualsSkillsAreAllThere() {
        let wanted = ["GitHub", "Gmail", "Google Calendar", "Google Docs", "Google Drive", "Google Sheets", "Google Slides", "Slack", "Linear",
                      "Notion", "Jira", "Confluence", "Asana", "Trello", "ClickUp", "Airtable", "Discord", "LinkedIn", "X", "YouTube", "Amazon"]

        let names = Set(store.builtIn.map(\.name))

        for name in wanted { #expect(names.contains(name), "\(name)") }
    }

    @Test func aSkillReadsItsHeaderBodyAndActions() throws {
        let skill = try #require(Skill.parse("""
        # My Tool
        sites: tool.example, other.example/app

        Know this first.

        ## Actions
        - Check it [/item/]: Check this item.
        - Sum it: Sum it up.
        """))

        #expect(skill.id == "my-tool")
        #expect(skill.sites == ["tool.example", "other.example/app"])
        #expect(skill.body == "Know this first.")
        #expect(skill.actions == [SkillAction(title: "Check it", path: "/item/", prompt: "Check this item."),
                                       SkillAction(title: "Sum it", path: nil, prompt: "Sum it up.")])
    }

    @Test func aSkillNeedsANameAndSites() {
        #expect(Skill.parse("sites: a.example\n\nNo name") == nil)
        #expect(Skill.parse("# Name\n\nNo sites") == nil)
    }

    @Test func sitesMatchByHostAndPath() {
        #expect(Skill.matches("github.com", host: "gist.github.com", path: "/"))
        #expect(!Skill.matches("github.com", host: "notgithub.com", path: "/"))
        #expect(Skill.matches("docs.google.com/document", host: "docs.google.com", path: "/document/d/1"))
        #expect(!Skill.matches("docs.google.com/document", host: "docs.google.com", path: "/spreadsheets/d/1"))
    }

    @Test func duplicateToEditOverridesTheBuiltIn() throws {
        let github = try #require(store.skill(named: "GitHub"))

        let copy = try #require(store.duplicate(github))
        store.save(copy.text.replacingOccurrences(of: "Review pull request", with: "Look over"), replacing: copy)

        #expect(store.skills(for: url("https://github.com/a")).map(\.builtIn) == [false])
        let titles = store.skills(for: url("https://github.com/a/b/pull/1")).flatMap(\.actions).map(\.title)
        #expect(titles.contains("Look over"))
        #expect(!titles.contains("Review pull request"))
        #expect(store.all.filter { $0.id == "github" }.count == 1)
    }

    @Test func deletingACopyBringsTheBuiltInBack() throws {
        let original = try #require(store.skill(named: "GitHub"))
        let copy = try #require(store.duplicate(original))

        store.delete(copy)

        #expect(store.skill(named: "GitHub")?.builtIn == true)
    }

    @Test func aBuiltInCannotBeDeleted() throws {
        store.delete(try #require(store.skill(named: "GitHub")))

        #expect(store.skill(named: "GitHub") != nil)
    }

    @Test func renamingLeavesNoOldFile() throws {
        store.save("# First\nsites: a.example\n\nBody")
        let first = try #require(store.mine.first)

        store.save("# Second\nsites: a.example\n\nBody", replacing: first)

        #expect(store.mine.map(\.id) == ["second"])
    }

    @Test func aSkillThatCannotBeReadIsNotSaved() {
        let saved = store.save("no header")

        #expect(saved == .unreadable)
        #expect(store.mine.isEmpty)
    }

    @Test func theToolsListAndRead() throws {
        let listed = try #require(KnowledgeTools.call("skills", ["url": "https://github.com/a"]))
        let read = try #require(KnowledgeTools.call("skill", ["name": "GitHub"]))
        let byPage = try #require(KnowledgeTools.call("skill", ["url": "https://gist.github.com/a"]))
        let missing = try #require(KnowledgeTools.call("skill", ["name": "Nothing Here"]))

        #expect(listed.text?.contains("GitHub") == true)
        #expect(!(listed.text?.contains("Slack") == true))
        #expect(read.text?.contains("Files changed") == true)
        #expect(byPage.text?.contains("Files changed") == true)
        #expect(missing.failed)
    }
}
