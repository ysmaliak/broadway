import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct DeveloperTests {
    @Test func localServers() {
        let local = ["http://localhost:3000/", "http://127.0.0.1:8080/", "https://shop.test/", "http://app.localhost:5173/x"]
        let remote = ["https://example.com/", "http://test.example.com:3000/", "file:///tmp/a.html"]

        let found = local.map { LocalServer.isLocal(URL(string: $0)) }
        let refused = remote.map { LocalServer.isLocal(URL(string: $0)) }

        #expect(found == [true, true, true, true])
        #expect(refused == [false, false, false])
    }

    @Test func portShowsOnlyOnLocalPages() {
        let local = URL(string: "http://localhost:3000/a")
        let remote = URL(string: "https://example.com:8443/a")

        let port = LocalServer.port(local)
        let none = LocalServer.port(remote)

        #expect(port == 3000)
        #expect(none == nil)
    }

    @Test func serverKeyIsHostAndPort() {
        let url = URL(string: "http://LocalHost:3000/some/path?q=1")

        let key = LocalServer.key(url)

        #expect(key == "localhost:3000")
    }

    @Test func parseRefusesUnknownKinds() {
        let raw: [String: Any] = ["kind": "nonsense", "message": "x"]

        let entry = DevEntry.parse(raw)

        #expect(entry == nil)
    }

    @Test func parseCapsWhatThePageSends() {
        let raw: [String: Any] = ["kind": "error", "message": String(repeating: "x", count: 100_000)]

        let entry = DevEntry.parse(raw)

        #expect(entry?.message.count == 4000)
    }

    @Test func failedRequests() {
        var fine = DevEntry(kind: .request)
        fine.status = 200
        var missing = DevEntry(kind: .request)
        missing.status = 404
        var refused = DevEntry(kind: .request)
        refused.status = 0

        let failed = [fine, missing, refused].map(\.failed)

        #expect(failed == [false, true, true])
    }

    @Test func agentCopyDropsSecrets() {
        var entry = DevEntry(kind: .request)
        entry.method = "POST"
        entry.url = "http://localhost:3000/api?token=abc123&page=2"
        entry.status = 500
        entry.milliseconds = 12
        entry.headers = ["Authorization": "Bearer abc.def", "Content-Type": "application/json"]
        entry.body = "{\"jwt\":\"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl\"}"

        let text = DevCopy.agent(entry, page: "http://localhost:3000/")

        #expect(text.contains("POST http://localhost:3000/api?token=[removed]&page=2 returned 500 in 12 ms"))
        #expect(text.contains("Content-Type: application/json"))
        #expect(!text.contains("Authorization"))
        #expect(!text.contains("abc123"))
        #expect(!text.contains("eyJhbGci"))
    }

    @Test func agentCopyOfAnError() {
        var entry = DevEntry(kind: .error)
        entry.message = "x is not a function"
        entry.source = "http://localhost:3000/app.js"
        entry.line = 12
        entry.column = 5
        entry.stack = "secret stack"

        let text = DevCopy.agent(entry, page: "http://localhost:3000/")

        #expect(text.hasPrefix("Error: x is not a function"))
        #expect(text.contains("At: http://localhost:3000/app.js:12:5"))
        #expect(!text.contains("secret stack"))
    }

    @Test func curl() {
        var entry = DevEntry(kind: .request)
        entry.method = "POST"
        entry.url = "http://localhost:3000/a"
        entry.headers = ["X-One": "it's"]
        entry.body = "a=1"

        let text = DevCopy.curl(entry)

        #expect(text == #"curl 'http://localhost:3000/a' -X POST -H 'X-One: it'\''s' --data-raw 'a=1'"#)
    }

    @MainActor
    @Test func logKeepsTheNewest() {
        let log = DevLog()

        for index in 0..<(DevLog.cap + 5) {
            var entry = DevEntry(kind: .error)
            entry.message = "\(index)"
            log.add(entry)
        }

        #expect(log.entries.count == DevLog.cap)
        #expect(log.entries.first?.message == "5")
        #expect(log.errorCount == DevLog.cap)
    }
}
