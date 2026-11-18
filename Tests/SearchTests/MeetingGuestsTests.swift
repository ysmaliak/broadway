import AppKit
import Testing
@testable import Search

private final class NoCalendar: CalendarSource, @unchecked Sendable {
    var hasAccess: Bool { true }
    func requestAccess() async -> Bool { true }
    func events(from start: Date, to end: Date) -> [CalendarEvent] { [] }
    func calendars() -> [MeetingCalendar] { [] }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct MeetingGuestsTests {
    private let nameless = MeetingPerson(name: "", email: "a.very.long.address.for.a.shared.mailbox@example.test")

    @Test func aGuestWithANameShowsTheFirstWordOfIt() {
        #expect(MeetingGuests.name(MeetingPerson(name: "Dana Scully", email: "dana@example.test")) == "Dana")
    }

    @Test func aGuestWithNoNameShowsTheAddressBeforeTheAt() {
        #expect(MeetingGuests.name(nameless) == "a.very.long.address.for.a.shared.mailbox")
        #expect(MeetingGuests.name(MeetingPerson(name: "", email: "walter.skinner@example.test")) == "walter.skinner")
        #expect(MeetingGuests.name(MeetingPerson(name: "", email: "no-at-sign")) == "no-at-sign")
        #expect(MeetingGuests.name(MeetingPerson(name: "", email: "@example.test")) == "@example.test")
    }

    @Test func aLineWithRoomIsWhole() {
        #expect(MeetingGuests.line(["Dana"]) == "With Dana")
        #expect(MeetingGuests.line(["Dana", "Fox"]) == "With Dana and Fox")
        #expect(MeetingGuests.line(["Dana", "Fox", "Monica"]) == "With Dana and 2 others")
        #expect(MeetingGuests.line([]) == "")
    }

    @Test func aLineTooLongCutsTheNameAndKeepsTheCount() {
        let names = ["a.very.long.address.for.a.shared.mailbox", "Jun", "Ines", "Monica", "Fox"]

        let line = MeetingGuests.line(names) { $0.count <= 30 }

        #expect(line == "With a.very.long… and 4 others")
    }

    @Test func aCutNeverEndsOnADotBeforeTheEllipsis() {
        let names = ["a.very.long.address", "Jun", "Ines"]

        let line = MeetingGuests.line(names) { $0.count <= 31 }

        #expect(line == "With a.very.long… and 2 others")
    }

    @Test func aLoneNameIsLeftToTheLabelsOwnCut() {
        let line = MeetingGuests.line(["a.very.long.address.for.a.shared.mailbox"]) { $0.count <= 12 }

        #expect(line == "With a.very.long.address.for.a.shared.mailbox")
    }

    @Test func theSecondOfTwoNamesStaysWhenTheFirstIsCut() {
        let line = MeetingGuests.line(["a.very.long.address.for.a.shared.mailbox", "Dana"]) { $0.count <= 26 }

        #expect(line == "With a.very.long… and Dana")
    }

    @Test func aReminderWithALongNamelessGuestKeepsItsCount() throws {
        let suite = "meeting-guests-tests-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        MeetingFaces.shared.forget()
        MeetingFaces.shared.sources = []
        let alerts = MeetingAlerts(meetings: Meetings(source: NoCalendar()), prefs: MeetingAlertPrefs(store: store), store: store)
        alerts.clock = { MeetingAlerts.surfaceNow }
        let stack = MeetingAlertStackView(alerts: alerts)
        stack.due = MeetingAlerts.surfaceMeetings("long")
        let size = stack.intrinsicContentSize
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let stage = KitFlippedView(frame: NSRect(origin: .zero, size: size))
        window.contentView = stage
        stack.frame = stage.bounds
        stage.addSubview(stack)

        stage.layoutSubtreeIfNeeded()
        let line = try #require(stack.kitSubviews(of: KitLabel.self).first { $0.text.hasPrefix("With ") })

        #expect(line.text.hasPrefix("With a."))
        #expect(line.text.hasSuffix("… and 7 others"))
        #expect(line.intrinsicContentSize.width <= line.frame.width + 0.5)
    }
}
