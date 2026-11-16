import AppKit
import Darwin
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AddressTests {
    @Test func existingPathsKeepTheirLiteralNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for name in ["report.pdf", "résumé #1? 100%.html"] {
            let file = folder.appendingPathComponent(name)
            try Data("local file".utf8).write(to: file)
            let url = try #require(Address.file(from: " \(file.path)\n"))
            #expect(Address.url(from: file.path) == nil, "Suggestions and text drops must not resolve paths")
            #expect(url.isFileURL)
            #expect(url.path == file.path)
            #expect(url.query == nil)
            #expect(url.fragment == nil)
            #expect(Address.url(from: url.absoluteString) == url)
        }
        #expect(Address.file(from: folder.path) == nil)
        #expect(Address.file(from: folder.appendingPathComponent("missing.pdf").path) == nil)
    }

    @Test(.enabled(if: #filePath.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/"), "Checkout is outside the home directory"))
    func homeRelativePath() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        let file = #filePath
        let url = try #require(Address.file(from: "~/" + file.dropFirst(home.count)))
        #expect(url.path == file)
    }

    @Test func onlyRegularFilesAreAccepted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("regular.txt")
        try Data("text".utf8).write(to: file)
        let pipe = folder.appendingPathComponent("pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        for path in [folder.path, pipe.path, link.path, "/dev/zero", "/dev/random",
                     "/" + file.path, folder.appendingPathComponent("missing").path] {
            #expect(Address.file(from: path) == nil, "\(path)")
        }
        try FileManager.default.removeItem(at: file)
        #expect(Address.file(from: link.path) == nil, "A broken link is not a regular file either")
    }

    @Test func addressesAndSearchPhrasesKeepTheirMeaning() {
        #expect(Address.url(from: "example.com")?.absoluteString == "https://example.com")
        #expect(Address.url(from: "localhost:3000/test")?.absoluteString == "http://localhost:3000/test")
        #expect(Address.url(from: "https://example.com/a?q=b#c")?.absoluteString == "https://example.com/a?q=b#c")
        for text in ["", "two words", "./report.pdf", "person@example.com", "javascript:alert(1)"] {
            #expect(Address.url(from: text) == nil, "\(text)")
            #expect(Address.file(from: text) == nil, "\(text)")
        }
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FileDestinationTests {
    @Test func onlyCommittedDestinationsResolvePathsAndSiteSearchKeepsPrecedence() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).html")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        browser.typed = file.path
        #expect(browser.ending == nil)
        #expect(!browser.offers.contains { $0.url.isFileURL })
        #expect(browser.destination(for: file.path) == file)
        #expect(browser.destination(for: file.absoluteString) == file)
        #expect(browser.destination(for: "/dev/zero") == browser.searchURL(for: "/dev/zero"))

        let site = SearchSite(name: "Fixture", host: "example.test", template: "https://example.test/?q=%s")
        browser.siteChip = site
        #expect(browser.destination(for: file.path) == site.url(for: file.path))
        browser.siteChip = nil
        try FileManager.default.removeItem(at: file)
        #expect(browser.destination(for: file.path) == browser.searchURL(for: file.path))
    }
}
