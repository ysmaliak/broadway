import AppKit
import Testing
@testable import Search

@MainActor
final class OnboardingStageStub: OnboardingStage {
    var raised = 0
    var cleared = 0
    var handed: [() -> Void] = []
    var steps: [String] = []

    func raise(_ onboarding: Onboarding) { raised += 1 }
    func handOff(_ onboarding: Onboarding, done: @escaping () -> Void) { handed.append(done) }
    func clear() { cleared += 1 }
    func makeWay() { steps.append("aside") }
    func takeBack() { steps.append("back") }
}

@Suite(.timeLimit(.minutes(5))) struct OnboardingOnceTests {
    @Test func aFreshProfileIsWelcomedOnce() {
        let first = Onboarding.due(testing: false, forced: false, seen: false, freshProfile: true)
        let again = Onboarding.due(testing: false, forced: false, seen: true, freshProfile: true)

        #expect(first)
        #expect(!again)
    }

    @Test func aProfileInUseIsNeverWelcomed() {
        let due = Onboarding.due(testing: false, forced: false, seen: false, freshProfile: false)

        #expect(!due)
    }

    @Test func aWelcomeCutShortComesBackOnTheNextLaunch() {
        let due = Onboarding.due(testing: false, forced: false, seen: false, freshProfile: false, begun: true)
        let done = Onboarding.due(testing: false, forced: false, seen: true, freshProfile: false, begun: true)

        #expect(due)
        #expect(!done)
    }

    @Test func askingShowsItAgainEvenWhenSeen() {
        let due = Onboarding.due(testing: false, forced: true, seen: true, freshProfile: false)

        #expect(due)
    }

    @Test func aTestRunIsWelcomedOnlyWhenAsked() {
        let quiet = Onboarding.due(testing: true, forced: false, seen: false, freshProfile: true, begun: true)
        let asked = Onboarding.due(testing: true, forced: true, seen: true, freshProfile: false)

        #expect(!quiet)
        #expect(asked)
    }

    @Test(arguments: Onboarding.profileFiles)
    func anyKeptFileMeansTheProfileIsInUse(_ name: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(Onboarding.freshProfile(in: folder))

        try Data("[]".utf8).write(to: folder.appendingPathComponent(name))

        #expect(!Onboarding.freshProfile(in: folder))
    }

    @Test func aMissingFolderIsAFreshProfile() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        #expect(Onboarding.freshProfile(in: folder))
    }

    @Test func theDrawnIntroTakesItsTimeAndEverythingComesToRestBeforeItEnds() {
        let score = OnboardingScore.current(reduced: false)
        let written = score.written(letters: OnboardingWord.text.count)

        #expect(score.drawn)
        #expect(score.ends >= 5 && score.ends <= 6)
        #expect(score.grid < score.line)
        #expect(score.gridTakes >= 1.2)
        #expect(score.lineTakes >= 1.5)
        #expect(score.line + score.lineTakes <= score.recede - 0.2)
        #expect(score.word > score.recede && score.word < score.mapRests)
        #expect(score.mapRests < score.ends)
        #expect(score.letterTakes >= 0.7)
        #expect(score.word + Double(OnboardingWord.text.count - 1) * score.letterGap + score.letterTakes <= written)
        #expect(written <= score.ends - 0.25)
        #expect(OnboardingLayout.cardWaits >= 0.25)
    }

    @Test func reduceMotionDrawsNothingAndIsShorter() {
        let score = OnboardingScore.current(reduced: true)

        #expect(!score.drawn)
        #expect(score.ends < OnboardingScore.drawn.ends)
        #expect(score.lineTakes == 0)
        #expect(score.recedeTakes == 0)
    }

    @Test func everyWordSaysBroadway() {
        let words = Onboarding.Step.allCases.flatMap { [Onboarding.title($0), Onboarding.line($0)] }

        #expect(OnboardingWord.text == "Broadway")
        #expect(!words.contains { $0.contains("Ave ") || $0.hasSuffix("Ave.") || $0.contains("Ave?") })
        #expect(Onboarding.title(.links).contains("Broadway"))
        #expect(Onboarding.title(.agents).contains("Broadway"))
    }

    @Test func thePenNeverGoesBackAndSlowsAtTheBend() {
        let drawn = OnboardingPen.stroke(from: 0.1, to: 0.9, bend: 0.5, samples: 81)
        let steps = zip(drawn.dropFirst(), drawn).map { $0 - $1 }

        #expect(drawn.first == 0.1)
        #expect(drawn.last == 0.9)
        #expect(steps.allSatisfy { $0 >= 0 })
        let middle = drawn.firstIndex { $0 >= 0.5 } ?? 40
        let straight = drawn.firstIndex { $0 >= 0.3 } ?? 20
        #expect(steps[middle - 1] < steps[straight - 1])
        #expect(steps[0] < steps[straight - 1])
    }

    @Test func thePenEntersAndLeavesWhatTheDisplayShows() {
        let wide = CGRect(x: -400, y: 100, width: 1824, height: 824)

        let reach = OnboardingPen.reach(in: wide)

        #expect(reach.enters >= 0)
        #expect(reach.enters < reach.bend)
        #expect(reach.bend < reach.leaves)
        #expect(reach.leaves <= 1)
    }

    @Test func theMapIsTheIconsMap() {
        let church = BroadwayMap.spot(avenue: BroadwayMap.graceChurch.avenue, street: BroadwayMap.graceChurch.street)
        let route = BroadwayMap.route()
        let grid = BroadwayMap.grid()

        #expect(BroadwayMap.tilt == 29)
        #expect(route.boundingBoxOfPath.insetBy(dx: -1, dy: -1).contains(church))
        #expect(route.copy(strokingWithWidth: BroadwayMap.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(church))
        #expect(!grid.isEmpty)
        #expect(grid.boundingBoxOfPath.contains(CGRect(x: 0, y: 0, width: BroadwayMap.canvas, height: BroadwayMap.canvas)))
    }

    @Test(arguments: [
        (CGSize(width: 1280, height: 800), CGFloat(0)),
        (CGSize(width: 1470, height: 956), CGFloat(32)),
        (CGSize(width: 1512, height: 982), CGFloat(32)),
        (CGSize(width: 1728, height: 1117), CGFloat(38)),
        (CGSize(width: 1920, height: 1080), CGFloat(0)),
        (CGSize(width: 2560, height: 1440), CGFloat(0)),
        (CGSize(width: 3008, height: 1692), CGFloat(0)),
        (CGSize(width: 3840, height: 2160), CGFloat(0)),
        (CGSize(width: 1080, height: 1920), CGFloat(0)),
    ])
    func theCardAndTheWordmarkFitEveryDisplay(size: CGSize, safeTop: CGFloat) {
        let cap = OnboardingWord.glyphs(size: OnboardingLayout.wordSize).capHeight

        let layout = OnboardingLayout(size: size, safeTop: safeTop, capHeight: cap)

        let room = CGRect(x: 0, y: 0, width: size.width, height: size.height - safeTop)
        #expect(layout.unit >= 1 && layout.unit <= OnboardingLayout.largest)
        #expect(room.insetBy(dx: 24, dy: 24).contains(layout.cardFrame))
        let headerTop = layout.headerCentre.y + layout.wordHeight * layout.header / 2
        let headerBottom = layout.headerCentre.y - layout.wordHeight * layout.header / 2
        #expect(headerTop <= room.maxY - 24)
        #expect(abs(headerBottom - layout.cardFrame.maxY - OnboardingLayout.cardGap) < 0.5)
        #expect(abs((headerTop + layout.cardFrame.minY) / 2 - room.midY) < 0.5)
        #expect(abs(layout.centre.y - room.midY) < 0.5)
        #expect(layout.baseline >= 0)
        #expect(layout.wide * BroadwayMap.canvas >= size.height - 1)
    }

    @Test func theWordmarkGrowsWithTheDisplayAndStops() {
        let cap = OnboardingWord.glyphs(size: OnboardingLayout.wordSize).capHeight

        let small = OnboardingLayout(size: CGSize(width: 1280, height: 800), safeTop: 0, capHeight: cap)
        let big = OnboardingLayout(size: CGSize(width: 2560, height: 1440), safeTop: 0, capHeight: cap)
        let huge = OnboardingLayout(size: CGSize(width: 5120, height: 2880), safeTop: 0, capHeight: cap)

        #expect(small.wordHeight == cap)
        #expect(big.wordHeight > small.wordHeight)
        #expect(huge.wordHeight == big.wordHeight)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class OnboardingTests {
    private var browser: Browser!
    private var settings: UserDefaults!
    private var suite = ""
    private var clock: [(delay: TimeInterval, work: () -> Void)] = []
    private var asked = 0
    private var answers: [() -> Void] = []

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        suite = "onboarding.tests.\(UUID().uuidString)"
        settings = UserDefaults(suiteName: suite)
        keepSetting(browser.prefs, \.sidePosition, "sidebar.position")
        keepSetting(browser.prefs, \.agentsOn, "agents.on")
    }

    private func tearDown() async {
        settings.removePersistentDomain(forName: suite)
        browser.closeAll()
        browser = nil
    }

    private func made(isDefault: Bool = false, sources: [String] = ["Chrome", "Arc"]) -> Onboarding {
        let onboarding = Onboarding(settings: settings)
        onboarding.after = { [weak self] delay, work in self?.clock.append((delay, work)) }
        onboarding.isDefault = { isDefault }
        onboarding.askDefault = { [weak self] answered in
            self?.asked += 1
            self?.answers.append(answered)
        }
        onboarding.sources = { sources }
        onboarding.defaultBrowser = { nil }
        return onboarding
    }

    private func atSteps(_ onboarding: Onboarding) {
        onboarding.begin(in: browser, reduced: false)
        onboarding.endIntro()
    }

    private func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func aFreshLaunchBeginsAndFinishingIsRemembered() {
        let onboarding = made()

        let shown = onboarding.arrive(in: browser, testing: false, freshProfile: true)
        let begun = settings.bool(forKey: Onboarding.begunKey)
        onboarding.close()
        let again = made().arrive(in: browser, testing: false, freshProfile: true)

        #expect(shown)
        #expect(begun)
        #expect(onboarding.seen)
        #expect(onboarding.phase == .away)
        #expect(!settings.bool(forKey: Onboarding.begunKey))
        #expect(!again)
    }

    @Test func aLaunchOnAProfileInUseShowsNothingAndNeverWill() {
        let onboarding = made()

        let shown = onboarding.arrive(in: browser, testing: false, freshProfile: false)
        let later = made().arrive(in: browser, testing: false, freshProfile: true)

        #expect(!shown)
        #expect(onboarding.phase == .away)
        #expect(onboarding.seen)
        #expect(!later)
    }

    @Test func quittingMidwayBringsItBackOnTheNextLaunch() {
        let first = made()
        first.arrive(in: browser, testing: false, freshProfile: true)
        first.endIntro()
        first.later()

        let next = made()
        let shown = next.arrive(in: browser, testing: false, freshProfile: false)

        #expect(!first.seen)
        #expect(shown)
        #expect(next.phase == .intro)
    }

    @Test func askingForItAgainIsSpentOnOneLaunch() {
        settings.set(true, forKey: Onboarding.seenKey)
        settings.set(true, forKey: Onboarding.showKey)

        let shown = made().arrive(in: browser, testing: false, freshProfile: false)
        let again = made().arrive(in: browser, testing: false, freshProfile: false)

        #expect(shown)
        #expect(!settings.bool(forKey: Onboarding.showKey))
        #expect(!again)
    }

    @Test func arrivingTwiceBeginsOnce() {
        let stage = OnboardingStageStub()
        let onboarding = made()
        onboarding.stage = stage

        onboarding.arrive(in: browser, testing: false, freshProfile: true)
        onboarding.arrive(in: browser, testing: false, freshProfile: true)

        #expect(stage.raised == 1)
        #expect(clock.count == 1)
    }

    @Test func theIntroEndsOnItsOwnClock() throws {
        let onboarding = made()

        onboarding.begin(in: browser, reduced: false)
        let waiting = onboarding.phase
        let timer = try #require(clock.first)
        timer.work()

        #expect(waiting == .intro)
        #expect(timer.delay == OnboardingScore.drawn.ends)
        #expect(onboarding.phase == .steps)
        #expect(onboarding.step == .space)
    }

    @Test func reduceMotionEndsTheIntroSooner() throws {
        let onboarding = made()

        onboarding.begin(in: browser, reduced: true)

        #expect(onboarding.score == .calm)
        #expect(try #require(clock.first).delay == OnboardingScore.calm.ends)
    }

    @Test func anOldClockNeverEndsALaterIntro() throws {
        let onboarding = made()
        onboarding.begin(in: browser, reduced: false)
        onboarding.close()

        onboarding.begin(in: browser, reduced: false)
        try #require(clock.first).work()

        #expect(clock.count == 2)
        #expect(onboarding.phase == .intro)
    }

    @Test(arguments: [("\r", UInt16(36)), ("\u{3}", UInt16(76)), ("\u{1b}", UInt16(53)), (" ", UInt16(49))])
    func aKeySkipsTheIntro(chars: String, code: UInt16) {
        let onboarding = made()
        onboarding.begin(in: browser, reduced: false)

        let taken = onboarding.takes(key(chars, code))

        #expect(taken)
        #expect(onboarding.phase == .steps)
        #expect(onboarding.step == .space)
    }

    @Test func otherKeysAreHeldDuringTheIntro() {
        let onboarding = made()
        onboarding.begin(in: browser, reduced: false)

        let letter = onboarding.takes(key("a", 0))
        let newTab = onboarding.takes(key("t", 17, .command))
        let quit = onboarding.takes(key("q", 12, .command))

        #expect(letter)
        #expect(newTab)
        #expect(!quit)
        #expect(onboarding.phase == .intro)
    }

    @Test func skippingTwiceIsOneSkip() {
        let onboarding = made()
        onboarding.begin(in: browser, reduced: false)

        onboarding.endIntro()
        onboarding.endIntro()
        clock.first?.work()

        #expect(onboarding.phase == .steps)
        #expect(onboarding.step == .space)
    }

    @Test func returnTakesTheStepAndEscapeLeavesItForLater() {
        let onboarding = made()
        atSteps(onboarding)
        onboarding.go(.links)

        let escaped = onboarding.takes(key("\u{1b}", 53))
        let afterEscape = onboarding.step
        let asksAfterEscape = asked
        onboarding.go(.links)
        let entered = onboarding.takes(key("\r", 36))

        #expect(escaped)
        #expect(afterEscape == .agents)
        #expect(asksAfterEscape == 0)
        #expect(entered)
        #expect(asked == 1)
        #expect(onboarding.step == .agents)
    }

    @Test func typingPassesThroughOnTheSteps() {
        let onboarding = made()
        atSteps(onboarding)

        let letter = onboarding.takes(key("h", 4))
        let paste = onboarding.takes(key("v", 9, .command))
        let newTab = onboarding.takes(key("t", 17, .command))

        #expect(!letter)
        #expect(!paste)
        #expect(newTab)
        #expect(onboarding.step == .space)
    }

    @Test func closingTheWindowKeyEndsItAndIsRemembered() {
        let onboarding = made()
        atSteps(onboarding)

        let taken = onboarding.takes(key("w", 13, .command))

        #expect(taken)
        #expect(onboarding.phase == .away)
        #expect(onboarding.seen)
        #expect(browser.bringingIn == nil)
    }

    @Test(arguments: SpaceLook.offered)
    func theSpaceStepNamesTheSpaceAndGivesItExactlyThePickedLook(_ id: String) {
        let worn = SpaceLook(colours: ["123456"], intensity: 0.5, transparency: 0.45, grain: 0.7, glass: id != "glass")
        browser.setSpaceLook(browser.spaceID, to: worn)
        let onboarding = made()
        atSteps(onboarding)
        let before = onboarding.look

        onboarding.name = "  Home  "
        onboarding.look = id
        onboarding.primary()

        #expect(before == "custom")
        #expect(browser.space.name == "Home")
        #expect(browser.space.look == SpaceLook.offered(id))
        #expect(onboarding.step == .side)
    }

    @Test func aLookNobodyPickedLeavesTheSpacesLookAlone() {
        let worn = SpaceLook(colours: ["123456"], intensity: 0.5, transparency: 0.45, grain: 0.7)
        browser.setSpaceLook(browser.spaceID, to: worn)
        let onboarding = made()
        atSteps(onboarding)

        onboarding.primary()

        #expect(browser.space.look == worn)
        #expect(onboarding.step == .side)
    }

    @Test func anEmptyNameKeepsTheSpacesName() {
        let onboarding = made()
        atSteps(onboarding)
        let name = browser.space.name

        onboarding.name = "   "
        onboarding.primary()

        #expect(browser.space.name == name)
        #expect(onboarding.step == .side)
    }

    @Test func aSpaceWithNoLookOpensOnNoirAndContinueGivesItNoir() {
        let onboarding = made()
        atSteps(onboarding)
        let before = browser.space.look
        let opened = onboarding.look

        onboarding.primary()

        #expect(before == nil)
        #expect(opened == "noir")
        #expect(browser.space.look == SpaceLook.offered("noir"))
    }

    @Test func aSpaceWithNoLookKeepsNoneWhenTheStepIsPutOff() {
        let onboarding = made()
        atSteps(onboarding)

        onboarding.later()

        #expect(browser.space.look == nil)
        #expect(onboarding.step == .side)
    }

    @Test func aSpaceSavedAsGrayOpensOnGrayAndStaysGray() {
        browser.setSpaceLook(browser.spaceID, to: SpaceLook())
        let onboarding = made()
        atSteps(onboarding)
        let opened = onboarding.look

        onboarding.primary()

        #expect(opened == "gray")
        #expect(browser.space.look == SpaceLook())
    }

    @Test(arguments: SidebarPosition.allCases)
    func theSideStepMovesTheSidebar(_ side: SidebarPosition) {
        let onboarding = made()
        atSteps(onboarding)
        onboarding.go(.side)

        onboarding.side = side
        onboarding.primary()

        #expect(browser.prefs.sidePosition == side)
        #expect(onboarding.step == .links)
    }

    @Test func theLinksStepAsksMacOSOnce() {
        let onboarding = made()
        atSteps(onboarding)
        onboarding.go(.links)

        onboarding.primary()

        #expect(asked == 1)
        #expect(onboarding.defaultAsked)
        #expect(onboarding.step == .agents)
    }

    @Test func theOverlayStepsAsideForMacOSsQuestionAndComesBackOnTheAnswer() {
        let stage = OnboardingStageStub()
        let onboarding = made()
        onboarding.stage = stage
        atSteps(onboarding)
        onboarding.go(.links)

        onboarding.primary()
        let whileAsked = stage.steps
        answers.first?()

        #expect(whileAsked == ["aside"])
        #expect(stage.steps == ["aside", "back"])
        #expect(onboarding.step == .agents)
    }

    @Test func theOverlaySitsAboveTheMenuBarOnlyWhileItIsInFront() {
        let shown = OnboardingShow.level(front: true, active: true, aside: false)
        let elsewhere = OnboardingShow.level(front: true, active: false, aside: false)
        let asked = OnboardingShow.level(front: true, active: true, aside: true)
        let probe = OnboardingShow.level(front: false, active: true, aside: false)

        #expect(shown.rawValue > NSWindow.Level.mainMenu.rawValue)
        #expect(elsewhere == .normal)
        #expect(asked == .normal)
        #expect(probe == .normal)
    }

    @Test func theLinksStepIsLeftOutWhenAlreadyTheDefault() {
        let onboarding = made(isDefault: true)

        atSteps(onboarding)

        #expect(onboarding.steps == [.space, .side, .agents, .key, .bring])
        #expect(asked == 0)
    }

    @Test func theAgentsStepTurnsAgentsOn() {
        browser.prefs.agentsOn = false
        let onboarding = made()
        atSteps(onboarding)
        onboarding.go(.agents)

        onboarding.primary()

        #expect(browser.prefs.agentsOn)
        #expect(onboarding.step == .key)
    }

    @Test func theLastStepOpensBringThingsOverOnTheChosenBrowser() {
        let stage = OnboardingStageStub()
        let onboarding = made()
        onboarding.stage = stage
        atSteps(onboarding)
        onboarding.go(.bring)
        let offered = onboarding.source

        onboarding.source = "Arc"
        onboarding.primary()
        let leaving = onboarding.phase
        stage.handed.first?()

        #expect(offered == "Chrome")
        #expect(onboarding.lead(.bring) == "Bring Over from Arc")
        #expect(browser.bringingIn == "Arc")
        #expect(onboarding.bringing == "Arc")
        #expect(leaving == .leaving)
        #expect(stage.handed.count == 1)
        #expect(onboarding.phase == .away)
        #expect(onboarding.seen)
    }

    private func keyed(_ stub: OpenRouterStub) -> (Onboarding, OpenRouterKey) {
        let keys = OpenRouterKey(store: OpenRouterMemoryStore())
        keys.client = { stub.client }
        let onboarding = made()
        onboarding.keys = keys
        atSteps(onboarding)
        onboarding.go(.key)
        return (onboarding, keys)
    }

    private func settled(_ onboarding: Onboarding) async throws {
        for _ in 0..<250 where onboarding.step == .key && (onboarding.keyNote == nil || onboarding.keyNote == AIGroupWords.checking) {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func theKeyStepIsNeverFirstOrLastAndNeverLeftOut() {
        for isDefault in [false, true] {
            let onboarding = made(isDefault: isDefault)
            atSteps(onboarding)
            let at = onboarding.steps.firstIndex(of: .key)

            #expect(at != nil)
            #expect(at != 0)
            #expect(at != onboarding.steps.count - 1)
        }
    }

    @Test func anEmptyKeyFieldGoesOnWithoutAskingOpenRouter() {
        let stub = OpenRouterStub.naming("Kyoto Trip")
        let (onboarding, keys) = keyed(stub)

        #expect(onboarding.lead(.key) == "Continue")

        onboarding.primary()

        #expect(onboarding.step == .bring)
        #expect(!keys.present)
        #expect(stub.requests.isEmpty)
    }

    @Test func aRefusedKeyIsSaidInPlaceAndTheStepStays() async throws {
        let stub = OpenRouterStub.naming("Kyoto Trip")
        let (onboarding, keys) = keyed(stub)
        onboarding.keyTyped = "sk-or-bad-1"

        #expect(onboarding.lead(.key) == "Add Key")

        onboarding.primary()
        try await settled(onboarding)

        #expect(onboarding.step == .key)
        #expect(onboarding.keyNote == "OpenRouter turned this key down")
        #expect(!keys.present)

        onboarding.keyTyped = "sk-or-bad-2"

        #expect(onboarding.keyNote == nil)

        onboarding.later()

        #expect(onboarding.step == .bring)
        #expect(!keys.present)
    }

    @Test func aGoodKeyIsSavedToTheSameKeyAsSettingsAndTheWalkGoesOn() async throws {
        let stub = OpenRouterStub.naming("Kyoto Trip")
        let (onboarding, keys) = keyed(stub)
        onboarding.keyTyped = " sk-or-good-onboarding\n"

        onboarding.primary()
        try await settled(onboarding)

        #expect(onboarding.step == .bring)
        #expect(keys.present)
        #expect(keys.key == "sk-or-good-onboarding")
        #expect(onboarding.keyTyped.isEmpty)
        #expect(onboarding.keyNote == nil)
        #expect(stub.requests.count == 1)
        #expect(stub.requests.first?.0.url?.path().hasSuffix("/key") == true)
    }

    @Test func getAKeyOpensOpenRoutersKeysPage() {
        var opened: [URL] = []
        let onboarding = made()
        onboarding.openLink = { opened.append($0) }
        atSteps(onboarding)
        onboarding.go(.key)

        onboarding.openKeysPage()

        #expect(opened == [URL(string: "https://openrouter.ai/settings/keys")!])
        #expect(onboarding.step == .key)
    }

    @Test func theKeyStepNamesFolderNamesAmongWhatIsSent() {
        #expect(AIGroupWords.stepLine(mac: true).contains("Only tab titles, site names, folder names and searches are sent."))
        #expect(AIGroupWords.stepLine(mac: false).contains("Only tab titles, site names, folder names and searches go to OpenRouter."))
    }

    @Test func onAMacWithoutAppleIntelligenceTheKeyIsWhatTurnsOnFolders() {
        let line = AIGroupWords.stepLine(mac: false)

        #expect(line.contains("turns on folders"))
        #expect(line.contains("fraction of a cent"))
        #expect(line.contains("Keychain"))
    }

    @Test(arguments: Onboarding.Step.allCases, ["", "Chrome", "Safari"])
    func noWordOnAStepTrailsOffOrCarriesASemicolon(_ step: Onboarding.Step, _ source: String) {
        let onboarding = made(sources: source.isEmpty ? [] : [source])
        onboarding.source = source

        for words in [Onboarding.title(step), Onboarding.line(step), onboarding.lead(step)] {
            #expect(!words.isEmpty)
            #expect(!words.contains("…") && !words.contains("...") && !words.contains(";"), "\(words)")
        }
    }

    @Test func safariIsARealChoiceThatOpensBringThingsOverOnSafari() {
        let stage = OnboardingStageStub()
        let onboarding = made(sources: ["Safari", "Chrome"])
        onboarding.stage = stage
        atSteps(onboarding)
        onboarding.go(.bring)
        let offered = onboarding.source

        onboarding.source = "Safari"
        let lead = onboarding.lead(.bring)
        onboarding.primary()
        stage.handed.first?()

        #expect(offered == "Chrome")
        #expect(lead == "Bring Over from Safari")
        #expect(browser.bringingIn == "Safari")
        #expect(onboarding.bringing == "Safari")
    }

    @Test(arguments: [(["Safari", "Chrome", "Dia", "Arc"], "Arc", "Arc"), (["Safari", "Chrome", "Dia", "Arc"], "Firefox", "Chrome"),
                      (["Safari", "Chrome"], "Safari", "Safari"), (["Safari"], nil, "Safari"), (["Firefox"], "Safari", "Firefox")])
    func theFirstPickIsTheDefaultBrowserInTheRowThenOneReadDirectlyThenSafari(_ row: [String], _ preferred: String?, _ picked: String) {
        let onboarding = made(sources: row)
        onboarding.defaultBrowser = { preferred }

        atSteps(onboarding)

        #expect(onboarding.source == picked)
    }

    @Test func withNoBrowserFoundTheLastStepStillOpensBringThingsOver() {
        let onboarding = made(sources: [])
        atSteps(onboarding)
        onboarding.go(.bring)

        let lead = onboarding.lead(.bring)
        onboarding.primary()

        #expect(lead == "Bring Things Over")
        #expect(browser.bringingIn == "")
        #expect(onboarding.seen)
    }

    @Test func notNowOnEveryStepChangesNothingAndEnds() {
        browser.prefs.agentsOn = false
        let side = browser.prefs.sidePosition
        let name = browser.space.name
        let look = browser.space.look
        let onboarding = made()
        atSteps(onboarding)
        onboarding.name = "Elsewhere"
        onboarding.side = side == .left ? .right : .left

        var walked: [Onboarding.Step] = []
        while onboarding.phase == .steps {
            walked.append(onboarding.step)
            onboarding.later()
        }

        #expect(walked == Onboarding.Step.allCases)
        #expect(browser.space.name == name)
        #expect(browser.space.look == look)
        #expect(browser.prefs.sidePosition == side)
        #expect(!browser.prefs.agentsOn)
        #expect(asked == 0)
        #expect(browser.bringingIn == nil)
        #expect(onboarding.seen)
        #expect(onboarding.phase == .away)
    }

    @Test func nothingIsTakenBeforeTheStepsOrAfterTheEnd() {
        let onboarding = made()
        onboarding.begin(in: browser, reduced: false)

        onboarding.primary()
        onboarding.later()
        onboarding.go(.bring)
        let during = (onboarding.phase, onboarding.step)
        onboarding.close()
        onboarding.primary()

        #expect(during.0 == .intro)
        #expect(during.1 == .space)
        #expect(asked == 0)
        #expect(browser.bringingIn == nil)
        #expect(onboarding.phase == .away)
    }

    @Test func aReplayStartsFromTheTopWithWhatTheBrowserHasNow() {
        let onboarding = made()
        atSteps(onboarding)
        onboarding.name = "Work"
        onboarding.primary()
        onboarding.close()

        onboarding.begin(in: browser, reduced: false)

        #expect(onboarding.phase == .intro)
        #expect(onboarding.step == .space)
        #expect(onboarding.name == "Work")
        #expect(onboarding.bringing == nil)
        #expect(!onboarding.defaultAsked)
    }

    @Test func abandoningClearsTheStageAndStopsTheClock() {
        let stage = OnboardingStageStub()
        let onboarding = made()
        onboarding.stage = stage
        onboarding.begin(in: browser, reduced: false)

        onboarding.abandon()
        clock.first?.work()

        #expect(stage.cleared == 1)
        #expect(onboarding.phase == .away)
        #expect(!onboarding.seen)
    }
}

@Suite struct OnboardingBringRowTests {
    @Test func allFourFoundMakeTheRowInItsOwnOrder() {
        let row = ImportSource.offered(found: ["Brave", "Arc", "Dia", "Chrome"], safari: true)

        #expect(row == ["Safari", "Chrome", "Dia", "Arc"])
        #expect(ImportSource.firstPick(in: row, defaultBrowser: nil) == "Chrome")
    }

    @Test func safariAloneIsTheRowAndThePick() {
        let row = ImportSource.offered(found: [], safari: true)

        #expect(row == ["Safari"])
        #expect(ImportSource.firstPick(in: row, defaultBrowser: nil) == "Safari")
    }

    @Test func someoneWhoOnlyUsedFirefoxStillSeesFirefox() {
        let alone = ImportSource.offered(found: ["Firefox"], safari: false)
        let withSafari = ImportSource.offered(found: ["Firefox"], safari: true)

        #expect(alone == ["Firefox"])
        #expect(ImportSource.firstPick(in: alone, defaultBrowser: nil) == "Firefox")
        #expect(withSafari == ["Safari", "Firefox"])
        #expect(ImportSource.firstPick(in: withSafari, defaultBrowser: nil) == "Firefox")
    }

    @Test func chromeBetaWithoutChromeOnlyFillsAPlace() {
        let row = ImportSource.offered(found: ["Brave", "Chrome Beta"], safari: true)

        #expect(row == ["Safari", "Brave", "Chrome Beta"])
        #expect(!row.contains("Chrome"))
        #expect(ImportSource.firstPick(in: row, defaultBrowser: nil) == "Brave")
    }

    @Test func sixBrowsersFoundKeepFourChoices() {
        let row = ImportSource.offered(found: ["Chrome", "Arc", "Brave", "Edge", "Firefox", "Zen"], safari: true)

        #expect(row == ["Safari", "Chrome", "Arc", "Brave"])
        #expect(ImportSource.firstPick(in: row, defaultBrowser: nil) == "Chrome")
        #expect(ImportSource.firstPick(in: row, defaultBrowser: "Firefox") == "Chrome")
        #expect(ImportSource.firstPick(in: row, defaultBrowser: "Brave") == "Brave")
        #expect(ImportSource.firstPick(in: row, defaultBrowser: "Safari") == "Safari")
    }

    @Test func nothingFoundMeansNoRow() {
        #expect(ImportSource.offered(found: [], safari: false).isEmpty)
        #expect(ImportSource.firstPick(in: [], defaultBrowser: "Chrome") == "")
    }

    @Test func thePanelListsChromeDiaAndArcFirst() {
        #expect(Chromium.known.prefix(3).map(\.name) == ["Chrome", "Dia", "Arc"])
        #expect(ImportSource.offered(found: Chromium.known.map(\.name), safari: false) == ["Chrome", "Dia", "Arc", "ego lite"])
    }

    @Test func theDefaultBrowserIsKnownByItsApp() {
        #expect(ImportSource.name(ofApp: "Safari.app") == "Safari")
        #expect(ImportSource.name(ofApp: "Google Chrome.app") == "Chrome")
        #expect(ImportSource.name(ofApp: "Google Chrome Beta.app") == "Chrome Beta")
        #expect(ImportSource.name(ofApp: "Arc.app") == "Arc")
        #expect(ImportSource.name(ofApp: "Firefox.app") == "Firefox")
        #expect(ImportSource.name(ofApp: "Broadway.app") == nil)
    }
}
