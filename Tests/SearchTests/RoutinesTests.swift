import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class RoutinesTests {
    private var folder: URL!
    private var routines: Routines!
    private var browser: Browser!
    private var fake: FakeProvider!
    private var utc: Calendar!

    init() async throws {
        keepSetting(Shared.prefs, \.ai, "ai")
        keepSetting(Shared.prefs, \.agentsOn, "agents.on")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("routines-\(UUID().uuidString)")
        Store.settings.removeObject(forKey: Routines.onKey)
        routines = Routines(file: folder.appendingPathComponent("routines.json"))
        routines.command = "/x/broadway"
        browser = Browser(record: WindowRecord())
        browser.prefs.ai = true
        browser.prefs.agentsOn = true
        fake = FakeProvider(plan: .claude, echoes: true)
        Plans.shared.standIn(fake, for: .claude)
        await Plans.shared.refresh()
        utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
    }

    private func tearDown() async {
        routines.on = false
        Store.settings.removeObject(forKey: Routines.onKey)
        Plans.shared.standIn(nil, for: .claude)
        browser.prefs.agentsOn = false
        browser.closeAll()
        browser = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func date(_ text: String) -> Date {
        let format = ISO8601DateFormatter()
        return format.date(from: text + ":00Z")!
    }

    private func finished(_ routine: Routine) async {
        for _ in 0..<500 where routines.isRunning(routine.id) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func added(_ schedule: String, _ prompt: String = "check prices", at now: Date) -> Routine {
        guard case .added(let routine) = routines.add(schedule: schedule, prompt: prompt, now: now) else { fatalError("not added") }
        return routine
    }

    @Test func theManualsScheduleWordsAllParse() {
        #expect(RoutineSchedule("daily 9:00") == .daily(hour: 9, minute: 0))
        #expect(RoutineSchedule("weekdays 18:30") == .weekdays(hour: 18, minute: 30))
        #expect(RoutineSchedule("mon,thu 8:15") == .days([2, 5], hour: 8, minute: 15))
        #expect(RoutineSchedule("hourly") == .every(hours: 1))
        #expect(RoutineSchedule("every 2h") == .every(hours: 2))
        #expect(RoutineSchedule("  DAILY   9:00 ") == .daily(hour: 9, minute: 0))
    }

    @Test func whatIsNotAScheduleIsRefused() {
        for text in ["", "daily", "daily 25:00", "daily 9:60", "daily 9", "every", "every 0h", "every 25h", "every 2", "mon,xyz 8:15", "sometimes 9:00", "hourly 9:00", "daily 9:00 extra"] {
            #expect(RoutineSchedule(text) == nil, "\(text)")
        }
    }

    @Test func scheduleWordsRoundTrip() {
        for text in ["daily 9:00", "weekdays 18:30", "mon,thu 8:15", "hourly", "every 2h"] {
            #expect(RoutineSchedule(text)?.words == text)
        }
    }

    @Test func dailyIsTodayIfStillToComeElseTomorrow() {
        let schedule = RoutineSchedule("daily 9:00")!

        #expect(schedule.next(after: date("2026-11-02T08:00"), calendar: utc) == date("2026-11-02T09:00"))
        #expect(schedule.next(after: date("2026-11-02T09:00"), calendar: utc) == date("2026-11-03T09:00"))
        #expect(schedule.next(after: date("2026-11-02T10:00"), calendar: utc) == date("2026-11-03T09:00"))
    }

    @Test func weekdaysSkipTheWeekend() {
        let schedule = RoutineSchedule("weekdays 18:30")!

        #expect(schedule.next(after: date("2026-11-06T19:00"), calendar: utc) == date("2026-11-09T18:30"))
        #expect(schedule.next(after: date("2026-11-07T10:00"), calendar: utc) == date("2026-11-09T18:30"))
    }

    @Test func namedDaysLandOnThem() {
        let schedule = RoutineSchedule("mon,thu 8:15")!

        #expect(schedule.next(after: date("2026-11-02T09:00"), calendar: utc) == date("2026-11-05T08:15"))
        #expect(schedule.next(after: date("2026-11-05T09:00"), calendar: utc) == date("2026-11-09T08:15"))
    }

    @Test func everyCountsFromTheLastRun() {
        #expect(RoutineSchedule("every 2h")!.next(after: date("2026-11-02T09:10"), calendar: utc) == date("2026-11-02T11:10"))
        #expect(RoutineSchedule("hourly")!.next(after: date("2026-11-02T09:10"), calendar: utc) == date("2026-11-02T10:10"))
    }

    @Test func aTimeThatDoesNotExistOnADaylightChangeStillRuns() throws {
        var lisbon = Calendar(identifier: .gregorian)
        lisbon.timeZone = try #require(TimeZone(identifier: "Europe/Lisbon"))
        let schedule = RoutineSchedule("daily 1:30")!

        let next = schedule.next(after: date("2027-03-27T12:00"), calendar: lisbon)

        #expect(next == date("2027-03-28T01:00"))
    }

    @Test func aScheduleAtTheStartOfTheCommandLeavesTheTask() {
        #expect(RoutineSchedule.leading(["daily 9:00", "check", "prices"])?.schedule == "daily 9:00")
        #expect(RoutineSchedule.leading(["daily", "9:00", "check"])?.rest == ["check"])
        #expect(RoutineSchedule.leading(["hourly", "check"])?.schedule == "hourly")
        #expect(RoutineSchedule.leading(["2h", "check"])?.schedule == "every 2h")
        #expect(RoutineSchedule.leading(["every", "2h", "check"])?.rest == ["check"])
        #expect(RoutineSchedule.leading(["soon", "check"]) == nil)
    }

    @Test func onlyAMissedRunIsDueAndATurnedOffRoutineNever() {
        let waiting = Routine(name: "a", schedule: "daily 9:00", prompt: "x", created: date("2026-11-02T08:00"))
        var early = waiting
        early.created = date("2026-11-02T09:30")
        var off = waiting
        off.on = false

        let due = RoutineClock.due([waiting, early, off], at: date("2026-11-02T09:40"), calendar: utc)

        #expect(due.map(\.id) == [waiting.id])
    }

    @Test func manyMissedRunsAreOneCatchUp() async throws {
        routines.begin(for: browser)
        routines.on = true
        let routine = added("hourly", at: date("2026-11-01T00:00"))

        routines.tick(now: date("2026-11-02T12:00"), calendar: utc)
        await finished(routine)
        routines.tick(now: date("2026-11-02T12:01"), calendar: utc)
        await finished(routine)

        #expect(fake.requests.count == 1)
        #expect(routines.routines.first?.lastRun == date("2026-11-02T12:00"))
    }

    @Test func offByDefaultNothingRuns() async {
        routines.begin(for: browser)
        _ = added("hourly", at: date("2026-11-01T00:00"))

        routines.tick(now: date("2026-11-02T12:00"), calendar: utc)
        try? await Task.sleep(for: .milliseconds(30))

        #expect(!routines.on)
        #expect(fake.requests.isEmpty)
    }

    @Test func agentsOffStopsThemToo() async {
        routines.begin(for: browser)
        routines.on = true
        browser.prefs.agentsOn = false
        _ = added("hourly", at: date("2026-11-01T00:00"))

        routines.tick(now: date("2026-11-02T12:00"), calendar: utc)
        try? await Task.sleep(for: .milliseconds(30))

        #expect(fake.requests.isEmpty)
    }

    @Test func noMoreThanTwoRunAtOnceAndTheRestWait() async {
        fake.echoes = false
        fake.script = [.hang]
        routines.begin(for: browser)
        routines.on = true
        let list = (0..<3).map { added("hourly", "job \($0)", at: date("2026-11-01T00:00")) }

        routines.tick(now: date("2026-11-02T12:00"), calendar: utc)

        #expect(list.filter { routines.isRunning($0.id) }.count == 2)
        #expect(routines.routines[2].lastRun == nil)
        for routine in routines.routines { routines.delete(routine.id) }
        try? await Task.sleep(for: .milliseconds(30))
    }

    @Test func aRoutineIsAReadOnlyTaskOnItsOwnChat() async throws {
        fake.echoes = false
        fake.script = [.hang]
        routines.begin(for: browser)
        routines.on = true
        let routine = added("hourly", "check https://prices.example/list", at: date("2026-11-01T00:00"))
        let earlier = Set(AgentTasks.shared.running.keys)

        routines.tick(now: date("2026-11-02T12:00"), calendar: utc)
        let conversation = try #require(AgentTasks.shared.running.first { !earlier.contains($0.key) }?.value)
        let entry = try #require(TaskLedger.shared.entry(conversation.chat.id))

        #expect(entry.origin == .routine)
        #expect(conversation.chat.kind == .routine)
        #expect(entry.allowed?.contains("prices.example") == true)
        #expect(entry.allowed?.contains("evil.example") == false)
        #expect(TaskLedger.shared.refusal("click", task: conversation.chat.id) != nil)
        #expect(TaskLedger.shared.refusal("type", task: conversation.chat.id) != nil)
        #expect(TaskLedger.shared.refusal("open", ["url": "https://evil.example/?x=1"], task: conversation.chat.id) != nil)
        #expect(KnowledgeTools.call("remember", ["subject": "you", "text": "From a page"], task: conversation.chat.id)?.failed ?? false)
        let id = conversation.chat.id
        routines.delete(routine.id)
        for _ in 0..<500 where AgentTasks.shared.running[id] != nil { try? await Task.sleep(for: .milliseconds(5)) }
        ChatStore.shared.delete(id)
    }

    @Test func aToolNobodyListedIsRefusedInAReadOnlyTask() {
        let task = UUID()
        TaskLedger.shared.open(task, origin: .routine, title: "x")

        let refused = TaskLedger.shared.refusal("sign_in", task: task)
        let read = TaskLedger.shared.refusal("text", task: task)
        TaskLedger.shared.close(task)

        #expect(refused != nil)
        #expect(read == nil)
    }

    @Test func aResultBecomesANowRow() async throws {
        routines.begin(for: browser)
        routines.on = true
        let routine = added("hourly", at: date("2026-11-01T00:00"))

        routines.tick(now: date("2026-11-02T12:00"), calendar: utc)
        await finished(routine)
        let rows = routines.rows(at: Date())

        #expect(rows.count == 1)
        #expect(rows.first?.title == "check prices")
        #expect(rows.first?.detail.hasPrefix("Fake answer") == true)
        if let chat = routines.routines.first?.result?.chat { ChatStore.shared.delete(chat) }
    }

    @Test func aFailureSaysSoUnderNow() async throws {
        fake.echoes = false
        fake.script = [.fail(.planOut("Your plan has run out"))]
        routines.begin(for: browser)
        routines.on = true
        let routine = added("hourly", at: date("2026-11-01T00:00"))

        routines.tick(now: date("2026-11-02T12:00"), calendar: utc)
        await finished(routine)

        #expect(routines.rows(at: Date()).first?.detail == "Didn't finish: Your plan has run out")
        #expect(routines.rows(at: Date()).first?.symbol == "exclamationmark.circle")
        if let chat = routines.routines.first?.result?.chat { ChatStore.shared.delete(chat) }
    }

    @Test func aRunThatGoesOnTooLongIsStopped() async throws {
        fake.echoes = false
        fake.script = [.hang]
        routines.longestRun = 0.02
        routines.begin(for: browser)
        routines.on = true
        let routine = added("hourly", at: date("2026-11-01T00:00"))

        routines.tick(now: date("2026-11-02T12:00"), calendar: utc)
        await finished(routine)

        #expect(!routines.isRunning(routine.id))
        #expect(routines.routines.first?.result?.failed == true)
        if let chat = routines.routines.first?.result?.chat { ChatStore.shared.delete(chat) }
    }

    @Test func runNowIsAnExplicitPressAndNeedsAgents() async throws {
        routines.begin(for: browser)
        let routine = added("daily 9:00", at: Date())

        browser.prefs.agentsOn = false
        let refused = routines.runNow(routine.id)
        browser.prefs.agentsOn = true
        let ran = routines.runNow(routine.id)
        await finished(routine)

        #expect(!refused)
        #expect(ran)
        #expect(fake.requests.count == 1)
        if let chat = routines.routines.first?.result?.chat { ChatStore.shared.delete(chat) }
    }

    @Test func turnOffAndDelete() throws {
        let routine = added("daily 9:00", at: Date())

        routines.setOn(routine.id, false)

        #expect(routines.routines.first?.on == false)

        routines.delete(routine.id)

        #expect(routines.routines.isEmpty)
    }

    @Test func theyComeBackAfterALaunch() async throws {
        let file = folder.appendingPathComponent("routines.json")
        _ = added("daily 9:00", at: Date())
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: file.path) { try? await Task.sleep(for: .milliseconds(5)) }

        let fresh = Routines(file: file)

        #expect(fresh.routines.map(\.schedule) == ["daily 9:00"])
    }

    @Test func broadwayEveryAddsListsAndDeletes() throws {
        let added = routines.answer(["words": ["daily 9:00", "check", "prices"]])
        let listed = routines.answer(["words": [String]()])
        let refused = routines.answer(["words": ["soon", "check"]])
        let empty = routines.answer(["words": ["hourly"]])
        let id = try #require((added["added"] as? [String: Any])?["id"] as? String)
        let deleted = routines.answer(["words": ["delete", id]])

        #expect(((added["added"] as? [String: Any])?["prompt"] as? String) == "check prices")
        #expect((added["running"] as? Bool) == false)
        #expect((listed["routines"] as? [[String: Any]])?.count == 1)
        #expect(refused["error"] != nil)
        #expect(empty["error"] != nil)
        #expect((deleted["deleted"] as? String) == "check prices")
        #expect(routines.routines.isEmpty)
    }

    @Test func theAnswerLineIsItsFirstRealLine() {
        #expect(RoutineClock.line("\n\n  Prices fell  \nmore") == "Prices fell")
        #expect(RoutineClock.line(String(repeating: "a", count: 300)).count == 140)
    }

    @Test func hostsNamedInAPromptAreFound() {
        #expect(RoutineClock.hosts(in: "check https://www.prices.example/list and shop.com") == ["prices.example", "shop.com"])
    }
}
