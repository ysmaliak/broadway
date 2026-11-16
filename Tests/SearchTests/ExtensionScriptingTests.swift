import Foundation
import JavaScriptCore
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionScriptingTests {
    @Test func forwardedFunctionKeepsArgumentsAndResult() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("script-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let path = try ExtensionShims.scriptingFile("(value, amount) => value + amount", arguments: ["clip", 2], in: folder)
        let source = try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
        let context = try #require(JSContext())
        #expect(context.evaluateScript(source)?.toString() == "clip2")
        #expect(try ExtensionShims.scriptingFile("(value, amount) => value + amount", arguments: ["clip", 2], in: folder) == path)
        // Past a megabyte of source, refused (Security).
        #expect(throws: (any Error).self) { try ExtensionShims.scriptingFile("() => '" + String(repeating: "x", count: 1_000_001) + "'", arguments: [], in: folder) }
    }
}
