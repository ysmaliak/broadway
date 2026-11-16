import AppKit
import Testing
@testable import Search

private final class FakeCalendar: CalendarSource, @unchecked Sendable {
    var stored: [CalendarEvent]
    var granted: Bool
    var answer: Bool
    var asked = 0

    init(events: [CalendarEvent] = [], granted: Bool = true, answer: Bool = true) {
        stored = events
        self.granted = granted
        self.answer = answer
    }

    var hasAccess: Bool { granted }

    func requestAccess() async -> Bool {
        asked += 1
        granted = answer
        return answer
    }

    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        stored.filter { $0.end > start && $0.start < end }
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct NextMeetingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        keepSettings("meetings.next")
    }

    private func event(_ id: String = "e", in minutes: Double, lasting: Double = 30, link: String = "",
                       people: [MeetingPerson] = []) -> CalendarEvent {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEvent(id: id, title: id, start: start, end: start.addingTimeInterval(lasting * 60),
                             notes: link, people: people)
    }

    private func fresh() -> Browser {
        _ = NSApplication.shared
        return Browser(record: WindowRecord())
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    @Test func knowsEachCallService() {
        #expect(MeetingLink.service(of: url("https://meet.google.com/abc-defg-hij")) == .meet)
        #expect(MeetingLink.service(of: url("https://acme.zoom.us/j/123456?pwd=x")) == .zoom)
        #expect(MeetingLink.service(of: url("https://teams.microsoft.com/l/meetup-join/19%3Aabc")) == .teams)
        #expect(MeetingLink.service(of: url("https://app.slack.com/huddle/T1/C1")) == .slack)
        #expect(MeetingLink.service(of: url("https://acme.webex.com/meet/dana")) == .webex)
        #expect(MeetingLink.service(of: url("https://meet.google.com/")) == nil)
        #expect(MeetingLink.service(of: url("https://zoom.us/pricing")) == nil)
        #expect(MeetingLink.service(of: url("https://notmeet.google.com.evil.example/abc")) == nil)
    }

    @Test func findsTheLinkInLocationOrNotes() {
        let notes = "Agenda at https://docs.example/a\nJoin: https://acme.zoom.us/j/99887766?pwd=abc."

        let found = MeetingLink.find(in: ["", "Room 4", notes])

        #expect(found?.service == .zoom)
        #expect(found?.url.host() == "acme.zoom.us")
        #expect(MeetingLink.find(in: ["Room 4", "https://docs.example/a"]) == nil)
    }

    @Test func zoomInTheBrowserIsTheSameCallAsItsInvite() {
        #expect(MeetingLink.same(url("https://acme.zoom.us/j/123?pwd=x"), url("https://acme.zoom.us/wc/123/join")))
        #expect(!MeetingLink.same(url("https://acme.zoom.us/j/123"), url("https://acme.zoom.us/j/456")))
        #expect(!MeetingLink.same(url("https://meet.google.com/aaa-bbbb-ccc"), url("https://meet.google.com/xxx-yyyy-zzz")))
    }

    @Test func meetRedirectingToItsOwnPathIsTheSameCall() {
        #expect(MeetingLink.same(url("https://meet.google.com/abc-defg-hij"), url("https://meet.google.com/meet/abc-defg-hij")))
    }

    @Test func skipsAllDayDeclinedAndFinished() {
        var allDay = event("all", in: 5)
        allDay.allDay = true
        var declined = event("no", in: 6)
        declined.declined = true
        let finished = event("past", in: -60, lasting: 30)
        let real = event("real", in: 90)

        let picked = Meetings.pick([allDay, declined, finished, real], at: now)

        #expect(picked?.event.id == "real")
    }

    @Test func aCallYouCanJoinBeatsAnEarlierMeetingWithoutOne() {
        let room = event("room", in: -5)
        let call = event("call", in: 10, link: "https://meet.google.com/abc-defg-hij")

        let picked = Meetings.pick([room, call], at: now)

        #expect(picked?.event.id == "call")
    }

    @Test func pinCountsDownThenTurnsToJoinAMinuteBefore() {
        let link = "https://meet.google.com/abc-defg-hij"

        #expect(Meeting(event: event(in: 23, link: link)).pinLabel(at: now) == .countdown("23m"))
        #expect(Meeting(event: event(in: 180, link: link)).pinLabel(at: now) == nil)
        #expect(Meeting(event: event(in: 1, link: link)).pinLabel(at: now) == .join)
        #expect(Meeting(event: event(in: -10, link: link)).pinLabel(at: now) == .join)
        #expect(Meeting(event: event(in: -10)).pinLabel(at: now) == .started(minutes: 10))
        #expect(Meeting(event: event(in: -31)).pinLabel(at: now) == nil)
        #expect(Meeting(event: event(in: 13 * 60)).pinLabel(at: now) == nil)
    }

    @Test(arguments: [(31, nil), (30, "30m"), (29, "29m")] as [(Double, String?)])
    func pinShowsTheCountdownOnlyInTheLastThirtyMinutes(minutes: Double, shown: String?) {
        let meeting = Meeting(event: event(in: minutes, link: "https://meet.google.com/abc-defg-hij"))

        let label = meeting.pinLabel(at: now)

        #expect(label == shown.map(Meeting.PinLabel.countdown))
    }

    @Test(arguments: [(1, "Now"), (0.5, "Now"), (-0.5, "Now"), (-1, "1m ago"), (-2.9, "2m ago"), (-59.9, "59m ago"),
                      (-60, "1h ago"), (-119, "1h ago"), (-150, "2h ago")] as [(Double, String)])
    func pinCountsTheTimeSinceTheStartWithoutALink(minutes: Double, shown: String) {
        let meeting = Meeting(event: event(in: minutes, lasting: 240))

        let label = meeting.pinLabel(at: now)

        #expect(label?.text == shown)
    }

    @Test func pinCountsTheTimeSinceTheStartOnceTheCallIsOpen() {
        let meeting = Meeting(event: event(in: -2, link: "https://meet.google.com/abc-defg-hij"))

        let away = meeting.pinLabel(at: now)
        let there = meeting.pinLabel(at: now, onCall: true)

        #expect(away == .join)
        #expect(there == .started(minutes: 2))
        #expect(meeting.pinLabel(at: now.addingTimeInterval(27 * 60), onCall: true) == .started(minutes: 29))
        #expect(meeting.pinLabel(at: now.addingTimeInterval(28 * 60), onCall: true) == nil)
    }

    @Test(arguments: [(0, "Starting now, Design sync"), (1, "Started 1 minute ago, Design sync"),
                      (2, "Started 2 minutes ago, Design sync"), (61, "Started 1 hour ago, Design sync"),
                      (125, "Started 2 hours ago, Design sync")] as [(Int, String)])
    func voiceOverReadsTheTimeSinceTheStartInFull(minutes: Int, said: String) {
        let label = Meeting.PinLabel.started(minutes: minutes)

        let badge = PinMeetingBadgeView(browser: nil)
        badge.show(label, title: "Design sync")
        badge.frame = NSRect(origin: .zero, size: badge.intrinsicContentSize)
        badge.layoutSubtreeIfNeeded()
        let middle = NSPoint(x: badge.frame.midX, y: badge.frame.midY)

        #expect(label.said(title: "Design sync") == said)
        #expect(badge.accessibilityLabel() == said)
        #expect(badge.hitTest(middle) == nil)
        badge.show(.join, title: "Design sync")
        #expect(badge.hitTest(middle) === badge)
    }

    @Test func everyTimeSinceTheStartFitsTheSmallestTile() {
        let labels = (0..<60).map { Meeting.PinLabel.started(minutes: $0) } + (1...23).map { .started(minutes: $0 * 60) }
        let badge = PinMeetingBadgeView(browser: nil)

        let widths = labels.map { label in
            badge.show(label, title: "Design sync")
            return (label.text, badge.intrinsicContentSize.width)
        }

        let widest = widths.max { $0.1 < $1.1 }
        #expect(widths.allSatisfy { $0.1 <= PinMeetingPlaces.narrowest }, "\(widths)")
        #expect((widest?.1 ?? 0) > 30, "\(String(describing: widest))")
        #expect(badge.intrinsicContentSize.height == PinMeetingPlaces.capsule)
    }

    @Test func pinCountsTheTimeSinceTheStartWhenThisWindowIsOnTheCall() async {
        let browser = fresh()
        defer { browser.closeAll() }
        let start = Date().addingTimeInterval(-150)
        let call = CalendarEvent(id: "c", title: "Call", start: start, end: start.addingTimeInterval(1800),
                                 location: "https://meet.google.com/abc-defg-hij")
        let meetings = Meetings(source: FakeCalendar(events: [call]))
        await meetings.refresh()
        let before = browser.pinLabel(for: meetings.next, at: Date())

        browser.newTab()
        browser.active?.go(to: url("https://meet.google.com/abc-defg-hij?authuser=0"))
        let after = browser.pinLabel(for: meetings.next, at: Date())

        #expect(before == .join)
        #expect(after == .started(minutes: 2))
    }

    @Test func theCallsTabShowsOnlyItsLastFiveMinutes() {
        #expect(Meeting(event: event(in: -26, lasting: 30)).minutesLeft(at: now) == 4)
        #expect(Meeting(event: event(in: -10, lasting: 30)).minutesLeft(at: now) == nil)
        #expect(Meeting(event: event(in: -31, lasting: 30)).minutesLeft(at: now) == nil)
    }

    @Test func joinableWithinFifteenMinutesAndWithALink() {
        let link = "https://meet.google.com/abc-defg-hij"
        #expect(Meeting(event: event(in: 14, link: link)).joinable(at: now))
        #expect(!Meeting(event: event(in: 16, link: link)).joinable(at: now))
        #expect(!Meeting(event: event(in: 5)).joinable(at: now))
    }

    @Test func refreshReadsTheStoreAndEmptiesWithoutAccess() async {
        let fake = FakeCalendar(events: [event(in: 20)])
        let meetings = Meetings(source: fake)

        await meetings.refresh(at: now)
        #expect(meetings.next?.event.id == "e")
        fake.granted = false
        await meetings.refresh(at: now)

        #expect(meetings.next == nil)
    }

    @Test func turningOnAsksOnceAndADenialLeavesItOff() async {
        let saved = Shared.prefs.nextMeeting
        defer { Shared.prefs.nextMeeting = saved }
        let refused = FakeCalendar(granted: false, answer: false)
        let allowed = FakeCalendar(granted: true)
        let off = Meetings(source: refused)
        let on = Meetings(source: allowed)

        let first = await off.turnOn()
        let second = await on.turnOn()
        on.stop()

        #expect(!first)
        #expect(refused.asked == 1)
        #expect(second)
        #expect(allowed.asked == 0)
        #expect(Shared.prefs.nextMeeting)
    }

    @Test func aTestRunNeverTouchesTheRealCalendars() async {
        let saved = Shared.prefs.nextMeeting
        defer { Shared.prefs.nextMeeting = saved }
        let meetings = Meetings(source: nil)

        let granted = await meetings.turnOn()

        #expect(!granted)
    }

    @Test func joinOpensTheCallOnce() async throws {
        let browser = fresh()
        defer { browser.closeAll() }
        browser.newTab()
        browser.active?.go(to: url("https://example.com/"))
        let start = Date().addingTimeInterval(300)
        let call = CalendarEvent(id: "c", title: "Call", start: start, end: start.addingTimeInterval(1800),
                                 location: "https://meet.google.com/abc-defg-hij")
        let meetings = Meetings(source: FakeCalendar(events: [call]))
        await meetings.refresh()
        let count = browser.tabs.count

        browser.joinNextMeeting(using: meetings)

        #expect(browser.tabs.count == (count + 1))
        #expect(browser.active?.shownURL?.host() == "meet.google.com")
        let there = try #require(browser.active)
        browser.newTab()
        browser.joinNextMeeting(using: meetings)
        #expect(browser.activeID == there.id)
        #expect(browser.tabs.filter { $0.shownURL?.host() == "meet.google.com" }.count == 1)
    }

    @Test func joinWithNothingSoonOpensNothing() async {
        let browser = fresh()
        defer { browser.closeAll() }
        let later = Date().addingTimeInterval(3600)
        let call = CalendarEvent(id: "c", title: "Call", start: later, end: later.addingTimeInterval(1800),
                                 location: "https://meet.google.com/abc-defg-hij")
        let meetings = Meetings(source: FakeCalendar(events: [call]))
        await meetings.refresh()
        let count = browser.tabs.count

        browser.joinNextMeeting(using: meetings)

        #expect(browser.tabs.count == count)
    }

    @Test func findsTabsOpenWithThosePeople() {
        let one = UUID(), two = UUID(), three = UUID()
        let tabs = [(id: one, title: "Dana Reyes | Slack", url: "https://slack.example/d"),
                    (id: two, title: "Inbox", url: "https://mail.example/?q=sam@example.com"),
                    (id: three, title: "Weather", url: "https://weather.example/")]
        let people = [MeetingPerson(name: "Dana Reyes", email: "dana@example.com"),
                      MeetingPerson(name: "", email: "sam@example.com")]

        let found = Meetings.tabs(with: people, among: tabs)

        #expect(found == [one, two])
    }

    @Test func aShortNameDoesNotMatchEverything() {
        let id = UUID()

        let found = Meetings.tabs(with: [MeetingPerson(name: "Al", email: "")], among: [(id: id, title: "Algebra", url: "")])

        #expect(found.isEmpty)
    }

    @Test func knowsCalendarPins() {
        #expect(Meetings.isCalendar(url("https://calendar.google.com/calendar/u/0/r")))
        #expect(Meetings.isCalendar(url("https://calendar.notion.so/")))
        #expect(Meetings.isCalendar(url("https://outlook.office.com/calendar/view/week")))
        #expect(!Meetings.isCalendar(url("https://outlook.office.com/mail/")))
        #expect(Meetings.isCalendar(url("https://app.cal.com/bookings")))
        #expect(Meetings.isCalendar(url("https://app.reclaim.ai/planner")))
        #expect(!Meetings.isCalendar(url("https://example.com/calendar")))
    }

    @Test func meetingCommandsStayOutOfTheFieldWhileItIsOff() throws {
        let browser = fresh()
        defer { browser.closeAll() }
        let saved = browser.prefs.nextMeeting
        defer { browser.prefs.nextMeeting = saved }
        let join = try #require(Command.named("meeting.join"))

        browser.prefs.nextMeeting = false
        let off = FieldCommands.available(join, in: browser)
        browser.prefs.nextMeeting = true
        let on = FieldCommands.available(join, in: browser)

        #expect(!off)
        #expect(on)
    }
}
