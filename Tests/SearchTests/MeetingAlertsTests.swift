import AppKit
import EventKit
import Testing
@testable import Search

private final class AlertCalendar: CalendarSource, @unchecked Sendable {
    var stored: [CalendarEvent]
    var granted: Bool
    var reads = 0

    init(_ events: [CalendarEvent] = [], granted: Bool = true) {
        stored = events
        self.granted = granted
    }

    var hasAccess: Bool { granted }

    func requestAccess() async -> Bool { granted }

    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        reads += 1
        return stored.filter { $0.end > start && $0.start < end }
    }

    func calendars() -> [MeetingCalendar] {
        [MeetingCalendar(id: "work", title: "Work"), MeetingCalendar(id: "home", title: "Home")]
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class MeetingAlertsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var suite: String!
    private var store: UserDefaults!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        suite = "meeting-alerts-tests-\(UUID().uuidString)"
        store = UserDefaults(suiteName: suite)
    }

    private func tearDown() async {
        store.removePersistentDomain(forName: suite)
        MeetingLink.testHosts = [:]
    }

    private func event(_ id: String = "e", in minutes: Double, lasting: Double = 30, link: String = "",
                       calendar: String = "work") -> CalendarEvent {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEvent(id: id, title: id, start: start, end: start.addingTimeInterval(lasting * 60),
                             notes: link, calendar: calendar)
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    private final class Clock {
        var now: Date
        var armed: [Date?] = []
        var shown: [[String]] = []
        init(_ now: Date) { self.now = now }
    }

    private func alerts(_ source: AlertCalendar, lead: MeetingLead = .one, clock: Clock) -> MeetingAlerts {
        let prefs = MeetingAlertPrefs(store: store)
        prefs.lead = lead
        let made = MeetingAlerts(meetings: Meetings(source: source), prefs: prefs, store: store)
        made.clock = { clock.now }
        made.arm = { clock.armed.append($0) }
        made.present = { clock.shown.append($0.map(\.event.id)) }
        return made
    }

    @Test func eachLeadTimeAlertsThatLongBeforeTheStart() {
        let meeting = event(in: 5)

        #expect(MeetingAlertRules.plan([meeting], at: now, lead: MeetingLead.ten.seconds).due.count == 1)
        #expect(MeetingAlertRules.plan([meeting], at: now, lead: MeetingLead.five.seconds).due.count == 1)
        #expect(MeetingAlertRules.plan([meeting], at: now, lead: MeetingLead.two.seconds).next == meeting.start.addingTimeInterval(-120))
        #expect(MeetingAlertRules.plan([meeting], at: now, lead: MeetingLead.one.seconds).next == meeting.start.addingTimeInterval(-60))
        #expect(MeetingAlertRules.plan([meeting], at: now, lead: MeetingLead.start.seconds).next == meeting.start)
        #expect(MeetingAlertRules.plan([meeting], at: now, lead: MeetingLead.one.seconds).due.isEmpty)
    }

    @Test func theDefaultIsAMinuteBeforeAndOnOnceCalendarsAreAllowed() {
        let prefs = MeetingAlertPrefs(store: store)

        let blocked = MeetingAlerts(meetings: Meetings(source: AlertCalendar(granted: false)), prefs: prefs, store: store)
        let allowed = MeetingAlerts(meetings: Meetings(source: AlertCalendar()), prefs: prefs, store: store)

        #expect(prefs.lead == .one)
        #expect(prefs.chosen == nil)
        #expect(!blocked.wanted)
        #expect(allowed.wanted)
        prefs.chosen = false
        #expect(!allowed.wanted)
    }

    @Test func skipsDeclinedAllDayFinishedAndQuietCalendars() {
        var declined = event("declined", in: 0.5)
        declined.declined = true
        var allDay = event("allDay", in: 0.5)
        allDay.allDay = true
        let old = event("old", in: -11)
        let quiet = event("quiet", in: 0.5, calendar: "home")
        let real = event("real", in: 0.5)

        let plan = MeetingAlertRules.plan([declined, allDay, old, quiet, real], at: now, lead: 60, skip: ["home"])

        #expect(plan.due.map(\.event.id) == ["real"])
    }

    @Test func staysUntilTenMinutesInOrTheEnd() {
        let long = event("long", in: -9)
        let short = event("short", in: -2, lasting: 5)

        let plan = MeetingAlertRules.plan([long, short], at: now, lead: 60)

        #expect(plan.due.map(\.event.id) == ["long", "short"])
        #expect(plan.next == long.start.addingTimeInterval(600))
        #expect(MeetingAlertRules.gone(short) == short.end)
    }

    @Test func dismissedStaysAwayAndSnoozeComesBackAtTheStartOrInTwoMinutes() {
        let soon = event("soon", in: 1)
        let started = event("started", in: -1)
        let key = MeetingAlertRules.key(soon)

        let dismissed = MeetingAlertRules.plan([soon], at: now, lead: 120, dismissed: [key])
        let early = MeetingAlertRules.snooze(soon, at: now)
        let late = MeetingAlertRules.snooze(started, at: now)
        let snoozed = MeetingAlertRules.plan([soon], at: now, lead: 120, snoozed: [key: early])

        #expect(dismissed.due.isEmpty)
        #expect(dismissed.next == nil)
        #expect(early == soon.start)
        #expect(late == now.addingTimeInterval(120))
        #expect(snoozed.due.isEmpty)
        #expect(snoozed.next == soon.start)
    }

    @Test func knowsEveryProvidersLink() {
        #expect(MeetingLink.service(of: url("https://meet.google.com/abc-defg-hij")) == .meet)
        #expect(MeetingLink.service(of: url("https://us02web.zoom.us/j/81234567890?pwd=Zx")) == .zoom)
        #expect(MeetingLink.service(of: url("https://acme.zoom.us/w/81234567890")) == .zoom)
        #expect(MeetingLink.service(of: url("https://acme.zoomgov.com/j/1612345678")) == .zoom)
        #expect(MeetingLink.service(of: url("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0")) == .teams)
        #expect(MeetingLink.service(of: url("https://teams.live.com/meet/9876543210")) == .teams)
        #expect(MeetingLink.service(of: url("https://acme.webex.com/meet/dana")) == .webex)
        #expect(MeetingLink.service(of: url("https://acme.webex.com/acme/j.php?MTID=m1")) == .webex)
        #expect(MeetingLink.service(of: url("https://around.co/r/design-sync")) == .around)
        #expect(MeetingLink.service(of: url("https://meet.around.co/r/design-sync")) == .around)
        #expect(MeetingLink.service(of: url("https://facetime.apple.com/join#v=1&p=AbCd&k=EfGh")) == .facetime)
        #expect(MeetingLink.service(of: url("https://app.slack.com/huddle/T1/C1")) == .slack)
        #expect(MeetingLink.service(of: url("https://around.co/pricing")) == nil)
        #expect(MeetingLink.service(of: url("https://facetime.apple.com/")) == nil)
        #expect(MeetingLink.service(of: url("https://zoom.us/pricing")) == nil)
        #expect(MeetingLink.service(of: url("http://127.0.0.1:8080/meet/abc")) == nil)
    }

    @Test func findsEachProviderInTheLocationOrNotes() {
        let cases: [(String, MeetingLink.Service)] = [
            ("Join with Google Meet: https://meet.google.com/abc-defg-hij\nOr dial", .meet),
            ("Zoom: https://acme.zoom.us/j/99887766?pwd=abc.", .zoom),
            ("________________\nMicrosoft Teams meeting\nJoin: https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d", .teams),
            ("https://acme.webex.com/meet/dana", .webex),
            ("Around: https://around.co/r/standup", .around),
            ("FaceTime https://facetime.apple.com/join#v=1&p=AbCd", .facetime),
        ]
        for (notes, service) in cases {
            let meeting = Meeting(event: CalendarEvent(id: "x", title: "x", start: now, end: now.addingTimeInterval(60), location: "Room 4", notes: notes))
            #expect(meeting.service == service, "\(notes)")
        }
    }

    @Test func zoomAndTeamsOpenTheirAppsOnlyWhenInstalled() {
        let zoom = url("https://acme.zoom.us/j/81234567890?pwd=Zx9")
        let teams = url("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=x")
        let meet = url("https://meet.google.com/abc-defg-hij")

        let zoomApp = MeetingJoin.route(zoom, service: .zoom) { $0 == "zoommtg" }
        let zoomTab = MeetingJoin.route(zoom, service: .zoom) { _ in false }
        let teamsApp = MeetingJoin.route(teams, service: .teams) { $0 == "msteams" }
        let meetAnyway = MeetingJoin.route(meet, service: .meet) { _ in true }

        #expect(zoomApp == .app(url("zoommtg://acme.zoom.us/join?action=join&confno=81234567890&pwd=Zx9")))
        #expect(zoomTab == .tab(zoom))
        #expect(teamsApp == .app(url("msteams:/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=x")))
        #expect(meetAnyway == .tab(meet))
        #expect(MeetingJoin.zoomApp(url("https://acme.zoom.us/my/dana")) == nil)
    }

    @Test func respondOpensTheInvitationOrCalendar() {
        var google = event("g", in: 1)
        google.notes = "Invitation from Google Calendar: https://calendar.google.com/calendar/event?action=VIEW&eid=abc123"
        var other = event("o", in: 1)
        other.external = "040000008200E00074C5B7101A82E008@exchange"
        let bare = event("b", in: 1)

        #expect(MeetingAlertRules.reply(for: google)?.host() == "calendar.google.com")
        #expect(MeetingAlertRules.reply(for: other)?.scheme == "ical")
        #expect(MeetingAlertRules.reply(for: other)?.absoluteString.contains("040000008200E00074C5B7101A82E008%40exchange") == true)
        #expect(MeetingAlertRules.reply(for: bare) == nil)
    }

    @Test func theTimeLineChangesExactlyWhenItsWordsDo() {
        let meeting = event(in: 3)

        let changes = MeetingAlertRules.changes(meeting)

        #expect(changes.contains(meeting.start.addingTimeInterval(-30)))
        #expect(MeetingAlertRules.when(meeting, at: meeting.start.addingTimeInterval(-31)).hasSuffix("in 1 min"))
        #expect(MeetingAlertRules.when(meeting, at: meeting.start.addingTimeInterval(-30)).hasSuffix("now"))
        #expect(MeetingAlertRules.when(meeting, at: meeting.start.addingTimeInterval(60)).hasSuffix("started 1 min ago"))
        #expect(changes == changes.sorted())
    }

    @Test func initialsFromNamesOrAddresses() {
        #expect(MeetingAlertRules.initials(MeetingPerson(name: "Dana Scully", email: "")) == "DS")
        #expect(MeetingAlertRules.initials(MeetingPerson(name: "Fox", email: "")) == "F")
        #expect(MeetingAlertRules.initials(MeetingPerson(name: "", email: "walter.skinner@fbi.example")) == "WS")
        #expect(MeetingAlertRules.initials(MeetingPerson(name: "", email: "")) == "?")
    }

    @Test func oneTimerToTheNextAlertThenToWhenItGoes() async {
        let meeting = event("standup", in: 5)
        let source = AlertCalendar([meeting])
        let clock = Clock(now)
        let alerts = alerts(source, clock: clock)

        alerts.start()
        await alerts.reading?.value

        #expect(alerts.fireAt == meeting.start.addingTimeInterval(-60))
        #expect(alerts.due.isEmpty)
        #expect(source.reads == 1)

        clock.now = meeting.start.addingTimeInterval(-60)
        alerts.fire()

        #expect(alerts.due.map(\.event.id) == ["standup"])
        #expect(clock.shown.last == ["standup"])
        #expect(alerts.fireAt == meeting.start.addingTimeInterval(600))
        #expect(source.reads == 1)

        clock.now = meeting.start.addingTimeInterval(600)
        alerts.fire()

        #expect(alerts.due.isEmpty)
        #expect(alerts.fireAt == now.addingTimeInterval(MeetingAlerts.reread))
        alerts.stop()
    }

    @Test func reschedulesWhenTheCalendarChangesTheMacWakesOrTheZoneMoves() async {
        let later = event("later", in: 30)
        let source = AlertCalendar([later])
        let clock = Clock(now)
        let alerts = alerts(source, clock: clock)
        alerts.start()
        await alerts.reading?.value
        #expect(alerts.fireAt == later.start.addingTimeInterval(-60))

        let sooner = event("sooner", in: 3)
        source.stored.append(sooner)
        NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        await alerts.reading?.value

        #expect(alerts.fireAt == sooner.start.addingTimeInterval(-60))
        #expect(source.reads == 2)

        source.stored.removeAll { $0.id == "sooner" }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await alerts.reading?.value

        #expect(alerts.fireAt == later.start.addingTimeInterval(-60))
        #expect(source.reads == 3)

        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        await alerts.reading?.value

        #expect(source.reads == 4)
        alerts.stop()
    }

    @Test func leadChangeAndDismissReplanWithoutReading() async {
        let meeting = event("review", in: 4)
        let source = AlertCalendar([meeting])
        let clock = Clock(now)
        let alerts = alerts(source, clock: clock)
        alerts.start()
        await alerts.reading?.value
        #expect(alerts.due.isEmpty)

        alerts.prefs.lead = .five
        alerts.replan()

        #expect(alerts.due.map(\.event.id) == ["review"])

        alerts.dismiss(alerts.due[0])

        #expect(alerts.due.isEmpty)
        #expect(source.reads == 1)
        #expect(store.stringArray(forKey: "meetings.dismissed") == [MeetingAlertRules.key(meeting)])
        alerts.stop()
    }

    @Test func snoozeBringsItBackAtTheStart() async {
        let meeting = event("sync", in: 1)
        let clock = Clock(now)
        let alerts = alerts(AlertCalendar([meeting]), lead: .two, clock: clock)
        alerts.start()
        await alerts.reading?.value

        alerts.snooze(alerts.due[0])

        #expect(alerts.due.isEmpty)
        #expect(alerts.fireAt == meeting.start)

        clock.now = meeting.start
        alerts.fire()

        #expect(alerts.due.map(\.event.id) == ["sync"])
        alerts.stop()
    }

    @Test func joinPicksTheAppOrTheTabAndClosesTheAlert() async {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let zoom = event("zoom", in: 0.5, link: "https://acme.zoom.us/j/81234567890")
        let meet = event("meet", in: 0.5, link: "https://meet.google.com/abc-defg-hij")
        let clock = Clock(now)
        let alerts = alerts(AlertCalendar([zoom, meet]), clock: clock)
        alerts.installed = { $0 == "zoommtg" }
        alerts.start()
        await alerts.reading?.value
        #expect(alerts.due.count == 2)

        alerts.join(alerts.due.first { $0.event.id == "zoom" }!, in: browser)
        alerts.join(alerts.due.first { $0.event.id == "meet" }!, in: browser)

        #expect(alerts.opened.map(\.scheme) == ["zoommtg", "https"])
        #expect(browser.tabs.contains { $0.address?.host() == "meet.google.com" })
        #expect(alerts.due.isEmpty)
        alerts.stop()
    }

    @Test func noAccessMeansNoReadsAndNoTimer() async {
        let source = AlertCalendar([event(in: 0.5)], granted: false)
        let clock = Clock(now)
        let alerts = alerts(source, clock: clock)

        alerts.sync()
        await alerts.reading?.value

        #expect(!alerts.running)
        #expect(source.reads == 0)
        #expect(alerts.fireAt == nil)
    }
}
