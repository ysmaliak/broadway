import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionDownloadNumberTests {
    private func keep(_ name: String) -> Keep {
        Keep(name: name, from: "example.com", path: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())-\(name)").path, date: Date())
    }

    @Test func aDownloadKeepsItsNumberWhenNewerOnesArrive() throws {
        keepSettings("downloads.lastNumber")
        let loot = Loot()
        let first = keep("first.pdf"), second = keep("second.pdf")
        loot.add(first)
        let number = try #require(loot.kept.first?.number)
        loot.add(second)
        defer { loot.forget(first); loot.forget(second) }
        #expect(loot.kept(number: number)?.path == first.path)
        #expect(loot.kept.first?.number != number)
    }

    @Test func aPromisedNumberIsTheOneTheLandedFileGets() {
        keepSettings("downloads.lastNumber")
        let loot = Loot()
        let file = keep("asked.pdf")
        let number = loot.nextNumber()
        loot.promise(number, for: file.path)
        loot.add(file)
        defer { loot.forget(file) }
        #expect(loot.kept(number: number)?.path == file.path)
    }

    @Test func showRevealsTheDownloadTheNumberNamesAndSearchAnswersByIt() async throws {
        keepSettings("downloads.lastNumber")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("download-numbers-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Downloads", "version": "1", "permissions": ["downloads"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        let browser = Browser(record: WindowRecord())
        Browsers.register(browser)
        defer { browser.closeAll() }
        let mine = keep("mine.pdf"), later = keep("later.pdf")
        browser.loot.add(mine)
        let number = try #require(browser.loot.kept.first?.number)
        browser.loot.add(later)
        defer { browser.loot.forget(mine); browser.loot.forget(later) }
        Loot.benchAsked = []
        _ = try await ExtensionShims.answer(["api": "downloads.show", "args": [number]], from: context, owner: Extensions.shared)
        #expect(Loot.benchAsked == ["reveal mine.pdf"])
        let reply = try await ExtensionShims.answer(["api": "downloads.search", "args": [["id": number]]], from: context, owner: Extensions.shared) as? [String: Any]
        let found = reply?["value"] as? [[String: Any]]
        #expect(found?.count == 1)
        #expect(found?.first?["filename"] as? String == mine.path)
    }
}
