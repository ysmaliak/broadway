import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class AgentSSHSessionTests {
    private let socket = AgentSocket()

    init() {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    private func tearDown() {
        for link in AgentLinks.shared.links where link.name.hasPrefix("SSH from 192.0.2.") {
            TaskLedger.shared.close(link.id)
            AgentLinks.shared.forget(link.id)
        }
    }

    private func request(_ address: String) -> [String: Any] {
        ["op": "call", "agent": ["id": "ssh:\(address)", "name": "SSH from \(address)"]]
    }

    @Test func oneMachineIsOneSessionThatLeavesTheListOnceItEndsIdle() async throws {
        let first = try #require(socket.link(for: request("192.0.2.7"), create: true))
        let again = try #require(socket.link(for: request("192.0.2.7"), create: true))
        let other = try #require(socket.link(for: request("192.0.2.8"), create: true))
        let later = Date().addingTimeInterval(AgentLinks.shared.idleLimit + 60)

        #expect(first.id == again.id)
        #expect(other.id != first.id)
        #expect(first.name == "SSH from 192.0.2.7")
        #expect(first.process == nil)
        #expect(AgentLinks.shared.links.filter { $0.name == "SSH from 192.0.2.7" }.count == 1)

        await AgentLinks.sweepAll(at: later)

        #expect(!AgentLinks.shared.links.contains { $0.id == first.id })
        #expect(!AgentLinks.shared.links.contains { $0.id == other.id })
    }
}
