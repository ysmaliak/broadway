import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SpaceDraftTests {
    private var browser: Browser!
    private var saved = false
    private var made: [UUID] = []

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        saved = browser.prefs.usesSpaces
        browser.prefs.usesSpaces = true
    }

    private func tearDown() async {
        if browser.makingSpace { browser.leaveSpaceCreation() }
        try? await until { !self.browser.makingSpace && self.browser.spaceNext == nil }
        for id in made { browser.deleteSpace(id) }
        browser.prefs.usesSpaces = saved
        browser.closeAll()
        browser = nil
    }

    private func until(_ done: @escaping @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = Date().addingTimeInterval(5)
        while !done() {
            guard Date() < end else { Issue.record("timed out", sourceLocation: sourceLocation); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func openPage() -> Tab {
        browser.open(URL(string: "about:blank#before")!, foreground: true)
    }

    private func makeSpace() async throws {
        browser.askForSpace()
        try await until { self.browser.makingSpace && self.browser.spaceNext == nil }
    }

    @Test func theStageShowsTheDraftNotThePreviousTab() async throws {
        let tab = openPage()

        try await makeSpace()

        #expect(browser.draftComing)
        #expect(browser.stageVeiled)
        #expect(browser.shownTab == nil)
        #expect(browser.active === tab, "the tab stays where it was, only off the stage")
    }

    @Test func thePillAndTheBarButtonsHaveNoTabWhileMaking() async throws {
        let tab = openPage()
        #expect(browser.shownTab === tab)

        try await makeSpace()

        #expect(browser.shownTab == nil, "the pill shows its placeholder and back, forward and reload are off")
    }

    @Test func theFootLightsOnlyTheNewSpaceWhileMaking() async throws {
        _ = openPage()

        try await makeSpace()
        let spots = browser.footSpots

        #expect(spots.count == (browser.spaces.count + 1))
        #expect(spots.last?.kind == .draft)
        #expect(spots.last?.icon == browser.freeIcon)
        for spot in spots.dropLast() {
            #expect(!spot.here)
            #expect(FootLight(here: spot.here, next: spot.next, going: false, progress: 0).lit == 0)
        }
        #expect(FootLight(here: true, next: false, going: false, progress: 0).lit == 1)
        #expect(spots.last?.here == true)
    }

    @Test func theNewSpaceIsLitAsTheSlideBringsIt() {
        let here = browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0

        browser.spaceNext = browser.spaces.count
        let spots = browser.footSpots
        browser.spaceNext = nil

        #expect(spots.last?.kind == .draft)
        #expect(spots.last?.next == true)
        #expect(spots[here].here)
        for step in 0...10 {
            let progress = CGFloat(step) / 10
            let leaving = FootLight(here: spots[here].here, next: spots[here].next, going: true, progress: progress)
            let coming = FootLight(here: spots.last!.here, next: spots.last!.next, going: true, progress: progress)
            #expect(abs((leaving.lit + coming.lit) - 1) <= 0.0001)
            #expect(abs(coming.lit - progress) <= 0.0001)
        }
    }

    @Test func thePageFadesInWithTheSlideAndIsOnlyThenTakenOff() {
        let here = browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0

        browser.spaceNext = browser.spaces.count
        let coming = (0...10).map { browser.draftShare(progress: CGFloat($0) / 10) }
        let veiledComing = browser.stageVeiled
        browser.spaceNext = nil
        browser.makingSpace = true
        let landed = browser.draftShare(progress: 0)
        let veiledLanded = browser.stageVeiled
        browser.spaceNext = here
        let leaving = (0...10).map { browser.draftShare(progress: CGFloat($0) / 10) }
        let veiledLeaving = browser.stageVeiled
        browser.spaceNext = nil
        browser.makingSpace = false
        let left = browser.draftShare(progress: 0)

        #expect(browser.draftComing == false)
        for (step, share) in coming.enumerated() { #expect(abs(share - (CGFloat(step) / 10)) <= 0.0001) }
        for (step, share) in leaving.enumerated() { #expect(abs(share - (1 - CGFloat(step) / 10)) <= 0.0001) }
        #expect(landed == 1)
        #expect(left == 0)
        #expect(!veiledComing, "the page stays on the stage under the draft until the slide lands")
        #expect(veiledLanded)
        #expect(!veiledLeaving, "the page is back under the draft as soon as the way back begins")
    }

    @Test func aPickedIconShowsAtTheFoot() async throws {
        try await makeSpace()

        browser.spaceDraftIcon = TabIcon(emoji: "🌱")

        #expect(browser.footSpots.last?.icon == TabIcon(emoji: "🌱"))
        #expect(browser.draftIcon == TabIcon(emoji: "🌱"))
    }

    @Test func cancelBringsBackThePreviousTabAsItWas() async throws {
        let tab = openPage()
        let page = tab.built
        let space = browser.spaceID
        try await makeSpace()
        browser.spaceDraftIcon = TabIcon(emoji: "🌱")

        browser.leaveSpaceCreation()
        let index = browser.spaces.firstIndex { $0.id == space }!
        let coming = browser.row(at: index)?.active
        try await until { !self.browser.makingSpace && self.browser.spaceNext == nil }

        #expect(coming === tab, "the pill slides back to the tab's own words")
        #expect(browser.spaceID == space)
        #expect(browser.active === tab)
        #expect(browser.shownTab === tab)
        #expect(tab.built === page, "the same web view, not a reload")
        #expect(!browser.draftComing)
        #expect(browser.spaceDraftIcon == nil)
        #expect(!browser.footSpots.contains { $0.kind == .draft })
        #expect(browser.footSpots.filter { $0.here }.map(\.kind) == [.space(space)])
    }

    @Test func createTurnsTheDraftIntoTheSpaceOnItsEmptyPage() async throws {
        _ = openPage()
        try await makeSpace()
        browser.spaceDraftIcon = TabIcon(emoji: "🌱")
        let count = browser.spaces.count

        browser.addSpace(named: "Garden", icon: browser.draftIcon)
        let space = try #require(browser.spaces.last)
        made.append(space.id)

        #expect(browser.spaces.count == (count + 1))
        #expect(space.name == "Garden")
        #expect(space.icon == TabIcon(emoji: "🌱"))
        #expect(browser.spaceID == space.id)
        #expect(!browser.makingSpace)
        #expect(!browser.draftComing)
        let blank = try #require(browser.active)
        #expect(blank.isBlank, "its first tab is an empty page")
        #expect(browser.shownTab === blank)
        let spots = browser.footSpots
        #expect(!spots.contains { $0.kind == .draft })
        #expect(spots.last?.kind == .space(space.id))
        #expect(spots.last?.here == true)
        #expect(spots.last?.icon == TabIcon(emoji: "🌱"))
        #expect(spots.filter { $0.here }.count == 1)
    }
}
