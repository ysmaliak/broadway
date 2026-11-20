import AppKit
import Foundation
import Testing
@testable import Search

@MainActor
final class FakeUpdateEngine: UpdateEngine {
    var busy = false
    var running = "100"
    var version = "0.1"
    var begins = 0
    var reads: [(UpdateFound?, String?) -> Void] = []

    func begin() { begins += 1 }

    func read(_ done: @escaping (UpdateFound?, String?) -> Void) { reads.append(done) }

    func answer(_ found: UpdateFound?, _ failure: String? = nil) {
        guard !reads.isEmpty else { return }
        reads.removeFirst()(found, failure)
    }
}

@Suite(.timeLimit(.minutes(2)))
@MainActor
struct UpdateFlowTests {
    private let b = UpdateFound(version: "0.2", build: "200")
    private let c = UpdateFound(version: "0.3", build: "300")

    private func made(quietly: Bool = false, seen: Bool = true) -> (UpdateFlow, FakeUpdateEngine) {
        let flow = UpdateFlow()
        let engine = FakeUpdateEngine()
        flow.engine = engine
        flow.installsQuietly = { quietly }
        flow.cardSeen = { seen }
        return (flow, engine)
    }

    private func turn(_ seconds: Double = 0.1) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func staged(_ flow: UpdateFlow, _ update: UpdateFound) {
        flow.found(update, stage: .notDownloaded, informational: false) { _ in }
        flow.downloadStarted()
        flow.extractStarted()
        flow.ready { _ in }
        flow.cycleEnded()
    }

    @Test func anUpdateFoundWithQuietInstallsOffIsOfferedAndLeftAlone() {
        let (flow, engine) = made()
        var replies: [UpdateChoice] = []

        flow.found(b, stage: .notDownloaded, informational: false) { replies.append($0) }

        #expect(replies == [.dismiss])
        #expect(flow.found == b)
        #expect(flow.shown == .available)
        #expect(flow.card)
        #expect(flow.offered)
        #expect(!flow.quiet)
        #expect(engine.begins == 0)
    }

    @Test func aQuietDownloadKeepsTheCardOnAvailableAndStagesOnReady() {
        let (flow, _) = made(quietly: true)
        var replies: [UpdateChoice] = []

        flow.found(b, stage: .notDownloaded, informational: false) { replies.append($0) }
        flow.downloadStarted()
        flow.expect(1000)
        flow.receive(420)
        let during = (flow.shown, flow.progress, flow.quiet)
        flow.extractStarted()
        flow.ready { replies.append($0) }
        flow.cycleEnded()

        #expect(during.0 == .available)
        #expect(during.1 == nil)
        #expect(during.2)
        #expect(replies == [.install, .dismiss])
        #expect(flow.staged == b)
        #expect(flow.shown == .available)
        #expect(!flow.quiet)
    }

    @Test func installWithANewerUpdateThanTheStagedOneDropsItAndDownloadsTheNewest() async {
        let (flow, engine) = made(quietly: true)
        staged(flow, b)
        var replies: [UpdateChoice] = []

        flow.press()
        let checking = flow.shown
        engine.answer(c)
        let beganAfterRead = engine.begins
        flow.found(b, stage: .installing, informational: false) { replies.append($0) }
        flow.cycleEnded()
        await turn()
        let beganAgain = engine.begins
        flow.found(c, stage: .notDownloaded, informational: false) { replies.append($0) }
        flow.downloadStarted()
        flow.expect(1000)
        flow.receive(420)
        let downloading = (flow.shown, flow.progress)
        flow.extractStarted()
        let installing = flow.shown
        flow.ready { replies.append($0) }

        #expect(checking == .checking)
        #expect(beganAfterRead == 1)
        #expect(beganAgain == 2)
        #expect(replies == [.cancel, .install, .install])
        #expect(downloading.0 == .downloading)
        #expect(downloading.1 == 0.42)
        #expect(installing == .installing)
        #expect(flow.shown == .installing)
        #expect(flow.found == c)
    }

