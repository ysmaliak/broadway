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
    private var eye: Eye!
    private var browser: Browser!
    private var fake: FakeProvider!
    private var utc: Calendar!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("eye-\(UUID().uuidString)")
        Store.settings.removeObject(forKey: Eye.onKey)
        eye = Eye(file: folder.appendingPathComponent("eye.json"))
        eye.command = "/x/broadway"
        browser = Browser(record: WindowRecord())
        browser.prefs.ai = true
        browser.prefs.agentsOn = true
        eye.attach(browser)
        fake = FakeProvider(plan: .claude, echoes: true)
        Plans.shared.standIn(fake, for: .claude)
        await Plans.shared.refresh()
        utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
    }

    private func tearDown() async {
        eye.on = false
        Store.settings.removeObject(forKey: Eye.onKey)
        Plans.shared.standIn(nil, for: .claude)
        browser.prefs.agentsOn = false
        browser.closeAll()
        browser = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text + ":00Z")!
    }

    private func visited(_ address: String) {
        browser.history.record(URL(string: address)!, title: "Page")
    }

    private func entry(hosts: [String] = ["mail.example"], addressed: Bool = false) -> TaskLedger.Entry {
        TaskLedger.Entry(origin: .watch, title: "x", hosts: hosts, addressed: addressed)
    }

    @Test func theFirstLookAfterDawnIsTheMorning() {
        #expect(EyeClock.moment(lastReview: nil, awaySince: nil, reviewsToday: 0, now: date("2026-11-02T08:00"), calendar: utc) == .morning)
        #expect(EyeClock.moment(lastReview: date("2026-11-01T22:00"), awaySince: nil, reviewsToday: 0, now: date("2026-11-02T08:00"), calendar: utc) == .morning)
        #expect(EyeClock.moment(lastReview: date("2026-11-02T07:00"), awaySince: nil, reviewsToday: 1, now: date("2026-11-02T08:00"), calendar: utc) == nil)
        #expect(EyeClock.moment(lastReview: date("2026-11-01T22:00"), awaySince: nil, reviewsToday: 0, now: date("2026-11-02T04:00"), calendar: utc) == nil)
    }

    @Test func aBreakMustBeLongAndTheLastLookOld() {
        let now = date("2026-11-02T15:00")

        #expect(EyeClock.moment(lastReview: date("2026-11-02T09:00"), awaySince: date("2026-11-02T12:30"), reviewsToday: 1, now: now, calendar: utc) == .afterBreak)
        #expect(EyeClock.moment(lastReview: date("2026-11-02T09:00"), awaySince: date("2026-11-02T13:30"), reviewsToday: 1, now: now, calendar: utc) == nil)
        #expect(EyeClock.moment(lastReview: date("2026-11-02T14:00"), awaySince: date("2026-11-02T10:00"), reviewsToday: 1, now: now, calendar: utc) == nil)
    }

    @Test func fourADayIsTheLimit() {
        #expect(EyeClock.moment(lastReview: date("2026-11-02T09:00"), awaySince: date("2026-11-02T12:00"), reviewsToday: 4, now: date("2026-11-02T15:00"), calendar: utc) == nil)
    }

    @Test func threadsAreToldApartFromLists() {
        for list in ["https://github.com/notifications", "https://linear.app/acme/inbox", "https://mail.google.com/mail/u/0/#inbox",
                     "https://news.example/", "https://x.example/my-long-page-2026"] {
            #expect(!EyeClock.opensAThread(URL(string: list)), "\(list)")
        }
        for thread in ["https://github.com/acme/app/pull/123", "https://github.com/acme/app/issues/88", "https://linear.app/acme/issue/ENG-1/title",
                       "https://mail.google.com/mail/u/0/#inbox/FMfcgzQfBZbr", "https://acme.slack.com/client/T024BE7LH/C024BE7LH",
                       "https://reddit.com/r/swift/comments/abc/title", "https://x.com/someone/status/190"] {
            #expect(EyeClock.opensAThread(URL(string: thread)), "\(thread)")
        }
    }

    @Test func offByDefaultNothingLooksAndNothingIsSpent() async {
        visited("https://mail.example/inbox")
        eye.wentAway(now: date("2026-11-02T10:00"))

        eye.cameBack(now: date("2026-11-02T15:00"), calendar: utc)
        try? await Task.sleep(for: .milliseconds(30))

        #expect(!eye.on)
        #expect(!eye.looking)
        #expect(fake.requests.isEmpty)
    }

    @Test func turnedOnItLooksOnceAndOnlyAtListPages() async throws {
        fake.echoes = false
        fake.script = [.hang]
        visited("https://mail.example/inbox")
        eye.on = true

        eye.cameBack(now: date("2026-11-02T08:00"), calendar: utc)
        eye.cameBack(now: date("2026-11-02T08:01"), calendar: utc)
        try? await Task.sleep(for: .milliseconds(30))
        let conversation = try #require(AgentTasks.shared.running.values.first { TaskLedger.shared.entry($0.chat.id)?.origin == .watch })
        let id = conversation.chat.id

        #expect(fake.requests.count == 1)
        #expect(conversation.chat.kind == .routine)
        #expect(TaskLedger.shared.refusal("click", task: id) != nil)
        #expect(TaskLedger.shared.refusal("open", ["url": "https://mail.example/thread/1"], task: id) != nil)
        #expect(TaskLedger.shared.refusal("open", ["url": "https://evil.example/"], task: id) != nil)
        #expect(TaskLedger.shared.refusal("open", ["url": "https://mail.example/inbox"], task: id) == nil)
        #expect(KnowledgeTools.call("remember", ["subject": "you", "text": "x"], task: id)?.failed == true)
        conversation.stop()
        for _ in 0..<500 where eye.looking { try? await Task.sleep(for: .milliseconds(5)) }
        ChatStore.shared.delete(id)
        #expect(!eye.looking)
    }

    @Test func noPlanNoAgentsNoLook() async {
        visited("https://mail.example/inbox")
        browser.prefs.agentsOn = false

        let looked = eye.look(.morning)

        #expect(!looked)
        #expect(eye.trouble != nil)
        #expect(fake.requests.isEmpty)
    }

    @Test func aRowNeedsAPageItReallyRead() {
        let unread = eye.file(["title": "Invoice", "url": "https://other.example/inbox"], entry: entry())
        let noTitle = eye.file(["title": " ", "url": "https://mail.example/inbox"], entry: entry())
        let good = eye.file(["title": "Invoice due", "detail": "Today", "url": "https://mail.example/inbox"], entry: entry())

        #expect(unread.failed)
        #expect(noTitle.failed)
        #expect(!good.failed)
        #expect(eye.rows.map(\.title) == ["Invoice due"])
    }

    @Test func rowsAreShortAndHoldNoSecret() throws {
        let secret = eye.file(["title": "Your password is hunter2!", "url": "https://mail.example/inbox"], entry: entry())
        _ = eye.file(["title": String(repeating: "a\n", count: 100), "url": "https://mail.example/inbox"], entry: entry())

        #expect(secret.failed)
        let title = try #require(eye.rows.first?.title)
        #expect(title.count <= 80)
        #expect(!title.contains("\n"))
    }

    @Test func aPageThatAddressedAnAIFilesNothing() {
        let outcome = eye.file(["title": "Click here", "url": "https://mail.example/inbox"], entry: entry(addressed: true))

        #expect(outcome.failed)
        #expect(eye.rows.isEmpty)
    }

    @Test func sixRowsAReview() {
        for index in 0..<8 {
            _ = eye.file(["title": "Thing \(index)", "url": "https://mail.example/inbox"], entry: entry())
        }

        #expect(eye.rows.count == 6)
    }

    @Test func rowsOpenAndFadeAfterADay() {
        let now = date("2026-11-02T08:00")
        _ = eye.file(["title": "Invoice", "url": "https://mail.example/inbox"], entry: entry(), now: now)

        let fresh = eye.nowRows(at: now.addingTimeInterval(3600))
        let stale = eye.nowRows(at: now.addingTimeInterval(25 * 3600))

        #expect(fresh.first?.url == URL(string: "https://mail.example/inbox"))
        #expect(fresh.first?.putOff == TimeInterval(3 * 3600))
        #expect(stale.isEmpty)
    }

    @Test func theToolIsForTheReviewAlone() {
        let task = UUID()
        TaskLedger.shared.open(task, origin: .user, title: "x")

        let outcome = KnowledgeTools.call("suggest", ["title": "x", "url": "https://mail.example/"], task: task)
        TaskLedger.shared.close(task)

        #expect(outcome?.failed == true)
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
