import Foundation
import Testing
@testable import Search

/// The id an extension loaded from a folder gets (Crx.unpackedID): the one
/// Chrome gives it from the folder's path, which is what native messaging
/// hosts list. Never from the manifest's "key".
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class UnpackedIDTests {
    private var root: URL!

    init() throws {
        addTeardownBlock { self.tearDown() }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("unpacked-id-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String, manifest: [String: Any]) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: url.appendingPathComponent("manifest.json"))
        return url
    }

    // A made-up public key, and the id Chrome would work out from it.
    private let key = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl9gYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1+f4CBgoOEhYaHiImKi4yNjo+QkZKTlJWWl5iZmpucnZ6foKGi" // gitleaks:allow (bytes 1, 2, 3… in base64, not a real key)
    private let keyID = "gmamnbkpnmopddmcggdjbipgakiejpfc"

    @Test func theIdComesFromThePath() {
        // StopTheMadness Pro's bundled folder, and the id its host lists for Chrome.
        let path = "/Applications/StopTheMadness Pro.app/Contents/MacOS/StopTheMadness Chrome.app/Contents/Resources/chromium"
        #expect(Crx.unpackedID(for: URL(fileURLWithPath: path, isDirectory: true)) == "paflpghjhdjaeapkeiophohkhagfcjih")
    }

    @Test func aKeyInTheManifestIsIgnored() throws {
        let keyed = try folder("keyed", manifest: ["name": "A", "key": key])
        #expect(Crx.unpackedID(for: keyed) != keyID)
        let withKey = Crx.unpackedID(for: keyed)
        try JSONSerialization.data(withJSONObject: ["name": "A"]).write(to: keyed.appendingPathComponent("manifest.json"))
        #expect(Crx.unpackedID(for: keyed) == withKey)
    }

    @Test func foldersWithTheSameKeyDiffer() throws {
        let one = try folder("one", manifest: ["name": "A", "key": key])
        let two = try folder("two", manifest: ["name": "A", "key": key])
        #expect(Crx.unpackedID(for: one) != Crx.unpackedID(for: two))
    }

    @Test func foldersWithoutAKeyDifferAndALinkLeadsToItsFolder() throws {
        let one = try folder("one", manifest: ["name": "A"])
        let two = try folder("two", manifest: ["name": "A"])
        #expect(Crx.unpackedID(for: one) != Crx.unpackedID(for: two))
        #expect(Crx.unpackedID(for: one).count == 32)
        #expect(Crx.unpackedID(for: one).allSatisfy { ("a"..."p").contains($0) })

        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: one)
        #expect(Crx.unpackedID(for: link) == Crx.unpackedID(for: one))
    }

    @Test func reloadRefusesAFolderThatNowLeadsElsewhere() throws {
        let one = try folder("one", manifest: ["name": "A"])
        let path = Crx.realPath(of: one)
        let item = Installed(id: Crx.unpackedID(for: one), name: "A", version: "1", enabled: true, fromStore: false, permissions: [], source: path)
        #expect(item.sourceKeepsID)

        // Moved, and a link left where it was: the stored path now leads
        // through the link, to a folder with another id.
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: one, to: moved)
        try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: path), withDestinationURL: moved)
        #expect(!item.sourceKeepsID)
    }

    @Test func aListWrittenBeforeIdsCameFromPathsStillReloads() throws {
        let one = try folder("one", manifest: ["name": "A"])
        let json = #"[{"id": "local-1a2b3c4d", "name": "A", "version": "1", "enabled": true, "fromStore": false, "permissions": [], "source": "\#(one.path)"}]"#
        let list = try JSONDecoder().decode([Installed].self, from: Data(json.utf8))
        #expect(list.first?.source == one.path)
        #expect(list.first?.sourceKeepsID == true)

        let store = #"[{"id": "\#(keyID)", "name": "B", "version": "1", "enabled": true, "fromStore": true, "permissions": []}]"#
        #expect(try JSONDecoder().decode([Installed].self, from: Data(store.utf8)).first?.sourceKeepsID == true)
    }
}
