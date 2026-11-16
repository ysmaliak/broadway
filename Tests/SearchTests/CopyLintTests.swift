import Foundation
import Testing

@Suite(.timeLimit(.minutes(5)))
struct CopyLintTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func lint(_ arguments: [String] = []) throws -> (code: Int32, said: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("Tests/copy_lint.py").path] + arguments
        process.currentDirectoryURL = root
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func noWordAPersonReadsBreaksAMechanicalCopyRule() throws {
        let found = try Self.lint()

        #expect(found.code == 0, "Tests/copy_lint.py flags these. A single sentence takes no full stop, several keep theirs, and there is no semicolon, em dash between words, ellipsis on a command that only opens, exclamation mark, three typed dots, please, successfully or (s).\n\(found.said)")
        #expect(found.said.isEmpty)
    }

    @Test func theLintReadsThousandsOfStrings() throws {
        let found = try Self.lint(["--count"])

        let count = Int(found.said.split(separator: " ").first ?? "") ?? 0

        #expect(count > 4000, "\(found.said)")
    }
}
