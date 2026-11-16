import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class MeetingSpacesTests {
    private let here = UUID(), work = UUID(), home = UUID(), side = UUID()
    private var browser: Browser!
    private var window: NSWindow!
    private var first = UUID()
    private var second = UUID()
    private let memory = MeetingSpaceMemory.shared
    private let call = URL(string: "https://meet.google.com/abc-defg-hij")!

    init() async throws {
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        _ = NSApplication.shared
        forget()
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesSpaces = true
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        first = browser.spaceID
        browser.addSpace(named: "Work")
        second = browser.spaceID
        browser.switchSpace(to: first)
        LinkRules.shared.replaceAll([])
    }

    private func tearDown() async {
        LinkRules.shared.replaceAll([])
        forget()
        if let space = browser.spaces.first(where: { $0.id == second }) {
            browser.spaces.removeAll { $0.id == space.id }
            Spaces.write(browser.spaces)
        }
        window.contentView = nil
        window.close()
        browser.closeAll()
        browser = nil
    }

    private func forget() {
        memory.store.removeObject(forKey: MeetingSpaceMemory.accountsKey)
        memory.store.removeObject(forKey: MeetingSpaceMemory.openedKey)
        memory.clock = Date.init
        memory.lastChoice = nil
    }

    private func signals(tied: UUID? = nil, account: [UUID] = [], link: UUID? = nil, calendar: UUID? = nil) -> MeetingSpaceSignals {
        MeetingSpaceSignals(current: here, spaces: [here, work, home, side], tied: tied, account: account, link: link, calendar: calendar)
    }

    private func event(account: String = "", calendar: String = "work-cal") -> CalendarEvent {
        CalendarEvent(id: "standup", title: "Standup", start: Date(), end: Date().addingTimeInterval(900), url: call,
                      calendar: calendar, account: account)
    }

    private func spaceTabs(_ space: UUID) -> [URL] {
        let tabs = space == browser.spaceID ? browser.tabs : browser.parked[space]?.tabs ?? []
        return tabs.compactMap(\.address)
    }

    @Test func aSpaceTiedByThePersonComesFirst() {
        let chosen = MeetingSpaceChoice.choose(signals(tied: side, account: [work], link: home, calendar: home))

        #expect(chosen.space == side)
        #expect(chosen.reason == .tied)
    }

    @Test func theSpaceSignedIntoTheCalendarsAccountComesNext() {
        let chosen = MeetingSpaceChoice.choose(signals(account: [work], link: home, calendar: side))

        #expect(chosen.space == work)
        #expect(chosen.reason == .account)
    }

    @Test func twoSpacesOnTheSameAccountFallThroughToWhereItWasLastOpened() {
        let link = MeetingSpaceChoice.choose(signals(account: [work, home], link: side, calendar: here))
        let calendar = MeetingSpaceChoice.choose(signals(account: [work, home], calendar: home))

        #expect(link.space == side)
        #expect(link.reason == .link)
        #expect(calendar.space == home)
        #expect(calendar.reason == .calendar)
    }

    @Test func nothingClearStaysInTheCurrentSpace() {
        let nothing = MeetingSpaceChoice.choose(signals())
        let gone = MeetingSpaceChoice.choose(signals(tied: UUID(), account: [UUID()], link: UUID(), calendar: UUID()))

        #expect(nothing.space == here)
        #expect(nothing.reason == .current)
        #expect(gone.space == here)
        #expect(gone.reason == .current)
    }

    @Test func gmailsTitleNamesTheSpacesAccount() {
        #expect(MeetingSpaceChoice.account(inTitle: "Inbox (3) - Sam.Rowe@Example.com - Example Mail", at: URL(string: "https://mail.google.com/mail/u/1/#inbox")) == "sam.rowe@example.com")
        #expect(MeetingSpaceChoice.account(inTitle: "Inbox - sam.rowe@example.com", at: URL(string: "https://example.com/")) == nil)
        #expect(MeetingSpaceChoice.account(inTitle: "Gmail", at: URL(string: "https://mail.google.com/")) == nil)
    }

    @Test func accountsSeenLongAgoAreForgotten() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        memory.clock = { now }
        memory.saw(account: "Sam.Rowe@Example.com", in: work)

        let soon = memory.spaces(signedInto: "sam.rowe@example.com")
        now += MeetingSpaceMemory.accountKeep + 1
        let later = memory.spaces(signedInto: "sam.rowe@example.com")

        #expect(soon == [work])
        #expect(later.isEmpty)
    }

    @Test func joinOpensTheCallInTheSpaceSignedIntoTheCalendarsAccount() {
        memory.saw(account: "sam.rowe@example.com", in: second)

        browser.joinMeeting(call, event: event(account: "sam.rowe@example.com"))

        #expect(browser.spaceID == second)
        #expect(memory.lastChoice == .account)
        #expect(spaceTabs(second).contains(call))
        #expect(!spaceTabs(first).contains(call))
        #expect(memory.lastOpened(link: call) == second)
        #expect(memory.lastOpened(calendar: "work-cal") == second)
    }

    @Test func joinFollowsALinkRuleToASpace() {
        memory.saw(account: "sam.rowe@example.com", in: first)
        LinkRules.shared.add(LinkRule(match: .site("meet.google.com"), target: .space(second, folder: nil)))

        browser.joinMeeting(call, event: event(account: "sam.rowe@example.com"))

        #expect(browser.spaceID == second)
        #expect(memory.lastChoice == .tied)
    }

    @Test func joinGoesWhereThatCalendarsMeetingsWereLastOpened() {
        memory.opened(URL(string: "https://meet.google.com/xyz-abcd-efg"), calendar: "work-cal", in: second)

        browser.joinMeeting(call, event: event())

        #expect(browser.spaceID == second)
        #expect(memory.lastChoice == .calendar)
    }

    @Test func joinStaysInTheCurrentSpaceWhenNothingSaysOtherwise() {
        browser.joinMeeting(call, event: event(account: "nobody@example.test"))

        #expect(browser.spaceID == first)
        #expect(memory.lastChoice == .current)
        #expect(spaceTabs(first).contains(call))
    }

    @Test func joinGoesBackToTheCallAlreadyOpenInAnotherSpace() {
        browser.switchSpace(to: second)
        browser.open(call, foreground: true, from: browser.active)
        let opened = browser.active?.id
        browser.switchSpace(to: first)
        memory.saw(account: "sam.rowe@example.com", in: first)

        browser.joinMeeting(call, event: event(account: "sam.rowe@example.com"))

        #expect(browser.spaceID == second)
        #expect(browser.active?.id == opened)
        #expect(spaceTabs(second).filter { $0 == call }.count == 1)
        #expect(memory.lastChoice == nil)
    }

    @Test func joinWithSpacesOffOpensWhereYouAre() {
        memory.saw(account: "sam.rowe@example.com", in: second)
        browser.prefs.usesSpaces = false

        browser.joinMeeting(call, event: event(account: "sam.rowe@example.com"))

        #expect(browser.spaceID == first)
        #expect(browser.tabs.contains { $0.address == call })
    }

    @Test func aGmailTabTeachesItsSpacesAccount() {
        browser.switchSpace(to: second)
        browser.newTab()
        let tab = browser.active!

        tab.restore(url: URL(string: "https://mail.google.com/mail/u/0/#inbox")!, title: "Inbox (2) - sam.rowe@example.com - Gmail")
        browser.noteMeetingPage(tab)

        #expect(memory.spaces(signedInto: "sam.rowe@example.com") == [second])
    }
}
