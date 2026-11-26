import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LiveOffersTests {
    private let home = UUID()
    private let work = UUID()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let gitHub = URL(string: "https://github.com/acme/rocket/pulls")!

    private final class World {
        var now: Date
        var visit: LiveVisit
        var visits = 3
        var visitsIn: [UUID: Int] = [:]
        var answer: LiveReader.Answer = .items([LiveItem(key: "https://github.com/acme/rocket/pull/1", title: "One"),
                                                LiveItem(key: "https://github.com/acme/rocket/pull/2", title: "Two")], nil)
        var eyes = LiveOffers.Eyes(seen: true, held: false)
        var front = true
        var seen = true
        var folders: [LiveFolder] = []
        var added: [LiveOffer] = []
        var asked = 0

        init(now: Date, visit: LiveVisit) {
            self.now = now
            self.visit = visit
        }
    }

    private func world(_ url: URL? = nil, quiet: String? = nil) -> World {
        World(now: start, visit: LiveVisit(url: url ?? gitHub, space: home, quiet: quiet))
    }

    private func offers(_ world: World) -> LiveOffers {
        let made = LiveOffers()
        made.now = { world.now }
        made.later = { _, run in run() }
        made.visit = { _ in world.visit }
        made.visited = { _, space, _ in world.visitsIn[space] ?? world.visits }
        made.reader = { _ in
            world.asked += 1
            return world.answer
        }
        made.frontmost = { world.front }
        made.sight = { _ in world.seen }
        made.watching = { _ in world.eyes }
        made.folders = { world.folders }
        made.adds = { _, offer in
            world.added.append(offer)
            return LiveFolder(space: offer.space, name: offer.name, source: offer.source)
        }
        return made
    }

    private func settle(_ offers: LiveOffers, _ browser: Browser, shown: Bool = true) async {
        for _ in 0..<200 where (offers.offer(for: browser) != nil) != shown || offers.reads(browser) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func arrive(_ offers: LiveOffers, _ browser: Browser, shown: Bool = true) async {
        offers.consider(browser)
        await settle(offers, browser, shown: shown)
    }

    @Test func aSiteWithNoLiveFolderIsRefused() {
        let visit = LiveVisit(url: URL(string: "https://example.com/acme")!, space: home)

        let refusal = LiveOfferRule.refusal(visit, folders: [], past: [])

        #expect(refusal == "site")
    }

    @Test func aFeedIsLeftToSettings() {
        let feed = URL(string: "https://blog.example.com/feed.xml")!

        let spot = LiveOfferRule.spot(feed)

        #expect(LiveSuggestions.spot(feed) != nil)
        #expect(spot == nil)
    }

    @Test func aQuietVisitSaysWhy() {
        let visit = LiveVisit(url: gitHub, space: home, quiet: "private")

        let refusal = LiveOfferRule.refusal(visit, folders: [], past: [])

        #expect(refusal == "private")
    }

    @Test func aSignInPageIsNotTheMoment() {
        let visit = LiveVisit(url: URL(string: "https://github.com/login")!, space: home)

        let refusal = LiveOfferRule.refusal(visit, folders: [], past: [])

        #expect(refusal == "signing in")
    }

    @Test func aFolderOfThatKindInThisSpaceCoversItAndOneElsewhereDoesNot() {
        let visit = LiveVisit(url: gitHub, space: home)
        let here = LiveFolder(space: home, name: "PRs", source: .pullRequests)
        let there = LiveFolder(space: work, name: "PRs", source: .pullRequests)

        let covered = LiveOfferRule.refusal(visit, folders: [here], past: [])
        let open = LiveOfferRule.refusal(visit, folders: [there], past: [])

        #expect(covered == "covered")
        #expect(open == nil)
    }

    @Test func turnedDownHoldsForItsSpaceOnly() {
        let past = [LiveOfferPast(space: home, id: "github", turnedDown: start)]

        let here = LiveOfferRule.refusal(LiveVisit(url: gitHub, space: home), folders: [], past: past)
        let there = LiveOfferRule.refusal(LiveVisit(url: gitHub, space: work), folders: [], past: past)

        #expect(here == "turned down")
        #expect(there == nil)
    }

    @Test func aSavedAnswerForASiteNoLongerOfferedIsLeftOut() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("live-offers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let saved = [LiveOfferPast(space: home, id: "vercel", turnedDown: start), LiveOfferPast(space: home, id: "gitlab", turnedDown: start),
                     LiveOfferPast(space: home, id: "github", turnedDown: start)]
        try JSONEncoder().encode(saved).write(to: file)

        let offers = LiveOffers(file: file)

        #expect(offers.turnedDown(in: home).map(\.id) == ["github"])
    }

    @Test func aReturningGhostGetsWhatIsLeftAndNeverLessThanALastLook() {
        let lasts: TimeInterval = 45
        let look: TimeInterval = 10

        let left = [0, 30, 40, 50, 55, 80].map { LiveOfferRule.left(seen: $0, lasts: lasts, lastLook: look) }

        #expect(left == [45, 15, 10, 5, 0, 0])
    }

    @Test func anUnreadableSourceWaitsADayAndAnEmptyOneAnHour() {
        let shut = LiveOfferPast(space: home, id: "github", tried: start)
        let empty = LiveOfferPast(space: home, id: "github", tried: start, empty: true)

        #expect(LiveOfferRule.tries(nil, now: start))
        #expect(!LiveOfferRule.tries(shut, now: start.addingTimeInterval(2 * 3_600)))
        #expect(LiveOfferRule.tries(shut, now: start.addingTimeInterval(25 * 3_600)))
        #expect(!LiveOfferRule.tries(empty, now: start.addingTimeInterval(600)))
        #expect(LiveOfferRule.tries(empty, now: start.addingTimeInterval(3_700)))
    }

    @Test func theThirdVisitToAReadableSiteShowsTheGhost() async {
        let world = world()
        let offers = offers(world)
        let browser = Browser(record: WindowRecord())

        await arrive(offers, browser)

        let shown = offers.clock(for: browser)
        #expect(shown?.offer.id == "github")
        #expect(shown?.offer.space == home)
        #expect(shown?.offer.name == LiveSource.pullRequestsName)
        #expect(shown?.offer.items.count == 2)
        #expect(shown?.left == LiveOffers.lasts)
        #expect(offers.spoken == ["Suggested folder in the sidebar: PRs. Your open pull requests on GitHub, kept up to date."])
    }

    @Test func twoVisitsAreTooEarlyAndNothingIsRead() async {
        let world = world()
        world.visits = 2
        let offers = offers(world)
        let browser = Browser(record: WindowRecord())

        await arrive(offers, browser, shown: false)

        #expect(offers.offer(for: browser) == nil)
        #expect(world.asked == 0)
        #expect(offers.past.isEmpty)
    }

    @Test func aSourceThatAsksForSignInShowsNothingAndIsNotAskedAgainAtOnce() async {
        let world = world()
        world.answer = .signIn
        let offers = offers(world)
        let browser = Browser(record: WindowRecord())

        await arrive(offers, browser, shown: false)
        await arrive(offers, browser, shown: false)

        #expect(offers.offer(for: browser) == nil)
        #expect(world.asked == 1)
        #expect(offers.record(home, "github")?.tried == start)
        #expect(offers.record(home, "github")?.turnedDown == nil)
    }

    @Test func anEmptyReadShowsNothingAndIsAskedAgainAfterAnHour() async {
        let world = world()
        world.answer = .items([], nil)
        let offers = offers(world)
        let browser = Browser(record: WindowRecord())
        await arrive(offers, browser, shown: false)
        #expect(offers.record(home, "github")?.empty == true)

        world.answer = .items([LiveItem(key: "https://github.com/acme/rocket/pull/3", title: "Three")], nil)
        world.now = start.addingTimeInterval(LiveOffers.emptyRetry)
        await arrive(offers, browser)

        #expect(offers.offer(for: browser)?.items.count == 1)
        #expect(world.asked == 2)
    }

    @Test func leftAloneItTurnsItselfDownAndStaysDown() async {
        let world = world()
        let offers = offers(world)
        let browser = Browser(record: WindowRecord())
        await arrive(offers, browser)

        world.now = start.addingTimeInterval(LiveOffers.lasts - 1)
        offers.tick()
        let before = offers.offer(for: browser)
        world.now = start.addingTimeInterval(LiveOffers.lasts + 0.5)
        offers.tick()
        await arrive(offers, browser, shown: false)

        #expect(before != nil)
        #expect(offers.offer(for: browser) == nil)
        #expect(offers.record(home, "github")?.turnedDown != nil)
        #expect(offers.record(home, "github")?.byTimer == true)
        #expect(offers.reason(browser) == "turned down")
    }

    @Test func thePointerTheFoldAndBeingAwayEachHoldTheClock() async {
        let world = world()
        let offers = offers(world)
        let browser = Browser(record: WindowRecord())
        await arrive(offers, browser)
        world.now = start.addingTimeInterval(5)
        offers.tick()

        world.eyes.held = true
        offers.tick()
        world.now = start.addingTimeInterval(65)
        offers.tick()
        let held = offers.clock(for: browser)
        world.eyes = LiveOffers.Eyes(seen: false, held: false)
        offers.tick()
        world.now = start.addingTimeInterval(125)
        offers.tick()
        let hidden = offers.clock(for: browser)
        world.eyes.seen = true
        world.front = false
        offers.tick()
        world.now = start.addingTimeInterval(185)
        offers.tick()
        let away = offers.clock(for: browser)
        world.front = true
        offers.tick()
        world.now = start.addingTimeInterval(195)
        offers.tick()
        let running = offers.clock(for: browser)

        #expect(held?.holds == ["held"])
        #expect(held?.remaining(at: world.now) == LiveOffers.lasts - 5)
        #expect(hidden?.holds == ["hidden"])
        #expect(away?.holds == ["away"])
        #expect(away?.remaining(at: world.now) == LiveOffers.lasts - 5)
        #expect(running?.running == true)
        #expect(running?.remaining(at: world.now) == LiveOffers.lasts - 15)
    }

    @Test func leavingTheSiteTakesTheGhostAwayUnspentAndComingBackReturnsIt() async {
        let world = world()
        let offers = offers(world)
        let browser = Browser(record: WindowRecord())
        await arrive(offers, browser)

        world.now = start.addingTimeInterval(12)
        world.visit = LiveVisit(url: URL(string: "https://example.com/")!, space: home)
        offers.consider(browser)
        let away = offers.offer(for: browser)
        let kept = offers.record(home, "github")
        world.now = start.addingTimeInterval(600)
        world.visit = LiveVisit(url: gitHub, space: home)
        await arrive(offers, browser)

        #expect(away == nil)
        #expect(kept?.seen == 12)
        #expect(kept?.turnedDown == nil)
        #expect(offers.clock(for: browser)?.left == LiveOffers.lasts - 12)
        #expect(offers.spoken.count == 1)
    }

    @Test func aGhostSeenToItsLimitCountsAsTurnedDown() async {
        let world = world()
        let offers = offers(world)
        let browser = Browser(record: WindowRecord())
        await arrive(offers, browser)
        world.now = start.addingTimeInterval(40)
        world.visit = LiveVisit(url: URL(string: "https://example.com/")!, space: home)
        offers.consider(browser)
        world.visit = LiveVisit(url: gitHub, space: home)
        await arrive(offers, browser)
        let second = offers.clock(for: browser)?.left

        world.now = start.addingTimeInterval(49.5)
        world.visit = LiveVisit(url: URL(string: "https://example.com/")!, space: home)
        offers.consider(browser)
        world.visit = LiveVisit(url: gitHub, space: home)
        await arrive(offers, browser)
        let third = offers.clock(for: browser)?.left
        world.now = start.addingTimeInterval(49.5 + 5.5)
        world.visit = LiveVisit(url: URL(string: "https://example.com/")!, space: home)
        offers.consider(browser)

        #expect(second == LiveOffers.lastLook)
        #expect(third == LiveOffers.lasts + LiveOffers.lastLook - 49.5)
        #expect(offers.record(home, "github")?.turnedDown != nil)
        #expect(offers.record(home, "github")?.byTimer == true)
    }

    @Test func noThanksIsForThisSpaceAndAnotherSpaceIsStillAsked() async {
        let world = world()
        let offers = offers(world)
        let browser = Browser(record: WindowRecord())
        await arrive(offers, browser)

        offers.turnDown(browser)
        await arrive(offers, browser, shown: false)
        let here = offers.offer(for: browser)
        world.visit = LiveVisit(url: gitHub, space: work)
        await arrive(offers, browser)

        #expect(here == nil)
        #expect(offers.record(home, "github")?.turnedDown != nil)
        #expect(offers.record(home, "github")?.byTimer == nil)
        #expect(offers.offer(for: browser)?.space == work)
    }

    @Test func visitsMadeInAnotherSpaceDoNotBringTheGhostHere() async {
        let world = world()
        world.visitsIn = [home: 1, work: 5]
        let offers = offers(world)
        let browser = Browser(record: WindowRecord())

        await arrive(offers, browser, shown: false)
        let here = offers.offer(for: browser)
        let asked = world.asked
        world.visit = LiveVisit(url: gitHub, space: work)
        await arrive(offers, browser)

        #expect(here == nil)
        #expect(asked == 0)
        #expect(offers.offer(for: browser)?.space == work)
    }

    @Test func addFolderHandsOverWhatWasReadAndTurnsNothingDown() async {
        let world = world()
        let offers = offers(world)
        let browser = Browser(record: WindowRecord())
        await arrive(offers, browser)

        let made = offers.accept(browser)

        #expect(made?.source == .pullRequests)
        #expect(world.added.map(\.items.count) == [2])
        #expect(offers.offer(for: browser) == nil)
        #expect(offers.filled(in: browser) == made?.id)
        #expect(offers.turnedDown(in: home).isEmpty)
    }

    @Test func suggestAgainForgetsWhatThatSpaceTurnedDown() async {
        let world = world()
        let offers = offers(world)
        let browser = Browser(record: WindowRecord())
        await arrive(offers, browser)
        offers.turnDown(browser)
        world.visit = LiveVisit(url: gitHub, space: work)
        await arrive(offers, browser)
        offers.turnDown(browser)

        offers.suggestAgain(in: home)

        #expect(offers.turnedDown(in: home).isEmpty)
        #expect(offers.turnedDown(in: work).map(\.id) == ["github"])
    }

    @Test func aPrivateWindowAnAgentTabAndTheSwitchOffAreAllQuiet() async {
        let reasons = ["private", "agent", "suggestions off", "onboarding", "popup"]
        var shown: [Bool] = []

        for reason in reasons {
            let world = world(quiet: reason)
            let offers = offers(world)
            let browser = Browser(record: WindowRecord())
            await arrive(offers, browser, shown: false)
            shown.append(offers.offer(for: browser) != nil || world.asked > 0)
        }

        #expect(shown == [false, false, false, false, false])
    }

    @Test func anotherOfferUpKeepsTheGhostBack() async {
        let world = world()
        let offers = offers(world)
        let browser = Browser(record: WindowRecord())
        browser.linkNotice = LinkNotice("Opened in Work", choices: [])

        await arrive(offers, browser, shown: false)

        #expect(offers.offer(for: browser) == nil)
        #expect(offers.reason(browser) == "busy")
    }

    @Test func theLoopbackAliasIsForTestRunsOnly() {
        let settings = UserDefaults(suiteName: "live-offers-tests-\(UUID().uuidString)")!
        settings.set("5123=github.com", forKey: LiveSuggestions.aliasKey)
        let local = URL(string: "http://127.0.0.1:5123/acme/rocket")!
        let other = URL(string: "http://127.0.0.1:5124/acme/rocket")!
        let outside = URL(string: "http://example.com:5123/acme/rocket")!

        #expect(LiveSuggestions.alias(local, settings: settings, testing: true) == "github.com")
        #expect(LiveSuggestions.alias(local, settings: settings, testing: false) == nil)
        #expect(LiveSuggestions.alias(other, settings: settings, testing: true) == nil)
        #expect(LiveSuggestions.alias(outside, settings: settings, testing: true) == nil)
    }

    @Test func theSwitchAndTheTurnedDownRowAreInSettings() {
        let prefs = Preferences()
        let before = prefs.suggestsLiveFolders
        defer { prefs.suggestsLiveFolders = before }

        let applied = BenchSettings.set("live.offers", true, on: prefs)

        #expect(applied)
        #expect(prefs.suggestsLiveFolders)
        #expect(SettingsIndex.item("live.offers")?.keys == ["live.suggest"])
        #expect(SettingsIndex.item("live.offers.again") != nil)
    }

    @Test func theOutlinesDashesFitItsLengthWithNoneCut() {
        let lengths: [CGFloat] = [407, 523.4, 607]

        for length in lengths {
            let fitted = LiveGhostView.dashes(along: length)
            let count = length / (fitted.on + fitted.off)
            #expect(abs(count - count.rounded()) < 0.0001)
            #expect(abs(fitted.on - LiveGhostView.dash.on) < 1)
        }
    }

    @Test func theGhostIsOneRowWhateverItOffers() {
        let source = LiveSource(kind: .pullRequests, address: "https://github.com/pulls")
        let offer = LiveOffer(id: "github", space: UUID(), title: "GitHub", name: "PRs", source: source)

        #expect(LiveGhostView.height(offer, width: 188) == 34)
        #expect(LiveGhostView.height(offer, width: 428) == 34)
    }

    @Test func aLongNameLeavesNoRoomForTheWords() {
        let add: CGFloat = 38
        let words: CGFloat = 70
        let cross: CGFloat = 22

        let wide = LiveGhostView.nameRoom(width: 246, from: 33, add: add, decline: words)
        let narrow = LiveGhostView.nameRoom(width: 188, from: 33, add: add, decline: words)
        let folded = LiveGhostView.nameRoom(width: 188, from: 33, add: add, decline: cross)

        #expect(wide == 89)
        #expect(narrow == 31)
        #expect(folded == 79)
    }

    @Test func reduceMotionMovesTheClockInSteps() {
        #expect(LiveGhostButton.level(0) == 0)
        #expect(LiveGhostButton.level(0.37) == 0.25)
        #expect(LiveGhostButton.level(0.5) == 0.5)
        #expect(LiveGhostButton.level(1.2) == 1)
    }
}
