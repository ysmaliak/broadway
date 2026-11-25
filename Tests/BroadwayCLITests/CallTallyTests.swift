import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(5)))
struct CallTallyTests {
    @Test func callsAndFailuresAreCountedByCommandAndCode() {
        var tally = CallTally()

        tally.add("click", failed: nil)
        tally.add("click", failed: "not_found")
        tally.add("click", failed: "not_found")
        tally.add("scroll", failed: "usage")
        tally.add("logins list", failed: "person_only")

        #expect(tally.rows["click"] == CallTally.Row(calls: 3, codes: ["not_found": 2]))
        #expect(tally.rows["scroll"]?.failed == 1)
        #expect(tally.rows["logins list"]?.codes == ["person_only": 1])
        #expect(tally.sorted.map(\.command) == ["click", "logins list", "scroll"])
    }

    @Test func wordsThatCouldBeAnAddressOrPageTextBecomeOther() {
        var tally = CallTally()

        tally.add("https://bank.example/account?id=4", failed: "unknown_command")
        tally.add("Type my password hunter2", failed: "usage")
        tally.add("go", failed: "The page at https://bank.example said no")

        #expect(Set(tally.rows.keys) == ["other", "go"])
        #expect(tally.rows["other"]?.calls == 2)
        #expect(tally.rows["go"]?.codes == ["other": 1])
        let written = String(decoding: tally.data, as: UTF8.self)
        #expect(!written.contains("bank") && !written.contains("hunter2") && !written.contains("://"))
    }

    @Test func theCountStaysSmall() {
        var tally = CallTally()

        let letters = { (n: Int) in String([Character(UnicodeScalar(97 + n % 26)!), Character(UnicodeScalar(97 + (n / 26) % 26)!)]) }
        for n in 0..<(CallTally.commandLimit + 50) { tally.add("command " + letters(n), failed: nil) }
        var codes = CallTally()
        for n in 0..<(CallTally.codeLimit + 10) { codes.add("click", failed: "code_" + letters(n)) }

        #expect(tally.rows.count == CallTally.commandLimit + 1)
        #expect(tally.rows["other"]?.calls == 50)
        #expect(codes.rows["click"]?.codes.count == CallTally.codeLimit + 1)
        #expect(codes.rows["click"]?.codes["other"] == 10)
        #expect(tally.data.count < 64 * 1024)
    }

    @Test func aWrittenCountReadsBackTheSame() throws {
        var tally = CallTally()
        let began = Date(timeIntervalSince1970: 1_790_000_000)
        tally.add("click", failed: "stale_ref", at: began)
        tally.add("read", failed: nil, at: began.addingTimeInterval(60))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tally-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try tally.data.write(to: file)

        let read = CallTally.read(file)

        #expect(read == tally)
        #expect(read.since == began)
        #expect(CallTally.read(file.appendingPathExtension("gone")) == CallTally())
        #expect(CallTally(data: Data("not json".utf8)) == CallTally())
    }

    @Test func theTableAndTheJSONSayTheSame() throws {
        var tally = CallTally()
        tally.add("click", failed: "not_found")
        tally.add("click", failed: nil)
        tally.add("read", failed: nil)

        let lines = tally.lines()
        let object = tally.object

        #expect(lines.contains { $0.hasPrefix("command") && $0.contains("calls") && $0.contains("failed") })
        #expect(lines.contains { $0.hasPrefix("click") && $0.contains("not_found 1") })
        let commands = try #require(object["commands"] as? [[String: Any]])
        #expect(commands.first?["command"] as? String == "click")
        #expect(commands.first?["failed"] as? Int == 1)
        #expect(commands.first?["calls"] as? Int == 2)
        #expect(object["since"] is String)
        #expect(CallTally().lines() == ["No agent calls are counted yet"])
    }

    @Test func theFileSitsBesideTheSocket() {
        #expect(CallTally.file(socket: "/tmp/w/broadway.sock").path == "/tmp/w/agent-calls.json")
    }
}
