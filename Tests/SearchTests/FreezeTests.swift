import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(2)))
@MainActor
final class FreezeTests {
    private let folder: URL
    private let facts = FreezeFacts(version: "0.6", build: "600", system: "macOS 27.2 (27C55)", model: "Mac16,1, Apple silicon")

    init() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("freezes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func book(threshold: TimeInterval = FreezeBook.threshold) -> FreezeBook {
        FreezeBook(file: folder.appendingPathComponent("freezes-\(UUID().uuidString).json"), threshold: threshold)
    }

    private func freeze(_ seconds: Double, at: Date = Date(timeIntervalSince1970: 1_795_000_000), ended: Bool = true) -> Freeze {
        facts.freeze(at: at, seconds: seconds, ended: ended, front: .page)
    }

    private func waitFor(_ done: () -> Bool) async {
        for _ in 0..<150 {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aFreezeOfTwoSecondsIsRecordedAndOneJustUnderIsNot() {
        let book = book()

        let under = book.note(freeze(1.99))
        let at = book.note(freeze(2.0, at: Date(timeIntervalSince1970: 1_795_000_100)))

        #expect(!under)
        #expect(at)
        #expect(book.all.map(\.seconds) == [2.0])
    }

    @Test func onlyTheLastTwentyFreezesAreKept() {
        let book = book()

        for n in 0..<25 { book.note(freeze(2 + Double(n), at: Date(timeIntervalSince1970: 1_795_000_000 + Double(n) * 60))) }

        #expect(book.all.count == 20)
        #expect(book.all.first?.seconds == 7)
        #expect(book.latest?.seconds == 26)
    }

    @Test func freezesAreReadBackFromTheirFile() {
        let first = book()
        first.note(freeze(3.5))
        first.settle()

        let again = FreezeBook(file: first.file)

        #expect(again.all == first.all)
    }

    @Test func theEndOfAFreezeUpdatesTheRecordMadeWhileItWasStillGoing() {
        let book = book()
        var going = freeze(2.1, ended: false)
        going.stack = ["0   libsystem_kernel.dylib       mach_msg2_trap + 8"]

        book.note(going)
        book.note(freeze(4.2))

        #expect(book.all.count == 1)
        #expect(book.latest?.seconds == 4.2)
        #expect(book.latest?.ended == true)
        #expect(book.latest?.stack == going.stack)
    }

    @Test func theWatchRecordsAMainThreadThatStopsAnsweringWithItsStack() async {
        let book = book(threshold: 0.3)
        let watch = FreezeWatch(book: book, tick: 0.05, facts: facts) { .internalPage }
        watch.start()
        defer { watch.stop() }
        try? await Task.sleep(for: .milliseconds(150))

        usleep(800_000)
        await waitFor { book.latest?.ended == true }

        let found = book.latest
        #expect(book.all.count == 1)
        #expect((found?.seconds ?? 0) >= 0.3)
        #expect(found?.front == .internalPage)
        #expect(found?.stackFrom == "watchdog")
        #expect(found?.stack.isEmpty == false)
        #expect(found?.images.isEmpty == false)
    }

    @Test func theWatchLetsAStallUnderItsThresholdGo() async {
        let book = book(threshold: 0.5)
        let watch = FreezeWatch(book: book, tick: 0.05, facts: facts) { .page }
        watch.start()
        defer { watch.stop() }
        try? await Task.sleep(for: .milliseconds(150))

        usleep(150_000)
        try? await Task.sleep(for: .milliseconds(400))

        #expect(book.all.isEmpty)
    }

    @Test func aRecordedFreezeHoldsNothingPersonal() async throws {
        let book = book(threshold: 0.3)
        let watch = FreezeWatch(book: book, tick: 0.05, facts: facts) { .page }
        watch.start()
        defer { watch.stop() }
        try? await Task.sleep(for: .milliseconds(150))
        usleep(700_000)
        await waitFor { book.latest?.ended == true }
        book.settle()

        let saved = try String(contentsOf: book.file, encoding: .utf8)
        let report = FreezeReport.text(try #require(book.latest))
        let keys = try #require((try JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [[String: Any]])?.first).keys

        #expect(Set(keys).isSubset(of: ["at", "seconds", "ended", "version", "build", "system", "model", "front", "stack", "images", "stackFrom"]))
        for text in [saved, report] {
            #expect(!text.contains(NSHomeDirectory()))
            #expect(!text.contains("/Users/"))
            #expect(!text.contains(folder.path))
        }
        #expect(book.latest?.stack.allSatisfy { !$0.contains("/") } == true)
    }

    @Test func theReportReadsAsPlainTextForAnIssue() {
        var found = freeze(3.44)
        found.stack = ["0   libsystem_kernel.dylib       mach_msg2_trap + 8", "1   Broadway                     Broadway + 0x1a2b4"]
        found.images = ["0x100000000 Broadway 1A2B3C4D-0000-0000-0000-000000000000"]
        found.stackFrom = "watchdog"

        let text = FreezeReport.text(found, timeZone: TimeZone(identifier: "UTC")!)

        #expect(text == """
        Broadway stopped answering for 3.4 seconds

        When: 2026-11-18T11:06:40Z
        Broadway: 0.6 (600)
        System: macOS 27.2 (27C55)
        Mac: Mac16,1, Apple silicon
        In front: a page

        Main thread:
        ```
        0   libsystem_kernel.dylib       mach_msg2_trap + 8
        1   Broadway                     Broadway + 0x1a2b4

        Images:
        0x100000000 Broadway 1A2B3C4D-0000-0000-0000-000000000000
        ```

        """)
    }

    @Test func aFreezeThatNeverEndedSaysSoAndOneWithoutAStackSaysItWasNotCaught() {
        let text = FreezeReport.text(freeze(2.0, ended: false), timeZone: TimeZone(identifier: "UTC")!)

        #expect(text.hasPrefix("Broadway stopped answering for 2.0 seconds or more and did not answer again before it quit\n"))
        #expect(text.contains("Main thread: not caught"))
    }

    @Test func copyLastFreezeIsOffWithNoFreezeAndOnWithOne() {
        let book = book()
        let watch = FreezeMenuWatch()
        let item = MenuCommand(title: "Copy Last Freeze", action: #selector(MenuCommand.fire(_:)), keyEquivalent: "")
        watch.item = item
        watch.book = book
        let menu = NSMenu()

        watch.menuNeedsUpdate(menu)
        let before = item.isEnabled
        book.note(freeze(2.5))
        watch.menuNeedsUpdate(menu)

        #expect(!before)
        #expect(item.isEnabled)
    }

    @Test func theHelpMenuEndsWithCopyLastFreeze() {
        let menu = MenuBar.helpMenu()

        #expect(menu.items.last?.title == "Copy Last Freeze")
        #expect(menu.delegate === FreezeMenuWatch.shared)
    }

    @Test func copyLastFreezeCopiesTheLatestReport() {
        let book = book()
        book.note(freeze(2.5, at: Date(timeIntervalSince1970: 1_795_000_000)))
        book.note(freeze(6.0, at: Date(timeIntervalSince1970: 1_795_000_600)))
        var copied: [String] = []
        var said: [String] = []
        let hands = Support.Hands(handler: { _ in nil }, own: nil, open: { _ in }, copy: { copied.append($0) })

        let done = Freezes.copyLast(book: book, hands: hands) { said.append($0) }

        #expect(done)
        #expect(copied.count == 1)
        #expect(copied.first?.hasPrefix("Broadway stopped answering for 6.0 seconds\n") == true)
        #expect(said == ["Freeze report copied"])
    }

    @Test func copyLastFreezeDoesNothingWithNoFreeze() {
        var copied: [String] = []
        let hands = Support.Hands(handler: { _ in nil }, own: nil, open: { _ in }, copy: { copied.append($0) })

        let done = Freezes.copyLast(book: book(), hands: hands) { _ in }

        #expect(!done)
        #expect(copied.isEmpty)
    }

    @Test func aMetricKitHangFillsInTheStackOfAFreezeThatHasNone() throws {
        let book = book()
        let at = Date(timeIntervalSince1970: 1_795_000_000)
        book.note(freeze(3.0, at: at))
        let tree = """
        {"callStackPerThread": true, "callStacks": [{"threadAttributed": true, "callStackRootFrames": [{"binaryName": "libsystem_kernel.dylib",
        "offsetIntoBinaryTextSegment": 4096, "binaryUUID": "A", "address": 1, "sampleCount": 1, "subFrames": [{"binaryName": "Broadway",
        "offsetIntoBinaryTextSegment": 107188, "binaryUUID": "B", "address": 2, "sampleCount": 1}]}]}]}
        """

        let frames = FreezeStack.frames(fromMetricTree: Data(tree.utf8))
        book.attach(stack: frames, from: "MetricKit", seconds: 3.1, between: at.addingTimeInterval(-3600), and: at.addingTimeInterval(3600))

        #expect(frames.count == 2)
        #expect(frames[0].hasSuffix("libsystem_kernel.dylib + 0x1000"))
        #expect(frames[1].hasSuffix("Broadway + 0x1a2b4"))
        #expect(book.latest?.stack == frames)
        #expect(book.latest?.stackFrom == "MetricKit")
    }
}
