import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class AgentNameTests {
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

    private func link(_ agent: [String: Any]) throws -> AgentLink {
        let found = try #require(socket.link(for: ["op": "call", "agent": agent], create: true))
        made.append(found.id)
        return found
    }

    @Test func aSessionIsHeadedByTheFolderItsAgentWorksIn() throws {
        let one = try link(["session": "claude:\(UUID())", "executable": "claude", "workdir": "/Users/me/Developer/garden"])
        let two = try link(["session": "claude:\(UUID())", "executable": "claude", "workdir": "/Users/me/Developer/garden"])

        #expect(one.title == "Claude Code · garden")
        #expect(two.title == "Claude Code · garden 2")
        #expect(AgentLinks.shared.row(one)["name"] as? String == "Claude Code · garden")
    }

    @Test func aNameFromBroadwayAgentNameWins() throws {
        let named = try link(["id": "nightly-\(UUID())", "name": "Nightly check", "named": true, "workdir": "/Users/me/garden"])

        #expect(named.title == "Nightly check")
    }

    @Test func anSSHSessionTakesAFolderOnlyWhenTheCommandGaveOne() throws {
        let plain = try link(["id": "ssh:192.0.2.40", "name": "SSH from 192.0.2.40"])
        let placed = try link(["id": "ssh:192.0.2.41", "name": "SSH from 192.0.2.41", "workdir": "/Users/me/garden"])

        #expect(plain.title == "SSH from 192.0.2.40")
        #expect(placed.title == "SSH from 192.0.2.41 · garden")
    }

    @Test func aQuestionCardAndItsNoticeSayWhichAgent() throws {
        let one = try link(["session": "claude:\(UUID())", "executable": "claude", "workdir": "/Users/me/Developer/garden"])
        var question = AgentQuestion(kind: .approval(.send), title: "Send on shop.example?")
        question.task = one.id

        #expect(question.cardWords.who == "Claude Code · garden")
        #expect(one.needsYouLine == "Claude Code in garden needs you")
    }

    @Test func theAgentsHeaderDropsTheFolderWhenItAsksSoItsWordsFit() throws {
        let one = try link(["session": "claude:\(UUID())", "executable": "claude", "workdir": "/Users/me/Developer/garden"])

        let voice = AgentsLayout.voice([AgentsLayout.said(one, .needsYou("Send on shop.example?"))])

        #expect(one.title == "Claude Code · garden")
        #expect(voice.title == "Claude Code needs you")
        #expect(voice.line == "Send on shop.example?")
        #expect(voice.attention)
    }
}
