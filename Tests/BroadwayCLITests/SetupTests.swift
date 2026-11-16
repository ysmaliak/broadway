import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(5)))
final class SetupTests {
    private var home: URL!
    private var paths: Setup.Paths!
    private let binary = "/Applications/Broadway.app/Contents/Helpers/broadway"

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("broadway-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        paths = Setup.Paths(home: home.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    private func step(_ steps: [Step], _ part: String) -> Step? {
        steps.first { $0.part == part }
    }

    @Test func setupLinksWritesAndSkipsWhatIsNotHere() throws {
        let steps = Setup.install(Setup.parts, paths: paths, binary: binary)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: paths.link) == binary)
        #expect(step(steps, "fish")?.done == true)
        #expect(step(steps, "bash")?.done == true)
        #expect(step(steps, "zsh")?.done == false)
        #expect(step(steps, "claude")?.done == true)
        #expect(step(steps, "codex")?.done == false)
        let written = try String(contentsOfFile: paths.claudeSkill, encoding: .utf8)
        #expect(written.contains("broadway-guide: \(Setup.guideVersion)"))
        #expect(written.contains("Run `broadway guide`"))
    }

    @Test func aCopyOutsideTheAppIsNotLinked() {
        let steps = Setup.install(["command"], paths: paths, binary: "/x/.build/debug/broadway")

        #expect(step(steps, "command")?.done == false)
    }

    @Test func aStrangersFilesStay() throws {
        try FileManager.default.createDirectory(atPath: (paths.link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: paths.link))
        try FileManager.default.createDirectory(atPath: (paths.fish as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: paths.fish))

        let steps = Setup.install(["command", "completions"], paths: paths, binary: binary)
        let removed = Setup.uninstall(["command", "completions"], paths: paths)

        #expect(step(steps, "command")?.done == false)
        #expect(step(steps, "fish")?.done == false)
        #expect(step(removed, "command")?.done == false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths.link)) == Data("mine".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths.fish)) == Data("mine".utf8))
    }

    @Test func aLinkToSomethingElseIsLeft() throws {
        try FileManager.default.createDirectory(atPath: (paths.link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: paths.link, withDestinationPath: "/usr/local/bin/other")

        let removed = Setup.uninstall(["command"], paths: paths)

        #expect(step(removed, "command")?.done == false)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: paths.link) == "/usr/local/bin/other")
    }

    @Test func removeUndoesSetupAndLeavesASkillFolderWithMoreInIt() throws {
        _ = Setup.install(Setup.parts, paths: paths, binary: binary)
        let beside = (paths.claudeSkill as NSString).deletingLastPathComponent + "/notes.md"
        try Data("mine".utf8).write(to: URL(fileURLWithPath: beside))

        _ = Setup.uninstall(Setup.parts, paths: paths)

        #expect(!FileManager.default.fileExists(atPath: paths.claudeSkill))
        #expect(!FileManager.default.fileExists(atPath: paths.fish))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: paths.link)) == nil)
        #expect(FileManager.default.fileExists(atPath: beside))
    }

    @Test func theZshBlockGoesInOnceAndComesOutClean() {
        let start = "export A=1"

        let added = Setup.adding(block: Setup.zshBlock(paths: paths), to: start)
        let twice = Setup.adding(block: Setup.zshBlock(paths: paths), to: added)
        let out = Setup.removing(from: "\(added)export B=2\n")

        #expect(added.hasPrefix("export A=1\n# >>> broadway >>>"))
        #expect(twice == added)
        #expect(out == "export A=1\nexport B=2\n")
    }

    @Test func doctorSaysEachWayItBreaks() throws {
        let empty = Setup.checks(paths: paths, binary: binary, environment: ["PATH": "/usr/bin"], status: nil, running: false)

        let found = Dictionary(uniqueKeysWithValues: empty.map { ($0.name, $0) })
        #expect(found["command"]?.ok == false)
        #expect(found["command"]?.fix == "Run broadway setup command")
        #expect(found["path"]?.ok == false)
        #expect(found["path"]?.fix?.contains("fish_add_path") == true)
        #expect(found["running"]?.required == false)
        #expect(found["zsh"]?.detail == "not used here")
        #expect(found["claude"]?.ok == false)
        #expect(found["agents"] == nil)
    }

    @Test func doctorReadsTheAppsStatus() {
        let status: [String: Any] = ["agents": false, "version": "1.0.8", "plans": ["claude": ["connected": false]]]

        let checks = Setup.checks(paths: paths, binary: binary, environment: [:], status: status, running: true)

        let found = Dictionary(uniqueKeysWithValues: checks.map { ($0.name, $0) })
        #expect(found["agents"]?.ok == false)
        #expect(found["agents"]?.required == false)
        #expect(found["plan"]?.ok == false)
    }

    @Test func aFolderOnThePathIsFoundWithOrWithoutASlash() {
        #expect(Setup.onPath("/a/b", environment: ["PATH": "/x:/a/b/:/y"]))
        #expect(!Setup.onPath("/a/b", environment: ["PATH": "/a/bc"]))
    }

    private func put(_ text: String, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    private let oldSkill = """
    ---
    name: broadway
    description: an old one
    managed-by: written by broadway setup
    ---

    # Broadway for agents
        tab=$(broadway open https://example.com)
    """

    @Test func theStubIsShortAndCarriesItsGuideVersion() {
        #expect(Setup.skill.utf8.count < 1200)
        #expect(Setup.guide(in: Setup.skill) == Setup.guideVersion)
        #expect(Setup.skill.contains("managed-by: written by broadway setup"))
        #expect(!Setup.skill.contains("one working tab"))
    }

    @Test func refreshRewritesAnOldSkillBroadwayWrote() throws {
        try put(oldSkill, paths.claudeSkill)

        let steps = Setup.refresh(["claude", "codex"], paths: paths)

        #expect(step(steps, "claude")?.done == true)
        #expect(read(paths.claudeSkill) == Setup.skill)
        #expect(step(steps, "codex")?.done == false)
        #expect(!FileManager.default.fileExists(atPath: paths.codexSkill))
    }

    @Test func refreshLeavesAStrangersSkillAndACurrentOne() throws {
        let foreign = "---\nname: broadway\n---\nmine\n"
        try put(foreign, paths.claudeSkill)
        try put(Setup.skill, paths.codexSkill)

        let steps = Setup.refresh(["claude", "codex"], paths: paths)

        #expect(step(steps, "claude")?.note == "left alone: this file isn't broadway's")
        #expect(read(paths.claudeSkill) == foreign)
        #expect(step(steps, "codex")?.note == "up to date")
    }

    @Test func refreshNeverCreatesASkill() {
        let steps = Setup.refresh(["claude"], paths: paths)

        #expect(step(steps, "claude")?.note == "not there")
        #expect(!FileManager.default.fileExists(atPath: paths.claudeSkill))
    }

    @Test func guideVersionsCompareAsNumbers() {
        #expect(Setup.older(nil))
        #expect(Setup.older("0.3", than: "0.4"))
        #expect(!Setup.older("0.10", than: "0.4"))
        #expect(!Setup.older("0.4", than: "0.4"))
        #expect(Setup.older("0.4", than: "0.4.1"))
        #expect(!Setup.older("1.0", than: "0.4"))
    }

    @Test func doctorWarnsOnAStaleSkillAndPassesACurrentOne() throws {
        try put(oldSkill, paths.claudeSkill)
        let stale = Setup.checks(paths: paths, binary: binary, environment: [:], status: nil, running: false).first { $0.name == "claude" }
        try put(Setup.skill, paths.claudeSkill)
        let fresh = Setup.checks(paths: paths, binary: binary, environment: [:], status: nil, running: false).first { $0.name == "claude" }

        #expect(stale?.ok == false)
        #expect(stale?.required == false)
        #expect(stale?.detail == "\(paths.claudeSkill) is out of date")
        #expect(stale?.fix == "Run broadway setup claude")
        #expect(fresh?.ok == true)
    }
}
