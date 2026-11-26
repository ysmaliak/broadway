import Darwin
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(2)))
@MainActor
final class LineConnectionTests {
    private var ends: [Int32] = []
    private let limit = LineConnection.stallLimit

    init() {
        addTeardownBlock { self.tearDown() }
    }

    private func tearDown() {
        LineConnection.stallLimit = limit
        for end in ends { Darwin.close(end) }
    }

    private func pair() throws -> (LineConnection, Int32) {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
        ends.append(fds[1])
        return (LineConnection(fd: fds[0]), fds[1])
    }

    @Test func aBigAnswerToAClientNotYetReadingReturnsAtOnceAndArrivesWhole() async throws {
        let (connection, fd) = try pair()
        let text = String(repeating: "a", count: 3_000_000)

        let started = Date()
        connection.send(["text": text])
        connection.close()
        let took = Date().timeIntervalSince(started)
        var got = Data()
        for _ in 0..<2000 where got.last != 0x0A {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 { got.append(contentsOf: chunk[0..<count]) } else { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let answer = try JSONSerialization.jsonObject(with: got.dropLast()) as? [String: Any]

        #expect(took < 1)
        #expect(answer?["text"] as? String == text)
    }

    @Test func aClientWhoseAnswerStopsMovingIsDropped() async throws {
        LineConnection.stallLimit = 0.2
        let (connection, _) = try pair()
        var closed = false
        connection.onClose = { closed = true }

        connection.send(["text": String(repeating: "a", count: 3_000_000)])
        let waiting = connection.waiting
        for _ in 0..<300 where !closed { try? await Task.sleep(for: .milliseconds(10)) }

        #expect(waiting > 0)
        #expect(closed)
        #expect(connection.waiting == 0)
    }
}