    @Test func installWhenTheStagedUpdateIsStillTheNewestInstallsItAtOnce() {
        let (flow, engine) = made(quietly: true)
        staged(flow, b)
        var replies: [UpdateChoice] = []

        flow.press()
        engine.answer(b)
        flow.found(b, stage: .installing, informational: false) { replies.append($0) }

        #expect(engine.begins == 1)
        #expect(replies == [.install])
        #expect(flow.shown == .installing)
        #expect(flow.progress == 1)
    }

    @Test func installWhenTheFeedCannotBeReadStillInstallsTheStagedUpdate() {
        let (flow, engine) = made(quietly: true)
        staged(flow, b)
        var replies: [UpdateChoice] = []

        flow.press()
        engine.answer(nil, "The network connection was lost")
        flow.found(b, stage: .installing, informational: false) { replies.append($0) }

        #expect(replies == [.install])
        #expect(flow.shown == .installing)
    }

    @Test func installWithNothingNewerThanTheRunningBuildTakesTheCardAway() {
        let (flow, engine) = made()
        flow.found(b, stage: .notDownloaded, informational: false) { _ in }

        flow.press()
        let began = engine.begins
        flow.checkStarted()
        flow.notFound()

        #expect(began == 1)
        #expect(flow.found == nil)
        #expect(flow.shown == .idle)
        #expect(!flow.card)
        #expect(!flow.offered)
        #expect(flow.told.isEmpty)
    }

    @Test func aFailedInstallSaysWhyAndTheCrossPutsItAway() {
        let (flow, _) = made()
        flow.found(b, stage: .notDownloaded, informational: false) { _ in }

        flow.press()
        flow.found(b, stage: .notDownloaded, informational: false) { _ in }
        flow.downloadStarted()
        flow.failed("The update is improperly signed and could not be validated")
        let failed = (flow.shown, flow.trouble, flow.canInstall, flow.canCheck)
        flow.hide()

        #expect(failed.0 == .failed)
        #expect(failed.1 == "The update is improperly signed and could not be validated")
        #expect(failed.2)
        #expect(failed.3)
        #expect(flow.shown == .idle)
        #expect(flow.trouble == nil)
    }

    @Test func installDuringAQuietDownloadFollowsItAndStartsNoSecondOne() {
        let (flow, engine) = made(quietly: true)
        var replies: [UpdateChoice] = []
        flow.found(b, stage: .notDownloaded, informational: false) { replies.append($0) }
        flow.downloadStarted()
        flow.expect(1000)
        flow.receive(420)

        flow.press()
        let pressed = (flow.shown, flow.progress)
        flow.receive(330)
        let later = flow.progress
        flow.extractStarted()
        flow.ready { replies.append($0) }
        let held = replies
        engine.answer(b)

        #expect(pressed.0 == .downloading)
        #expect(pressed.1 == 0.42)
        #expect(later == 0.75)
        #expect(engine.begins == 0)
        #expect(held == [.install])
        #expect(replies == [.install, .install])
        #expect(flow.shown == .installing)
    }

    @Test func installDuringAQuietDownloadOfAnOlderUpdateSwitchesToTheNewest() async {
        let (flow, engine) = made(quietly: true)
        var replies: [UpdateChoice] = []
        flow.found(b, stage: .notDownloaded, informational: false) { replies.append($0) }
        flow.downloadStarted()

        flow.press()
        engine.answer(c)
        flow.extractStarted()
        flow.ready { replies.append($0) }
        flow.cycleEnded()
        await turn()

        #expect(replies == [.install, .cancel])
        #expect(engine.begins == 1)
        #expect(flow.found == c)
        #expect(flow.shown == .checking)
    }

    @Test func installWaitsWhileACheckOfSparklesOwnIsRunning() async {
        let (flow, engine) = made()
        flow.found(b, stage: .notDownloaded, informational: false) { _ in }
        engine.busy = true

        flow.press()
        let waiting = engine.begins
        engine.busy = false
        await turn(0.7)

        #expect(waiting == 0)
        #expect(engine.begins == 1)
        #expect(flow.shown == .checking)
    }

