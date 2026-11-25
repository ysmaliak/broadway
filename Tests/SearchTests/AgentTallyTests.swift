import BroadwayCLI
import Foundation
import Testing
@testable import Search

@MainActor
struct AgentTallyTests {
    @Test func aTallyClosedForQuitIsWholeOnDiskAndNeverOverwritesANewerOne() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tally-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(CallTally.name)
        let old = AgentTally(file: file)
        old.count("click", failed: nil)
        old.count("click", failed: "not_found")

        old.close()
        let onDisk = CallTally.read(file)
        let relaunched = AgentTally(file: file)
        relaunched.count("click", failed: nil)
        Disk.drain()
        old.count("wait", failed: nil)
        Disk.drain()
        let after = CallTally.read(file)

        #expect(onDisk.rows["click"]?.calls == 2)
        #expect(onDisk.rows["click"]?.codes == ["not_found": 1])
        #expect(relaunched.tally.rows["click"]?.calls == 3)
        #expect(after.rows["click"]?.calls == 3)
        #expect(after.rows["wait"]?.calls == 1)
    }
}
