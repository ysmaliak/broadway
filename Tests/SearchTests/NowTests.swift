import AppKit
import Testing
@testable import Search

@MainActor
private final class FakeBoard: CopiedBoard {
    var change = 1
    var secret = false
    var free = true
    var linky = true
    var words: String?
    var reads = 0

    func looksLikeLink() async -> Bool { linky }

    func text() -> String? {
        reads += 1
        return words
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class NowTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var folder: URL!
    private var floating = false

    init() async throws {
        keepSettings("newtab.floating", "live.on", "field.now")
        addTeardownBlock { await self.tearDown() }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("now-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        floating = Shared.prefs.floatingNewTab
        Shared.prefs.floatingNewTab = true
    }

    private func tearDown() async {
        try? FileManager.default.removeItem(at: folder)
        Shared.prefs.floatingNewTab = floating
    }

    private func fresh() -> Browser {
        _ = NSApplication.shared
        return Browser(record: WindowRecord())
    }

    private func meeting(in minutes: Double, link: String = "") -> Meeting {
        let start = now.addingTimeInterval(minutes * 60)
        return Meeting(event: CalendarEvent(id: "m", title: "Standup", start: start, end: start.addingTimeInterval(1800),
                                            location: link))
    }

    private func settled(_ look: (@escaping @MainActor () -> Void) -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            look { done.resume() }
        }
    }

    @Test func anyoneCanAddASource() throws {
        let browser = fresh()
        defer { browser.closeAll() }
        let memory = NowMemory(file: folder.appendingPathComponent("now.json"))
        var ran = false
        defer { NowBoard.remove("test") }

        NowBoard.add("test") { _, _ in
            [NowRow(id: "test:1", title: "A task finished", detail: "Agent", symbol: "checkmark") { _ in ran = true }]
        }
        let rows = NowBoard.rows(for: browser, at: Date(), memory: memory)
        try #require(NowBoard.row("test:1")).run(browser)

        #expect(rows.contains { $0.id == "test:1" })
        #expect(ran)
    }

    @Test func integrationRowsBelongToTheCurrentSpace() {
        let browser = fresh()
        let live = LiveFolders.shared
        let saved = browser.prefs.liveFolders
        let enabled = Store.settings.object(forKey: IntegrationNow.key)
        browser.prefs.liveFolders = true
        Store.settings.set(true, forKey: IntegrationNow.key)
        let other = live.add(name: "Other", source: .reviewRequests, space: UUID())
        let mine = live.add(name: "Mine", source: .reviewRequests, space: browser.spaceID)
        let otherKey = "https://github.com/test/other/pull/987654"
        let myKey = "https://github.com/test/mine/pull/987654"
        live.apply(.items([LiveItem(key: otherKey, title: "Other space")], nil), to: other.id)
        live.apply(.items([LiveItem(key: myKey, title: "This space")], nil), to: mine.id)
        defer {
            live.remove(other.id)
            live.remove(mine.id)
            browser.prefs.liveFolders = saved
            if let enabled { Store.settings.set(enabled, forKey: IntegrationNow.key) }
            else { Store.settings.removeObject(forKey: IntegrationNow.key) }
            browser.closeAll()
        }

        let rows = NowBoard.rows(for: browser, at: Date())

        #expect(rows.contains { $0.id == "integration:\(myKey)" })
        #expect(!rows.contains { $0.id == "integration:\(otherKey)" })
    }

    @Test func rowsSitFirstAndNoRowIsLitAtRest() {
        let browser = fresh()
        defer { browser.closeAll() }
        browser.newTab()
        browser.active?.go(to: URL(string: "https://example.com/")!)
        browser.newTab()
        NowBoard.add("test") { _, _ in [NowRow(id: "test:2", title: "Row", detail: "", symbol: "star") { _ in }] }
        defer { NowBoard.remove("test") }

        browser.retype()

        #expect(browser.fieldSections.first?.title == "Now")
        #expect(browser.fieldSections.first { $0.title == "Recent Tabs" } != nil)
        #expect(browser.picked == nil)
    }

    @Test func aPrivateWindowShowsNoNowRows() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { browser.closeAll() }
        NowBoard.add("test") { _, _ in [NowRow(id: "test:4", title: "Row", detail: "", symbol: "star") { _ in }] }
        defer { NowBoard.remove("test") }

        browser.retype()

        #expect(browser.offers.isEmpty)
    }

