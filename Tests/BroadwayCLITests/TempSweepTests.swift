import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(5)))
struct TempSweepTests {
    private let files = FileManager.default

    private func folder(_ name: String, in root: URL, age: TimeInterval) throws -> URL {
        let made = root.appendingPathComponent(name)
        try files.createDirectory(at: made, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: made.appendingPathComponent("inside.txt"))
        try files.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: made.path)
        return made
    }

    @Test func onlyItsOwnFoldersOlderThanADayGo() throws {
        let root = files.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let day: TimeInterval = 86400
        let old = try TempSweep.made.map { try folder($0 + UUID().uuidString, in: root, age: 2 * day) }
        let fresh = try folder("broadway-carried-" + UUID().uuidString, in: root, age: 60)
        let notOurs = try folder("broadway-carried-notes", in: root, age: 2 * day)
        let stranger = try folder("someone-" + UUID().uuidString, in: root, age: 2 * day)
        let deeper = try folder("keep/broadway-pdf-" + UUID().uuidString, in: root, age: 2 * day)
        let target = try folder("target", in: root, age: 2 * day)
        let link = root.appendingPathComponent("broadway-tiles-" + UUID().uuidString)
        try files.createSymbolicLink(at: link, withDestinationURL: target)
        let plain = root.appendingPathComponent("broadway-pdf-" + UUID().uuidString)
        try Data("x".utf8).write(to: plain)
        try files.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * day)], ofItemAtPath: plain.path)

        let removed = TempSweep.sweep(in: root)

        #expect(Set(removed) == Set(old.map(\.lastPathComponent)))
        #expect(old.allSatisfy { !files.fileExists(atPath: $0.path) })
        for kept in [fresh, notOurs, stranger, deeper, target, plain] { #expect(files.fileExists(atPath: kept.path), "\(kept.lastPathComponent)") }
        #expect((try? files.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test func aShotWithNoFileNamedIsKeptInAFolderOfItsOwnThatTheSweepKnows() throws {
        let root = files.temporaryDirectory.appendingPathComponent("sweep-shot-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        let first = URL(fileURLWithPath: try Render.kept("broadway-shot-20261124-225946.png", in: root))
        let second = URL(fileURLWithPath: try Render.kept("broadway-shot-20261124-225946.png", in: root))
        try Data("x".utf8).write(to: first)
        try files.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: first.deletingLastPathComponent().path)
        let removed = TempSweep.sweep(TempSweep.commandLine, in: root)

        #expect(first.deletingLastPathComponent() != second.deletingLastPathComponent())
        #expect(first.deletingLastPathComponent().lastPathComponent.hasPrefix("broadway-shot-"))
        #expect(removed == [first.deletingLastPathComponent().lastPathComponent])
        #expect(files.fileExists(atPath: second.deletingLastPathComponent().path))
    }

    @Test func aLongAnswerIsKeptInATemporaryFolderThatBothSweepsTake() throws {
        let root = files.temporaryDirectory.appendingPathComponent("sweep-long-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        let path = URL(fileURLWithPath: try Render.long("page text\n", named: "text-20261124-225946-42.txt", in: root))
        let folder = path.deletingLastPathComponent()
        let fresh = TempSweep.sweep(TempSweep.commandLine, in: root)
        try files.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: folder.path)
        let old = TempSweep.sweep(TempSweep.made, in: root)

        #expect(folder.deletingLastPathComponent().path == root.path)
        #expect(folder.lastPathComponent.hasPrefix("broadway-long-"))
        #expect(path.lastPathComponent == "text-20261124-225946-42.txt")
        #expect(fresh.isEmpty)
        #expect(old == [folder.lastPathComponent])
        #expect(!files.fileExists(atPath: path.path))
    }

    @Test func theCommandLineSweepsOnlyTheFoldersItMakes() throws {
        let root = files.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let carried = try folder("broadway-carried-" + UUID().uuidString, in: root, age: 3 * 86400)
        let pdf = try folder("broadway-pdf-" + UUID().uuidString, in: root, age: 3 * 86400)

        TempSweep.sweep(TempSweep.commandLine, in: root)

        #expect(!files.fileExists(atPath: carried.path))
        #expect(files.fileExists(atPath: pdf.path))
        #expect(TempSweep.made.contains("broadway-carried-"))
        #expect(TempSweep.commandLine == ["broadway-carried-", "broadway-shot-", "broadway-long-"])
    }

    @Test func theCommandLineSweepsAtMostOnceADay() throws {
        let root = files.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let first = try folder("broadway-carried-" + UUID().uuidString, in: root, age: 3 * 86400)

        let swept = TempSweep.whenDue(TempSweep.commandLine, in: root)
        let second = try folder("broadway-carried-" + UUID().uuidString, in: root, age: 3 * 86400)
        let again = TempSweep.whenDue(TempSweep.commandLine, in: root)
        let tomorrow = TempSweep.whenDue(TempSweep.commandLine, in: root, now: Date().addingTimeInterval(2 * 86400))

        #expect(swept == [first.lastPathComponent])
        #expect(again == nil)
        #expect(tomorrow == [second.lastPathComponent])
    }
}
