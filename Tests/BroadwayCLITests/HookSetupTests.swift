import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(5)))
final class HookSetupTests {
    private var home: URL!
    private var paths: Setup.Paths!
    private let binary = "/Applications/Broadway.app/Contents/Helpers/broadway"

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("broadway-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        paths = Setup.Paths(home: home.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    private func put(_ text: String, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private let foreign = """
    {
        "model": "opus",
        "permissions": {
            "allow": ["Bash(git status)"]
        },
        "hooks": {
            "Stop": [
                {
                    "matcher": "",
                    "hooks": [{"type": "command", "command": "say done"}]
                }
            ],
            "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "check-it"}]}]
        },
        "theme": "dark"
    }
    """

    private let plain = "{\n\t\"model\": \"sonnet\",\n\t\"env\": {\"A\": \"b/c\"}\n}"

    @Test func setupAddsTheHooksToAFreshHome() throws {
        let steps = Setup.install(["claude", "codex"], paths: paths, binary: binary)

        let claude = try read(paths.claudeSettings)
        let codex = try read(paths.codexHooks)
        let written = steps.filter { $0.path == paths.claudeSettings || $0.path == paths.codexHooks }
        #expect(written.count == 2 && written.allSatisfy { $0.done })
        #expect(HookSetup.installed("claude", in: claude))
        #expect(HookSetup.installed("codex", in: codex))
        #expect(claude.contains("\"command\": \"test -x ~/.local/bin/broadway && ~/.local/bin/broadway agents idle --hook claude || true\""))
        #expect(codex.contains("agents idle --hook codex"))
        #expect(!claude.contains("--hook codex"))
        #expect(claude == HookSetup.fresh("claude"))
    }

    @Test func twiceGivesTheSameFile() throws {
        try put(foreign, paths.claudeSettings)

        _ = Setup.install(["claude"], paths: paths, binary: binary)
        let once = try read(paths.claudeSettings)
        let again = Setup.install(["claude"], paths: paths, binary: binary)
        let twice = try read(paths.claudeSettings)

        #expect(once == twice)
        #expect(again.first { $0.path == paths.claudeSettings }?.note == "hooks already there")
    }

    @Test func aForeignHookAndEveryOtherSettingStay() throws {
        try put(foreign, paths.claudeSettings)

        _ = Setup.install(["claude"], paths: paths, binary: binary)
        let added = try read(paths.claudeSettings)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(added.utf8)) as? [String: Any])
        let hooks = try #require(object["hooks"] as? [String: Any])
        let stops = try #require(hooks["Stop"] as? [[String: Any]])

        #expect(object["model"] as? String == "opus")
        #expect(object["theme"] as? String == "dark")
        #expect(stops.count == 2)
        #expect((stops[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "say done")
        #expect((hooks["PreToolUse"] as? [[String: Any]])?.count == 1)
        #expect((hooks["SessionEnd"] as? [[String: Any]])?.count == 1)
        #expect(added.contains("\n        \"PreToolUse\": [{\"matcher\": \"Bash\", \"hooks\": [{\"type\": \"command\", \"command\": \"check-it\"}]}]"))
    }

    @Test func removeGivesBackTheOriginalBytes() throws {
        let fixtures = [foreign, plain, "{}", "{\"a\": 1}\n", "{\n  \"hooks\": {\n    \"Stop\": []\n  }\n}\n",
                        "{\n  \"hooks\": {}\n}", "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"x\"}]}]}}"]
        for fixture in fixtures {
            try put(fixture, paths.claudeSettings)

            let steps = Setup.install(["claude"], paths: paths, binary: binary)
            let added = try read(paths.claudeSettings)
            _ = Setup.uninstall(["claude"], paths: paths)
            let back = FileManager.default.fileExists(atPath: paths.claudeSettings) ? try read(paths.claudeSettings) : nil

            #expect(steps.first { $0.path == paths.claudeSettings }?.done == true, "\(fixture)")
            #expect(HookSetup.installed("claude", in: added), "\(fixture)")
            #expect(JSONText.valid(added), "\(added)")
            if fixture == "{}" {
                #expect(back == "{\n}", "\(String(describing: back))")
            } else {
                #expect(back == fixture, "\(String(describing: back))")
            }
        }
    }

    @Test func removeTakesOutAFileItMade() throws {
        _ = Setup.install(["claude", "codex"], paths: paths, binary: binary)

        let steps = Setup.uninstall(["claude", "codex"], paths: paths)

        #expect(!FileManager.default.fileExists(atPath: paths.claudeSettings))
        #expect(!FileManager.default.fileExists(atPath: paths.codexHooks))
        #expect(steps.filter { $0.note == "took out broadway's hooks" }.count == 2)
    }

    @Test func aHookThePersonAddedBesideOursStays() throws {
        _ = Setup.install(["claude"], paths: paths, binary: binary)
        var text = try read(paths.claudeSettings)
        text = text.replacingOccurrences(of: "\"Stop\": [\n", with: "\"Stop\": [\n      {\"hooks\": [{\"type\": \"command\", \"command\": \"mine\"}]},\n")
        try put(text, paths.claudeSettings)

        _ = Setup.uninstall(["claude"], paths: paths)
        let left = try read(paths.claudeSettings)

        #expect(left.contains("\"mine\""))
        #expect(!left.contains("--hook claude"))
        #expect(JSONText.valid(left))
    }

    @Test func aFileThatIsNotPlainJSONIsLeftAlone() throws {
        let odd = "{\n  // a comment\n  \"model\": \"opus\"\n}\n"
        try put(odd, paths.claudeSettings)

        let steps = Setup.install(["claude"], paths: paths, binary: binary)
        let removed = Setup.uninstall(["claude"], paths: paths)

        #expect(try read(paths.claudeSettings) == odd)
        #expect(steps.first { $0.path == paths.claudeSettings }?.note == "left alone: it isn't plain JSON")
        #expect(removed.first { $0.path == paths.claudeSettings }?.done == false)
    }

    @Test func hooksOfAnotherShapeAreLeftAlone() throws {
        let odd = "{\"hooks\": {\"Stop\": \"say done\"}}"
        try put(odd, paths.claudeSettings)

        let steps = Setup.install(["claude"], paths: paths, binary: binary)

        #expect(try read(paths.claudeSettings) == odd)
        #expect(steps.first { $0.path == paths.claudeSettings }?.done == false)
    }

    @Test func aSymlinkedSettingsFileStaysALink() throws {
        let real = home.appendingPathComponent("dotfiles/settings.json").path
        try put(plain, real)
        try FileManager.default.createSymbolicLink(atPath: paths.claudeSettings, withDestinationPath: real)

        _ = Setup.install(["claude"], paths: paths, binary: binary)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: paths.claudeSettings) == real)
        let linked = try read(real)
        #expect(HookSetup.installed("claude", in: linked))
        _ = Setup.uninstall(["claude"], paths: paths)
        #expect(try read(real) == plain)
    }

    @Test func refreshAddsHooksOnlyWhereTheSkillIsBroadways() throws {
        try put(Setup.skill, paths.claudeSkill)

        let steps = Setup.refresh(["claude", "codex"], paths: paths)

        let settings = try read(paths.claudeSettings)
        #expect(HookSetup.installed("claude", in: settings))
        #expect(!FileManager.default.fileExists(atPath: paths.codexHooks))
        #expect(!FileManager.default.fileExists(atPath: paths.codexSkill))
        #expect(steps.contains { $0.path == paths.claudeSettings && $0.done })
    }

    @Test func refreshLeavesAStrangersSkillsHome() throws {
        try put("---\nname: broadway\n---\nmine\n", paths.claudeSkill)

        _ = Setup.refresh(["claude"], paths: paths)

        #expect(!FileManager.default.fileExists(atPath: paths.claudeSettings))
    }

    @Test func doctorSaysWhenTheHooksAreMissing() throws {
        let before = Setup.checks(paths: paths, binary: binary, environment: [:], status: nil, running: false).first { $0.name == "claude hooks" }
        _ = Setup.install(["claude"], paths: paths, binary: binary)
        let after = Setup.checks(paths: paths, binary: binary, environment: [:], status: nil, running: false).first { $0.name == "claude hooks" }

        #expect(before?.ok == false)
        #expect(before?.fix == "Run broadway setup claude")
        #expect(after?.ok == true)
    }

    @Test func aStopEventAsksForIdleWithTheSessionFromTheEvent() throws {
        let event: [String: Any] = ["session_id": "11111111-2222-3333-4444-555555555555", "hook_event_name": "Stop",
                                    "stop_hook_active": false, "last_assistant_message": "All set", "background_tasks": [Any](), "session_crons": [Any]()]

        let request = try #require(AgentHook.request(agent: "claude", event: event, environment: ["CODEX_THREAD_ID": "other"]))
        let agent = try #require(request["agent"] as? [String: Any])

        #expect(request["verb"] as? String == "idle")
        #expect(request["noun"] as? String == "agents")
        #expect(request["hook"] as? Bool == true)
        #expect(request["person"] == nil)
        #expect(agent["session"] as? String == "claude:11111111-2222-3333-4444-555555555555")
    }

    @Test func codexEventsUseTheCodexKey() throws {
        let request = try #require(AgentHook.request(agent: "codex", event: ["session_id": "abc", "hook_event_name": "Stop"],
                                                     environment: ["CLAUDE_CODE_SESSION_ID": "other"]))

        #expect((request["agent"] as? [String: Any])?["session"] as? String == "codex:abc")
    }

    @Test func aSessionEndEndsAndOtherEventsDoNothing() {
        let end = AgentHook.request(agent: "claude", event: ["session_id": "x", "hook_event_name": "SessionEnd", "reason": "other"], environment: [:])
        let busy = AgentHook.request(agent: "claude", event: ["session_id": "x", "hook_event_name": "Stop", "background_tasks": [["id": "1"]]], environment: [:])
        let looping = AgentHook.request(agent: "claude", event: ["session_id": "x", "hook_event_name": "Stop", "session_crons": [["id": "1"]]], environment: [:])
        let prompt = AgentHook.request(agent: "claude", event: ["session_id": "x", "hook_event_name": "UserPromptSubmit"], environment: [:])
        let sub = AgentHook.request(agent: "claude", event: ["session_id": "x", "hook_event_name": "SubagentStop"], environment: [:])
        let nameless = AgentHook.request(agent: "claude", event: ["hook_event_name": "Stop"], environment: [:])
        let stranger = AgentHook.request(agent: "cursor", event: ["session_id": "x", "hook_event_name": "Stop"], environment: [:])

        #expect(end?["verb"] as? String == "done")
        #expect(busy == nil)
        #expect(looping == nil)
        #expect(prompt == nil)
        #expect(sub == nil)
        #expect(nameless == nil)
        #expect(stranger == nil)
    }
}
