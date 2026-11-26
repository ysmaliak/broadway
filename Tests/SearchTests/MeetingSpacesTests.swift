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
    private let places = MeetingSpacePlaces.shared
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
        memory.store.removeObject(forKey: MeetingSpaceMemory.fellKey)
        memory.store.removeObject(forKey: MeetingSpacePlaces.accountsKey)
        memory.store.removeObject(forKey: MeetingSpacePlaces.calendarsKey)
        memory.store.removeObject(forKey: MeetingSpacePlaces.offeredKey)
        places.reload()
        memory.forgetSession()
        memory.clock = Date.init
        memory.lastChoice = nil
        Meetings.shared.use(nil)
    }

    private func signals(tied: UUID? = nil, chosenCalendar: MeetingCalendarPlace = .account, chosenAccount: UUID? = nil,
                         account: [UUID] = [], link: UUID? = nil, calendar: UUID? = nil) -> MeetingSpaceSignals {
        MeetingSpaceSignals(current: here, spaces: [here, work, home, side], tied: tied, chosenCalendar: chosenCalendar,
                            chosenAccount: chosenAccount, account: account, link: link, calendar: calendar)
    }

    private func event(account: String = "", calendar: String = "work-cal", source: String = "", link: URL? = nil) -> CalendarEvent {
        CalendarEvent(id: "standup", title: "Standup", start: Date(), end: Date().addingTimeInterval(900), url: link ?? call,
                      calendar: calendar, account: account, source: source, sourceTitle: source.isEmpty ? "" : account)
    }

    private func workEvent(link: URL? = nil) -> CalendarEvent {
        event(account: "work@example.com", source: "source-work", link: link)
    }

    private func seenInBothSpacesLastInWork() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        memory.clock = { now }
        memory.saw(account: "work@example.com", in: first)
        now += 60
        memory.saw(account: "work@example.com", in: second)
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

    @Test func joinStayingHereWithALiveFoldersRowInFrontOpensTheCallLoose() throws {
        let live = browser.prefs.liveFolders
        browser.prefs.liveFolders = true
        let made = LiveFolders.shared.add(name: "PRs", source: LiveSource(kind: .pullRequests, address: "http://127.0.0.1:9/pulls"),
                                          space: first)
        defer {
            LiveFolders.shared.remove(made.id)
            browser.prefs.liveFolders = live
        }
        LiveFolders.shared.apply(.items([LiveItem(key: "http://127.0.0.1:9/acme/rocket/pull/1", title: "PR 1")], nil), to: made.id)
        browser.syncLive()
        let row = try #require(browser.tabs(in: made.id).first)
        browser.select(row)

        browser.joinMeeting(call, event: event(account: "nobody@example.test"))

        let tab = try #require(browser.tabs.first { $0.address == call })
        #expect(memory.lastChoice == .current)
        #expect(browser.spaceID == first)
        #expect(browser.active?.id == tab.id)
        #expect(tab.groupID == nil)
        #expect(browser.tabs(in: made.id).map(\.id) == [row.id])
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

    @Test func reproAWorkCallFromPersonalGoesToWorkWhenItsAccountWasSeenThroughACalendarSite() {
        browser.switchSpace(to: second)
        browser.newTab()
        let calendar = browser.active!
        calendar.restore(url: URL(string: "https://calendar.google.com/calendar/u/1/r/week?authuser=work@example.com")!,
                         title: "Google Calendar - Week of November 16, 2026")
        browser.noteMeetingPage(calendar)
        browser.switchSpace(to: first)

        browser.joinMeeting(call, event: event(account: "work@example.com"))

        #expect(browser.spaceID == second)
        #expect(memory.lastChoice == .account)
    }

    @Test func reproACallThatFellIntoTheCurrentSpaceDoesNotPullTheCalendarsNextCallThere() {
        browser.joinMeeting(call, event: event(account: "work@example.com"))
        if let landed = browser.tabs.first(where: { $0.address == call }) { browser.noteMeetingPage(landed) }
        browser.switchSpace(to: second)

        browser.joinMeeting(URL(string: "https://meet.google.com/xyz-abcd-efg")!, event: event(account: "work@example.com"))

        #expect(memory.lastChoice == .current)
        #expect(browser.spaceID == second)
        #expect(memory.lastOpened(calendar: "work-cal") == nil)
    }

    @Test func aChosenCalendarComesAfterALinkRuleAndBeforeEverythingLearned() {
        let ruled = MeetingSpaceChoice.choose(signals(tied: side, chosenCalendar: .space(home), chosenAccount: work))
        let calendar = MeetingSpaceChoice.choose(signals(chosenCalendar: .space(home), chosenAccount: work, account: [side], link: side))
        let account = MeetingSpaceChoice.choose(signals(chosenAccount: work, account: [side], link: side, calendar: side))

        #expect(ruled.reason == .tied)
        #expect(calendar.space == home)
        #expect(calendar.reason == .chosenCalendar)
        #expect(account.space == work)
        #expect(account.reason == .chosenAccount)
    }

    @Test func aCalendarSetToAnySpaceSkipsItsAccountsSpace() {
        let chosen = MeetingSpaceChoice.choose(signals(chosenCalendar: .any, chosenAccount: work, link: home))

        #expect(chosen.space == home)
        #expect(chosen.reason == .link)
    }

    @Test func aChosenSpaceThatIsGoneFallsThroughToWhatWasLearned() {
        let calendar = MeetingSpaceChoice.choose(signals(chosenCalendar: .space(UUID()), chosenAccount: work))
        let account = MeetingSpaceChoice.choose(signals(chosenAccount: UUID(), account: [home]))

        #expect(calendar.space == work)
        #expect(calendar.reason == .chosenAccount)
        #expect(account.space == home)
        #expect(account.reason == .account)
    }

    @Test func theSpacesChosenForAccountsAndCalendarsAreKept() {
        places.place(work, ofAccount: "source-work")
        places.place(.space(home), ofCalendar: "team")
        places.place(.any, ofCalendar: "holidays")
        let again = MeetingSpacePlaces(store: memory.store)

        #expect(again.space(ofAccount: "source-work") == work)
        #expect(again.place(ofCalendar: "team") == .space(home))
        #expect(again.place(ofCalendar: "holidays") == .any)
        #expect(again.place(ofCalendar: "birthdays") == .account)

        places.place(nil, ofAccount: "source-work")
        places.place(.account, ofCalendar: "team")

        #expect(MeetingSpacePlaces(store: memory.store).space(ofAccount: "source-work") == nil)
        #expect(MeetingSpacePlaces(store: memory.store).place(ofCalendar: "team") == .account)
    }

    @Test func aSpaceThatIsGoneShowsAsTheDefault() {
        let gone = UUID()

        #expect(places.shown(gone, among: [work, home]) == nil)
        #expect(places.shown(work, among: [work, home]) == work)
        #expect(places.shown(.space(gone), among: [work, home]) == .account)
        #expect(places.shown(.any, among: [work, home]) == .any)
    }

    @Test func calendarsGroupUnderTheirAccount() {
        let accounts = MeetingAccount.grouped([
            MeetingCalendar(id: "a", title: "Work", account: "work@example.com", source: "s1"),
            MeetingCalendar(id: "b", title: "Home", account: "me@example.org", source: "s2"),
            MeetingCalendar(id: "c", title: "Team", account: "work@example.com", source: "s1"),
        ])

        #expect(accounts.map(\.key) == ["s1", "s2"])
        #expect(accounts.map(\.title) == ["work@example.com", "me@example.org"])
        #expect(accounts[0].calendars.map(\.id) == ["a", "c"])
    }

    @Test func googleCalendarAndMeetTeachTheAccountTheirAddressShows() {
        #expect(MeetingSpaceChoice.account(inTitle: "Google Calendar - Week of November 16, 2026",
                                           at: URL(string: "https://calendar.google.com/calendar/r?authuser=Work@Example.com")) == "work@example.com")
        #expect(MeetingSpaceChoice.account(inTitle: "Meet - abc-defg-hij",
                                           at: URL(string: "https://meet.google.com/abc-defg-hij?authuser=work@example.com")) == "work@example.com")
        #expect(MeetingSpaceChoice.account(inTitle: "work@example.com - Calendar", at: URL(string: "https://calendar.google.com/calendar/u/1/r")) == "work@example.com")
        #expect(MeetingSpaceChoice.account(inTitle: "Google Calendar", at: URL(string: "https://calendar.google.com/calendar/u/1/r?authuser=1")) == nil)
        #expect(MeetingSpaceChoice.account(inTitle: "Calendar", at: URL(string: "https://calendar.example.com/?authuser=work@example.com")) == nil)
    }

    @Test func joinGoesToTheSpaceChosenForTheCalendarsAccount() {
        places.place(second, ofAccount: "source-work")
        memory.saw(account: "work@example.com", in: first)

        browser.joinMeeting(call, event: workEvent())

        #expect(browser.spaceID == second)
        #expect(memory.lastChoice == .chosenAccount)
    }

    @Test func joinGoesToTheSpaceChosenForOneCalendarOverItsAccount() {
        browser.switchSpace(to: second)
        places.place(second, ofAccount: "source-work")
        places.place(.space(first), ofCalendar: "work-cal")

        browser.joinMeeting(call, event: workEvent())

        #expect(browser.spaceID == first)
        #expect(memory.lastChoice == .chosenCalendar)
    }

    @Test func aFallbackLandingTeachesNeitherTheLinkNorTheCalendarWhenThePageLoads() {
        browser.joinMeeting(call, event: workEvent())
        let landed = browser.tabs.first { $0.address == call }
        if let landed { browser.noteMeetingPage(landed) }

        #expect(memory.lastChoice == .current)
        #expect(memory.lastOpened(link: call) == nil)
        #expect(memory.lastOpened(calendar: "work-cal") == nil)
    }

    @Test func movingACallsTabByHandTeachesItsLinkAndCalendar() {
        browser.joinMeeting(call, event: workEvent())
        let landed = browser.tabs.first { $0.address == call }!

        browser.finishMove(landed, toSpace: second)

        #expect(memory.lastOpened(link: call) == second)
        #expect(memory.lastOpened(calendar: "work-cal") == second)
        #expect(!memory.fellBack(call, in: first))
    }

    @Test func movingACallsTabByHandOffersItsAccountsSpaceOnce() {
        browser.joinMeeting(call, event: workEvent())
        let landed = browser.tabs.first { $0.address == call }!

        browser.finishMove(landed, toSpace: second)

        #expect(browser.linkNotice?.text == "Always open work@example.com calls in Work?")
        #expect(browser.linkNotice?.kind == .offer)
        #expect(places.wasOffered("source-work"))

        browser.showLinkNotice(nil)
        browser.switchSpace(to: second)
        let moved = browser.tabs.first { $0.address == call }!
        browser.finishMove(moved, toSpace: first)

        #expect(browser.linkNotice == nil)
        #expect(memory.lastOpened(link: call) == first)
    }

    @Test func aCallLandingAwayFromWhereItsAccountWasLastSeenOffersThatSpace() {
        seenInBothSpacesLastInWork()

        browser.joinMeeting(call, event: workEvent())

        #expect(memory.lastChoice == .current)
        #expect(browser.spaceID == first)
        #expect(browser.linkNotice?.text == "Always open work@example.com calls in Work?")
    }

    @Test func yesOnTheOfferSetsTheAccountsSpace() {
        seenInBothSpacesLastInWork()
        browser.joinMeeting(call, event: workEvent())

        browser.linkNotice?.choices.first { $0.id == "meeting.notice.yes" }?.run()

        #expect(places.space(ofAccount: "source-work") == second)
        #expect(browser.linkNotice == nil)
        browser.closeTab(browser.tabs.first { $0.address == call }!)
        browser.joinMeeting(call, event: workEvent())
        #expect(memory.lastChoice == .chosenAccount)
        #expect(browser.spaceID == second)
    }

    @Test func notNowLeavesTheAccountToAnySpaceAndDoesNotAskAgain() {
        seenInBothSpacesLastInWork()
        browser.joinMeeting(call, event: workEvent())

        browser.linkNotice?.choices.first { $0.id == "meeting.notice.notNow" }?.run()
        let other = URL(string: "https://meet.google.com/xyz-abcd-efg")!
        browser.joinMeeting(other, event: workEvent(link: other))

        #expect(places.space(ofAccount: "source-work") == nil)
        #expect(places.wasOffered("source-work"))
        #expect(browser.linkNotice == nil)
    }

    @Test func noOfferWhenTheCallsCalendarHasItsOwnSpace() {
        seenInBothSpacesLastInWork()
        places.place(.any, ofCalendar: "work-cal")

        browser.joinMeeting(call, event: workEvent())

        #expect(browser.linkNotice == nil)
        #expect(!places.wasOffered("source-work"))
    }

    @Test func noOfferWithSpacesOff() {
        seenInBothSpacesLastInWork()
        browser.prefs.usesSpaces = false

        browser.joinMeeting(call, event: workEvent())

        #expect(browser.linkNotice == nil)
        #expect(memory.lastOpened(link: call) == nil)
    }

    @Test func aCallLinkClickedOnACalendarPageTakesTheSameChoice() async {
        places.place(second, ofAccount: "source-work")
        Meetings.shared.use(FixedCalendar(events: [workEvent()]))
        await Meetings.shared.refresh()
        browser.newTab()
        let calendar = browser.active!
        calendar.restore(url: URL(string: "https://calendar.google.com/calendar/u/0/r")!, title: "Google Calendar")

        let taken = browser.joinsMeeting(call, from: calendar)

        #expect(taken)
        #expect(memory.lastChoice == .chosenAccount)
        #expect(browser.spaceID == second)
        #expect(spaceTabs(second).contains(call))
    }

    @Test func aCallLinkOnAnotherPageIsLeftToTheLinkRules() {
        browser.newTab()
        let page = browser.active!
        page.restore(url: URL(string: "https://chat.example.com/room")!, title: "Room")

        #expect(!browser.joinsMeeting(call, from: page))
    }

    @Test func aCallLinkOnACalendarPageWithOneSpaceIsLeftAlone() {
        browser.spaces.removeAll { $0.id == second }
        Spaces.write(browser.spaces)
        browser.newTab()
        let calendar = browser.active!
        calendar.restore(url: URL(string: "https://calendar.google.com/calendar/u/0/r")!, title: "Google Calendar")

        #expect(!browser.joinsMeeting(call, from: calendar))
    }
    @Test func aCallsOwnAddressNeverTeachesItsAccount() {
        let addressed = URL(string: "https://meet.google.com/abc-defg-hij?authuser=work@example.com")!
        browser.joinMeeting(addressed, event: workEvent(link: addressed))
        if let landed = browser.tabs.first(where: { $0.address == addressed }) { browser.noteMeetingPage(landed) }
        browser.switchSpace(to: second)

        browser.joinMeeting(URL(string: "https://meet.google.com/xyz-abcd-efg")!, event: workEvent())

        #expect(memory.spaces(signedInto: "work@example.com").isEmpty)
        #expect(memory.lastChoice == .current)
        #expect(browser.spaceID == second)
    }

    @Test func aFallbackLandingStaysUntaughtAfterARelaunch() async {
        browser.joinMeeting(call, event: workEvent())
        let landed = browser.tabs.first { $0.address == call }!
        memory.forgetSession()
        Meetings.shared.use(FixedCalendar(events: [workEvent()]))
        await Meetings.shared.refresh()

        browser.noteMeetingPage(landed)

        #expect(MeetingSpaceMemory(store: memory.store).fellBack(call, in: first))
        #expect(memory.lastOpened(link: call) == nil)
        #expect(memory.lastOpened(calendar: "work-cal") == nil)
    }

    @Test func theCallSpacesLearnedBeforeThisFixAreDroppedOnce() {
        memory.store.set(["calendar:work-cal": ["space": first.uuidString, "at": 1.0]], forKey: MeetingSpaceMemory.oldOpenedKey)

        let fresh = MeetingSpaceMemory(store: memory.store)

        #expect(memory.store.object(forKey: MeetingSpaceMemory.oldOpenedKey) == nil)
        #expect(fresh.lastOpened(calendar: "work-cal") == nil)
    }

    @Test func aMoveFromTheCommandLineTeachesNothingAndOffersNothing() {
        browser.joinMeeting(call, event: workEvent())
        let landed = browser.tabs.first { $0.address == call }!

        #expect(browser.moveToSpace(landed, id: second))

        #expect(memory.lastOpened(link: call) == nil)
        #expect(memory.lastOpened(calendar: "work-cal") == nil)
        #expect(browser.linkNotice?.text != "Always open work@example.com calls in Work?")
        #expect(!places.wasOffered("source-work"))
    }
}
