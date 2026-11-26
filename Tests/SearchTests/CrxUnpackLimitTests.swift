import Foundation
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(2)))
struct CrxUnpackLimitTests {
    private func zip(bytes: Int) throws -> (URL, Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crx-limit-\(UUID())")
        let source = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{\"manifest_version\":3}".utf8).write(to: source.appendingPathComponent("manifest.json"))
        try Data(count: bytes).write(to: source.appendingPathComponent("big.bin"))
        let archive = root.appendingPathComponent("x.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", source.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        return (root, try Data(contentsOf: archive))
    }

    @Test func aPackageThatUnpacksPastTheLimitIsRefusedAndLeavesNothing() throws {
        let (root, data) = try zip(bytes: 8 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(data.count < 1024 * 1024)
        let folder = root.appendingPathComponent("out", isDirectory: true)
        var refused: Crx.Refused?
        do { try Crx.unpack(data, into: folder, limit: 1024 * 1024) } catch let error as Crx.Refused { refused = error }
        guard case .unsafe = refused else {
            Issue.record("expected the unsafe refusal, got \(String(describing: refused))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(Crx.Refused.unsafe.localizedDescription == "This extension's package isn't safe to open")
    }

    @Test func aPackageWithinTheLimitUnpacks() throws {
        let (root, data) = try zip(bytes: 1024)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("out", isDirectory: true)
        try Crx.unpack(data, into: folder, limit: 1024 * 1024)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))
    }
}