    @Test func doneStaysGoneAcrossALaunch() async {
        let file = folder.appendingPathComponent("now.json")
        let memory = NowMemory(file: file)

        memory.done("a", at: Date())
        let expectation = Expectation(description: "written")
        Disk.write(file.deletingLastPathComponent().appendingPathComponent("flush")) {
            expectation.fulfill()
            return nil
        }
        await fulfillment(of: [expectation], timeout: 5)
        let reopened = NowMemory(file: file)

        #expect(reopened.hides("a", at: Date()))
        #expect(!reopened.hides("b", at: Date()))
    }

    @Test func putOffComesBack() {
        let memory = NowMemory(file: folder.appendingPathComponent("now.json"))

        memory.putOff("a", for: 3600, at: now)

        #expect(memory.hides("a", at: now.addingTimeInterval(3500)))
        #expect(!memory.hides("a", at: now.addingTimeInterval(3700)))
    }

    @Test func backspaceAndOptionReturnOnlyTouchAPickedNowRow() throws {
        let browser = fresh()
        defer { browser.closeAll() }
        NowBoard.add("test") { _, _ in [NowRow(id: "test:\(UUID())", title: "Row", detail: "", symbol: "star") { _ in }] }
        defer { NowBoard.remove("test") }
        let plain = Suggestion(key: "a", title: "b", url: URL(string: "https://example.com/")!, kind: .visited)
        browser.offers = [plain]
        browser.picked = 0

        let handled = browser.handleNowKey(KeyCombo("delete", command: false))

        #expect(!handled)
    }

    @Test func backspaceMarksDoneAndTheRowLeaves() throws {
        let browser = fresh()
        defer { browser.closeAll() }
        let id = "test:\(UUID())"
        NowBoard.add("test") { _, _ in [NowRow(id: id, title: "Row", detail: "", symbol: "star") { _ in }] }
        defer { NowBoard.remove("test") }
        browser.retype()
        browser.picked = 0

        let handled = browser.handleNowKey(KeyCombo("delete", command: false))

        #expect(handled)
        #expect(!browser.offers.contains { $0.key == "Row" })
    }

    @Test func optionReturnPutsOffForTheRowsOwnTime() {
        let browser = fresh()
        defer { browser.closeAll() }
        let id = "test:\(UUID())"
        NowBoard.add("test") { _, _ in [NowRow(id: id, title: "Row", detail: "", symbol: "star", putOff: 60) { _ in }] }
        defer { NowBoard.remove("test") }
        browser.retype()
        browser.picked = 0

        let handled = browser.handleNowKey(KeyCombo("return", command: false, option: true))

        #expect(handled)
        #expect(NowMemory.shared.hides(id, at: Date().addingTimeInterval(30)))
        #expect(!NowMemory.shared.hides(id, at: Date().addingTimeInterval(120)))
    }

    @Test func takingARowRetiresIt() {
        let browser = fresh()
        defer { browser.closeAll() }
        let id = "test:\(UUID())"
        var ran = 0
        NowBoard.add("test") { _, _ in [NowRow(id: id, title: "Row", detail: "", symbol: "star") { _ in ran += 1 }] }
        defer { NowBoard.remove("test") }
        browser.retype()
        let row = browser.offers[0]

        browser.take(row)
        browser.retype()

        #expect(ran == 1)
        #expect(!browser.offers.contains { $0.key == "Row" })
    }

    @Test func theMenuOffersDoneAndPutOff() {
        let browser = fresh()
        defer { browser.closeAll() }
        NowBoard.add("test") { _, _ in [NowRow(id: "test:\(UUID())", title: "Row", detail: "", symbol: "star") { _ in }] }
        defer { NowBoard.remove("test") }
        browser.retype()

        let titles = browser.fieldMenuItems(for: browser.offers[0]).map(\.title)

        #expect(titles.contains("Mark Done"))
        #expect(titles.contains("Put Off"))
        #expect(!titles.contains("Add to Favorites"))
    }

    @Test func aMeetingWithinTheHourTurnsIntoJoin() throws {
        let link = "https://meet.google.com/abc-defg-hij"

        let call = meeting(in: 40, link: link)
        let early = try #require(NowBoard.meetingRow(call, at: now))
        let soon = try #require(NowBoard.meetingRow(call, at: now.addingTimeInterval(30 * 60)))

        #expect(early.title == "Standup")
        #expect(early.stays)
        #expect(early.putOff == (25 * 60))
        #expect(soon.title == "Join Standup")
        #expect(!soon.stays)
        #expect(early.id == soon.id)
        #expect(NowBoard.meetingRow(meeting(in: 90, link: link), at: now) == nil)
        #expect(NowBoard.meetingRow(nil, at: now) == nil)
    }

