import Foundation
import Testing

struct LoggingTests {
    @Test func broadwayLogsThroughLoggerUnderOneSubsystem() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var plain: [String] = []
        var loggers: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("NSLog(") { plain.append(url.lastPathComponent) }
            loggers += text.components(separatedBy: "Logger(subsystem: ").dropFirst().map { String($0.prefix(while: { $0 != "," })) }
        }

        #expect(plain.isEmpty)
        #expect(loggers.count >= 10)
        #expect(Set(loggers) == ["\"com.ysmaliak.broadway\""])
    }
}
