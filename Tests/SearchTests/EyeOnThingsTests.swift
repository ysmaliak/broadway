import AppKit
import Testing
@testable import Search

@MainActor
private final class FakeReader: ReplyReader {
    var pages: [URL: String] = [:]
    var reads = 0

    func text(of url: URL) async -> String? {
        reads += 1
        return pages[url]
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class EyeOnThingsTests {
    private var folder: URL!
    private var browser: Browser!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("eye-\(UUID().uuidString)")
        browser = Browser(record: WindowRecord())
        browser.prefs.agentsOn = true
    }

    private func tearDown() async {
        browser.prefs.agentsOn = false
        browser.closeAll()
        browser = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text + ":00Z")!
    }

    @Test func anAddedLineIsAReply() {
        let old = ReplyCheck.lines(in: "Inbox\nAnna: can you look?\nReply\nSend")

        #expect(ReplyCheck.change(old: old, new: ReplyCheck.lines(in: "Inbox\nAnna: can you look?\nReply\nSend")) == .same)
        #expect(ReplyCheck.change(old: old, new: ReplyCheck.lines(in: "Inbox\nAnna: can you look?\nBen: done\nReply\nSend")) == .replied(1))
    }

    @Test func passingTimeAndCountersAreNotReplies() {
        let old = ReplyCheck.lines(in: "Anna: can you look?\n2 minutes ago\n3 views\nSend")

        #expect(ReplyCheck.change(old: old, new: ReplyCheck.lines(in: "Anna: can you look?\n1 hour ago\n14 views\nSend")) == .same)
    }

    @Test func aSignInPageIsNotAReply() {
        let old = ReplyCheck.lines(in: "Anna: can you look?\nBen: sure\nSend\nArchive")

        #expect(ReplyCheck.change(old: old, new: ReplyCheck.lines(in: "Sign in\nEmail\nPassword")) == .notTheSamePage)
    }

    @Test func noPageTextIsKeptOnDisk() async throws {
        let file = folder.appendingPathComponent("replies.json")
        let watches = ReplyWatches(file: file)

        watches.add(url: URL(string: "https://mail.example/t")!, title: "Thread", text: "Anna: the secret plan")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: file.path) { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(try !String(contentsOf: file, encoding: .utf8).contains("secret plan"))
    }

    @Test func aReplyBecomesARowAndEndsTheWatch() async throws {
        let url = URL(string: "https://mail.example/t")!
        let watches = ReplyWatches(file: folder.appendingPathComponent("replies.json"))
        let reader = FakeReader()
        reader.pages[url] = "Anna: can you look?\nBen: sure\nSend"
        watches.reader = reader
        watches.add(url: url, title: "Thread", text: "Anna: can you look?\nSend")
        let now = date("2026-11-02T08:00")

        await watches.check(now: now)
        await watches.check(now: now)

        #expect(reader.reads == 1)
        #expect(watches.rows(at: now).first?.title == "Reply in Thread")
        #expect(watches.rows(at: now).first?.url == url)
    }

    @Test func aPageThatWontReadSaysSoAndKeepsWatching() async {
        let watches = ReplyWatches(file: folder.appendingPathComponent("replies.json"))
        watches.reader = FakeReader()
        watches.add(url: URL(string: "https://mail.example/t")!, title: "Thread", text: "Anna\nBen")

        await watches.check()

        #expect(watches.watches.first?.unreadable == true)
        #expect(watches.watches.first?.replied == nil)
    }

    @Test func watchesEndAfterAWeekAndCanBeStopped() async throws {
        let start = date("2026-11-02T08:00")
        let watches = ReplyWatches(file: folder.appendingPathComponent("replies.json"))
        watches.reader = FakeReader()
        watches.add(url: URL(string: "https://mail.example/a")!, title: "A", text: "Anna\nBen", now: start)
        watches.add(url: URL(string: "https://mail.example/b")!, title: "B", text: "Anna\nBen", now: start.addingTimeInterval(6 * 86_400))
        let second = try #require(watches.watches.last)

        await watches.check(now: start.addingTimeInterval(8 * 86_400))

        #expect(watches.watches.map(\.title) == ["B"])

        watches.stop(second.id)

        #expect(watches.watches.isEmpty)
    }

    @Test func aPrivateTabCantBeWatched() async throws {
        let quiet = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { quiet.closeAll() }
        let tab = quiet.benchOpen(URL(string: "https://mail.example/t")!)

        #expect(!tab.canBeRead)
    }

    @Test func agentsOffStopsTheChecks() async {
        let url = URL(string: "https://mail.example/t")!
        let watches = ReplyWatches(file: folder.appendingPathComponent("replies.json"))
        watches.begin(for: browser)
        let reader = FakeReader()
        watches.reader = reader
        watches.add(url: url, title: "Thread", text: "Anna\nBen")
        browser.prefs.agentsOn = false

        await watches.check()

        #expect(reader.reads == 0)
    }
}
