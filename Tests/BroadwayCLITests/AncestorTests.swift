import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(5)))
struct AncestorTests {
    private let table: [Int32: AgentAncestor.Process] = [
        900: .init(parent: 800, name: "zsh", started: 9),
        800: .init(parent: 700, name: "claude", started: 8),
        700: .init(parent: 600, name: "-fish", started: 7),
        600: .init(parent: 1, name: "Rex", started: 6),
        500: .init(parent: 400, name: "bash", started: 5),
        400: .init(parent: 300, name: "node", started: 4),
        300: .init(parent: 1, name: "codex", started: 3),
        200: .init(parent: 100, name: "env", started: 2),
        100: .init(parent: 1, name: "python3", started: 1)
    ]

    @Test func shellsArePassedOverToTheAgent() {
        let start: Int32 = 900

        let found = AgentAncestor.find(from: start) { table[$0] }

        #expect(found == AgentAncestor(pid: 800, started: 8, name: "claude"))
    }

    @Test func nodeUnderAnAgentIsPassedOver() {
        let start: Int32 = 500

        let found = AgentAncestor.find(from: start) { table[$0] }

        #expect(found?.name == "codex")
    }

    @Test func aScriptIsItsOwnAgent() {
        let start: Int32 = 200

        let found = AgentAncestor.find(from: start) { table[$0] }

        #expect(found?.pid == 100)
    }

    @Test func aLoopOrAMissingProcessEndsTheWalk() {
        let looping: [Int32: AgentAncestor.Process] = [10: .init(parent: 11, name: "sh", started: 0), 11: .init(parent: 10, name: "zsh", started: 0)]

        let found = AgentAncestor.find(from: 10) { looping[$0] }
        let missing = AgentAncestor.find(from: 77) { _ in nil }

        #expect(found == nil)
        #expect(missing == nil)
    }

    @Test func thisProcessHasAnAncestor() {
        let me = getpid()

        let found = AgentAncestor.process(me)

        #expect(found != nil)
        #expect((found?.started ?? 0) > 0)
    }

    @Test func theAgentsOwnWorkingFolderGoesWithTheRequest() {
        let claude = AgentAncestor(pid: 800, started: 8, name: "claude")

        let said = AgentAncestor.request(environment: [:], name: nil, agent: nil, walk: { claude },
                                         workdir: { $0 == 800 ? "/Users/me/Developer/garden" : nil },
                                         cwd: "/Users/me/Developer/garden/Sources", home: "/Users/me")
        let lost = AgentAncestor.request(environment: [:], name: nil, agent: nil, walk: { claude }, workdir: { _ in nil },
                                         cwd: "/Users/me/Developer/garden/Sources", home: "/Users/me")

        #expect(said["workdir"] as? String == "/Users/me/Developer/garden")
        #expect(said["named"] == nil)
        #expect(lost["workdir"] as? String == "/Users/me/Developer/garden/Sources")
    }

    @Test func overSSHTheLoginsHomeFolderNamesNothing() {
        let environment = ["SSH_CONNECTION": "192.0.2.4 50000 192.0.2.5 22"]

        let home = AgentAncestor.request(environment: environment, name: nil, agent: nil, walk: { nil }, workdir: { _ in nil },
                                         cwd: "/Users/me", home: "/Users/me")
        let moved = AgentAncestor.request(environment: environment, name: nil, agent: nil, walk: { nil }, workdir: { _ in nil },
                                          cwd: "/Users/me/garden", home: "/Users/me")

        #expect(home["id"] as? String == "ssh:192.0.2.4")
        #expect(home["workdir"] == nil)
        #expect(moved["workdir"] as? String == "/Users/me/garden")
    }

    @Test func aNameTheAgentGaveIsMarkedAsGiven() {
        let said = AgentAncestor.request(environment: ["BROADWAY_AGENT_NAME": "Reviewer"], name: nil, agent: nil, walk: { nil })

        #expect(said["named"] as? Bool == true)
    }

    @Test func aNamedSessionWinsOverTheProcess() {
        let environment = ["BROADWAY_AGENT": "abc123", "BROADWAY_AGENT_NAME": "Nightly"]

        let said = AgentAncestor.request(environment: environment, name: nil, agent: nil)

        #expect((said["id"] as? String) == "abc123")
        #expect((said["name"] as? String) == "Nightly")
        #expect(said["pid"] == nil)
    }

