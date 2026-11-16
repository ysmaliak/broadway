import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SpaceStepTests {
    private var browser: Browser!
    private var ids: [UUID] = []

    init() {
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        keepSettings("shortcuts")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Store.settings.removeObject(forKey: "shortcuts")
        browser = Browser(record: WindowRecord())
        browser.closeAll()
        browser.prefs.usesSpaces = true
        ids = [browser.spaceID, UUID(), UUID()]
        browser.spaces = ids.enumerated().map { Space(id: $1, name: "Space \($0 + 1)", colour: $0) }
    }

    private func tearDown() {
        browser?.switchSpace(to: ids[0])
        browser?.closeAll()
        browser = nil
    }

    @Test func nextSpaceGoesToTheSpaceAfterTheOneOnScreen() {
        Command.named("spaces.next")?.run(browser)

        #expect(browser.spaceID == ids[1])
    }

    @Test func nextSpaceWrapsFromTheLastSpaceToTheFirst() {
        browser.switchSpace(to: ids[2])

        Command.named("spaces.next")?.run(browser)

        #expect(browser.spaceID == ids[0])
    }

    @Test func previousSpaceWrapsFromTheFirstSpaceToTheLast() {
        Command.named("spaces.previous")?.run(browser)

        #expect(browser.spaceID == ids[2])
    }

    @Test func previousSpaceFollowsTheOrderOfTheSpaces() {
        let spaces = browser.spaces
        browser.spaces = [spaces[2], spaces[0], spaces[1]]

        Command.named("spaces.previous")?.run(browser)

        #expect(browser.spaceID == ids[2])
    }

    @Test func withOneSpaceNextAndPreviousDoNothing() {
        browser.spaces = [browser.space]

        Command.named("spaces.next")?.run(browser)
        Command.named("spaces.previous")?.run(browser)

        #expect(browser.spaceID == ids[0])
    }

    @Test func optionCommandArrowsStepBetweenSpacesByDefault() {
        let store = ShortcutStore()

        let next = store.customCommand(on: KeyCombo("right", option: true))
        let previous = store.customCommand(on: KeyCombo("left", option: true))

        #expect(next?.id == "spaces.next")
        #expect(next?.title == "Next Space")
        #expect(next?.section == .spaces)
        #expect(previous?.id == "spaces.previous")
        #expect(previous?.title == "Previous Space")
    }

    @Test func theFieldOffersNextSpaceOnlyWithMoreThanOneSpace() throws {
        let next = try #require(Command.named("spaces.next"))

        let many = FieldCommands.available(next, in: browser)
        browser.spaces = [browser.space]
        let one = FieldCommands.available(next, in: browser)

        #expect(many)
        #expect(!one)
    }
}
