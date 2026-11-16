import Foundation
import Testing

@Suite(.timeLimit(.minutes(5)))
struct PublicTreeTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func check(_ arguments: [String] = []) throws -> (code: Int32, said: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("Tests/public_tree.py").path] + arguments
        process.currentDirectoryURL = root
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func planted(_ files: [String: String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("public-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files {
            let file = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        return folder
    }

    @Test func noTrackedFileHoldsAnythingPrivate() throws {
        let found = try Self.check()

        #expect(found.code == 0, "Tests/public_tree.py flags these. Use example people, example.com addresses, the team ABCDE12345 and paths under /Users/someone.\n\(found.said)")
        #expect(found.said.isEmpty)
    }

    @Test func eachKindOfLeakIsCaught() throws {
        let team = "Q1W2E3R4" + "T5"
        let files = [
            "home.txt": "open " + "/Users" + "/jdoe/Desktop/notes.txt",
            "email.txt": "write to jdoe" + "@" + "corp-mail.com",
            "identity.txt": "Developer ID Application: Jo Doe " + "(" + team + ")",
            "team.txt": "partition team" + "id:" + team,
            "key.txt": "token " + "gh" + "p_" + String(repeating: "a1B2", count: 9),
            "word.txt": "the zorblax project",
            "clean.txt": "support@broadwaybrowser.com, someone@example.com, /Users/someone/Desktop, team ABCDE12345",
        ]
        let folder = try Self.planted(files)
        let words = folder.appendingPathExtension("words")
        try "zorblax\n".write(to: words, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: words)
        }

        let found = try Self.check([folder.path, "--words", words.path])

        #expect(found.code == 1)
        let flagged = Set(found.said.split(separator: "\n").map { String($0.split(separator: ":").first ?? "") })
        #expect(flagged == ["home.txt", "email.txt", "identity.txt", "team.txt", "key.txt", "word.txt"], "\(found.said)")
        #expect(found.said.contains("home.txt:1: home path"))
        #expect(found.said.contains("email.txt:1: email address"))
        #expect(found.said.contains("identity.txt:1: signing identity"))
        #expect(found.said.contains("team.txt:1: team id"))
        #expect(found.said.contains("key.txt:1: GitHub token"))
        #expect(found.said.contains("word.txt:1: private word: zorblax"))
        #expect(!found.said.contains("a1B2a1B2"))
    }

    @Test func aCleanFolderPasses() throws {
        let folder = try Self.planted(["README.md": "Mail support@broadwaybrowser.com or sam@example.org about /Users/someone/Library."])
        defer { try? FileManager.default.removeItem(at: folder) }

        let found = try Self.check([folder.path, "--words", "/dev/null"])

        #expect(found.code == 0, "\(found.said)")
    }

    @Test func placesAndDocumentsThatStayPrivateAreCaught() throws {
        let hex = "5d2c1e9b7a3f4c08" + "b6e1d4a7f9c20b13"
        let files = [
            "worker.txt": "staging is at https://" + "broadway-site.some-team" + ".workers" + ".dev/",
            "cloudflare.txt": "account_id = \"" + hex + "\"",
            "notary.txt": "xcrun notarytool submit --key-id " + "AB12CD34EF",
            "store.txt": "https://appstoreconnect.apple.com/" + "apps/" + "1234567890/distribution",
            "document.txt": "the plan is at https://claude.ai/" + "artifact/" + "6b1e4d27-0c9a-4f3e-8d71-5a2c9e04f1b8",
            "repository.txt": "see https://github.com/someone/" + "broadway-" + "drafts",
            "former.txt": "it was at https://github.com/someone/" + "broadway-" + "mac before",
            "machine.txt": "git push " + "ssh://" + "buildbox/~/repo HEAD",
            "Tests/lists.json": "{\"url\": \"https://claude.ai/" + "artifact/" + "6b1e4d27-0c9a-4f3e-8d71-5a2c9e04f1b8\"}",
            "clean.txt": "https://github.com/ysmaliak/broadway, a Worker on workers.dev, notion.so and claude.ai",
        ]
        let folder = try Self.planted(files)
        defer { try? FileManager.default.removeItem(at: folder) }

        let found = try Self.check([folder.path, "--words", "/dev/null"])

        #expect(found.code == 1)
        let flagged = Set(found.said.split(separator: "\n").map { String($0.split(separator: ":").first ?? "") })
        #expect(flagged == ["worker.txt", "cloudflare.txt", "notary.txt", "store.txt", "document.txt", "repository.txt", "former.txt", "machine.txt"], "\(found.said)")
        #expect(found.said.contains("worker.txt:1: workers.dev address"))
        #expect(found.said.contains("cloudflare.txt:1: Cloudflare id"))
        #expect(found.said.contains("notary.txt:1: App Store Connect key"))
        #expect(found.said.contains("store.txt:1: App Store Connect address"))
        #expect(found.said.contains("document.txt:1: private document link"))
        #expect(found.said.contains("repository.txt:1: private repository"))
        #expect(found.said.contains("machine.txt:1: ssh address"))
        #expect(!found.said.contains(hex))
        #expect(!found.said.contains("AB12CD34EF"))
    }
}
