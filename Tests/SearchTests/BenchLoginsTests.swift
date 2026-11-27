import Foundation
import Testing
@testable import Search

@Suite
@MainActor
struct BenchLoginsTests {
    @Test func aLoginKeptWithAPortGivesItsPasswordBack() throws {
        let (kept, secret) = Bench.logins([
            ["host": "127.0.0.1", "port": 8080, "user": "sam@example.com", "password": "pw-sam-secret", "clear": true],
            ["host": "127.0.0.1", "port": 9090, "user": "sam@example.com", "password": "pw-other-secret", "clear": true],
        ])

        #expect(kept.map(\.port) == [8080, 9090])
        #expect(secret(kept[0])?.password == "pw-sam-secret")
        #expect(secret(kept[1])?.password == "pw-other-secret")
        #expect(secret(kept[0])?.port == 8080)
    }

    @Test func aLoginKeptWithoutAPortGivesItsPasswordBack() throws {
        let (kept, secret) = Bench.logins([["host": "example.com", "user": "lee@example.com", "password": "pw-lee-secret"]])

        #expect(secret(try #require(kept.first))?.password == "pw-lee-secret")
    }

    @Test func aLoginNeverKeptGivesNothing() {
        let (_, secret) = Bench.logins([["host": "example.com", "user": "lee@example.com", "password": "pw-lee-secret"]])

        #expect(secret(Kept(host: "example.com", user: "ana@example.com", used: nil)) == nil)
    }
}