    @Test func theAgentsOwnSessionIdKeysTheShellAndTheMCPTogether() {
        let claude = AgentAncestor.request(environment: ["CLAUDE_CODE_SESSION_ID": "5f0c2a"], name: nil, agent: nil)
        let codex = AgentAncestor.request(environment: ["CODEX_THREAD_ID": "t-77"], name: nil, agent: nil)
        let named = AgentAncestor.request(environment: ["CLAUDE_CODE_SESSION_ID": "5f0c2a", "BROADWAY_AGENT": "abc123"], name: nil, agent: nil)

        #expect(claude["session"] as? String == "claude:5f0c2a")
        #expect(codex["session"] as? String == "codex:t-77")
        #expect(named["session"] == nil)
        #expect(named["id"] as? String == "abc123")
    }

    @Test func anAgentIsNamedFromItsOwnFirstArgumentNotItsVersionedFile() {
        let claude = (arguments: ["claude", "--resume"], path: "/Users/me/.local/share/claude/versions/2.1.317", command: "2.1.317")

        let named = AgentAncestor.named(arguments: claude.arguments, path: claude.path, command: claude.command)

        #expect(named == "claude")
    }

    @Test func aScriptRunByNodeIsNamedForTheAgentItRuns() {
        let claude = ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]
        let codex = ["node", "--no-warnings", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"]
        let other = ["node", "server.js"]

        let names = [claude, codex, other].map { AgentAncestor.named(arguments: $0, path: "/usr/local/bin/node", command: "node") }

        #expect(names == ["claude", "codex", "node"])
    }

    @Test func geminiAndOpencodeRunByAnInterpreterAreNamedForThemselves() {
        let gemini = ["node", "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"]
        let opencode = ["bun", "/Users/me/.opencode/bin/opencode"]

        let names = [gemini, opencode].map { AgentAncestor.named(arguments: $0, path: nil, command: $0[0]) }

        #expect(names == ["gemini", "opencode"])
        #expect(AgentAncestor.isAgent("gemini") && AgentAncestor.isAgent("opencode"))
    }

    @Test func withoutArgumentsThePathThenTheCommandNameIt() {
        let path = "/Users/me/.codex/packages/bin/codex-code-mode-host"

        let fromPath = AgentAncestor.named(arguments: [], path: path, command: "codex-code-mode-")
        let fromCommand = AgentAncestor.named(arguments: [], path: nil, command: "python3")

        #expect(fromPath == "codex-code-mode-host")
        #expect(fromCommand == "python3")
    }

    @Test func theKernelsArgumentBlockIsReadPastTheExecutablePath() {
        var raw = withUnsafeBytes(of: Int32(2)) { Array($0) }
        raw += Array("/Users/me/.local/share/claude/versions/2.1.317".utf8) + [0, 0, 0]
        raw += Array("claude".utf8) + [0] + Array("--print".utf8) + [0] + Array("PATH=/bin".utf8) + [0]

        let found = AgentAncestor.parse(raw)

        #expect(found == ["claude", "--print"])
    }

    @Test func thisProcessReadsItsOwnArguments() {
        let me = getpid()

        let found = AgentAncestor.arguments(me)

        #expect(!found.isEmpty)
    }

    @Test func theFolderIsTheGitRootAboveTheWorkingDirectory() {
        let marks: [String: AgentAncestor.GitMark] = [
            "/Users/sam/Projects/personal/broadway/broadway-mac": .folder,
            "/Users/sam/Projects/personal/broadway/broadway-mac/.claude/worktrees/agent-space":
                .file("gitdir: /Users/sam/Projects/personal/broadway/broadway-mac/.git/worktrees/agent-space\n"),
            "/Users/sam/code/app/vendor/lib": .file("gitdir: ../../.git/modules/lib"),
        ]
        let look: (String) -> AgentAncestor.GitMark? = { marks[$0] }

        let inside = AgentAncestor.project(from: "/Users/sam/Projects/personal/broadway/broadway-mac/Sources/Search", look: look)
        let worktree = AgentAncestor.project(from: "/Users/sam/Projects/personal/broadway/broadway-mac/.claude/worktrees/agent-space/Tests", look: look)
        let submodule = AgentAncestor.project(from: "/Users/sam/code/app/vendor/lib/src", look: look)
        let loose = AgentAncestor.project(from: "/Users/sam/Downloads/notes", look: look)

        #expect(inside == "/Users/sam/Projects/personal/broadway/broadway-mac")
        #expect(worktree == "/Users/sam/Projects/personal/broadway/broadway-mac")
        #expect(submodule == "/Users/sam/code/app/vendor/lib")
        #expect(loose == "/Users/sam/Downloads/notes")
    }

