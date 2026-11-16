import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class OnboardingViewTests {
    private var browser: Browser!
    private var settings: UserDefaults!
    private var suite = ""
    private var windows: [NSWindow] = []

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        suite = "onboarding.view.tests.\(UUID().uuidString)"
        settings = UserDefaults(suiteName: suite)
        keepSetting(browser.prefs, \.sidePosition, "sidebar.position")
    }

    private func tearDown() async {
        for window in windows { window.close() }
        settings.removePersistentDomain(forName: suite)
        browser.closeAll()
        browser = nil
    }

    private func made(sources: [String] = ["Chrome", "Arc"]) -> Onboarding {
        let onboarding = Onboarding(settings: settings)
        onboarding.after = { _, _ in }
        onboarding.isDefault = { false }
        onboarding.askDefault = { answered in answered() }
        onboarding.sources = { sources }
        onboarding.defaultBrowser = { nil }
        return onboarding
    }

    private func placed(_ onboarding: Onboarding, _ size: NSSize = NSSize(width: 1280, height: 800)) -> OnboardingView {
        let view = OnboardingView(onboarding: onboarding)
        let window = OnboardingWindow(onboarding: onboarding, frame: NSRect(origin: .zero, size: size))
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.layoutIfNeeded()
        windows.append(window)
        return view
    }

    private func labels(in view: NSView) -> [String] {
        view.kitSubviews(of: KitLabel.self).map(\.text) + view.kitSubviews(of: KitParagraph.self).map(\.text)
    }

    private func button(_ id: String, in view: NSView) -> KitButton? {
        view.kitSubviews(of: KitButton.self).first { $0.accessibilityIdentifier() == id }
    }

    private func hit(_ target: NSView, in view: OnboardingView) -> NSView? {
        let middle = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        return view.window?.contentView?.hitTest(middle)
    }

    private func within(_ found: NSView?, _ target: NSView) -> Bool {
        var view = found
        while let now = view {
            if now === target { return true }
            view = now.superview
        }
        return false
    }

    private func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func theIntroShowsNoCardAndIsOneButtonThatSkips() {
        let onboarding = made()
        onboarding.begin(in: browser, reduced: false)
        let view = placed(onboarding)

        view.play()
        view.layoutSubtreeIfNeeded()
        let hidden = view.card.isHidden
        let element = view.scene.isAccessibilityElement()
        let pressed = view.scene.accessibilityPerformPress()
        view.layoutSubtreeIfNeeded()

        #expect(hidden)
        #expect(element)
        #expect(view.scene.accessibilityLabel() == "Broadway")
        #expect(view.scene.accessibilityHelp()?.contains("skip") == true)
        #expect(pressed)
        #expect(onboarding.phase == .steps)
        #expect(!view.card.isHidden)
        #expect(!view.scene.isAccessibilityElement())
        #expect(view.accessibilityLabel() == "Welcome to Broadway")
    }

    @Test func aClickAnywhereSkipsTheIntro() throws {
        let onboarding = made()
        onboarding.begin(in: browser, reduced: false)
        let view = placed(onboarding)
        view.play()
        view.layoutSubtreeIfNeeded()
        let corner = try #require(view.window?.contentView?.hitTest(NSPoint(x: 40, y: 40)))
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 40), modifierFlags: [], timestamp: 0,
                                                    windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

        corner.mouseDown(with: click)

        #expect(corner === view.scene)
        #expect(onboarding.phase == .steps)
    }

    @Test func theDrawnIntroDrawsAndTheCalmOneOnlyFades() {
        let drawn = made()
        drawn.begin(in: browser, reduced: false)
        let calm = made()
        calm.begin(in: browser, reduced: true)

        let first = placed(drawn)
        first.play()
        let second = placed(calm)
        second.play()

        #expect(first.scene.draws)
        #expect(first.scene.veiled)
        #expect(!second.scene.draws)
        #expect(second.scene.veiled)
    }

    @Test func aKeyReachesTheOnboardingThroughItsWindow() throws {
        let onboarding = made()
        onboarding.begin(in: browser, reduced: false)
        let view = placed(onboarding)
        let window = try #require(view.window as? OnboardingWindow)

        window.sendEvent(key("\r", 36))
        let afterReturn = onboarding.phase
        let held = window.performKeyEquivalent(with: key("t", 17, .command))
        let closed = window.performKeyEquivalent(with: key("w", 13, .command))

        #expect(window.canBecomeKey)
        #expect(window.title == "Welcome to Broadway")
        #expect(afterReturn == .steps)
        #expect(held)
        #expect(closed)
        #expect(onboarding.phase == .away)
    }

    @Test(arguments: Onboarding.Step.allCases)
    func eachStepHasItsTitleOneMainButtonAndNotNow(_ step: Onboarding.Step) throws {
        let onboarding = made()
        onboarding.open(at: step, in: browser)

        let view = placed(onboarding)

        let index = try #require(Onboarding.Step.allCases.firstIndex(of: step))
        #expect(!view.card.isHidden)
        #expect(view.card.frame.size == OnboardingCard.size)
        #expect(view.card.layer?.animationKeys() == nil)
        #expect(labels(in: view).contains(Onboarding.title(step)))
        #expect(labels(in: view).contains(step == .key ? onboarding.keyLine() : Onboarding.line(step)))
        #expect(view.card.accessibilityLabel() == Onboarding.title(step))
        let lead = try #require(button("onboarding.primary", in: view))
        let later = try #require(button("onboarding.later", in: view))
        #expect(lead.accessibilityLabel() == onboarding.lead(step))
        #expect(later.accessibilityLabel() == "Not Now")
        #expect(view.kitSubviews(of: KitButton.self).count == (step == .key ? 3 : 2))
        let dots = try #require(view.kitSubviews(of: OnboardingDots.self).first)
        #expect(dots.accessibilityLabel() == "Step \(index + 1) of \(Onboarding.Step.allCases.count)")
        #expect(view.card.bounds.contains(lead.frame))
        #expect(view.card.bounds.contains(later.frame))
        #expect(later.frame.maxX <= lead.frame.minX)
    }

    @Test(arguments: Onboarding.Step.allCases)
    func clicksLandOnTheButtons(_ step: Onboarding.Step) throws {
        let onboarding = made()
        onboarding.open(at: step, in: browser)
        let view = placed(onboarding)
        let lead = try #require(button("onboarding.primary", in: view))
        let later = try #require(button("onboarding.later", in: view))

        let onLead = hit(lead, in: view)
        let onLater = hit(later, in: view)

        #expect(within(onLead, lead))
        #expect(within(onLater, later))
    }

    @Test func theSpaceStepHasANameFieldAndEveryLookWithinTheCard() throws {
        let onboarding = made()
        onboarding.open(at: .space, in: browser)

        let view = placed(onboarding)

        let field = try #require(view.kitSubviews(of: KitField.self).first)
        let tiles = view.kitSubviews(of: SpaceLookTile.self)
        let window = try #require(view.kitSubviews(of: SpaceLookWindow.self).first)
        #expect(field.text == browser.space.name)
        #expect(field.field.accessibilityLabel() == "Space name")
        #expect(tiles.map(\.name) == SpaceLook.offers.map(\.name))
        #expect(onboarding.look == "noir")
        #expect(tiles.filter(\.picked).map(\.offer.id) == [onboarding.look])
        #expect(tiles.allSatisfy { $0.accessibilityRole() == .radioButton })
        #expect(window.look == SpaceLook.offered(onboarding.look))
        let inside = view.card.bounds.insetBy(dx: OnboardingCard.inset - 1, dy: 0)
        #expect(tiles.allSatisfy { inside.contains($0.convert($0.bounds, to: view.card)) })
        #expect(inside.contains(window.convert(window.bounds, to: view.card)))
        #expect(tiles.allSatisfy { $0.frame.width >= 80 && $0.frame.height >= 44 })
        #expect(within(hit(field, in: view), field))
        #expect(tiles.allSatisfy { hit($0, in: view) === $0 })
        #expect(view.card.firstField === field.field)
    }

    @Test func typingANameAndPickingALookReachTheModelAndTheSmallWindow() throws {
        let onboarding = made()
        onboarding.open(at: .space, in: browser)
        let view = placed(onboarding)
        let field = try #require(view.kitSubviews(of: KitField.self).first)
        let window = try #require(view.kitSubviews(of: SpaceLookWindow.self).first)

        for tile in view.kitSubviews(of: SpaceLookTile.self) {
            field.field.stringValue = "Home"
            field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field.field))
            tile.action()
            view.layoutSubtreeIfNeeded()

            #expect(onboarding.name == "Home")
            #expect(onboarding.look == tile.offer.id)
            #expect(window.look == tile.look)
            #expect(view.kitSubviews(of: SpaceLookTile.self).filter(\.picked).map(\.name) == [tile.name])
        }
    }

    @Test func aSpaceInALookOfItsOwnShowsThatLookAndPicksNoTile() throws {
        let worn = SpaceLook(colours: ["123456"], intensity: 0.5, transparency: 0.3, grain: 0.6)
        browser.setSpaceLook(browser.spaceID, to: worn)
        let onboarding = made()
        onboarding.open(at: .space, in: browser)

        let view = placed(onboarding)

        let window = try #require(view.kitSubviews(of: SpaceLookWindow.self).first)
        #expect(onboarding.look == "custom")
        #expect(window.look == worn)
        #expect(view.kitSubviews(of: SpaceLookTile.self).filter(\.picked).isEmpty)
    }

    @Test func theSideStepOffersBothSidesAndAClickPicksOne() throws {
        browser.prefs.sidePosition = .left
        let onboarding = made()
        onboarding.open(at: .side, in: browser)
        let view = placed(onboarding)
        let choices = view.kitSubviews(of: OnboardingChoice.self)
        let right = try #require(choices.first { $0.accessibilityIdentifier() == "onboarding.side.right" })

        let found = hit(right, in: view)
        let pressed = right.accessibilityPerformPress()
        view.layoutSubtreeIfNeeded()

        #expect(choices.count == 2)
        #expect(found === right)
        #expect(pressed)
        #expect(onboarding.side == .right)
        #expect(choices.filter(\.picked).map { $0.accessibilityIdentifier() } == ["onboarding.side.right"])
        #expect(browser.prefs.sidePosition == .left)
    }

    @Test func theLastStepOffersEachBrowserFoundAndNamesTheChosenOne() throws {
        let onboarding = made(sources: ["Chrome", "Arc", "Brave"])
        onboarding.open(at: .bring, in: browser)
        let view = placed(onboarding)
        let choices = view.kitSubviews(of: OnboardingChoice.self)
        let arc = try #require(choices.first { $0.accessibilityIdentifier() == "onboarding.source.Arc" })

        _ = arc.accessibilityPerformPress()
        view.layoutSubtreeIfNeeded()

        #expect(choices.count == 3)
        #expect(onboarding.source == "Arc")
        #expect(button("onboarding.primary", in: view)?.accessibilityLabel() == "Bring Over from Arc")
        #expect(choices.filter(\.picked).count == 1)
    }

    @Test(arguments: [Onboarding.Step.side, .links, .agents])
    func theWindowPicturesAfterTheFirstStepWearTheSpacesLook(_ step: Onboarding.Step) throws {
        let dusk = try #require(SpaceLook.offered("dusk"))
        browser.setSpaceLook(browser.spaceID, to: dusk)
        let onboarding = made()
        onboarding.open(at: step, in: browser)

        let view = placed(onboarding)

        let pictures = view.kitSubviews(of: OnboardingSidePicture.self)
        #expect(pictures.count == (step == .side ? 2 : 1))
        for picture in pictures {
            let ground = try #require(picture.kitSubviews(of: SpaceGroundView.self).first)
            #expect(picture.look == dusk)
            #expect(ground.blend == LookBlend(from: dusk))
            #expect(ground.staged)
            #expect(ground.frame.size == picture.bounds.size)
        }
    }

    @Test func aSpaceWithNoLookKeepsThePlainWindowPictureAndGlassGetsSomethingBehindIt() throws {
        let plain = OnboardingSidePicture(right: false)
        let glass = OnboardingSidePicture(right: true, look: try #require(SpaceLook.offered("glass")))

        #expect(plain.look == SpaceLook())
        #expect(plain.kitSubviews(of: SpaceLookBackdrop.self).isEmpty)
        #expect(glass.kitSubviews(of: SpaceLookBackdrop.self).map(\.bright) == [true])
    }

    @Test func aBrowserWhoseAppIsNotFoundGetsAQuietMarkSmallerThanAnIcon() throws {
        let mark = OnboardingSourceMark(icon: nil)
        mark.frame = NSRect(x: 0, y: 0, width: 64, height: 64)

        mark.layoutSubtreeIfNeeded()

        let symbol = try #require(mark.kitSubviews(of: KitSymbol.self).first)
        #expect(mark.plain)
        #expect(symbol.frame.width <= 32 && symbol.frame.height <= 32)
        #expect(abs(symbol.frame.midX - 32) <= 1 && abs(symbol.frame.midY - 32) <= 1)
        #expect(!OnboardingSourceMark(icon: NSImage(size: NSSize(width: 8, height: 8))).plain)
    }

    @Test func goingToTheNextStepSwapsTheTextAndKeepsTheFooter() throws {
        let onboarding = made()
        onboarding.open(at: .space, in: browser)
        let view = placed(onboarding)
        let lead = try #require(button("onboarding.primary", in: view))
        let dots = try #require(view.kitSubviews(of: OnboardingDots.self).first)

        onboarding.later()
        view.layoutSubtreeIfNeeded()

        #expect(button("onboarding.primary", in: view) === lead)
        #expect(view.kitSubviews(of: OnboardingDots.self).first === dots)
        #expect(dots.index == 1)
        #expect(view.card.panel?.step == .side)
        #expect(view.card.accessibilityLabel() == Onboarding.title(.side))
        #expect(view.kitSubviews(of: KitField.self).allSatisfy { $0.superview !== view.card.panel })
    }

    @Test(arguments: [NSSize(width: 1280, height: 800), NSSize(width: 1512, height: 982), NSSize(width: 2560, height: 1440)])
    func theCardSitsCentredUnderTheWordmarkOverTheWholeMap(_ size: NSSize) throws {
        let onboarding = made()
        onboarding.open(at: .space, in: browser)

        let view = placed(onboarding, size)

        let layout = try #require(view.scene.placed)
        let wordTop = layout.headerCentre.y + layout.wordHeight * layout.header / 2
        #expect(layout.size == size)
        #expect(view.scene.raised)
        #expect(abs(view.card.frame.midX - size.width / 2) <= 0.5)
        #expect(view.bounds.insetBy(dx: 24, dy: 24).contains(view.card.frame))
        #expect(view.card.frame.maxY < layout.headerCentre.y)
        #expect(abs((wordTop + view.card.frame.minY) / 2 - (size.height - layout.safeTop) / 2) <= 1)
        #expect(view.scene.backdrop.insetBy(dx: 0, dy: -1).contains(CGRect(x: size.width / 2 - 1, y: 0, width: 2, height: size.height)))
        #expect(abs(view.scene.backdrop.midX - size.width / 2) <= 0.5)
    }

    @Test func aSkippedIntroRestsWhereAFinishedOneDoes() async throws {
        let skipped = made()
        skipped.begin(in: browser, reduced: false)
        let cut = placed(skipped)
        cut.play()
        cut.layoutSubtreeIfNeeded()
        let opened = made()
        opened.open(at: .space, in: browser)
        let rested = placed(opened)

        skipped.endIntro()
        cut.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(Int(OnboardingView.dipTakes * 1000) + 400))

        #expect(cut.scene.raised)
        #expect(!cut.scene.draws)
        #expect(cut.scene.backdrop == rested.scene.backdrop)
        #expect(cut.scene.placed == rested.scene.placed)
        #expect(cut.card.frame == rested.card.frame)
        #expect(!cut.card.isHidden)
    }

    @Test func theStageRaisesAWindowAndTheEndTakesItAway() throws {
        let show = OnboardingShow()
        let onboarding = made()
        onboarding.stage = show

        onboarding.begin(in: browser, reduced: false)
        let window = try #require(show.window)
        let view = try #require(show.view)
        onboarding.endIntro()
        onboarding.close()

        #expect(window.contentView === view || show.window == nil)
        #expect(window.styleMask == [.borderless])
        #expect(!window.isOpaque)
        #expect(!window.isVisible)
        #expect(show.window == nil)
        #expect(onboarding.phase == .away)
        #expect(onboarding.seen)
    }

    @Test func aReplayReplacesTheWindowInsteadOfStackingAnother() throws {
        let show = OnboardingShow()
        let onboarding = made()
        onboarding.stage = show
        onboarding.begin(in: browser, reduced: false)
        let first = try #require(show.window)

        onboarding.abandon()
        onboarding.begin(in: browser, reduced: false)

        let second = try #require(show.window)
        #expect(second !== first)
        #expect(first.contentView == nil)
        #expect(onboarding.phase == .intro)
        onboarding.abandon()
    }
}
