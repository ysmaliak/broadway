import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
struct MozillaFilesTests {
    @Test func aProfileReachedByTwoSpellingsOfItsFolderIsReadOnce() throws {
        let folder = "SearchTests/\(UUID().uuidString)"
        let root = Chromium.base.appendingPathComponent(folder, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("zen/Profiles/x", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data().write(to: profile.appendingPathComponent("places.sqlite"))
        let other = root.appendingPathComponent("Zen/Profiles/x/places.sqlite")
        let caseBlind = FileManager.default.fileExists(atPath: other.path)
        let source = Mozilla.Source(name: "Zen", folders: ["\(folder)/zen/Profiles", "\(folder)/Zen/Profiles", "\(folder)/zen", "\(folder)/Zen"])

        let files = source.files(only: "x")

        #expect(files.count == 1)
        #expect(source.files.count == 1 || !caseBlind)
    }
}
