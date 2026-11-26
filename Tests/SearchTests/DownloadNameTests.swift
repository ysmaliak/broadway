import Foundation
import Testing
@testable import Search

struct DownloadNameTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("search-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aTakenNameGainsTheNextFreeNumberBeforeItsExtension() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(DownloadPlace.free("report.pdf", in: folder).lastPathComponent == "report.pdf")
        try Data().write(to: folder.appendingPathComponent("report.pdf"))
        try Data().write(to: folder.appendingPathComponent("report 2.pdf"))
        try Data().write(to: folder.appendingPathComponent("notes"))

        #expect(DownloadPlace.free("report.pdf", in: folder).lastPathComponent == "report 3.pdf")
        #expect(DownloadPlace.free("notes", in: folder).lastPathComponent == "notes 2")
    }

    @Test func aHookDownloadMovedOntoATakenNameIsNumbered() throws {
        let from = try folder(), to = try folder()
        defer {
            try? FileManager.default.removeItem(at: from)
            try? FileManager.default.removeItem(at: to)
        }
        let file = from.appendingPathComponent("photo.png")
        try Data([1]).write(to: file)
        try Data([2]).write(to: to.appendingPathComponent("photo.png"))

        let moved = try #require(HookDownloads.move(file, to: to))

        #expect(moved.lastPathComponent == "photo 2.png")
        #expect(try Data(contentsOf: moved) == Data([1]))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