    @Test func checkForUpdatesSaysUpToDateOrAvailableOrWhyNot() {
        let (flow, engine) = made(seen: false)

        flow.checkNow()
        let checking = flow.phase
        flow.notFound()
        flow.checkNow()
        flow.found(b, stage: .notDownloaded, informational: false) { _ in }
        flow.cycleEnded()
        flow.checkNow()
        flow.failed("The network connection was lost")

        #expect(checking == .checking)
        #expect(engine.begins == 3)
        #expect(flow.told == [.upToDate("0.1"), .available(b), .checkFailed("The network connection was lost")])
        #expect(flow.phase == .idle)
        #expect(flow.shown == .available)
    }

    @Test func checkForUpdatesWithTheCardInViewAsksNothing() {
        let (flow, _) = made(seen: true)

        flow.checkNow()
        flow.found(b, stage: .notDownloaded, informational: false) { _ in }

        #expect(flow.told.isEmpty)
        #expect(flow.shown == .available)
    }

    @Test func checkForUpdatesWhileAnUpdateIsStagedReadsTheFeedItself() {
        let (flow, engine) = made(quietly: true, seen: false)
        staged(flow, b)

        flow.checkNow()
        let reading = (flow.phase, engine.reads.count)
        engine.answer(c)

        #expect(reading.0 == .checking)
        #expect(reading.1 == 1)
        #expect(engine.begins == 0)
        #expect(flow.found == c)
        #expect(flow.told == [.available(c)])
        #expect(flow.phase == .idle)
        #expect(flow.staged == b)
    }

    @Test func checkForUpdatesAfterTheCrossShowsTheCardAgain() {
        let (flow, _) = made()
        flow.found(b, stage: .notDownloaded, informational: false) { _ in }
        flow.cycleEnded()
        flow.hide()
        let hidden = flow.card

        flow.checkNow()
        flow.found(b, stage: .notDownloaded, informational: false) { _ in }
        flow.cycleEnded()

        #expect(!hidden)
        #expect(flow.card)
        #expect(flow.shown == .available)
    }

    @Test func theAvailableAlertComesAfterSparkleHasItsAnswer() async {
        let (flow, _) = made(seen: false)
        var order: [String] = []
        flow.tell = { _ in order.append("tell") }

        flow.checkNow()
        flow.found(b, stage: .notDownloaded, informational: false) { _ in order.append("reply") }
        await turn()

        #expect(order == ["reply", "tell"])
        #expect(flow.told == [.available(b)])
    }

    @Test func aQuitThatIsHeldOffersInstallAgainWhichAsksToQuitOnceMore() async {
        let (flow, engine) = made()
        let wait = UpdateFlow.quitWait
        UpdateFlow.quitWait = 0.2
        defer { UpdateFlow.quitWait = wait }
        var retries = 0
        flow.found(b, stage: .notDownloaded, informational: false) { _ in }
        flow.cycleEnded()
        flow.press()
        await turn(0.7)
        flow.found(b, stage: .notDownloaded, informational: false) { _ in }
        flow.downloadStarted()
        flow.extractStarted()
        flow.ready { _ in }

        flow.installing { retries += 1 }
        let installing = flow.shown
        await turn(0.5)
        let held = (flow.shown, flow.canCheck)
        flow.press()

        #expect(engine.begins == 1)
        #expect(installing == .installing)
        #expect(held.0 == .available)
        #expect(held.1)
        #expect(retries == 1)
        #expect(flow.shown == .installing)
    }

    @Test func theCrossHidesTheCardUntilANewerUpdateIsFound() {
        let (flow, _) = made()
        flow.found(b, stage: .notDownloaded, informational: false) { _ in }
        let arrived = flow.arrivals

        flow.hide()
        let hidden = (flow.card, flow.offered)
        flow.found(b, stage: .notDownloaded, informational: false) { _ in }
        let same = flow.card
        flow.found(c, stage: .notDownloaded, informational: false) { _ in }

        #expect(!hidden.0)
        #expect(hidden.1)
        #expect(!same)
        #expect(flow.card)
        #expect(flow.arrivals == arrived + 1)
    }

