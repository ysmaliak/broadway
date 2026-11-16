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
        let steps = Setup.install(Setup.parts, paths: paths, binary: binary, guide: "the guide")

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: paths.link) == binary)
        #expect(step(steps, "fish")?.done == true)
        #expect(step(steps, "bash")?.done == true)
        #expect(step(steps, "zsh")?.done == false)
        #expect(step(steps, "claude")?.done == true)
        #expect(step(steps, "codex")?.done == false)
        #expect(try String(contentsOfFile: paths.claudeSkill, encoding: .utf8).contains("the guide"))
    }

    @Test func aCopyOutsideTheAppIsNotLinked() {
        let steps = Setup.install(["command"], paths: paths, binary: "/x/.build/debug/broadway", guide: "")

        #expect(step(steps, "command")?.done == false)
    }

    @Test func aStrangersFilesStay() throws {
        try FileManager.default.createDirectory(atPath: (paths.link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: paths.link))
        try FileManager.default.createDirectory(atPath: (paths.fish as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: paths.fish))

        let steps = Setup.install(["command", "completions"], paths: paths, binary: binary, guide: "")
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
        _ = Setup.install(Setup.parts, paths: paths, binary: binary, guide: "")
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
        let empty = Setup.checks(paths: paths, binary: binary, environment: ["PATH": "/usr/bin"], status: nil, running: false, guide: "")

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

        let checks = Setup.checks(paths: paths, binary: binary, environment: [:], status: status, running: true, guide: "")

        let found = Dictionary(uniqueKeysWithValues: checks.map { ($0.name, $0) })
        #expect(found["agents"]?.ok == false)
        #expect(found["agents"]?.required == false)
        #expect(found["plan"]?.ok == false)
    }

    @Test func aFolderOnThePathIsFoundWithOrWithoutASlash() {
        #expect(Setup.onPath("/a/b", environment: ["PATH": "/x:/a/b/:/y"]))
        #expect(!Setup.onPath("/a/b", environment: ["PATH": "/a/bc"]))
    }
}
