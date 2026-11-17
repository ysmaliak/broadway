import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class HookFileTests {
    private let lab: HookLab

    init() throws {
        let lab = try HookLab("file")
        self.lab = lab
        addTeardownBlock { lab.close() }
    }

    private func write(_ hooks: [[String: Any]]) throws -> URL {
        let file = lab.folder.appendingPathComponent("written.json")
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "hooks": hooks])
        try data.write(to: file)
        return file
    }

    @Test func theFileGivesBackItsHooksInTheirOrder() throws {
        let first = UUID()
        let second = UUID()
        let file = try write([
            ["id": first.uuidString, "event": "link", "program": "/opt/hooks/links", "on": true],
            ["id": second.uuidString, "event": "timer", "program": "/opt/hooks/tidy", "on": false, "minutes": 30],
        ])

        let book = HookBook(file: file)

        #expect(book.hooks.map(\.id) == [first, second])
        #expect(book.hooks.map(\.event) == [.link, .timer])
        #expect(book.hooks[1].minutes == 30)
        #expect(!book.hooks[1].on)
    }

    @Test func aHookThisBuildDoesNotKnowIsKeptAsItIsAndNeverRun() throws {
        let known = UUID()
        let file = try write([
            ["id": UUID().uuidString, "event": "clipboard", "program": "/opt/hooks/clip", "on": true, "colour": "teal"],
            ["id": known.uuidString, "event": "link", "program": "/opt/hooks/links", "on": true, "note": "kept too"],
        ])
        let book = HookBook(file: file)

        book.turn(known, on: false)
        let data = HookBook.data(book.entries)
        Disk.write(file, now: true) { data }

        #expect(book.hooks.map(\.id) == [known])
        #expect(HookEvent.allCases.allSatisfy { book.ready(for: $0).isEmpty })
        let again = try #require(HookBook.read(Data(contentsOf: file)))
        #expect(again.count == 2)
        #expect(again[0].hook == nil)
        #expect(again[0].raw["event"] as? String == "clipboard")
        #expect(again[0].raw["colour"] as? String == "teal")
        #expect(again[1].raw["note"] as? String == "kept too")
        #expect(again[1].hook?.on == false)
    }

    @Test func aFileThatIsNotWholeIsSetAsideAndNothingRuns() throws {
        let file = lab.folder.appendingPathComponent("broken.json")
        try Data(#"{"version": 1, "hooks": [{"id": "#.utf8).write(to: file)

        let book = HookBook(file: file)

        #expect(book.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: lab.folder.path).filter { $0.hasPrefix("broken.unreadable-") }
        #expect(aside.count == 1)
    }

    @Test func theFileIsWrittenWholeWithEveryHook() async throws {
        let program = try lab.program("links", "echo '{}'")

        let added = try lab.add(.link, program)

        #expect(await hookSoon { (try? Data(contentsOf: self.lab.book.file)).flatMap(HookBook.read)?.count == 1 })
        let again = HookBook(file: lab.book.file)
        #expect(again.hooks == [added])
        let text = try String(contentsOf: lab.book.file, encoding: .utf8)
        #expect(text.contains("\"version\" : 1"))
    }

    @Test func aTimerRunsNoMoreOftenThanEveryFiveMinutes() throws {
        let file = try write([["id": UUID().uuidString, "event": "timer", "program": "/opt/hooks/tidy", "on": true, "minutes": 1]])

        let book = HookBook(file: file)

        #expect(book.hooks.first?.minutes == 5)
    }

    @Test func aHookWithARelativeProgramIsNotUnderstood() throws {
        let file = try write([["id": UUID().uuidString, "event": "link", "program": "links.sh", "on": true]])

        let book = HookBook(file: file)

        #expect(book.hooks.isEmpty)
        #expect(book.entries.count == 1)
    }

    @Test func aPermissionHookKeepsTheHashOfTheProgramItWasApprovedWith() throws {
        let program = try lab.program("meetings", "echo '{}'")

        let hook = try lab.add(.permission, program)

        #expect(hook.hash == Hook.hash(of: try Data(contentsOf: program)))
    }

    @Test func otherKindsOfHookKeepNoHash() throws {
        let program = try lab.program("links", "echo '{}'")

        let hook = try lab.add(.link, program)

        #expect(hook.hash == nil)
    }

    @Test func aRowSaysHowLongAgoItsHookRan() throws {
        let hook = try lab.add(.link, lab.program("links", "echo '{}'"))
        let now = Date()

        lab.book.note(hook.id, HookResult(at: now.addingTimeInterval(-125)), missed: false)

        #expect(lab.book.line(hook, now: now) == "Ran 2 minutes ago")
    }

    @Test func aRowSaysWhenItsHookHasNotRun() throws {
        let hook = try lab.add(.link, lab.program("links", "echo '{}'"))

        #expect(lab.book.line(hook) == "Hasn't run yet")
    }

    @Test func aRowNamesItsProgramAndFolderAndWhatItIsFor() throws {
        let hook = try lab.add(.timer, lab.program("tidy", "echo '{}'"), minutes: 15)

        #expect(hook.purpose == "Every 15 minutes")
        #expect(HookWords.place(hook, home: lab.folder) == "tidy in ~")
        #expect(HookWords.place(hook, home: lab.home) == "tidy in \(lab.folder.path)")
    }

    @Test func turningAHookBackOnClearsWhyItWasSwitchedOff() throws {
        let hook = try lab.add(.link, lab.program("links", "echo '{}'"))
        for _ in 0..<HookBook.missesAllowed { lab.book.note(hook.id, HookResult(at: Date(), problem: "Timed out"), missed: true) }

        lab.book.turn(hook.id, on: true)

        #expect(lab.book.hook(hook.id)?.off == nil)
        #expect(lab.book.hook(hook.id)?.on == true)
        #expect(lab.book.misses[hook.id] == 0)
    }

    @Test func removingAHookTakesItOutOfTheFile() throws {
        let hook = try lab.add(.link, lab.program("links", "echo '{}'"))

        lab.book.remove(hook.id)

        #expect(lab.book.hooks.isEmpty)
    }
}
