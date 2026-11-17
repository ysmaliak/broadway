import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(5)))
final class SetupAgentsTests {
    private var home: URL!
    private var paths: Setup.Paths!
    private let binary = "/Applications/Broadway.app/Contents/Helpers/broadway"
    private let others = ["cursor", "opencode", "gemini"]

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("broadway-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = Setup.Paths(home: home.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    private func make(_ folder: String) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    private func step(_ steps: [Step], _ part: String) -> Step? {
        steps.first { $0.part == part }
    }

    private func tree() -> [String: Data] {
        var found: [String: Data] = [:]
        guard let walker = FileManager.default.enumerator(atPath: home.path) else { return found }
        for case let relative as String in walker {
            let full = home.appendingPathComponent(relative).path
            var folder: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &folder)
            found[relative] = folder.boolValue ? Data() : (try? Data(contentsOf: URL(fileURLWithPath: full))) ?? Data()
        }
        return found
    }

    @Test func nothingInstalledGetsNothing() {
        let before = tree()

        let steps = Setup.install(others, paths: paths, binary: binary)

        #expect(steps.allSatisfy { !$0.done })
        #expect(steps.allSatisfy { $0.note.hasPrefix("skipped") })
        #expect(tree() == before)
        #expect(!FileManager.default.fileExists(atPath: paths.gemini))
        #expect(!FileManager.default.fileExists(atPath: paths.opencode))
        #expect(!FileManager.default.fileExists(atPath: paths.cursor))
    }

    @Test func oneInstalledGetsItsSkillInItsOwnFolder() throws {
        try make(paths.gemini)

        let steps = Setup.install(others, paths: paths, binary: binary)

        #expect(step(steps, "gemini")?.done == true)
        #expect(step(steps, "gemini")?.path == paths.geminiSkill)
        #expect(step(steps, "opencode")?.done == false)
        #expect(step(steps, "cursor")?.done == false)
        let written = try String(contentsOfFile: paths.geminiSkill, encoding: .utf8)
        #expect(written.hasPrefix("---\nname: broadway\n"))
        #expect(written.contains("  managed-by: \(Setup.mark)"))
        #expect(written.contains("  broadway-guide: \"\(Setup.guideVersion)\""))
        #expect(Setup.guide(in: written) == Setup.guideVersion)
        #expect(!FileManager.default.fileExists(atPath: paths.opencode))
        #expect(!FileManager.default.fileExists(atPath: paths.cursor))
    }

    @Test func eachAgentHasItsDocumentedFolder() {
        #expect(paths.geminiSkill == home.path + "/.gemini/skills/broadway/SKILL.md")
        #expect(paths.opencodeSkill == home.path + "/.config/opencode/skills/broadway/SKILL.md")
        #expect(paths.cursorSkill == home.path + "/.cursor/skills/broadway/SKILL.md")
    }

    @Test func cursorReadsClaudesSkillSoItGetsNoSecondCopy() throws {
        try make(paths.cursor)
        try make(paths.claude)

        let steps = Setup.install(["claude", "cursor"], paths: paths, binary: binary)

        #expect(step(steps, "claude")?.done == true)
        #expect(step(steps, "cursor")?.done == false)
        #expect(step(steps, "cursor")?.note.contains("~/.claude/skills") == true)
        #expect(!FileManager.default.fileExists(atPath: paths.cursorSkill))
        let cursor = Setup.checks(paths: paths, binary: binary, environment: [:], status: nil, running: false).first { $0.name == "cursor" }
        #expect(cursor?.ok == true)
    }

    @Test func cursorAloneGetsItsOwnCopy() throws {
        try make(paths.cursor)

        let steps = Setup.install(others, paths: paths, binary: binary)

        #expect(step(steps, "cursor")?.done == true)
        #expect(FileManager.default.fileExists(atPath: paths.cursorSkill))
    }

    @Test func aFileOfThePersonsOwnIsLeftAndSaidSo() throws {
        try make((paths.opencodeSkill as NSString).deletingLastPathComponent)
        let mine = Data("---\nname: broadway\ndescription: my own notes\n---\n".utf8)
        try mine.write(to: URL(fileURLWithPath: paths.opencodeSkill))

        let steps = Setup.install(others, paths: paths, binary: binary)
        let refreshed = Setup.refresh(others, paths: paths)
        let removed = Setup.uninstall(others, paths: paths)

        #expect(step(steps, "opencode")?.done == false)
        #expect(step(steps, "opencode")?.note == "left alone: this file isn't broadway's")
        #expect(step(refreshed, "opencode")?.done == false)
        #expect(step(removed, "opencode")?.done == false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths.opencodeSkill)) == mine)
        let check = Setup.checks(paths: paths, binary: binary, environment: [:], status: nil, running: false).first { $0.name == "opencode" }
        #expect(check?.ok == false)
        #expect(check?.detail.contains("isn't broadway's") == true)
    }

    @Test func removeAfterSetupLeavesTheFolderAsItWas() throws {
        try make(paths.gemini)
        try make(paths.opencode)
        try make(paths.cursor)
        try Data("{\"theme\": \"dark\"}\n".utf8).write(to: URL(fileURLWithPath: paths.gemini + "/settings.json"))
        try make(paths.opencode + "/skills/review")
        try Data("---\nname: review\ndescription: mine\n---\n".utf8).write(to: URL(fileURLWithPath: paths.opencode + "/skills/review/SKILL.md"))
        let before = tree()

        _ = Setup.install(others, paths: paths, binary: binary)
        #expect(tree() != before)
        let removed = Setup.uninstall(others, paths: paths)

        #expect(step(removed, "gemini")?.done == true)
        #expect(step(removed, "opencode")?.done == true)
        #expect(step(removed, "cursor")?.done == true)
        #expect(tree() == before)
    }

    @Test func removeAfterSetupForEveryAgentLeavesTheHomeAsItWas() throws {
        for folder in [paths.claude, paths.codex, paths.gemini, paths.opencode, paths.cursor] { try make(folder) }
        try make(paths.codex + "/skills/review")
        let before = tree()

        _ = Setup.install(Setup.parts.filter { $0 != "command" && $0 != "completions" }, paths: paths, binary: binary)
        #expect(FileManager.default.fileExists(atPath: paths.claudeSkill))
        _ = Setup.uninstall(Setup.parts.filter { $0 != "command" && $0 != "completions" }, paths: paths)

        #expect(tree() == before)
    }

    @Test func removeKeepsAnEmptySkillsFolderOfThePersons() throws {
        try make(paths.cursor + "/skills")
        try make(paths.gemini)
        let before = tree()

        _ = Setup.install(others, paths: paths, binary: binary)
        _ = Setup.install(others, paths: paths, binary: binary)
        _ = Setup.refresh(others, paths: paths)
        _ = Setup.uninstall(others, paths: paths)

        #expect(tree() == before)
        #expect(FileManager.default.fileExists(atPath: paths.cursor + "/skills"))
        #expect(!FileManager.default.fileExists(atPath: paths.gemini + "/skills"))
    }

    @Test func aSkillsFolderSetupMadeIsSaidSoInTheSkill() throws {
        try make(paths.gemini)
        try make(paths.opencode + "/skills")

        _ = Setup.install(others, paths: paths, binary: binary)

        #expect(try String(contentsOfFile: paths.geminiSkill, encoding: .utf8).contains("  \(Setup.madeFolder)\n"))
        #expect(try !String(contentsOfFile: paths.opencodeSkill, encoding: .utf8).contains(Setup.madeFolder))
    }

    @Test func refreshRewritesOnlyAnOlderSkillOfBroadways() throws {
        try make(paths.gemini)
        _ = Setup.install(["gemini"], paths: paths, binary: binary)
        let old = try String(contentsOfFile: paths.geminiSkill, encoding: .utf8)
            .replacingOccurrences(of: "broadway-guide: \"\(Setup.guideVersion)\"", with: "broadway-guide: \"0.3\"")
        try Data(old.utf8).write(to: URL(fileURLWithPath: paths.geminiSkill))

        let refreshed = Setup.refresh(others, paths: paths)

        #expect(step(refreshed, "gemini")?.done == true)
        let now = try String(contentsOfFile: paths.geminiSkill, encoding: .utf8)
        #expect(Setup.guide(in: now) == Setup.guideVersion)
        #expect(now.contains(Setup.madeFolder))
        #expect(step(refreshed, "opencode")?.note == "not there")
        #expect(!FileManager.default.fileExists(atPath: paths.opencode))
    }

    @Test func doctorReportsEachAgent() throws {
        try make(paths.gemini)
        try make(paths.opencode)
        _ = Setup.install(["gemini"], paths: paths, binary: binary)

        let checks = Setup.checks(paths: paths, binary: binary, environment: [:], status: nil, running: false)
        let named = Dictionary(checks.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        #expect(named["gemini"]?.ok == true)
        #expect(named["gemini"]?.detail == paths.geminiSkill)
        #expect(named["opencode"]?.ok == false)
        #expect(named["opencode"]?.fix == "Run broadway setup opencode")
        #expect(named["cursor"]?.ok == true)
        #expect(named["cursor"]?.detail == "not used here")
    }

    @Test func setupWithNoWordsCoversTheOtherAgentsToo() {
        #expect(Set(others).isSubset(of: Set(Setup.parts)))
    }
}
