import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct BrowserImportBoundaryTests {
    @Test func profilesAndFilesCannotFollowLinksOutsideRoot() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("browser")
        let outside = parent.appendingPathComponent("browser-other")
        let profile = root.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        try Data("{}".utf8).write(to: outside.appendingPathComponent("Bookmarks"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Profile 1"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent("History"), withDestinationURL: outside.appendingPathComponent("Bookmarks"))
        let source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "", rootOverride: root)
        #expect(source.profiles.map(\.lastPathComponent) == ["Default"])
        #expect(source.file("History", in: profile) == nil)
        #expect(source.file("Bookmarks", in: profile) != nil)
        #expect(source.file("../browser-other/Bookmarks") == nil)
    }

    @Test func linkedBookmarksCannotAuthorizeReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data().write(to: profile.appendingPathComponent("History"))
        try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent("Bookmarks"), withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("outside-bookmarks"))
        let source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "", rootOverride: root)
        let found = Chromium.bookmarkRead(in: source)
        #expect(found.nodes.isEmpty)
        #expect(!found.complete)
    }

    @Test func snapshotRefusesDatabaseAndSidecarLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = root.appendingPathComponent("data")
        let database = root.appendingPathComponent("History")
        try Data("fixture".utf8).write(to: data)
        try FileManager.default.createSymbolicLink(at: database, withDestinationURL: data)
        #expect(throws: (any Error).self) { try Snapshot(of: database) }
        try FileManager.default.removeItem(at: database)
        try Data("database".utf8).write(to: database)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("History-wal"), withDestinationURL: data)
        #expect(throws: (any Error).self) { try Snapshot(of: database) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("History-wal"))
        try Data("wal".utf8).write(to: root.appendingPathComponent("History-wal"))
        let snapshot = try Snapshot(of: database)
        #expect(try Data(contentsOf: snapshot.file) == Data("database".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: snapshot.file.path + "-wal")) == Data("wal".utf8))
    }

    @Test func jsonReadRejectsOversizedFilesAndDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "", rootOverride: root)
        for name in ["Local State", "Bookmarks", "Preferences", "Secure Preferences"] {
            let url = root.appendingPathComponent(name)
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 64 * 1024 * 1024 + 1)
            try handle.close()
            #expect(throws: (any Error).self, "\(name)") { try source.data(name) }
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try source.data("directory") }
    }

    @Test func jsonReadsResolvedInRootFileAndRefusesOutsideLink() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("browser")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("actual")
        let outside = parent.appendingPathComponent("outside")
        try Data("inside".utf8).write(to: target)
        try Data("outside".utf8).write(to: outside)
        let source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "", rootOverride: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Local State"), withDestinationURL: target)
        #expect(source.file("Local State") == target.resolvingSymlinksInPath())
        #expect(try source.data("Local State") == Data("inside".utf8))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Preferences"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try source.data("Preferences") }
    }

    @Test func oversizedBookmarksCannotAuthorizeReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let url = profile.appendingPathComponent("Bookmarks")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 64 * 1024 * 1024 + 1)
        try handle.close()
        let source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "", rootOverride: root)
        let result = Chromium.bookmarkRead(in: source)
        #expect(result.nodes.isEmpty)
        #expect(!result.complete)
    }

}
