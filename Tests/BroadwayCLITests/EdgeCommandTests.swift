import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(5)))
struct EdgeCommandTests {
    private func context(_ words: [String], socket: String = "/nonexistent/broadway.sock") throws -> Context {
        let (globals, _) = try Globals.extract(words, environment: [:])
        let place = Place(socket: socket, wakes: false, world: nil, bundle: nil, named: false)
        return Context(globals: globals, console: Console(json: true, quiet: true, noColor: true, environment: [:]), place: place, environment: [:], binary: "/nonexistent/broadway")
    }

    private func failure(_ words: [String]) throws -> Failure? {
        do { _ = try BroadwayCommand.route(words, context: try context(words)) } catch let failure as Failure { return failure }
        return nil
    }

    @Test func anUnknownCommandWithWordsAfterItAnswersLikeAnyUnknownCommand() throws {
        let alone = try #require(try failure(["zzzz"]))
        let browse = try #require(try failure(["browse", "https://example.com"]))
        let typo = try #require(try failure(["clikc", "@e3"]))

        #expect(browse.code == alone.code)
        #expect(browse.exit == alone.exit)
        #expect(browse.message.hasPrefix("Unknown command browse"))
        #expect(browse.message.contains("open"))
        #expect(typo.code == alone.code)
        #expect(typo.message.hasPrefix("Unknown command clikc"))
        #expect(try failure(["book a flight to Lisbon"])?.code == "no_tasks")
        #expect(try failure(["tasks", "list"])?.code == "no_tasks")
    }

    @Test func doctorCallsReadsTheCountAndFailuresStaysAHiddenAlias() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("broadway.sock").path
        var tally = CallTally()
        tally.add("click", failed: "not_found")
        try tally.data.write(to: CallTally.file(socket: socket))
        let doctor = try #require(Builtins.find("doctor"))

        let calls = try doctor.run(try context(["doctor", "--calls"], socket: socket), ["--calls"])
        let alias = try doctor.run(try context(["doctor", "--failures"], socket: socket), ["--failures"])
        var extra: Failure?
        do { _ = try doctor.run(try context(["doctor"], socket: socket), ["--calls", "now"]) } catch let failure as Failure { extra = failure }

        #expect(calls == .done)
        #expect(alias == .done)
        #expect(extra?.code == "usage")
        #expect(extra?.message.contains("--calls") == true)
        #expect(doctor.usage.contains("--calls"))
        #expect(!doctor.usage.contains("--failures"))
        #expect(doctor.details.contains("--calls"))
        #expect(!doctor.details.contains("--failures"))
        #expect(doctor.examples.contains("broadway doctor --calls"))
        #expect(!doctor.examples.contains("broadway doctor --failures"))
    }
}
