import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SettingsPicturesTests {
    private func held(_ view: NSView, size: NSSize, dark: Bool = false) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width + 40, height: size.height + 40),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let holder = NSView(frame: NSRect(origin: .zero, size: NSSize(width: size.width + 40, height: size.height + 40)))
        window.contentView = holder
        view.frame = NSRect(x: 20, y: 20, width: size.width, height: size.height)
        holder.addSubview(view)
        holder.layoutSubtreeIfNeeded()
        return window
    }

    private func brightness(_ view: NSView, at point: NSPoint) throws -> CGFloat {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let colour = try #require(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
        return (colour.redComponent + colour.greenComponent + colour.blueComponent) / 3
    }

    @Test func theLightAndDarkMiniaturesDrawTheirOwnLookWhateverTheWindowIs() throws {
        let light = SettingsPictureView(.window(WindowScene(dark: false)), radius: 10)
        let dark = SettingsPictureView(.window(WindowScene(dark: true)), radius: 10)
        let size = NSSize(width: 108, height: 72)
        let one = held(light, size: size, dark: true)
        let two = held(dark, size: size, dark: false)
        defer { one.close(); two.close() }

        let page = NSPoint(x: 80, y: 60)
        let lit = try brightness(light, at: page)
        let dim = try brightness(dark, at: page)

        #expect(lit > 0.8)
        #expect(dim < 0.35)
    }

    @Test func autoIsLightAboveTheDiagonalAndDarkBelowIt() throws {
        let auto = SettingsPictureView(.window(WindowScene(auto: true)), radius: 10)
        let window = held(auto, size: NSSize(width: 108, height: 72))
        defer { window.close() }

        let above = try brightness(auto, at: NSPoint(x: 36, y: 40))
        let below = try brightness(auto, at: NSPoint(x: 100, y: 64))

        #expect(above > 0.8)
        #expect(below < 0.35)
    }

    @Test func theColumnSitsOnTheSideItIsOn() throws {
        let left = SettingsPictureView(.window(WindowScene(dark: false, right: false)), radius: 10)
        let right = SettingsPictureView(.window(WindowScene(dark: false, right: true)), radius: 10)
        let size = NSSize(width: 108, height: 72)
        let one = held(left, size: size)
        let two = held(right, size: size)
        defer { one.close(); two.close() }

        let pageNearLeftEdge = NSPoint(x: 20, y: 60)
        let onLeft = try brightness(left, at: pageNearLeftEdge)
        let onRight = try brightness(right, at: pageNearLeftEdge)

        #expect(onRight > onLeft + 0.02)
    }

    @Test func aNewSceneFadesInAndTheSameSceneDoesNothing() throws {
        keepSettings("motion.testReduced")
        Store.settings.set(false, forKey: "motion.testReduced")
        let first = PictureScene.window(WindowScene(dark: false))
        let second = PictureScene.window(WindowScene(dark: true))
        let picture = SettingsPictureView(first)
        let window = held(picture, size: NSSize(width: 52, height: 34))
        defer { window.close() }

        picture.show(first)

        #expect(picture.layer?.animation(forKey: SettingsPictureView.fadeKey) == nil)

        picture.show(second)

        let fade = try #require(picture.layer?.animation(forKey: SettingsPictureView.fadeKey) as? CATransition)
        #expect(fade.type == .fade)
        #expect(abs(fade.duration - 0.15) < 0.001)
        #expect(picture.scene == second)
    }

    @Test func underReduceMotionAPictureChangesWithoutAFade() {
        keepSettings("motion.testReduced")
        Store.settings.set(true, forKey: "motion.testReduced")
        let picture = SettingsPictureView(.window(WindowScene(dark: false)))
        let window = held(picture, size: NSSize(width: 52, height: 34))
        defer { window.close() }

        picture.show(.window(WindowScene(dark: true)))

        #expect(picture.layer?.animation(forKey: SettingsPictureView.fadeKey) == nil)
        #expect(picture.scene == .window(WindowScene(dark: true)))
    }

    @Test func aPictureIsDecorationForVoiceOver() {
        let picture = SettingsPictureView(.window(WindowScene(dark: false)))

        let element = picture.isAccessibilityElement()

        #expect(!element)
        #expect(picture.accessibilityChildren()?.isEmpty ?? true)
    }

    @Test func theLiveSceneFollowsTheSidebarSideAndTheCard() {
        let prefs = Shared.prefs
        keepSetting(prefs, \.cards, "layout.cards")
        keepSetting(prefs, \.sidePosition, "sidebar.position")
        prefs.tabsLayout = .right
        prefs.cards = false

        let scene = WindowScene.live(prefs, nil)

        #expect(scene.right)
        #expect(!scene.card)
        #expect(scene.dark == nil)
    }

    private func key(_ code: UInt16, _ characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func themes() -> SettingsPictureChoice {
        SettingsPictureChoice("Theme", options: [
            .init(title: "Auto", scene: WindowScene(auto: true)),
            .init(title: "Light", scene: WindowScene(dark: false)),
            .init(title: "Dark", scene: WindowScene(dark: true)),
        ], picked: 0)
    }

    @Test func cardsAreMiniaturesTenApartWithTheirNamesUnder() {
        let choice = themes()
        let size = choice.intrinsicContentSize
        let window = held(choice, size: size)
        defer { window.close() }

        choice.layoutSubtreeIfNeeded()
        let pictures = choice.cards.map { choice.convert($0.picture.bounds, from: $0.picture) }
        let names = choice.cards.map { choice.convert($0.name.bounds, from: $0.name) }

        #expect(pictures.map(\.size) == Array(repeating: NSSize(width: 108, height: 72), count: 3))
        #expect(pictures.map(\.minX) == [0, 118, 236])
        #expect(choice.cards.allSatisfy { $0.picture.radius == 10 })
        #expect(zip(names, pictures).allSatisfy { $0.minY >= $1.maxY && abs($0.midX - $1.midX) < 0.5 })
        #expect(size.width == 344)
    }

    @Test func arrowsMoveAndSpaceChooses() throws {
        let choice = themes()
        var chosen: [Int] = []
        choice.pick = { chosen.append($0) }
        let window = held(choice, size: choice.intrinsicContentSize)
        defer { window.close() }
        _ = choice.becomeFirstResponder()

        choice.keyDown(with: try key(124, "\u{F703}"))
        choice.keyDown(with: try key(124, "\u{F703}"))

        #expect(choice.focused == 2)
        #expect(choice.picked == 0)
        #expect(chosen.isEmpty)

        choice.keyDown(with: try key(49, " "))

        #expect(choice.picked == 2)
        #expect(chosen == [2])

        choice.keyDown(with: try key(123, "\u{F702}"))
        choice.keyDown(with: try key(123, "\u{F702}"))
        choice.keyDown(with: try key(123, "\u{F702}"))

        #expect(choice.focused == 0)
        #expect(choice.picked == 2)
    }

    @Test func voiceOverReadsRadioButtonsInAGroupNamedByTheRow() throws {
        let choice = themes()
        var chosen: [Int] = []
        choice.pick = { chosen.append($0) }

        let buttons = try #require(choice.accessibilityChildren() as? [NSView])
        let pressed = buttons[1].accessibilityPerformPress()

        #expect(choice.accessibilityRole() == .radioGroup)
        #expect(choice.accessibilityLabel() == "Theme")
        #expect(buttons.map { $0.accessibilityRole() } == [.radioButton, .radioButton, .radioButton])
        #expect(buttons.map { $0.accessibilityLabel() } == ["Auto", "Light", "Dark"])
        #expect(pressed)
        #expect(chosen == [1])
        #expect(buttons.map { $0.accessibilityValue() as? Int } == [0, 1, 0])
        #expect(choice.cards.allSatisfy { !$0.picture.isAccessibilityElement() })
    }

    @Test func appearanceShowsThemeAndNewTabsAsPictureCardsUnderTheirWords() throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        keepSetting(prefs, \.floatingNewTab, "newtab.floating")
        prefs.floatingNewTab = false
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let shell = SettingsShell()
        shell.go(to: .appearance)
        let page = SettingsPageView(browser: browser, shell: shell)
        let window = held(page, size: NSSize(width: 640, height: 1600))
        defer { window.close() }

        page.rebuild()
        page.layoutSubtreeIfNeeded()
        let rows = page.kitSubviews(of: SettingsRowView.self)
        let theme = try #require(rows.first { $0.rowID == "look" })
        let newTab = try #require(rows.first { $0.rowID == "newtab.floating" })

        for row in [theme, newTab] {
            let cards = try #require(row.control as? SettingsPictureChoice)
            let detail = row.convert(row.detail.bounds, from: row.detail)
            let frame = row.convert(cards.bounds, from: cards)
            let words = row.detail.superview.map { row.convert(row.detail.alignmentRect(forFrame: row.detail.frame), from: $0) } ?? .zero
            #expect(abs(frame.minX - words.minX) < 0.5)
            #expect(frame.minY >= detail.maxY)
            #expect(cards.accessibilityLabel() == row.title.stringValue)
        }
        let newTabCards = try #require(newTab.control as? SettingsPictureChoice)
        #expect(newTabCards.options.map(\.scene?.newTabPage) == [true, false])
        #expect(newTabCards.options.map(\.scene?.floatingField) == [false, true])
        #expect(newTabCards.picked == 0)

        prefs.floatingNewTab = true
        page.refresh()

        #expect(newTabCards.picked == 1)
    }

    @Test func noRowDrawsAPictureOfItsOwn() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let shell = SettingsShell()
        let page = SettingsPageView(browser: browser, shell: shell)
        let window = held(page, size: NSSize(width: 640, height: 1600))
        defer { window.close() }

        var loose: [String] = []
        for place in SettingsPage.blocks.flatMap({ $0 }) {
            shell.go(to: place)
            page.rebuild()
            for picture in page.kitSubviews(of: SettingsPictureView.self) {
                var above = picture.superview
                while let view = above, !(view is SettingsPictureChoice) { above = view.superview }
                if above == nil { loose.append(place.rawValue) }
            }
        }

        #expect(loose.isEmpty)
    }
}