    @Test func theRequestCarriesTheFolderAndAnySpaceAsked() {
        let look: (String) -> AgentAncestor.GitMark? = { $0 == "/Users/sam/work/app" ? .folder : nil }

        let said = AgentAncestor.place(environment: ["BROADWAY_SPACE": " Work "], cwd: "/Users/sam/work/app/./src/", look: look)
        let plain = AgentAncestor.place(environment: ["BROADWAY_SPACE": ""], cwd: "/tmp/x", look: { _ in nil })

        #expect(said["cwd"] as? String == "/Users/sam/work/app/src")
        #expect(said["folder"] as? String == "/Users/sam/work/app")
        #expect(said["space"] as? String == "Work")
        #expect(plain["space"] == nil)
        #expect(plain["folder"] as? String == "/tmp/x")
    }

    @Test func aNamedSessionStillSaysWhereItWorks() {
        let said = AgentAncestor.request(environment: ["BROADWAY_AGENT": "abc123", "BROADWAY_SPACE": "Home"], name: nil, agent: nil)

        #expect(said["id"] as? String == "abc123")
        #expect(said["space"] as? String == "Home")
        #expect(said["folder"] is String)
    }

    private let ssh = "192.0.2.41 56064 192.0.2.7 22"

    private let overSSH: [Int32: AgentAncestor.Process] = [
        91024: .init(parent: 91022, name: "fish", started: 4),
        91022: .init(parent: 91019, name: "sshd-session: sam@notty", started: 3),
        91019: .init(parent: 1, name: "sshd-session: sam [priv]", started: 2),
        81024: .init(parent: 81022, name: "-fish", started: 4),
        81022: .init(parent: 81019, name: "sshd-session: sam@ttys000", started: 3),
        81019: .init(parent: 1, name: "sshd-session: sam [priv]", started: 2),
        71485: .init(parent: 71484, name: "sh", started: 4),
        71484: .init(parent: 71483, name: "login", started: 3),
        71483: .init(parent: 1, name: "SCREEN", started: 2),
        61001: .init(parent: 61000, name: "zsh", started: 3),
        61000: .init(parent: 1, name: AgentAncestor.named(arguments: ["tmux: server (/private/tmp/tmux-501/default)"], path: "tmux", command: "tmux"), started: 2),
        51001: .init(parent: 51000, name: "zsh", started: 4),
        51000: .init(parent: 50999, name: "claude", started: 3),
        50999: .init(parent: 91022, name: "-fish", started: 2),
    ]

    private func walk(from start: Int32) -> () -> AgentAncestor? {
        { AgentAncestor.find(from: start) { self.overSSH[$0] } }
    }

    @Test func aCommandOverSSHIsKeyedByTheAddressItCameFrom() {
        let plain = AgentAncestor.request(environment: ["SSH_CONNECTION": ssh], name: nil, agent: nil, walk: walk(from: 91024))
        let terminal = AgentAncestor.request(environment: ["SSH_CONNECTION": "192.0.2.41 56068 192.0.2.7 22"], name: nil, agent: nil, walk: walk(from: 81024))

        #expect(AgentAncestor.find(from: 91024) { overSSH[$0] }?.name == "sshd-session: sam@notty")
        #expect(plain["id"] as? String == "ssh:192.0.2.41")
        #expect(plain["name"] as? String == "SSH from 192.0.2.41")
        #expect(plain["pid"] == nil)
        #expect(plain["executable"] == nil)
        #expect(terminal["id"] as? String == plain["id"] as? String)
    }

    @Test func aNamedAgentOverSSHStillWins() {
        let environment = ["SSH_CONNECTION": ssh, "BROADWAY_AGENT": "one", "BROADWAY_AGENT_NAME": "Nightly"]

        let said = AgentAncestor.request(environment: environment, name: nil, agent: nil, walk: walk(from: 91024))
        let named = AgentAncestor.request(environment: ["SSH_CONNECTION": ssh, "BROADWAY_AGENT_NAME": "Reviewer"], name: nil, agent: nil, walk: walk(from: 91024))

        #expect(said["id"] as? String == "one")
        #expect(said["name"] as? String == "Nightly")
        #expect(named["id"] as? String == "ssh:192.0.2.41/reviewer")
        #expect(named["name"] as? String == "Reviewer")
    }

