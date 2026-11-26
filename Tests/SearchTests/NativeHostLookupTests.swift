import Foundation
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(2)))
struct NativeHostLookupTests {
    private let id = "abcdefghijklmnopabcdefghijklmnop"

    private func folder(_ root: URL, _ name: String, manifest: [String: Any]) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("com.example.host.json"))
        let program = folder.appendingPathComponent("host")
        try Data("#!/bin/sh\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        return folder
    }

    private func manifest(name: String = "com.example.host", type: String = "stdio", allowed: [String]) -> [String: Any] {
        ["name": name, "type": type, "path": "host", "allowed_origins": allowed]
    }

    @Test func aLaterFolderThatListsTheExtensionIsUsedWhenAnEarlierOneDoesNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-hosts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try folder(root, "first", manifest: manifest(allowed: ["chrome-extension://ponmlkjihgfedcbaponmlkjihgfedcba/"]))
        let second = try folder(root, "second", manifest: manifest(allowed: ["chrome-extension://\(id)/"]))
        let found = try ExtensionNative.host("com.example.host", for: id, in: [first, second])
        #expect(found.standardizedFileURL == second.appendingPathComponent("host").standardizedFileURL)
    }

    @Test func aHostWhoseManifestNamesAnotherHostOrAnotherTypeIsNotRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-hosts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let renamed = try folder(root, "renamed", manifest: manifest(name: "com.example.other", allowed: ["chrome-extension://\(id)/"]))
        let typed = try folder(root, "typed", manifest: manifest(type: "socket", allowed: ["chrome-extension://\(id)/"]))
        #expect(throws: ExtensionNative.Refused.self) { try ExtensionNative.host("com.example.host", for: id, in: [renamed, typed]) }
    }

    @Test func aHostThatListsOtherExtensionsOnlyIsForbidden() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-hosts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try folder(root, "other", manifest: manifest(allowed: ["chrome-extension://ponmlkjihgfedcbaponmlkjihgfedcba/"]))
        do {
            _ = try ExtensionNative.host("com.example.host", for: id, in: [other])
            Issue.record("expected a refusal")
        } catch let refused as ExtensionNative.Refused {
            #expect(refused.why == "Access to the specified native messaging host is forbidden.")
        }
    }

    @Test func aRelativePathThatLeavesItsFolderIsNotRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-hosts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try folder(root, "outside", manifest: manifest(allowed: []))
        var escaping = manifest(allowed: ["chrome-extension://\(id)/"])
        escaping["path"] = "../outside/host"
        let inner = try folder(root, "inner", manifest: escaping)
        #expect(throws: ExtensionNative.Refused.self) { try ExtensionNative.host("com.example.host", for: id, in: [inner]) }
    }
}
