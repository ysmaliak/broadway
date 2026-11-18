import BroadwayCLI
import Foundation
import Testing
@testable import Search

@MainActor
@Suite(.timeLimit(.minutes(5)))
struct FailureLogTests {
    private static let host = "files.example.test"
    private static let address = "https://\(host)/reports/2026/report.zip?token=abc"
    private static let path = "/Users/sam/Downloads/report.zip"

    private let folder: URL
    private let log: FailureLog

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("failure-log-\(UUID().uuidString)")
        log = FailureLog(folder: folder)
    }

    private func row(_ line: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func written(_ kind: String, _ fields: [String: String], private secret: Bool = false) -> [String] {
        DownloadTrace.write(kind, fields, private: secret, to: log)
        DownloadTrace.settle()
        return log.lines()
    }

    private func clean(_ line: String) -> Bool {
        !line.contains("://") && line.range(of: #"/[A-Za-z]"#, options: .regularExpression) == nil
            && !line.contains(Self.host) && !line.contains("report") && !line.contains("sam")
    }

    @Test func aFailureIsWrittenWithoutItsAddressPathOrDescription() throws {
        let description = "The file “report.zip” couldn’t be saved in \(Self.path) from \(Self.address)"

        let lines = written("failed", ["url": Self.address, "file": Self.path, "suggested": "report.zip", "error": description,
                                       "domain": "NSURLErrorDomain", "code": "-1009"])

        let only = try #require(lines.first)
        #expect(lines.count == 1)
        #expect(clean(only))
        let found = try row(only)
        #expect(Set(found.keys) == ["kind", "time", "domain", "code"])
        #expect(found["kind"] as? String == "failed")
        #expect(found["domain"] as? String == "NSURLErrorDomain")
        #expect(found["code"] as? Int == -1009)
    }

    @Test func onlyTheKindTheVerdictTheErrorAndTheYesOrNoFlagsAreKept() throws {
        let fields = ["verdict": "tab-under-file", "clicked": "true", "view": "false", "main": "true", "held": "false", "listed": "true",
                      "type": "application/zip", "list": "content-blockers", "name": "report.zip", "site": Self.host, "kind": "window"]

        let found = try row(try #require(FailureLog.entry("window", fields, at: Date())))

        #expect(Set(found.keys) == ["kind", "time", "verdict", "clicked", "view", "main", "held", "listed"])
        #expect(found["verdict"] as? String == "tab-under-file")
        #expect(found["clicked"] as? Bool == true)
        #expect(found["view"] as? Bool == false)
    }

    @Test func aValueOutsideItsFixedSetIsDroppedOrNamedOther() throws {
        let fields = ["verdict": Self.address, "domain": "com.example.files", "code": "lost at \(Self.host)", "held": "maybe"]

        let found = try row(try #require(FailureLog.entry(Self.address, fields, at: Date())))

        #expect(found["kind"] as? String == "other")
        #expect(found["domain"] as? String == "other")
        #expect(found["verdict"] == nil)
        #expect(found["code"] == nil)
        #expect(found["held"] == nil)
    }

    @Test func everyKindTheBrowserSendsIsWrittenWithNoAddressOrPath() throws {
        let fields = ["url": Self.address, "file": Self.path, "suggested": "report.zip", "type": "application/zip", "list": Self.host,
                      "error": "Could not reach \(Self.address)", "domain": "WebKitErrorDomain", "code": "102"]
        for kind in FailureLog.kinds {
            let line = try #require(FailureLog.entry(kind, fields, at: Date()))
            #expect(clean(line), "\(line)")
            #expect(try row(line)["kind"] as? String == kind)
        }
    }

    @Test func theLogNeverHoldsMoreThan500LinesAndKeepsTheNewest() throws {
        var most = 0
        for n in 1...1200 {
            log.append(#"{"kind":"failed","code":\#(n)}"#)
            if n % 50 == 0 || n > 490 && n < 510 { most = max(most, log.lines().count) }
        }

        let codes = try log.lines().map { try row($0)["code"] as? Int }

        #expect(most == FailureLog.limit)
        #expect(codes.count <= FailureLog.limit && codes.count >= FailureLog.trimmed)
        #expect(codes.last == 1200)
        #expect(codes == Array((1200 - codes.count + 1)...1200).map { Optional($0) })
        #expect(log.last(3).count == 3)
    }

    @Test func aLogOpenedAgainCountsWhatIsAlreadyThere() {
        for n in 1...FailureLog.limit { log.append(#"{"code":\#(n)}"#) }

        let again = FailureLog(file: log.file)
        again.append(#"{"code":0}"#)

        #expect(again.lines().count == FailureLog.trimmed)
        #expect(again.lines().last == #"{"code":0}"#)
    }

    @Test func aPrivateWindowWritesNothing() {
        let lines = written("failed", ["url": Self.address, "domain": "NSURLErrorDomain", "code": "-1001"], private: true)

        #expect(lines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: log.file.path))
    }

    @Test func clearingEmptiesTheLog() {
        #expect(written("page-failed", ["domain": "WebKitErrorDomain", "code": "102"]).count == 1)

        DownloadTrace.forget(log)
        DownloadTrace.settle()

        #expect(log.lines().isEmpty)
    }

    @Test func aTestWorldWritesNothingToDiskAndKeepsItsTraceWhole() {
        DownloadTrace.note("failed", ["url": Self.address, "file": Self.path], private: false)

        #expect(DownloadTrace.disk == nil)
        #expect(DownloadTrace.events.contains { $0["url"] == Self.address && $0["file"] == Self.path })
    }

    @Test func doctorFailuresPrintsTheLastLinesNewestLast() throws {
        for n in 1...5 { log.append(try #require(FailureLog.entry("failed", ["domain": "NSURLErrorDomain", "code": String(-1000 - n)], at: Date()))) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent(".build/debug/broadway")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path))

        let printed = try run(binary, ["--socket", folder.appendingPathComponent("broadway.sock").path, "doctor", "failures", "2"])
        let json = try run(binary, ["--socket", folder.appendingPathComponent("broadway.sock").path, "--json", "doctor", "failures"])

        let shown = printed.split(separator: "\n").map(String.init)
        #expect(shown == log.last(2))
        let envelope = try row(json.trimmingCharacters(in: .whitespacesAndNewlines))
        let data = try #require(envelope["data"] as? [String: Any])
        let rows = try #require(data["failures"] as? [[String: Any]])
        #expect(rows.map { $0["code"] as? Int } == [-1001, -1002, -1003, -1004, -1005])
    }

    private func run(_ binary: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "NO_COLOR": "1"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
