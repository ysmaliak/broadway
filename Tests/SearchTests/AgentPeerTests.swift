import AppKit
import BroadwayCLI
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class AgentPeerTests {
    private let socket = AgentSocket()
    private let alive = AgentLinks.shared.alive
    private var made: [UUID] = []

    private let table: [Int32: AgentAncestor.Process] = [
        4000: .init(parent: 3000, name: "broadway", started: 40),
        3000: .init(parent: 2000, name: "zsh", started: 30),
        2000: .init(parent: 1000, name: "claude", started: 77),
        1000: .init(parent: 1, name: "Terminal", started: 10),
        5000: .init(parent: 4900, name: "sshd-session", started: 55),
        4900: .init(parent: 1, name: "sshd", started: 49),
        6000: .init(parent: 1, name: "ssh", started: 66),
        7000: .init(parent: 1, name: "socat", started: 70),
    ]

    init() {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    private func tearDown() {
        AgentLinks.shared.alive = alive
        for id in made {
            TaskLedger.shared.close(id)
            AgentLinks.shared.forget(id)
        }
    }

    private func trusted(_ said: [String: Any], peer: Int32) -> [String: Any] {
        AgentPeer.trusted(said, peer: peer) { self.table[$0] }
    }

    @Test func anAncestorAboveThePeerIsKept() {
        let said: [String: Any] = ["pid": 2000, "started": 77, "executable": "claude"]

        let out = trusted(said, peer: 4000)

        #expect(out["pid"] as? Int == 2000)
        #expect(out["remote"] == nil)
    }

    @Test func anAncestorNotAboveThePeerIsReplacedByTheWalkFromThePeer() {
        let said: [String: Any] = ["pid": 9999, "started": 1, "executable": "codex"]

        let out = trusted(said, peer: 4000)

        #expect(out["pid"] as? Int == 2000)
        #expect(out["started"] as? Int64 == 77)
        #expect(out["executable"] as? String == "claude")
    }

    @Test func aReusedProcessIdIsNotTrusted() {
        let said: [String: Any] = ["pid": 2000, "started": 78, "executable": "claude"]

        let out = trusted(said, peer: 4000)

        #expect(out["started"] as? Int64 == 77)
    }

    @Test func aRequestCarriedBySshKeepsItsSessionAndLosesItsProcess() {
        let said: [String: Any] = ["pid": 2000, "started": 77, "executable": "claude", "session": "claude:abc"]

        let out = trusted(said, peer: 5000)

        #expect(out["pid"] == nil)
        #expect(out["started"] == nil)
        #expect(out["remote"] as? Bool == true)
        #expect(out["session"] as? String == "claude:abc")
        #expect(out["id"] == nil)
    }

    @Test func withNoIdOrSessionTheCarrierIsTheOrigin() {
        let said: [String: Any] = ["pid": 2000, "started": 77, "executable": "claude", "host": "studio"]

        let out = trusted(said, peer: 6000)
        let plain = trusted(["host": "studio"], peer: 6000)

        #expect(out["id"] as? String == "ssh:via-6000-66")
        #expect(out["name"] as? String == "Claude Code")
        #expect(plain["name"] as? String == "SSH from studio")
    }

    @Test func anIdGivenByTheAgentWins() {
        let out = trusted(["id": "nightly", "pid": 2000, "started": 77], peer: 5000)

        #expect(out["id"] as? String == "nightly")
        #expect(out["pid"] == nil)
    }

    @Test func aProgramThatSaysItCameFromElsewhereIsTakenAtItsWord() {
        let out = trusted(["pid": 2000, "started": 77, "direct": false], peer: 7000)

        #expect(out["pid"] == nil)
        #expect(out["id"] as? String == "ssh:via-7000-70")
    }

    @Test func aForwardedSessionIsNotEndedForAProcessThisMacCannotSee() async throws {
        let said = trusted(["pid": 2000, "started": 77, "executable": "claude", "session": "claude:\(UUID())"], peer: 5000)
        let found = try #require(socket.link(for: ["op": "call", "agent": said], create: true))
        made.append(found.id)
        let carried = trusted(["pid": 2000, "started": 77, "executable": "claude"], peer: 6000)
        let first = try #require(socket.link(for: ["op": "call", "agent": carried], create: true))
        let again = try #require(socket.link(for: ["op": "call", "agent": carried], create: true))
        made.append(first.id)
        AgentLinks.shared.alive = { _, _ in false }

        AgentLinks.shared.sweep()

        #expect(AgentLinks.shared.link(found.id)?.live == true)
        #expect(AgentLinks.shared.link(found.id)?.process == nil)
        #expect(AgentLinks.shared.link(found.id)?.remote == true)
        #expect(AgentLooking.overSSH(found.id))
        #expect(first.id == again.id)
        #expect(AgentLinks.shared.link(first.id)?.live == true)
    }

    @Test func anMCPConnectionFromTheSameMachineTakesBackWhatItsLastConnectionLeft() throws {
        let rejoining = AgentLinks.shared.rejoining
        defer { AgentLinks.shared.rejoining = rejoining }
        var taken: (UUID, [UUID])?
        AgentLinks.shared.rejoining = { taken = ($0, $1) }
        let hello: [String: Any] = ["op": "mcp", "agent": ["id": "ssh:192.0.2.71", "name": "SSH from 192.0.2.71"]]
        let first = try #require(socket.link(for: hello, create: true, connection: UUID(), name: "Probe"))
        made.append(first.id)
        AgentLinks.shared.end(first.id, .done(nil))
        let other = try #require(socket.link(for: ["op": "mcp", "agent": ["id": "ssh:192.0.2.72"]], create: true, connection: UUID(), name: "Probe"))
        made.append(other.id)
        #expect(taken == nil)

        let again = try #require(socket.link(for: hello, create: true, connection: UUID(), name: "Probe"))
        made.append(again.id)

        #expect(again.id != first.id)
        #expect(taken?.0 == again.id)
        #expect(taken?.1 == [first.id])
        #expect(AgentLinks.shared.link(again.id)?.remote == true)
    }
}
