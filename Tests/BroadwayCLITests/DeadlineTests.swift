import Darwin
import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.serialized)
struct DeadlineTests {
    @Test func timeoutIsAGlobalOption() throws {
        let (globals, rest) = try Globals.extract(["--timeout", "2.5", "tabs"], environment: [:])

        #expect(globals.timeout == 2.5)
        #expect(rest == ["tabs"])
    }

    @Test func aTimeoutThatIsNotANumberIsAMistake() {
        #expect(throws: Failure.self) { try Globals.extract(["--timeout", "soon", "tabs"], environment: [:]) }
    }

    @Test func pageCommandsHaveADefaultDeadlineAndStreamsDoNot() throws {
        let plain = Globals()

        let page = try #require(BroadwayCommand.deadline(["snapshot"], globals: plain))
        let patient = try #require(BroadwayCommand.deadline(["bookmarks", "add", "x", "--wait-person", "30"], globals: plain))
        let stream = BroadwayCommand.deadline(["watch"], globals: plain)
        let task = BroadwayCommand.deadline(["summarize this page"], globals: plain)

        #expect(abs(page.timeIntervalSinceNow - 600) < 5)
        #expect(patient.timeIntervalSinceNow > 1800)
        #expect(stream == nil)
        #expect(task == nil)
    }

    @Test func aPeerThatNeverAnswersIsCalledNotAnswering() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("s.sock").path
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) } }
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        listen(server, 8)
        defer { close(server) }
        Link.halted = nil
        Link.watch = Link.Watch(socket: path, deadline: nil, reads: true, first: 0.3, every: 1, patience: 0.5)
        defer { Link.watch = nil; Link.halted = nil }
        let link = try #require(Link(path: path))

        let began = Date()
        let line = link.line()

        #expect(line == nil)
        #expect(Link.halted?.code == "not_answering")
        #expect(Link.halted?.exit == .unanswered)
        #expect(Date().timeIntervalSince(began) < 3)
    }
}
