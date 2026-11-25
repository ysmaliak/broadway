import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class AgentSignerTests {
    private let socket = AgentSocket()
    private var made: [UUID] = []

    init() {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    private func tearDown() {
        for id in made {
            TaskLedger.shared.close(id)
            AgentLinks.shared.forget(id)
        }
    }

    private func team(_ word: String) -> String {
        AgentSigner.vendors.first { $0.word == word }?.team ?? ""
    }

    private func facts(_ executable: String, team: String? = nil, signer: String? = nil, apple: Bool = false, valid: Bool = true) -> AgentCodeFacts {
        AgentCodeFacts(executable: executable, valid: valid, apple: apple, team: team, signer: signer)
    }

    @Test func claudeCodeSignedByAnthropicSaysSo() {
        let program = AgentSigner.judge(facts("2.1.331", team: team("claude"), signer: "Anthropic PBC"), told: "claude")

        #expect(program == .developer("Anthropic PBC"))
        #expect(program.line(name: "Claude Code") == "Claude Code, signed by Anthropic PBC")
        #expect(program.detail == "Signed by Anthropic PBC")
    }

    @Test func codexSignedByOpenAISaysSo() {
        let program = AgentSigner.judge(facts("codex", team: team("codex"), signer: "OpenAI OpCo, LLC"), told: "codex")

        #expect(program.line(name: "Codex") == "Codex, signed by OpenAI OpCo, LLC")
    }

    @Test func aProgramThatCallsItselfClaudeButIsNotSignedIsNamedPlainly() {
        let program = AgentSigner.judge(facts("claude"), told: "claude")

        #expect(program == .claims("Claude Code", signer: nil))
        #expect(program.line(name: "Claude Code") == "Calls itself Claude Code, not signed")
    }

    @Test func aProgramThatCallsItselfCodexSignedBySomeoneElseNamesTheSigner() {
        let program = AgentSigner.judge(facts("codex", team: "ABCDE12345", signer: "Someone Else Ltd"), told: "codex")

        #expect(program.line(name: "Codex") == "Calls itself Codex, signed by Someone Else Ltd")
    }

    @Test func aBrokenSignatureWithTheRightTeamIsNotTrusted() {
        let program = AgentSigner.judge(facts("claude", team: team("claude"), signer: "Anthropic PBC", valid: false), told: "claude")

        #expect(program.line(name: "Claude Code") == "Calls itself Claude Code, not signed")
    }

    @Test func anAgentRunByAnInterpreterShowsNoSigner() {
        let node = AgentSigner.judge(facts("node"), told: "claude")
        let python = AgentSigner.judge(facts("python3.12", apple: true), told: "python3")
        let framework = AgentSigner.judge(facts("Python", apple: true), told: "aider")

        #expect(node == .interpreter)
        #expect(node.line(name: "Claude Code") == nil)
        #expect(python == .interpreter)
        #expect(framework == .interpreter)
    }

    @Test func aSystemProgramIsSignedByApple() {
        let program = AgentSigner.judge(facts("Terminal", apple: true), told: "Terminal")

        #expect(program.line(name: "Terminal") == "Terminal, signed by Apple")
    }

    @Test func anUnknownProgramWithNoTeamIsNotSigned() {
        let program = AgentSigner.judge(facts("myscript"), told: "myscript")

        #expect(program.line(name: "Myscript") == "Myscript, not signed")
    }

    @Test func anotherMachineHasNoSignatureToRead() {
        #expect(AgentSigner.elsewhere.line(name: "Claude Code") == "From another machine over ssh")
    }

    @Test func theSignerIsTheCertificatesOrganisation() {
        #expect(AgentSigner.organisation("Developer ID Application: Example Co (ABCDE12345)") == "Example Co")
        #expect(AgentSigner.organisation("Developer ID Application: Example Co, LLC (ABCDE12345)") == "Example Co, LLC")
    }

    @Test func aRunningSystemProgramIsReadThroughItsAuditToken() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["20"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let pid = sleeper.processIdentifier
        let started = try #require(AgentProcess.startTime(pid))

        let found = try #require(AgentSigner.read(pid: pid, started: started))
        let stale = AgentSigner.read(pid: pid, started: started + 1)

        #expect(found.apple)
        #expect(found.executable == "sleep")
        #expect(AgentSigner.judge(found, told: "sleep") == .apple)
        #expect(stale == nil)
    }

    @Test func theFirstQuestionOfASessionShowsItsSigner() throws {
        let found = try #require(socket.link(for: ["op": "call", "agent": ["session": "claude:\(UUID())", "executable": "claude", "workdir": "/Users/me/garden"]], create: true))
        made.append(found.id)
        AgentLinks.shared.sign(found.id, .developer("Anthropic PBC"))
        var first = AgentQuestion(kind: .approval(.send), title: "Send on shop.example?")
        first.task = found.id
        var second = AgentQuestion(kind: .approval(.send), title: "Send again?")
        second.task = found.id

        AgentLinks.shared.asked(found.id, question: first.id)
        AgentLinks.shared.asked(found.id, question: second.id)

        #expect(first.cardWords.signer == "Claude Code, signed by Anthropic PBC")
        #expect(first.cardWords.who == "Claude Code · garden")
        #expect(second.cardWords.signer == "")
        #expect(AgentLinks.shared.link(found.id).map(AgentLinks.shared.row)?["program"] as? String == "Claude Code, signed by Anthropic PBC")
    }

    @Test func aSessionFromAnotherMachineSaysSoOnItsCard() throws {
        let found = try #require(socket.link(for: ["op": "call", "agent": ["id": "ssh:192.0.2.90", "name": "SSH from 192.0.2.90"]], create: true))
        made.append(found.id)
        var question = AgentQuestion(kind: .choice(["One", "Two"]), title: "Which?")
        question.task = found.id
        question.asker = found.title

        AgentLinks.shared.asked(found.id, question: question.id)

        #expect(question.cardWords.signer == "From another machine over ssh")
        #expect(AgentLinks.shared.link(found.id)?.program == .elsewhere)
    }
}