    @Test func anAgentRunningInsideAnSSHLoginIsStillThatAgent() {
        let said = AgentAncestor.request(environment: ["SSH_CONNECTION": ssh], name: nil, agent: nil, walk: walk(from: 51001))
        let session = AgentAncestor.request(environment: ["SSH_CONNECTION": ssh, "CLAUDE_CODE_SESSION_ID": "5f0c2a"], name: nil, agent: nil, walk: walk(from: 51001))

        #expect(said["id"] == nil)
        #expect(said["pid"] as? Int == 51000)
        #expect(said["executable"] as? String == "claude")
        #expect(session["session"] as? String == "claude:5f0c2a")
        #expect(session["id"] == nil)
    }

    @Test func screenAndTmuxArePassedOverAndTheirSSHAddressKeysTheSession() {
        let screen = AgentAncestor.request(environment: ["SSH_CONNECTION": ssh], name: nil, agent: nil, walk: walk(from: 71485))
        let tmux = AgentAncestor.request(environment: ["SSH_CONNECTION": ssh], name: nil, agent: nil, walk: walk(from: 61001))
        let local = AgentAncestor.request(environment: [:], name: nil, agent: nil, walk: walk(from: 61001))

        #expect(AgentAncestor.named(arguments: ["tmux: server (/private/tmp/tmux-501/default)"], path: "tmux", command: "tmux") == "tmux")
        #expect(AgentAncestor.named(arguments: ["sshd-session: sam@notty"], path: "sshd-session", command: "sshd-session") == "sshd-session")
        #expect(AgentAncestor.find(from: 61001) { overSSH[$0] } == nil)
        #expect(screen["id"] as? String == "ssh:192.0.2.41")
        #expect(tmux["id"] as? String == "ssh:192.0.2.41")
        #expect(local["id"] == nil)
        #expect(local["pid"] == nil)
    }

    @Test func launchersThatEndTheWalkAreNamedPlainly() {
        let mosh = AgentAncestor(pid: 40, started: 1, name: "mosh-server")
        let sshd = AgentAncestor(pid: 41, started: 1, name: "sshd: sam@notty")
        let et = AgentAncestor(pid: 42, started: 1, name: "etterminal")
        let cron = AgentAncestor(pid: 43, started: 1, name: "cron")

        let moshed = AgentAncestor.request(environment: ["SSH_CONNECTION": ssh], name: nil, agent: nil, walk: { mosh })
        let loose = AgentAncestor.request(environment: [:], name: nil, agent: nil, walk: { sshd })
        let eternal = AgentAncestor.request(environment: [:], name: nil, agent: nil, walk: { et })
        let timed = AgentAncestor.request(environment: [:], name: nil, agent: nil, walk: { cron })

        #expect(moshed["name"] as? String == "Mosh from 192.0.2.41")
        #expect(loose["executable"] as? String == "SSH")
        #expect(eternal["executable"] as? String == "Eternal Terminal")
        #expect(timed["executable"] as? String == "cron")
    }

    @Test func anAppWhoseFirstWordIsAShellIsStillFound() {
        let apps: [Int32: AgentAncestor.Process] = [
            31: .init(parent: 30, name: "zsh", started: 2),
            30: .init(parent: 1, name: "Script Editor", started: 1),
        ]

        let found = AgentAncestor.find(from: 31) { apps[$0] }

        #expect(found?.name == "Script Editor")
    }

    @Test func aRequestOverAForwardedSocketCarriesNoProcessAndSaysSo() {
        let said: [String: Any] = ["pid": 800, "started": 8, "executable": "claude", "session": "claude:x"]

        let out = AgentAncestor.forwarded(said, host: "studio")

        #expect(out["pid"] == nil)
        #expect(out["started"] == nil)
        #expect(out["direct"] as? Bool == false)
        #expect(out["host"] as? String == "studio")
        #expect(out["executable"] as? String == "claude")
        #expect(out["session"] as? String == "claude:x")
    }

    @Test func sshAndItsServerCarryAForwardedSocket() {
        #expect(AgentAncestor.carrier("ssh"))
        #expect(AgentAncestor.carrier("sshd-session: me@notty"))
        #expect(!AgentAncestor.carrier("broadway"))
    }
}
