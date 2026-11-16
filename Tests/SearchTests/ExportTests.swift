import Foundation
import Testing

@Suite(.timeLimit(.minutes(5)))
struct ExportTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let author = "Some One <12345+someone" + "@" + "users.noreply.github.com>"

    @discardableResult
    private static func run(_ arguments: [String], in folder: URL) throws -> (code: Int32, said: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func git(_ arguments: [String], in folder: URL) throws -> String {
        let found = try run(["git", "-c", "user.name=Someone", "-c", "user.email=someone@example.com", "-c", "commit.gpgsign=false"] + arguments, in: folder)
        #expect(found.code == 0, "git \(arguments.joined(separator: " ")): \(found.said)")
        return found.said.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func export(_ commit: String, to folder: URL, from source: URL, _ more: [String] = []) throws -> (code: Int32, said: String) {
        try run(["python3", root.appendingPathComponent("Release/export.py").path, commit, folder.path,
                 "--from", source.path, "--author", author, "--words", "/dev/null"] + more, in: source)
    }

    private static func write(_ files: [String: String], in folder: URL) throws {
        for (name, text) in files {
            let file = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private static func commit(_ files: [String: String], removing gone: [String] = [], in source: URL) throws -> String {
        try write(files, in: source)
        for name in gone { try FileManager.default.removeItem(at: source.appendingPathComponent(name)) }
        _ = try git(["add", "--all"], in: source)
        _ = try git(["commit", "--quiet", "-m", "a change"], in: source)
        return try git(["rev-parse", "HEAD"], in: source)
    }

    private static func world() throws -> (place: URL, source: URL) {
        let place = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        let source = place.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("Tests/public_tree.py"), to: source.appendingPathComponent("Tests/public_tree.py"))
        _ = try git(["init", "--quiet", "--initial-branch=main"], in: source)
        return (place, source)
    }

    private static func text(_ name: String, in folder: URL) -> String? {
        try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func aFreshExportIsOneCommitByTheNoreplyAuthor() throws {
        let (place, source) = try Self.world()
        defer { try? FileManager.default.removeItem(at: place) }
        let first = try Self.commit(["VERSION": "0.3\n", "README.md": "hello\n"], in: source)
        let published = place.appendingPathComponent("public")

        let found = try Self.export(first, to: published, from: source)

        #expect(found.code == 0, "\(found.said)")
        #expect(try Self.git(["rev-list", "--count", "HEAD"], in: published) == "1")
        #expect(try Self.git(["log", "-1", "--format=%an <%ae>|%cn <%ce>|%s"], in: published) == "\(Self.author)|\(Self.author)|Broadway 0.3")
        #expect(try Self.git(["remote"], in: published).isEmpty)
        #expect(Self.text("README.md", in: published) == "hello\n")
    }

    @Test func anUpdateAddsOneCommitWithTheNewTreeAndTheMessage() throws {
        let (place, source) = try Self.world()
        defer { try? FileManager.default.removeItem(at: place) }
        let first = try Self.commit(["VERSION": "0.3\n", "README.md": "hello\n", "docs/old.md": "old\n"], in: source)
        let published = place.appendingPathComponent("public")
        #expect(try Self.export(first, to: published, from: source).code == 0)
        let before = try Self.git(["rev-parse", "HEAD"], in: published)
        let second = try Self.commit(["README.md": "changed\n", "docs/new.md": "new\n"], removing: ["docs/old.md"], in: source)

        let found = try Self.export(second, to: published, from: source, ["--update", "--message", "Broadway 0.3.1"])

        #expect(found.code == 0, "\(found.said)")
        #expect(try Self.git(["rev-list", "--count", "HEAD"], in: published) == "2")
        #expect(try Self.git(["rev-parse", "HEAD^"], in: published) == before)
        #expect(try Self.git(["log", "-1", "--format=%an <%ae>|%cn <%ce>|%s"], in: published) == "\(Self.author)|\(Self.author)|Broadway 0.3.1")
        #expect(try Self.git(["rev-parse", "HEAD^{tree}"], in: published) == Self.git(["rev-parse", "\(second)^{tree}"], in: source))
        #expect(Self.text("README.md", in: published) == "changed\n")
        #expect(Self.text("docs/new.md", in: published) == "new\n")
        #expect(Self.text("docs/old.md", in: published) == nil)
        #expect(try Self.git(["status", "--porcelain"], in: published).isEmpty)
        #expect(try Self.git(["remote"], in: published).isEmpty)
    }

    @Test func aTreeTheCheckRefusesChangesNothingEitherWay() throws {
        let (place, source) = try Self.world()
        defer { try? FileManager.default.removeItem(at: place) }
        let first = try Self.commit(["VERSION": "0.3\n", "README.md": "hello\n"], in: source)
        let published = place.appendingPathComponent("public")
        #expect(try Self.export(first, to: published, from: source).code == 0)
        let before = try Self.git(["rev-parse", "HEAD"], in: published)
        let leaking = try Self.commit(["notes.txt": "write to jdoe" + "@" + "corp-mail.com\n"], in: source)
        let other = place.appendingPathComponent("other")

        let updated = try Self.export(leaking, to: published, from: source, ["--update", "--message", "Broadway 0.3.1"])
        let fresh = try Self.export(leaking, to: other, from: source)

        #expect(updated.code == 1)
        #expect(updated.said.contains("is unchanged"), "\(updated.said)")
        #expect(try Self.git(["rev-parse", "HEAD"], in: published) == before)
        #expect(Self.text("notes.txt", in: published) == nil)
        #expect(try Self.git(["status", "--porcelain"], in: published).isEmpty)
        #expect(fresh.code == 1)
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    @Test func anUpdateNeedsAMessageAndACleanCloneAndANewTree() throws {
        let (place, source) = try Self.world()
        defer { try? FileManager.default.removeItem(at: place) }
        let first = try Self.commit(["VERSION": "0.3\n", "README.md": "hello\n"], in: source)
        let published = place.appendingPathComponent("public")
        #expect(try Self.export(first, to: published, from: source).code == 0)
        let second = try Self.commit(["README.md": "changed\n"], in: source)

        let unnamed = try Self.export(second, to: published, from: source, ["--update"])
        let same = try Self.export(first, to: published, from: source, ["--update", "--message", "again"])
        try Self.write(["stray.txt": "mine\n"], in: published)
        let dirty = try Self.export(second, to: published, from: source, ["--update", "--message", "Broadway 0.3.1"])

        #expect(unnamed.code == 1)
        #expect(unnamed.said.contains("--update needs --message"))
        #expect(same.code == 1)
        #expect(same.said.contains("no commit was made"))
        #expect(dirty.code == 1)
        #expect(dirty.said.contains("has changes of its own"))
        #expect(try Self.git(["rev-list", "--count", "HEAD"], in: published) == "1")
        #expect(Self.text("README.md", in: published) == "hello\n")
    }
}
