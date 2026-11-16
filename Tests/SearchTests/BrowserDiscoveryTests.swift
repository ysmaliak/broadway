import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct BrowserDiscoveryTests {
    @Test func extensionOnlyProfileIsDiscoverable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let extensions = root.appendingPathComponent("Default/Extensions", isDirectory: true)
        let id = "dfpnncgnidnmgipnpgfgfdmanngkhblg"
        try FileManager.default.createDirectory(at: extensions.appendingPathComponent(id), withIntermediateDirectories: true)
        let source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "", rootOverride: root)

        #expect(source.profiles.map(\.lastPathComponent) == ["Default"])
        #expect(Chromium.preview(of: source, profile: "Default").extensions == [id])
    }

    @Test func browserWithoutSupportedPasswordKeyKeepsOtherData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data().write(to: profile.appendingPathComponent("Login Data"))
        try Data("{}".utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        let source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "", importsPasswords: false, rootOverride: root)

        #expect(source.profiles.map(\.lastPathComponent) == ["Default"])
        #expect(source.files().isEmpty)
        #expect(Chromium.preview(of: source, profile: nil).passwords == 0)
    }

    @Test func chosenFolderIsIgnoredByTestRunsAndNeverPersisted() {
        let source = Chromium.Source(name: "Fixture-\(UUID().uuidString)", folder: "Fixture", service: "", account: "", app: "")
        let selected = FileManager.default.temporaryDirectory.appendingPathComponent("other-browser")

        Chromium.useForSession(selected, for: source)

        #expect(Store.testing)
        #expect(Chromium.chosenRoot(for: source.name) == nil)
        #expect(source.root == Chromium.base.appendingPathComponent(source.folder, isDirectory: true))
        #expect(Store.settings.string(forKey: "import.folder.\(source.name)") == nil)
    }

    @Test func readableEmptyAndMissingFoldersKeepDifferentResults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "")
        source.rootOverride = root
        let empty = source.discovery
        #expect(empty.profiles.isEmpty)
        #expect(empty.error == nil)
        #expect(Chromium.Unavailable(source: source, error: empty.error).message.contains("no browser profile"))

        source.rootOverride = root.appendingPathComponent("missing")
        let missing = source.discovery
        #expect(missing.profiles.isEmpty)
        #expect(missing.error != nil)
        #expect(Chromium.Unavailable(source: source, error: missing.error).message.contains("data folder was not found"))
    }

    @Test func deniedFolderKeepsPermissionErrorAndRecoversAfterAccessIsRestored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let profile = root.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        var source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "")
        source.rootOverride = root
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        let denied = source.discovery
        #expect(denied.profiles.isEmpty)
        #expect(denied.error != nil)
        let message = Chromium.Unavailable(source: source, error: denied.error).message
        #expect(message.contains("macOS hasn't allowed Broadway"))
        #expect(message.contains("for this session"))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        #expect(source.discovery.error == nil)
        #expect(source.profiles.map(\.lastPathComponent) == ["Default"])
        let recovered = try #require(source.profiles.first)
        #expect(try Data(contentsOf: recovered.appendingPathComponent("Bookmarks")) == Data("{}".utf8))
    }

    @Test func deniedProfileKeepsReadableSiblingAndReportsPermissionFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let denied = root.appendingPathComponent("Default")
        let readable = root.appendingPathComponent("Profile 1")
        for profile in [denied, readable] {
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        }
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
            try? FileManager.default.removeItem(at: root)
        }
        var source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "")
        source.rootOverride = root
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)

        let partial = source.discovery
        #expect(partial.profiles.map(\.lastPathComponent) == ["Profile 1"])
        #expect(partial.error != nil)
        let message = Chromium.Unavailable(source: source, error: partial.error, partial: true).message
        #expect(message.contains("Some of Fixture's profiles"))
        #expect(message.contains("all of them"))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
        let restored = source.discovery
        #expect(restored.error == nil)
        #expect(Set(restored.profiles.map { $0.lastPathComponent }) == ["Default", "Profile 1"])
    }

    @Test func ordinaryRootFilesAndEmptyProfilesDoNotBecomeReadFailures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("Local State"))
        defer { try? FileManager.default.removeItem(at: root) }
        var source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "")
        source.rootOverride = root
        #expect(source.discovery.profiles.isEmpty)
        #expect(source.discovery.error == nil)
    }

    @Test func unlistableProfileStillOffersKnownReadableFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = root.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path)
            try? FileManager.default.removeItem(at: root)
        }
        var source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "")
        source.rootOverride = root
        // Traversal and a known file remain readable even without listing the directory.
        try FileManager.default.setAttributes([.posixPermissions: 0o100], ofItemAtPath: profile.path)
        let partial = source.discovery
        #expect(partial.profiles.map(\.lastPathComponent) == ["Default"])
        #expect(partial.error != nil)
        #expect(try source.data("Bookmarks", in: profile) == Data("{}".utf8))
    }

}
