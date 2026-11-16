import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class NewSpaceCardTests {
    private var browser: Browser!
    private var saved: (spaces: Bool, stacked: Bool) = (false, false)
    private var made: [UUID] = []

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        saved = (browser.prefs.usesSpaces, browser.prefs.stackedSpaces)
        browser.prefs.usesSpaces = true
        browser.prefs.stackedSpaces = false
    }

    private func tearDown() async {
        browser.leaveSpaceCreation()
        try? await rested()
        for id in made { browser.deleteSpace(id) }
        browser.prefs.usesSpaces = saved.spaces
        browser.prefs.stackedSpaces = saved.stacked
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

    private func rested(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await until({ !self.browser.makingSpace && self.browser.spaceNext == nil }, sourceLocation: sourceLocation)
    }

    private func landed(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await until({ self.browser.makingSpace && self.browser.spaceNext == nil }, sourceLocation: sourceLocation)
    }

    private func fill(name: String = "Garden") -> (look: String, icon: TabIcon) {
        let look = SpaceLook.offered[2]
        let icon = TabIcon(emoji: "🌱")
        browser.spaceAsk.draft?.name = name
        browser.spaceAsk.draft?.look = look
        browser.spaceAsk.accounts = .separate
        browser.spaceDraftIcon = icon
        return (look, icon)
    }

    @Test func askingPutsTheCardUpAndSlidesTheColumnToTheDraft() async throws {
        let space = browser.spaceID

        browser.askForSpace()
        let up = browser.spaceAsk.up
        let draft = browser.spaceAsk.draft
        browser.askForSpace()
        try await landed()

        #expect(up)
        #expect(browser.spaceAsk.draft === draft, "asking again keeps the card that is up")
        #expect(browser.makingSpace)
        #expect(browser.spaceID == space)
        #expect(browser.spaceAsk.name.isEmpty)
        #expect(browser.spaceAsk.accounts == .shared)
        #expect(browser.spaceAsk.look == nil)
    }

    @Test func theNewSpaceGetsExactlyWhatWasPickedAndTheOldOneIsUntouched() async throws {
        let before = browser.space
        browser.askForSpace()
        try await landed()
        let picked = fill(name: "  Garden ")
        let count = browser.spaces.count

        let created = browser.createAskedSpace()
        let space = try #require(browser.spaces.last)
        if space.id != before.id { made.append(space.id) }

        #expect(created)
        #expect(browser.spaces.count == count + 1)
        #expect(space.name == "Garden")
        #expect(space.look == SpaceLook.offered(picked.look))
        #expect(space.icon == picked.icon)
        #expect(space.sharesSignIns == false)
        #expect(space.accounts == .separate)
        #expect(browser.spaceID == space.id)
        let old = try #require(browser.spaces.first { $0.id == before.id })
        #expect(old.name == before.name)
        #expect(old.look == before.look)
        #expect(old.icon == before.icon)
        #expect(!browser.spaceAsk.up)
        #expect(browser.spaceAsk.created)
        #expect(!browser.makingSpace)
        #expect(browser.spaceDraftIcon == nil)
    }

    @Test func theDefaultLookAndAccountsMakeAPlainSharedSpace() async throws {
        browser.askForSpace()
        try await landed()
        browser.spaceAsk.draft?.name = "Plain"
        let icon = browser.freeIcon

        browser.createAskedSpace()
        let space = try #require(browser.spaces.last)
        made.append(space.id)

        #expect(space.name == "Plain")
        #expect(space.look == nil)
        #expect(space.icon == icon)
        #expect(space.sharesSignIns == true)
    }

    @Test func nothingIsCreatedWithoutAName() async throws {
        browser.askForSpace()
        try await landed()
        let count = browser.spaces.count
        browser.spaceAsk.draft?.name = "   "

        let created = browser.createAskedSpace()

        #expect(!created)
        #expect(browser.spaces.count == count)
        #expect(browser.spaceAsk.up)
    }

    @Test func returnInTheNameFieldCreatesTheSpaceAndNeverRenamesTheCurrentOne() async throws {
        let before = browser.space
        browser.askForSpace()
        try await landed()
        let draft = try #require(browser.spaceAsk.draft)
        let card = NewSpaceCard(browser: browser, draft: draft)
        let field = try #require(card.kitSubviews(of: KitField.self).first)
        let count = browser.spaces.count

        field.onSubmit?()
        let afterEmpty = browser.spaces.count
        draft.name = "Garden"
        draft.look = SpaceLook.offered[3]
        field.onSubmit?()
        field.onSubmit?()
        let space = try #require(browser.spaces.last)
        if space.id != before.id { made.append(space.id) }

        #expect(afterEmpty == count)
        #expect(browser.spaces.count == count + 1)
        #expect(space.name == "Garden")
        let old = try #require(browser.spaces.first { $0.id == before.id })
        #expect(old.name == before.name)
        #expect(old.look == before.look)
    }

    @Test func leavingPutsEverythingBackAsItWas() async throws {
        let space = browser.spaceID
        let spaces = browser.spaces
        var sent = false
        browser.askForSpace { _ in sent = true }
        try await landed()
        _ = fill()

        browser.leaveSpaceCreation()
        let up = browser.spaceAsk.up
        try await rested()

        #expect(!up)
        #expect(!browser.spaceAsk.created)
        #expect(browser.spaces == spaces)
        #expect(browser.spaceID == space)
        #expect(browser.spaceDraftIcon == nil)
        #expect(browser.afterSpaceCreated == nil)
        #expect(!sent)
        #expect(!browser.footSpots.contains { $0.kind == .draft })
    }

    @Test func leavingWhileTheColumnIsStillSlidingComesBack() async throws {
        let space = browser.spaceID
        let count = browser.spaces.count

        browser.askForSpace()
        browser.leaveSpaceCreation()
        try await rested()

        #expect(!browser.spaceAsk.up)
        #expect(!browser.makingSpace)
        #expect(browser.spaceID == space)
        #expect(browser.spaces.count == count)
        #expect(!browser.footSpots.contains { $0.kind == .draft })
    }

    @Test func aFoldedColumnGetsTheSameCardAndNoDraftPage() async throws {
        let space = browser.spaceID
        let count = browser.spaces.count
        browser.folded = true
        defer { browser.folded = false }

        browser.askForSpace()
        let asked = (up: browser.spaceAsk.up, making: browser.makingSpace, next: browser.spaceNext)
        _ = fill()
        browser.leaveSpaceCreation()
        let left = (up: browser.spaceAsk.up, icon: browser.spaceDraftIcon)
        browser.askForSpace()
        let again = (accounts: browser.spaceAsk.accounts, name: browser.spaceAsk.name, look: browser.spaceAsk.look)
        let picked = fill()
        browser.createAskedSpace()
        let created = try #require(browser.spaces.last)
        if created.id != space { made.append(created.id) }

        #expect(asked.up)
        #expect(!asked.making)
        #expect(asked.next == nil)
        #expect(!left.up)
        #expect(left.icon == nil)
        #expect(again.accounts == .shared)
        #expect(again.name.isEmpty)
        #expect(again.look == nil)
        #expect(browser.spaces.count == count + 1)
        #expect(created.name == "Garden")
        #expect(created.look == SpaceLook.offered(picked.look))
        #expect(created.icon == picked.icon)
        #expect(created.sharesSignIns == false)
        #expect(browser.spaceID == created.id)
        #expect(!browser.spaceAsk.up)
    }

    @Test func stackedSpacesGetTheSameCardAndNoDraftPage() async throws {
        let count = browser.spaces.count
        browser.prefs.stackedSpaces = true

        browser.askForSpace()
        let asked = (up: browser.spaceAsk.up, making: browser.makingSpace, next: browser.spaceNext)
        browser.leaveSpaceCreation()

        #expect(asked.up)
        #expect(!asked.making)
        #expect(asked.next == nil)
        #expect(!browser.spaceAsk.up)
        #expect(browser.spaces.count == count)
    }

    @Test func goingToAnotherSpaceTakesTheCardDown() async throws {
        let first = browser.spaceID
        browser.addSpace(named: "Other")
        let other = try #require(browser.spaces.last)
        made.append(other.id)
        browser.folded = true
        defer { browser.folded = false }
        var sent = false

        browser.askForSpace { _ in sent = true }
        browser.switchSpace(to: first)

        #expect(browser.spaceID == first)
        #expect(!browser.spaceAsk.up)
        #expect(browser.afterSpaceCreated == nil)
        #expect(!sent)
    }

    @Test func aTabSentToTheNewSpaceGoesThereWithoutSwitching() async throws {
        let space = browser.spaceID
        var got: Space?
        browser.folded = true
        defer { browser.folded = false }

        browser.askForSpace { got = $0 }
        browser.spaceAsk.draft?.name = "Later"
        browser.createAskedSpace()
        let created = try #require(browser.spaces.last)
        made.append(created.id)

        #expect(got?.id == created.id)
        #expect(browser.spaceID == space)
        #expect(browser.afterSpaceCreated == nil)
    }

    private func hosted() throws -> (window: NSWindow, layer: NewSpaceLayerView, other: NSTextField) {
        browser.folded = true
        browser.askForSpace()
        let draft = try #require(browser.spaceAsk.draft)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 760))
        let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        let layer = NewSpaceLayerView(browser: browser, draft: draft)
        layer.frame = root.bounds
        root.addSubview(other)
        root.addSubview(layer)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        return (window, layer, other)
    }

    private func holds(_ window: NSWindow, _ layer: NSView) -> Bool {
        (window.firstResponder as? NSView)?.isDescendant(of: layer) == true
    }

    private func settle() async throws {
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func theCardKeepsTheKeyboardThroughTheIconPickerAndTakesItBackWhenNothingHasIt() async throws {
        let (window, layer, other) = try hosted()
        defer {
            browser.iconPicker.close()
            browser.leaveSpaceCreation()
            browser.folded = false
            window.contentView = nil
        }
        let start = holds(window, layer)
        let icon = try #require(layer.card.kitSubviews(of: KitButton.self).first { $0.accessibilityLabel() == "Choose an Icon" })

        icon.action?()
        window.makeFirstResponder(other)
        try await settle()
        let picking = (up: browser.spaceAsk.up, target: browser.iconPicker.target)
        browser.iconPicker.close()
        window.makeFirstResponder(nil)
        try await settle()
        let cancelled = (up: browser.spaceAsk.up, held: holds(window, layer))
        icon.action?()
        window.makeFirstResponder(other)
        try await settle()
        browser.setIcon(TabIcon(emoji: "🌱"), of: .draft)
        browser.iconPicker.close()
        try await settle()
        let picked = (up: browser.spaceAsk.up, held: holds(window, layer))

        #expect(start, "the name has the caret as the card arrives")
        #expect(picking.up)
        #expect(picking.target == .draft)
        #expect(cancelled.up)
        #expect(cancelled.held, "with nothing focused the caret goes back to the name")
        #expect(picked.up)
        #expect(picked.held)
        #expect(browser.spaceDraftIcon == TabIcon(emoji: "🌱"))
    }

    @Test func theCardGoesWhenTheKeyboardGoesElsewhereInTheWindow() async throws {
        let (window, layer, other) = try hosted()
        defer {
            browser.leaveSpaceCreation()
            browser.folded = false
            window.contentView = nil
        }
        let start = holds(window, layer)
        let count = browser.spaces.count

        window.makeFirstResponder(other)
        try await settle()

        #expect(start)
        #expect(!browser.spaceAsk.up)
        #expect(browser.spaces.count == count)
    }

    @Test func theCardGoesWhenAnotherTabComesToTheFront() async throws {
        let (window, _, _) = try hosted()
        defer {
            browser.leaveSpaceCreation()
            browser.folded = false
            window.contentView = nil
        }

        browser.open(URL(string: "about:blank#other")!, foreground: true)
        try await until { !self.browser.spaceAsk.up }

        #expect(!browser.spaceAsk.up)
    }

    @Test func theCardScalesDownToFitASmallWindow() {
        let card = NSSize(width: 560, height: 640)

        let roomy = NewSpaceLayerView.scale(card: card, in: NSSize(width: 1200, height: 800))
        let short = NewSpaceLayerView.scale(card: card, in: NSSize(width: 1200, height: 512))
        let narrow = NewSpaceLayerView.scale(card: card, in: NSSize(width: 480, height: 900))
        let tiny = NewSpaceLayerView.scale(card: card, in: NSSize(width: 100, height: 100))

        #expect(roomy == 1)
        #expect(short == 0.75)
        #expect(narrow == 0.8)
        #expect(tiny == 0.5)
    }
}
