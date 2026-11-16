import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FilesTests {
    private let old = Date(timeIntervalSince1970: 100)
    private let new = Date(timeIntervalSince1970: 200)

    private func item(_ name: String, _ source: String) -> FileItem {
        FileItem(id: name, kind: .downloaded, name: name, source: source, path: "/tmp/\(name)", date: old)
    }

    @Test func mergedNewestFirst() {
        let keep = Keep(name: "a.pdf", from: "a.example", path: "/a.pdf", date: old)
        let upload = Upload(name: "b.png", site: "b.example", path: "/b.png", date: new)

        let items = FileItem.merged(downloads: [keep], uploads: [upload])

        #expect(items.map(\.name) == ["b.png", "a.pdf"])
        #expect(items.map(\.kind) == [.uploaded, .downloaded])
    }

    @Test func foundByNameOrSource() {
        let items = [item("Report.pdf", "docs.example"), item("photo.png", "shop.example")]

        let byName = FileItem.found(items, matching: "report")
        let bySource = FileItem.found(items, matching: "SHOP")

        #expect(byName.map(\.name) == ["Report.pdf"])
        #expect(bySource.map(\.name) == ["photo.png"])
    }

    @Test func everyWordHasToMatch() {
        let items = [item("Report.pdf", "docs.example"), item("Report.png", "shop.example")]

        let found = FileItem.found(items, matching: "report docs")

        #expect(found.map(\.name) == ["Report.pdf"])
    }

    @Test func nothingTypedShowsEverything() {
        let items = [item("a", "b")]

        let found = FileItem.found(items, matching: "   ")

        #expect(found == items)
    }

    @MainActor
    @Test func uploadsAreOnePerFileAndSite() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("files-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let uploads = Uploads(file: folder.appendingPathComponent("uploads.json"))
        let url = URL(fileURLWithPath: "/tmp/a.txt")

        uploads.add([url], to: "one.example", at: old)
        uploads.add([url], to: "one.example", at: new)
        uploads.add([url], to: "two.example", at: new)

        #expect(uploads.kept.count == 2)
        #expect(uploads.kept.map { $0.site }.sorted() == ["one.example", "two.example"])
    }
}
