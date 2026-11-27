import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SpaceKitTests {
    private var browser: Browser!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
    }

    private func tearDown() async {
        browser.spaceDraftName.text = ""
        browser.closeAll()
        browser = nil
    }

    private func all(in view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { all(in: $0) }
    }

    private func button(_ label: String, in view: NSView) -> KitButton? {
        all(in: view).compactMap { $0 as? KitButton }.first { $0.accessibilityLabel() == label }
    }

    private func type(_ text: String, in card: NSView) {
        guard let field = all(in: card).compactMap({ $0 as? NSTextField }).first else {
            Issue.record("no name field")
            return
        }
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func card() -> NewSpaceCard {
        NewSpaceCard(browser: browser, draft: NewSpaceAsk.draft(in: browser))
    }

    @Test func theCardCreatesOnlyOnceItIsNamed() async throws {
        let card = card()

        let before = button("Create", in: card)?.isEnabled
        type("Errands", in: card)
        for _ in 0..<100 where button("Create", in: card)?.isEnabled != true { try await Task.sleep(for: .milliseconds(10)) }

        #expect(before == false)
        #expect(card.draft.name == "Errands")
        #expect(button("Create", in: card)?.isEnabled == true)
        #expect(browser.spaceDraftName.text == "Errands")
    }

    @Test func theCardIsTheOnboardingsWidthAndKeepsItsHeight() {
        let card = card()

        let first = card.fit()
        card.frame = NSRect(x: 0, y: 0, width: NewSpaceCard.width, height: first)
        card.layoutSubtreeIfNeeded()
        let second = card.fit()

        #expect(NewSpaceCard.width == OnboardingCard.size.width)
        #expect(first == second)
        #expect(first > OnboardingCard.stageHeight + 200)
    }

    @Test func theCardIsBuiltFromTheOnboardingsOwnViews() {
        let card = card()

        _ = card.fit()
        let views = all(in: card)

        #expect(views.contains { $0 is OnboardingStageView })
        #expect(views.contains { $0 is OnboardingPanel })
        #expect(views.compactMap { $0 as? SpaceLookTile }.map(\.offer) == SpaceLook.offers)
        #expect(views.contains { $0 is SpaceLookWindow })
        #expect(views.contains { ($0 as? KitParagraph)?.text == NewSpaceCard.title })
    }

    @Test func theIconButtonOpensThePickerAndTakesWhatIsChosen() throws {
        let card = card()
        let icon = try #require(button("Choose an Icon", in: card))
        defer {
            browser.iconPicker.close()
            browser.spaceDraftIcon = nil
        }

        icon.action?()
        let target = browser.iconPicker.target
        browser.setIcon(TabIcon(emoji: "🌱"), of: .draft)

        #expect(target == .draft)
        #expect(browser.spaceDraftIcon == TabIcon(emoji: "🌱"))
        #expect(browser.draftIcon == TabIcon(emoji: "🌱"))
        #expect(all(in: card).compactMap { $0 as? NewSpaceIconFace }.first?.icon == TabIcon(emoji: "🌱"))
    }

    @Test func theCardSaysWhatSeparateAccountsMean() {
        let card = card()
        let choice = all(in: card).first { $0.accessibilityRole() == .radioGroup }
        let separate = choice?.accessibilityChildren()?.compactMap { $0 as? NSView }.last

        let pressed = separate?.accessibilityPerformPress()

        #expect(pressed == true)
        #expect(browser.spaceAsk.accounts == .separate)
        #expect(choice?.accessibilityLabel() == "Accounts")
        #expect(separate?.accessibilityLabel() == "Separate Accounts")
        #expect(separate?.accessibilityHelp() == "Every site starts signed out, with cookies of its own. Good for a second account.")
        browser.spaceAsk.accounts = .shared
    }

    @Test func aSpaceSaysWhichAccountsItUses() {
        let first = Space(id: Space.firstID, name: "Home", colour: 0)
        let shared = Space(id: UUID(), name: "Work", colour: 0, sharesSignIns: true)
        let separate = Space(id: UUID(), name: "Clients", colour: 0, sharesSignIns: false)
        let old = Space(id: UUID(), name: "Old", colour: 0)

        let said = [first, shared, separate, old].map(\.accounts)

        #expect(said == [.shared, .shared, .separate, .separate])
        #expect(SpaceAccounts.allCases.map(\.title) == ["Shared Accounts", "Separate Accounts"])
        #expect(SpaceAccounts.shared.caption == "Stays signed in to the sites your other spaces use")
        #expect(SpaceAccounts(shares: false) == .separate)
    }

    @Test func aHeaderNamesItsSpaceAndFoldsFromVoiceOver() throws {
        let folds = StackedFolds()
        let other = Space(id: UUID(), name: "Errands", colour: 0, icon: TabIcon(symbol: "cart"))
        let header = StackedHeaderView(browser: browser, folds: folds, space: other, count: 5)
        defer { folds.forget(other.id) }

        let fold = try #require(header.accessibilityCustomActions()?.first)
        let named = fold.name
        _ = fold.handler?()

        #expect(header.accessibilityLabel() == "Errands")
        #expect(named == "Fold")
        #expect(folds.isFolded(other.id))
        #expect(header.accessibilityValue() as? String == "5 tabs")
        #expect(header.accessibilityCustomActions()?.first?.name == "Unfold")
    }

    @Test func aFoldedHeadingWithNoTabsShowsNoCount() throws {
        let folds = StackedFolds()
        let other = Space(id: UUID(), name: "Errands", colour: 0, icon: TabIcon(symbol: "cart"))
        folds.set(other.id, folded: true)
        defer { folds.forget(other.id) }
        let header = StackedHeaderView(browser: browser, folds: folds, space: other, count: 0)
        header.frame = NSRect(x: 0, y: 0, width: 246, height: StackedHeaderView.height)
        header.layoutSubtreeIfNeeded()
        let chip = try #require(header.subviews.compactMap { $0 as? KitBox }.first { box in box.subviews.contains { $0 is KitLabel } })
        let name = try #require(header.subviews.compactMap { $0 as? KitLabel }.first)

        let empty = (chip.alphaValue, header.accessibilityValue() as? String)
        header.count = 2
        header.layoutSubtreeIfNeeded()
        let holding = (chip.alphaValue, chip.subviews.compactMap { $0 as? KitLabel }.first?.text, header.accessibilityValue() as? String)
        header.count = 0
        header.layoutSubtreeIfNeeded()
        let emptied = (chip.alphaValue, header.accessibilityValue() as? String)

        #expect(empty.0 == 0)
        #expect(empty.1 == "No tabs")
        #expect(holding.0 == 1)
        #expect(holding.1 == "2")
        #expect(holding.2 == "2 tabs")
        #expect(emptied.0 == 0)
        #expect(emptied.1 == "No tabs")
        #expect(name.text == "Errands")
    }

    @Test func aHeadersMenuStartsWithFoldAndNewTabDrawnAsTheSpaceMenusCommands() throws {
        let other = Space(id: UUID(), name: "Errands", colour: 0, icon: TabIcon(symbol: "cart"))
        browser.spaces.append(other)
        let folds = StackedFolds()
        let header = StackedHeaderView(browser: browser, folds: folds, space: other, count: 2)
        defer { folds.forget(other.id) }
        let press = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

        let rows = try #require(header.menu(for: press)).items

        #expect(rows.prefix(2).map(\.title) == ["Fold Errands", "New Tab in Errands"])
        #expect(rows[2].isSeparatorItem)
        #expect(rows.prefix(2).allSatisfy { $0.image == nil && $0.offStateImage != nil })
        #expect(rows.filter { !$0.isSeparatorItem }.dropFirst(2 + browser.spaces.count).filter { $0.offStateImage == nil }.map(\.title) == [])
        #expect(rows.contains { $0.title == "Rename “Errands”…" })
    }

    @Test func theCurrentSpacesHeaderSaysSo() {
        let header = StackedHeaderView(browser: browser, folds: StackedFolds(), space: browser.space, count: 1)

        let value = header.accessibilityValue() as? String

        #expect(value == "Current space")
        #expect(header.intrinsicContentSize.height == StackedHeaderView.height)
    }

    @Test func aMarkShowsAnEmojiOrASymbol() {
        let mark = SpaceMarkView(icon: TabIcon(symbol: "airplane"), size: 15)
        let symbolWidth = mark.intrinsicContentSize.width

        mark.icon = TabIcon(emoji: "🌿")

        #expect(symbolWidth > 0)
        #expect(mark.intrinsicContentSize.height >= 15)
        #expect(all(in: mark).filter { !$0.isHidden }.count == 1)
    }

    @Test func theFootLightsTheSpaceHereOnLayers() throws {
        let motion = SpaceMotion()
        let dot = NSView()
        let here = SpaceLitView(motion: motion, content: dot, here: true, next: false)
        let other = SpaceLitView(motion: motion, content: NSView(), here: false, next: false)
        var inked: CGFloat?
        other.tint = { inked = $0 }

        here.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        here.layoutSubtreeIfNeeded()
        other.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        other.layoutSubtreeIfNeeded()

        let lit = try #require(dot.layer)
        let grown = try #require(here.layer)
        #expect(abs(grown.sublayerTransform.m11 - 1.08) < 0.001)
        #expect(lit.opacity == 1)
        #expect(other.content.layer?.opacity ?? 0 < 0.6)
        #expect(inked == 0)
        #expect(motion.followers.allObjects.count == 2)
    }

    @Test func aPickedLookEasesTheGroundAndADragDoesNot() throws {
        let ground = LiveGroundView(browser: browser, motion: browser.spaceMotion, opaque: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = ground
        ground.layoutSubtreeIfNeeded()
        let base = try #require(ground.subviews.first?.layer)
        let id = browser.space.id
        let before = browser.space.look ?? SpaceLook()
        defer { browser.setSpaceLook(id, to: before, lasting: false) }

        browser.setSpaceLook(id, to: SpaceLook(colour: SpaceLook.palette[1].id), lasting: false)
        ground.layoutSubtreeIfNeeded()
        let dragged = base.animation(forKey: kCATransition)
        KitChange.eased { browser.setSpaceLook(id, to: SpaceLook(colour: SpaceLook.palette[2].id), lasting: false) }
        ground.layoutSubtreeIfNeeded()
        let picked = base.animation(forKey: kCATransition)

        #expect(dragged == nil)
        #expect(picked != nil || Motion.reduced)
    }
}
