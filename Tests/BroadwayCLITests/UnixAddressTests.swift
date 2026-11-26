import Darwin
import Foundation
import Testing
@testable import BroadwayCLI

struct UnixAddressTests {
    @Test func aPathTooLongForASocketIsRefusedWithoutTheCall() {
        var called = false
        let result = UnixAddress.call(-1, String(repeating: "a", count: 200)) { _, _, _ in
            called = true
            return 0
        }
        #expect(result == nil)
        #expect(!called)
    }

    @Test func aSocketBoundAtAPathIsReachedAtTheSamePath() throws {
        let path = "/tmp/bw-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(server >= 0)
        defer { close(server) }
        #expect(UnixAddress.call(server, path, { bind($0, $1, $2) }) == 0)
        #expect(listen(server, 4) == 0)

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(client >= 0)
        defer { close(client) }

        #expect(UnixAddress.call(client, path, { Darwin.connect($0, $1, $2) }) == 0)
        #expect(!Link.blocked(path))
        let link = try #require(Link(path: path))
        close(link.fd)
        #expect(Link(path: path + ".missing") == nil)
    }
}
