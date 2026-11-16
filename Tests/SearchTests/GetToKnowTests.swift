import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class GetToKnowTests {
    private var folder: URL!
    private var store: MemoryStore!
    private var book: AutofillBook!
    private var meet: GetToKnow!
    private var task: UUID!

    private var entry: TaskLedger.Entry { TaskLedger.Entry(origin: .meet, title: "Meet", hosts: ["github.com"]) }

    init() async throws {
        keepSettings(MemoryStore.onKey)
        addTeardownBlock { await self.tearDown() }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("know-\(UUID().uuidString)")
        store = MemoryStore(folder: folder.appendingPathComponent("Memory"))
        store.on = true
        book = AutofillBook(keeper: MemoryKeeper())
        meet = GetToKnow(file: folder.appendingPathComponent("know.json"))
        task = UUID()
        TaskLedger.shared.open(task, origin: .meet, title: "Meet", allowed: ["github.com"])
    }

    private func tearDown() async {
        TaskLedger.shared.close(task)
        try? FileManager.default.removeItem(at: folder)
    }

    private func trace(_ address: String, count: Int) -> History.Trace {
        History.Trace(key: address, address: address, title: "Page", url: URL(string: address)!, last: Date(), count: count)
    }

    private func call(_ name: String, _ arguments: [String: Any]) -> ToolOutcome {
        KnowledgeTools.call(name, arguments, task: task, store: store, meet: meet) ?? .failure("no tool")
    }

    @Test func nothingStartsOnItsOwn() async throws {
        let fake = FakeProvider(plan: .claude, echoes: true)
        Plans.shared.standIn(fake, for: .claude)
        defer { Plans.shared.standIn(nil, for: .claude) }
        let file = folder.appendingPathComponent("again.json")

        let fresh = GetToKnow(file: file)
        try? await Task.sleep(for: .milliseconds(30))

        #expect(fresh.stage == .idle)
        #expect(fake.requests.isEmpty)
    }

    @Test func aRunCutOffByQuittingIsNotPickedUpAgain() throws {
        let file = folder.appendingPathComponent("cut.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"stage":"reading","findings":[],"refused":[]}"#.utf8).write(to: file)

        let fresh = GetToKnow(file: file)

        #expect(fresh.stage == .done)
    }

    @Test func theSitesAreTheMostUsedWithoutBanksOrPasswordManagers() {
        let history = [trace("https://github.com/a", count: 9), trace("https://www.github.com/b", count: 2), trace("https://www.chase.com/x", count: 50),
                       trace("https://my.1password.com/x", count: 40), trace("https://linear.app/x", count: 3), trace("https://examplebank.com/", count: 30),
                       trace("http://localhost/", count: 99), trace("file:///tmp/a.html", count: 99)]

        let sites = GetToKnow.sites(from: history)

        #expect(sites == ["github.com", "linear.app"])
    }

    @Test func aRunStartsAsAReadOnlyTaskOnItsSitesAndOnlyWhenPressed() async throws {
        let fake = FakeProvider(plan: .claude, script: [.emit(.text("Done")), .emit(.finished(ProviderUsage()))])
        Plans.shared.standIn(fake, for: .claude)
        defer { Plans.shared.standIn(nil, for: .claude) }
        await Plans.shared.refresh()
        let prefs = Preferences()
        var seen: TaskLedger.Entry?

        let started = meet.begin(sites: ["github.com"], prefs: prefs, choice: Plans.shared.choice(.tasks, prefs)!, command: "/x/broadway", reading: 30)
        seen = TaskLedger.shared.entries.values.first { $0.origin == .meet && $0.allowed == ["github.com"] && $0.title != "Meet" }
        for _ in 0..<500 where meet.stage == .reading { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(started)
        #expect(seen?.origin.readOnly == true)
        #expect(fake.requests.count == 1)
        #expect(meet.stage == .done)
    }

    @Test func aboutTenMinutesThenItStops() async throws {
        let fake = FakeProvider(plan: .claude, script: [.hang])
        Plans.shared.standIn(fake, for: .claude)
        defer { Plans.shared.standIn(nil, for: .claude) }
        await Plans.shared.refresh()
        let prefs = Preferences()

        meet.begin(sites: ["github.com"], prefs: prefs, choice: Plans.shared.choice(.tasks, prefs)!, command: "/x/broadway", reading: 0.02)
        for _ in 0..<500 where meet.stage == .reading { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(meet.stage == .done)
        #expect(GetToKnow.reading == 600)
    }

    @Test func findingsWaitForTheReviewAndTouchNothing() {
        _ = call("remember", ["subject": "you", "text": "Works on Broadway", "url": "https://github.com/me"])
        _ = call("profile_found", ["field": "company", "value": "Acme"])
        _ = call("address_found", ["line1": "12 Elm St", "city": "Lisbon", "postal": "1000"])

        #expect(meet.waiting.count == 3)
        #expect(store.notes.isEmpty)
        #expect(!book.hasProfile)
        #expect(book.addresses.isEmpty)
    }

    @Test func aFindingNamesOnlyASiteTheAgentReallyRead() {
        TaskLedger.shared.saw(URL(string: "https://github.com/me"), addressed: false, task: task)

        _ = call("remember", ["subject": "you", "text": "Fact one", "url": "https://github.com/me"])
        _ = call("remember", ["subject": "you", "text": "Fact two", "url": "https://evil.example/x"])

        #expect(meet.findings.map(\.site) == ["github.com", "github.com"])
    }

    @Test func secretsAreRefusedAndOnlyTheirKindIsRecorded() throws {
        TaskLedger.shared.saw(URL(string: "https://github.com/me"), addressed: false, task: task)

        let note = call("remember", ["subject": "you", "text": "Card 4242 4242 4242 4242"])
        let profile = call("profile_found", ["field": "phone", "value": "password: hunter2"])
        let address = call("address_found", ["line1": "Code 482913 verification code", "city": "Lisbon"])
        let pressed = folder.appendingPathComponent("know.json")
        meet.keep(store: store, book: book)

        #expect(note.failed && profile.failed && address.failed)
        #expect(meet.findings.isEmpty)
        #expect(meet.refused.map(\.kind) == [.cardNumber, .password, .code])
        #expect(meet.refused.map(\.site) == ["github.com", "github.com", "github.com"])
        let written = try? String(contentsOf: pressed, encoding: .utf8)
        #expect(!(written?.contains("4242 4242") ?? false) && !(written?.contains("42424242") ?? false))
        #expect(!(written?.contains("hunter2") ?? false))
    }

    @Test func aFixCannotSlipASecretIn() throws {
        _ = call("remember", ["subject": "you", "text": "Works on Broadway"])
        let id = try #require(meet.findings.first?.id)

        let refused = meet.fix(id, text: "My password is hunter2")

        #expect(refused == .password)
        #expect(meet.findings.first?.text == "Works on Broadway")
    }

    @Test func keepFillsNotesProfileAndAddressesWithTheirSources() throws {
        TaskLedger.shared.saw(URL(string: "https://github.com/me"), addressed: false, task: task)
        _ = call("remember", ["subject": "people", "name": "Sam", "text": "Runs design"])
        _ = call("profile_found", ["field": "company", "value": "Acme"])
        _ = call("profile_found", ["field": "link", "value": "https://me.example"])
        _ = call("address_found", ["line1": "12 Elm St", "city": "Lisbon", "postal": "1000"])

        meet.keep(store: store, book: book)

        let line = try #require(store.note(.people, "Sam")?.entries.first)
        #expect(line.source?.by == "Get to Know Me")
        #expect(line.source?.pages == ["github.com"])
        #expect(book.profile.company == "Acme")
        #expect(book.profile.links == ["https://me.example"])
        #expect(book.addresses.count == 1)
        #expect(meet.waiting.isEmpty)
    }

    @Test func crossedOutFindingsAreNotKept() throws {
        _ = call("remember", ["subject": "you", "text": "Wrong fact"])
        let id = try #require(meet.findings.first?.id)

        meet.cross(id, store: store, book: book)
        meet.keep(store: store, book: book)

        #expect(store.notes.isEmpty)
        #expect(meet.findings.first?.state == .crossed)
    }

    @Test func aProfileAlreadyFilledIsLeftAsItIs() {
        var profile = AutofillProfile()
        profile.company = "Mine"
        book.save(profile: profile)
        _ = call("profile_found", ["field": "company", "value": "Theirs"])

        meet.keep(store: store, book: book)

        #expect(book.profile.company == "Mine")
    }

    @Test func crossingOutAfterKeepTakesItBack() throws {
        _ = call("remember", ["subject": "people", "name": "Sam", "text": "Runs design"])
        _ = call("address_found", ["line1": "12 Elm St", "city": "Lisbon"])
        _ = call("profile_found", ["field": "company", "value": "Acme"])
        meet.keep(store: store, book: book)

        for finding in meet.findings { meet.cross(finding.id, store: store, book: book) }

        #expect(store.note(.people, "Sam") == nil)
        #expect(book.addresses.isEmpty)
        #expect(book.profile.company == "")
    }

    @Test func anAddressAlreadyInTheBookIsNotAddedAgain() {
        book.save(address: AutofillAddress(line1: "12 Elm St.", city: "Lisbon", postal: "1000"))
        _ = call("address_found", ["line1": "12 elm st", "city": "Lisbon", "postal": "1000"])

        meet.keep(store: store, book: book)

        #expect(book.addresses.count == 1)
    }

    @Test func tidyDropsCopiesAndOldAddressesAndLeavesTheRest() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let thin = AutofillAddress(line1: "12 Elm St", postal: "1000")
        let full = AutofillAddress(name: "Ada", line1: "12 elm st.", city: "Lisbon", postal: "1000")
        let other = AutofillAddress(line1: "9 Oak Broadway", city: "Porto", postal: "4000")
        var old = Finding(kind: .address, text: "1 Old Rd", address: AutofillAddress(id: "gone", line1: "1 Old Rd", postal: "2000"),
                          seen: now.addingTimeInterval(-3 * 365 * 86_400), site: "shop.example")
        old.savedID = "gone"
        let recent = Finding(kind: .address, text: "5 New Rd", address: AutofillAddress(line1: "5 New Rd", postal: "3000"),
                             seen: now.addingTimeInterval(-86_400), site: "shop.example")
        let copy = Finding(kind: .note, subject: .you, text: "Likes tea", site: "a.example")
        let twin = Finding(kind: .note, subject: .you, text: "likes TEA", site: "b.example")

        let plan = Tidy.plan(addresses: [thin, full, other], findings: [old, recent, copy, twin], now: now)

        #expect(Set(plan.addresses) == [thin.id, "gone"])
        #expect(Set(plan.findings) == [old.id, twin.id])
    }

    @Test func tidyUpClearsThemAndCopiesInNotes() throws {
        book.save(address: AutofillAddress(id: "a", line1: "12 Elm St", city: "Lisbon", postal: "1000"))
        book.save(address: AutofillAddress(id: "b", line1: "12 Elm St", postal: "1000"))
        store.save(.you, name: "About you", text: "# About you\n\n- Likes tea\n- likes tea\n- Likes rain\n")

        meet.tidyUp(store: store, book: book)

        #expect(book.addresses.map(\.id) == ["a"])
        #expect(store.note(.you, "About you")?.entries.map(\.bare) == ["Likes tea", "Likes rain"])
    }

    @Test func aReadOnlyTaskCannotChangeASiteOrLeaveItsSites() {
        for tool in ["click", "type", "press", "navigate"] {
            #expect(TaskLedger.shared.refusal(tool, task: task) != nil, "\(tool)")
        }
        #expect(TaskLedger.shared.refusal("text", task: task) == nil)
        #expect(TaskLedger.shared.refusal("open", ["url": "https://github.com/me"], task: task) == nil)
        #expect(TaskLedger.shared.refusal("open", ["url": "https://gist.github.com/me"], task: task) == nil)
        #expect(TaskLedger.shared.refusal("open", ["url": "https://evil.example/?data=secret"], task: task) != nil)
        #expect(TaskLedger.shared.refusal("open", ["url": "https://notgithub.com/"], task: task) != nil)
        #expect(TaskLedger.shared.refusal("open", ["url": "https://github.com.evil.example/"], task: task) != nil)
    }

    @Test func aTaskThePersonStartedIsNotLimited() {
        let mine = UUID()
        TaskLedger.shared.open(mine, origin: .user, title: "Mine")
        defer { TaskLedger.shared.close(mine) }

        #expect(TaskLedger.shared.refusal("click", task: mine) == nil)
        #expect(TaskLedger.shared.refusal("open", ["url": "https://anywhere.example"], task: mine) == nil)
    }

    @Test func onlyGetToKnowMeCanSuggest() {
        let mine = UUID()
        TaskLedger.shared.open(mine, origin: .user, title: "Mine")
        defer { TaskLedger.shared.close(mine) }

        let fromTask = KnowledgeTools.call("profile_found", ["field": "name", "value": "Eve"], task: mine, store: store, meet: meet)
        let fromOutside = KnowledgeTools.call("address_found", ["line1": "1 Road", "city": "Lisbon"], task: nil, store: store, meet: meet)

        #expect(fromTask?.failed == true)
        #expect(fromOutside?.failed == true)
        #expect(meet.findings.isEmpty)
    }

    @Test func itComesBackAfterALaunch() async throws {
        _ = call("remember", ["subject": "you", "text": "A fact"])
        await Task.detached { }.value
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("know.json").path) {
            try? await Task.sleep(for: .milliseconds(5))
        }

        let fresh = GetToKnow(file: folder.appendingPathComponent("know.json"))

        #expect(fresh.findings.first?.text == "A fact")
    }
}
