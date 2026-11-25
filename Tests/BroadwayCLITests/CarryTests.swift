import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(2)))
struct CarryTests {
    @Test func aFileOnTheOtherMacArrivesHereInPieces() throws {
        let remote = Data((0..<(Carry.piece * 2 + 5)).map { UInt8($0 % 249) })
        var asked: [Int] = []

        let file = try Carry.fetch("/var/folders/x/T/broadway-pdf-1/page.pdf") { request in
            let from = request["from"] as? Int ?? 0
            asked.append(from)
            let piece = remote[from..<min(from + Carry.piece, remote.count)]
            return ["name": "page.pdf", "bytes": Data(piece).base64EncodedString(), "size": remote.count, "from": from]
        }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        #expect(asked == [0, Carry.piece, Carry.piece * 2])
        #expect(file.lastPathComponent == "page.pdf")
        #expect(FileManager.default.contents(atPath: file.path) == remote)
    }

    @Test func uploadSendsTheBytesOfFilesHereInPiecesIntoOneFolder() throws {
        let folder = NSTemporaryDirectory() + "carry-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let big = Data((0..<(Carry.piece + 3)).map { UInt8($0 % 13) })
        try big.write(to: URL(fileURLWithPath: folder + "/big.bin"))
        try Data("hi".utf8).write(to: URL(fileURLWithPath: folder + "/note.txt"))
        var received: [String: Data] = [:]
        var folders: [String?] = []

        let sent = try Carry.send([folder + "/big.bin", folder + "/note.txt"]) { request in
            let name = request["name"] as? String ?? ""
            folders.append(request["folder"] as? String)
            received[name, default: Data()].append(Data(base64Encoded: request["bytes"] as? String ?? "") ?? Data())
            return ["folder": "/there/broadway-stdin-1", "path": "/there/broadway-stdin-1/" + name]
        }

        #expect(sent.paths == ["/there/broadway-stdin-1/big.bin", "/there/broadway-stdin-1/note.txt"])
        #expect(sent.folder == "/there/broadway-stdin-1")
        #expect(received["big.bin"] == big)
        #expect(received["note.txt"] == Data("hi".utf8))
        #expect(folders == [nil, "/there/broadway-stdin-1", "/there/broadway-stdin-1"])
    }

    @Test func moreThan25MBIsRefusedBeforeAnythingIsSent() throws {
        let path = NSTemporaryDirectory() + "carry-big-\(UUID().uuidString).bin"
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.truncate(atOffset: UInt64(Carry.most + 1))
        try handle.close()
        var calls = 0

        #expect(throws: Failure.self) { _ = try Carry.send([path]) { _ in calls += 1; return [:] } }
        #expect(calls == 0)
        #expect(throws: Failure.self) { _ = try Carry.send(["/nowhere/at/all.txt"]) { _ in calls += 1; return [:] } }
        #expect(throws: Failure.self) { _ = try Carry.send([path, "/elsewhere/" + (path as NSString).lastPathComponent]) { _ in calls += 1; return [:] } }
    }
}