    @Test func aFreshDownloadThatIsStillThere() throws {
        let file = folder.appendingPathComponent("report.pdf")
        try Data("x".utf8).write(to: file)
        let keep = Keep(name: "report.pdf", from: "", path: file.path, date: now.addingTimeInterval(-60))
        var gone = keep
        gone.path = folder.appendingPathComponent("gone.pdf").path
        var old = keep
        old.date = now.addingTimeInterval(-3600)

        #expect(NowBoard.downloadRow([keep], at: now)?.title == "report.pdf")
        #expect(NowBoard.downloadRow([gone], at: now) == nil)
        #expect(NowBoard.downloadRow([old], at: now) == nil)
    }

    @Test func aCopiedLinkShowsForFiveMinutes() {
        let link = URL(string: "https://example.com/a")!
        let copy = CopiedLink.Copy(change: 7, at: now, link: link)

        #expect(NowBoard.copiedRow(copy, at: now.addingTimeInterval(240), showing: nil) != nil)
        #expect(NowBoard.copiedRow(copy, at: now.addingTimeInterval(360), showing: nil) == nil)
    }

    @Test func theLinkOfThePageYouAreOnIsNotOffered() {
        let link = URL(string: "https://example.com/a")!
        let copy = CopiedLink.Copy(change: 7, at: now, link: link)

        let row = NowBoard.copiedRow(copy, at: now, showing: link)

        #expect(row == nil)
    }

    @Test func aKnownLinkIsNamedAndAnUnreadOneIsNot() {
        let read = CopiedLink.Copy(change: 1, at: now, link: URL(string: "https://example.com/a")!)
        let unread = CopiedLink.Copy(change: 2, at: now, link: nil)

        #expect(NowBoard.copiedRow(read, at: now, showing: nil)?.title.contains("example.com") == true)
        #expect(NowBoard.copiedRow(unread, at: now, showing: nil)?.title == "Open Copied Link")
    }

    @Test func onlyAWholeLinkCounts() {
        #expect(CopiedLink.link(in: " https://example.com/a?b=1\n")?.host() == "example.com")
        #expect(CopiedLink.link(in: "read https://example.com/a today") == nil)
        #expect(CopiedLink.link(in: "ftp://example.com/a") == nil)
        #expect(CopiedLink.link(in: "plain words") == nil)
    }

    @Test func whatWasOnTheClipboardAtLaunchIsNotJustCopied() {
        let board = FakeBoard()
        board.words = "https://example.com/a"
        let copied = CopiedLink(board: board)

        copied.look(at: now, skipping: false) {}

        #expect(copied.copy == nil)
        #expect(board.reads == 0)
    }

    @Test func askingIsNeverDoneBehindYourBack() async {
        let board = FakeBoard()
        board.free = false
        board.words = "https://example.com/a"
        let copied = CopiedLink(board: board)
        board.change = 2

        await settled { done in copied.look(at: now, skipping: false, then: done) }

        #expect(copied.copy?.change == 2)
        #expect(copied.copy?.link == nil)
        #expect(board.reads == 0)
        #expect(copied.read()?.host() == "example.com")
    }

    @Test func allowedToReadTheLinkIsKept() async {
        let board = FakeBoard()
        board.words = "https://example.com/a"
        let copied = CopiedLink(board: board)
        board.change = 2

        await settled { done in copied.look(at: now, skipping: false, then: done) }

        #expect(copied.copy?.link?.host() == "example.com")
    }

    @Test func secretsAndPrivateTabsAreSkipped() {
        let board = FakeBoard()
        board.words = "https://example.com/a"
        let copied = CopiedLink(board: board)

        board.change = 2
        board.secret = true
        copied.look(at: now, skipping: false) { Issue.record("kept a secret") }
        board.change = 3
        board.secret = false
        copied.look(at: now, skipping: true) { Issue.record("kept a private copy") }

        #expect(copied.copy == nil)
        #expect(board.reads == 0)
    }

    @Test func aCopyThatIsNotALinkClearsTheLast() async {
        let board = FakeBoard()
        board.words = "https://example.com/a"
        let copied = CopiedLink(board: board)
        board.change = 2
        await settled { done in copied.look(at: now, skipping: false, then: done) }

        board.change = 3
        board.linky = false
        copied.look(at: now, skipping: false) { Issue.record("kept words") }

        #expect(copied.copy == nil)
    }

    @Test func aPrivatePasteboardReadsThroughTheRealCalls() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("now-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let board = MacClipboard(board: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/a", forType: .string)

        let linky = await board.looksLikeLink()
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))

        #expect(linky)
        #expect(board.secret)
    }

    @Test func aTestRunNeverReadsTheRealClipboard() {
        #expect(Store.testing)
        CopiedLink.shared.look(skipping: false) { Issue.record("read the clipboard") }
        #expect(CopiedLink.shared.copy == nil)
    }
}