    @Test func anInformationalUpdateIsNeverOffered() {
        let (flow, _) = made(quietly: true)
        var replies: [UpdateChoice] = []

        flow.found(c, stage: .notDownloaded, informational: true) { replies.append($0) }

        #expect(replies == [.dismiss])
        #expect(flow.found == nil)
    }

    @Test func versionsCompareTheWaySparkleDoes() {
        #expect(UpdateFlow.newer("202611201954", than: "202611201953"))
        #expect(UpdateFlow.newer("0.10", than: "0.9"))
        #expect(!UpdateFlow.newer("200", than: "200"))
        #expect(!UpdateFlow.newer("1.0", than: "1.0.1"))
    }

    @Test func theFeedIsReadForItsNewestItemThatFitsThisMac() {
        let feed = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item><sparkle:version>200</sparkle:version><sparkle:shortVersionString>0.2</sparkle:shortVersionString>
              <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion><enclosure url="https://x/b.dmg" length="1"/></item>
            <item><sparkle:version>400</sparkle:version><sparkle:shortVersionString>0.4</sparkle:shortVersionString>
              <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion><enclosure url="https://x/d.dmg" length="1"/></item>
            <item><sparkle:version>500</sparkle:version><sparkle:channel>beta</sparkle:channel><enclosure url="https://x/e.dmg" length="1"/></item>
            <item><enclosure url="https://x/c.dmg" sparkle:version="300" sparkle:shortVersionString="0.3" length="1"/></item>
          </channel>
        </rss>
        """

        let items = UpdateFeedParser.items(Data(feed.utf8))
        let newest = UpdateFeedParser.newest(items, system: "27.2.0")

        #expect(items.map(\.build) == ["200", "400", "500", "300"])
        #expect(newest == c)
        #expect(UpdateFeedParser.items(Data("not a feed".utf8)).isEmpty)
    }

    @Test func theWordsForEachState() {
        let found = UpdateFound(version: "0.7", build: "70")
        let looks = [UpdatePhase.available, .checking, .downloading, .installing, .failed].map {
            UpdateCardLook.of($0, found: found, progress: $0 == .downloading ? 0.426 : nil, trouble: $0 == .failed ? "The disk is full" : nil)
        }
        let unknown = UpdateCardLook.of(.downloading, found: found, progress: nil, trouble: nil)

        #expect(looks.map(\.title) == ["Update Available", "Checking for Updates", "Downloading", "Installing", "Couldn't Update"])
        #expect(looks[0].trailing == .button("Install", label: "Install Update"))
        #expect(looks[0].label == "Update available, version 0.7")
        #expect(looks[0].tip == "Version 0.7")
        #expect(looks[1].trailing == .spinner)
        #expect(looks[2].trailing == .percent("42%"))
        #expect(looks[2].label == "Downloading, 42%")
        #expect(looks[2].line == .part(0.426))
        #expect(unknown.trailing == .spinner)
        #expect(unknown.line == .waiting)
        #expect(looks[3].line == .part(1))
        #expect(looks[4].trailing == .button("Try Again", label: "Try Again"))
        #expect(looks[4].tip == "The disk is full")
        #expect(looks[0].line == .none && looks[1].line == .none && looks[4].line == .none)
        #expect(UpdateWords.percent(1) == "100%")
        #expect(UpdateWords.percent(0.999) == "99%")
        #expect(UpdateWords.downloading(nil) == "Downloading")
        #expect(UpdateWords.available("0.7") == "Broadway 0.7 is available")
        #expect(UpdateWords.newest("0.6") == "Version 0.6 is the newest")
        #expect(UpdateWords.reason(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "The disk is full."])) == "The disk is full")
        #expect(UpdateWords.reason(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "The update is improperly signed and could not be validated. Please try again later or contact the app developer."]))
            == "The update is improperly signed and could not be validated")
        for text in looks.flatMap({ [$0.title, $0.label] }) + [UpdateWords.upToDate, UpdateWords.checkFailed, UpdateWords.checking] {
            #expect(!text.contains(";") && !text.hasSuffix("."))
        }
    }
}
