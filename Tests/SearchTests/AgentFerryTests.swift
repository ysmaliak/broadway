import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct AgentFerryTests {
    @Test func broadwayHandsOverAPdfItMadeInPieces() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("broadway-pdf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("page.pdf")
        let bytes = Data((0..<(AgentFerry.piece + 10)).map { UInt8($0 % 251) })
        try bytes.write(to: file)

        let first = AgentFerry.read(["path": file.path])["data"] as? [String: Any]
        let second = AgentFerry.read(["path": file.path, "from": AgentFerry.piece])["data"] as? [String: Any]

        let one = try #require((first?["bytes"] as? String).flatMap { Data(base64Encoded: $0) })
        let two = try #require((second?["bytes"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(first?["size"] as? Int == bytes.count)
        #expect(first?["name"] as? String == "page.pdf")
        #expect(one + two == bytes)
    }

    @Test func anyOtherFileIsRefused() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("other-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let refused = AgentFerry.read(["path": file.path])
        let home = AgentFerry.read(["path": NSHomeDirectory() + "/.ssh/id_ed25519"])
        let climbed = AgentFerry.read(["path": FileManager.default.temporaryDirectory.path + "/broadway-pdf-x/../../" + file.lastPathComponent])

        #expect(refused["ok"] as? Bool == false)
        #expect((refused["error"] as? [String: Any])?["code"] as? String == "not_found")
        #expect(home["ok"] as? Bool == false)
        #expect(climbed["ok"] as? Bool == false)
    }

    @Test func aFinishedDownloadIsHandedOver() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("report-\(UUID().uuidString).bin")
        try Data("report".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let before = AgentFerry.downloads
        AgentFerry.downloads = { [file] }
        defer { AgentFerry.downloads = before }

        let answer = AgentFerry.read(["path": file.path])["data"] as? [String: Any]

        #expect((answer?["bytes"] as? String).flatMap { Data(base64Encoded: $0) } == Data("report".utf8))
    }

    @Test func bytesSentInPiecesBecomeOneFileInAnUploadFolder() throws {
        let first = AgentFerry.take(["name": "../.notes.txt", "bytes": Data("one ".utf8).base64EncodedString()])["data"] as? [String: Any]
        let folder = try #require(first?["folder"] as? String)
        defer { AgentGiven.drop(URL(fileURLWithPath: folder)) }
        let second = AgentFerry.take(["name": "notes.txt", "folder": folder, "bytes": Data("two".utf8).base64EncodedString()])["data"] as? [String: Any]

        let path = try #require(second?["path"] as? String)
        #expect(path == first?["path"] as? String)
        #expect((path as NSString).lastPathComponent == "notes.txt")
        #expect(URL(fileURLWithPath: folder).deletingLastPathComponent().resolvingSymlinksInPath().path == AgentGiven.root.path)
        #expect(FileManager.default.contents(atPath: path) == Data("one two".utf8))
        #expect(AgentGiven.folder(["given": folder], paths: [URL(fileURLWithPath: path)]) != nil)
    }

    @Test func moreThan25MBIsRefusedAndNothingIsKept() throws {
        let start = AgentFerry.take(["name": "big.bin", "bytes": Data(count: 10).base64EncodedString()])["data"] as? [String: Any]
        let folder = try #require(start?["folder"] as? String)
        let path = try #require(start?["path"] as? String)
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.truncate(atOffset: UInt64(AgentFerry.most))
        try handle.close()

        let over = AgentFerry.take(["name": "big.bin", "folder": folder, "bytes": Data(count: 10).base64EncodedString()])
        let stranger = AgentFerry.take(["name": "x.txt", "folder": NSHomeDirectory(), "bytes": Data(count: 1).base64EncodedString()])

        #expect((over["error"] as? [String: Any])?["message"] as? String == "Files to upload come to more than 25 MB")
        #expect(!FileManager.default.fileExists(atPath: folder))
        #expect(stranger["ok"] as? Bool == false)
    }
}