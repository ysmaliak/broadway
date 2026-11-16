import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct KitPopupTests {
    private func moving(_ reduced: Bool) {
        Store.settings.set(reduced, forKey: "motion.testReduced")
        Store.settings.set(false, forKey: "motion.testLowPower")
    }

    private func still() {
        Store.settings.removeObject(forKey: "motion.testReduced")
        Store.settings.removeObject(forKey: "motion.testLowPower")
    }

    private func world() -> (NSWindow, NSView) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: CGRect(x: 40, y: 300, width: 80, height: 24))
        window.contentView?.addSubview(anchor)
        return (window, anchor)
    }

    @Test func aPopupIsABorderlessChildPanelOfTheAnchorsWindow() throws {
        let (window, anchor) = world()
        defer { window.close() }

        let popup = try #require(KitPopup.show(NSView(), size: NSSize(width: 200, height: 100), from: anchor.bounds, of: anchor))
        defer { popup.close() }

        let panel = try #require(popup.panel)
        #expect(panel.parent === window)
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }

    @Test func aPopupTakesKeyOnlyWhenItsContentHasAField() throws {
        let (window, anchor) = world()
        defer { window.close() }

        let plain = try #require(KitPopup.show(NSView(), size: NSSize(width: 200, height: 100), from: anchor.bounds, of: anchor))
        let plainKey = plain.panel?.canBecomeKey
        plain.close()
        let field = try #require(KitPopup.show(NSView(), size: NSSize(width: 200, height: 100), from: anchor.bounds, of: anchor, focus: true))
        defer { field.close() }

        #expect(plainKey == false)
        #expect(field.panel?.canBecomeKey == true)
    }

    @Test func closingAPopupTellsItsOwnerOnce() throws {
        let (window, anchor) = world()
        defer { window.close() }
        var closes = 0
        let popup = try #require(KitPopup.show(NSView(), size: NSSize(width: 200, height: 100), from: anchor.bounds, of: anchor,
                                               onClose: { closes += 1 }))

        popup.close()
        popup.close()

        #expect(closes == 1)
        #expect(!popup.isShown)
        #expect(KitPopup.current(in: window) == nil)
    }

    @Test func theContentSitsSixPointsInsideTheSurface() throws {
        let (window, anchor) = world()
        defer { window.close() }
        let content = NSView()

        let popup = try #require(KitPopup.show(content, size: NSSize(width: 200, height: 100), from: anchor.bounds, of: anchor))
        defer { popup.close() }
        let stage = try #require(popup.panel?.contentView as? KitPopupStage)
        stage.layoutSubtreeIfNeeded()

        #expect(stage.surface.frame.size == NSSize(width: 212, height: 112))
        #expect(content.frame.size == NSSize(width: 200, height: 100))
        #expect(content.convert(content.bounds, to: stage.surface).minX == 6)
    }

    @Test func thePanelLeavesRoomAroundTheSurfaceForItsShadow() throws {
        let (window, anchor) = world()
        defer { window.close() }

        let popup = try #require(KitPopup.show(NSView(), size: NSSize(width: 200, height: 100), from: anchor.bounds, of: anchor))
        defer { popup.close() }
        let panel = try #require(popup.panel)

        #expect(panel.frame.width == 212 + PopupLook.room * 2)
        #expect(panel.frame.height == 112 + PopupLook.room * 2)
        #expect(PopupLook.room >= PopupLook.shadow.radius + PopupLook.shadow.y)
    }

    @Test func theSurfaceHasRoundedContinuousCornersAnEdgeAndAShadow() throws {
        let (window, anchor) = world()
        defer { window.close() }
        let popup = try #require(KitPopup.show(NSView(), size: NSSize(width: 200, height: 100), from: anchor.bounds, of: anchor))
        defer { popup.close() }
        let stage = try #require(popup.panel?.contentView as? KitPopupStage)
        stage.layoutSubtreeIfNeeded()

        stage.surface.appearance = NSAppearance(named: .darkAqua)
        stage.surface.updateLayer()
        let dark = try #require(stage.surface.layer)
        let darkClip = try #require(stage.surface.clip.layer)
        let darkEdge = darkClip.borderColor.flatMap { NSColor(cgColor: $0) }
        let darkOpacity = dark.shadowOpacity
        stage.surface.appearance = NSAppearance(named: .aqua)
        stage.surface.updateLayer()
        let lightOpacity = dark.shadowOpacity
        let lightEdge = darkClip.borderColor.flatMap { NSColor(cgColor: $0) }

        #expect(darkClip.cornerRadius == 14)
        #expect(darkClip.cornerCurve == .continuous)
        #expect(darkClip.masksToBounds)
        #expect(dark.shadowRadius == 18)
        #expect(dark.shadowOffset == CGSize(width: 0, height: -6))
        #expect(dark.shadowPath != nil)
        #expect(lightOpacity == 0.16)
        #expect(darkOpacity == 0.30)
        #expect(abs((darkEdge?.alphaComponent ?? 0) - 0.12) < 0.001)
        #expect(abs((lightEdge?.alphaComponent ?? 0) - 0.10) < 0.001)
    }

    @Test func popupRowsNestTheirCornersInsideTheSurface() {
        let look = PopupLook.self

        let nested = look.corner - look.inset

        #expect(look.row == 30)
        #expect(look.rowCorner == nested)
        #expect(look.rowCorner == 8)
        #expect(look.fontSize == 13)
        #expect(look.gap == 6)
    }

    @Test func aPopupGrowsInFromThePointOnItsEdgeNearestTheAnchor() throws {
        moving(false)
        defer { still() }
        let (window, anchor) = world()
        defer { window.close() }

        let popup = try #require(KitPopup.show(NSView(), size: NSSize(width: 200, height: 100), from: anchor.bounds, of: anchor))
        defer { popup.close(animated: false) }
        let layer = try #require(popup.stage.surface.layer)
        let grow = try #require(layer.animation(forKey: "popup.grow") as? CASpringAnimation)
        let fade = try #require(layer.animation(forKey: "popup.fade") as? CABasicAnimation)
        let from = try #require((grow.fromValue as? NSValue)?.caTransform3DValue)
        let point = popup.growthPoint
        let size = layer.bounds.size
        let pivot = CGPoint(x: point.x - layer.anchorPoint.x * size.width, y: point.y - layer.anchorPoint.y * size.height)
        let moved = CGPoint(x: from.m11 * pivot.x + from.m41, y: from.m22 * pivot.y + from.m42)

        #expect(abs(from.m11 - 0.90) < 0.0001)
        #expect(abs(moved.x - pivot.x) < 0.001)
        #expect(abs(moved.y - pivot.y) < 0.001)
        #expect(fade.fromValue as? Swift.Float == 0)
        #expect(abs(fade.duration - 0.12) < 0.0001)
        #expect(abs(grow.stiffness - KitSpring(response: 0.26, damping: 0.80).stiffness) < 0.001)
    }

    @Test func theGrowthPointIsOnTheEdgeThatFacesTheAnchor() {
        let row = CGRect(x: 10, y: 600, width: 240, height: 30)
        let button = CGRect(x: 700, y: 820, width: 26, height: 26)
        let beside = CGRect(x: 256, y: 430, width: 300, height: 200)
        let under = CGRect(x: 700, y: 614, width: 300, height: 200)

        let fromRow = KitPopup.growth(anchor: row, frame: beside, edge: .right)
        let fromButton = KitPopup.growth(anchor: button, frame: under, edge: .below)

        #expect(fromRow == CGPoint(x: 0, y: 185))
        #expect(fromButton == CGPoint(x: 13, y: 200))
    }

    @Test func underReduceMotionAPopupShowsAndGoesAtOnce() throws {
        moving(true)
        defer { still() }
        let (window, anchor) = world()
        defer { window.close() }

        let popup = try #require(KitPopup.show(NSView(), size: NSSize(width: 200, height: 100), from: anchor.bounds, of: anchor))
        let opening = popup.stage.surface.layer?.animationKeys() ?? []
        popup.close()

        #expect(opening.isEmpty)
        #expect(popup.panel == nil)
        #expect(window.childWindows?.isEmpty ?? true)
    }

    @Test func goingOutItFadesAndShrinksTowardTheSamePoint() throws {
        moving(false)
        defer { still() }
        let (window, anchor) = world()
        defer { window.close() }
        let popup = try #require(KitPopup.show(NSView(), size: NSSize(width: 200, height: 100), from: anchor.bounds, of: anchor))
        let layer = try #require(popup.stage.surface.layer)

        popup.close()
        let shrink = try #require(layer.animation(forKey: "popup.grow") as? CABasicAnimation)
        let fade = try #require(layer.animation(forKey: "popup.fade") as? CABasicAnimation)
        let goal = try #require((shrink.toValue as? NSValue)?.caTransform3DValue)

        #expect(abs(goal.m11 - 0.96) < 0.0001)
        #expect(fade.toValue as? Swift.Float == 0)
        #expect(abs(fade.duration - 0.10) < 0.0001)
        #expect(popup.closing)
    }

    @Test func movingToAnotherAnchorGlidesWithoutGrowingAgain() throws {
        moving(false)
        defer { still() }
        let (window, anchor) = world()
        defer { window.close() }
        let other = NSView(frame: CGRect(x: 40, y: 200, width: 80, height: 24))
        window.contentView?.addSubview(other)
        let popup = try #require(KitPopup.show(NSView(), size: NSSize(width: 200, height: 100), from: anchor.bounds, of: anchor))
        defer { popup.close(animated: false) }
        let layer = try #require(popup.stage.surface.layer)
        layer.removeAllAnimations()

        popup.move(to: other.bounds, of: other)

        #expect(layer.animation(forKey: "glide") != nil)
        #expect(layer.animation(forKey: "popup.grow") == nil)
        #expect(layer.animation(forKey: "popup.fade") == nil)
    }

    @Test func aPressOnThePopupLeavesItOpen() {
        let press = KitPopup.press(onPanel: true, inSurface: true, inAnchor: false)

        let answer = KitPopup.answer(press, follows: false)

        #expect(press == .inside)
        #expect(answer == PopupAnswer(closes: false, eats: false))
    }

    @Test func aPressOutsideClosesItAndStillReachesWhatWasPressed() {
        let press = KitPopup.press(onPanel: false, inSurface: false, inAnchor: false)

        let answer = KitPopup.answer(press, follows: false)

        #expect(press == .outside)
        #expect(answer == PopupAnswer(closes: true, eats: false))
    }

    @Test func aSecondPressOnTheAnchorClosesItWithoutReachingTheAnchor() {
        let press = KitPopup.press(onPanel: false, inSurface: false, inAnchor: true)

        let answer = KitPopup.answer(press, follows: false)

        #expect(press == .anchor)
        #expect(answer == PopupAnswer(closes: true, eats: true))
    }

    @Test func aPressInTheShadowAroundTheSurfaceClosesIt() {
        let press = KitPopup.press(onPanel: true, inSurface: false, inAnchor: false)

        let answer = KitPopup.answer(press, follows: false)

        #expect(press == .margin)
        #expect(answer.closes)
    }

    @Test func escapeClosesItAndOtherKeysPassThrough() {
        let escape: UInt16 = 53
        let down: UInt16 = 125

        let onEscape = KitPopup.answer(key: escape, follows: false)
        let onDown = KitPopup.answer(key: down, follows: false)

        #expect(onEscape == PopupAnswer(closes: true, eats: true))
        #expect(onDown == PopupAnswer(closes: false, eats: false))
    }

    @Test func aPopupThatFollowsAFieldLeavesEscapeAndTheFieldToIt() {
        let press = KitPopup.press(onPanel: false, inSurface: false, inAnchor: true)

        let onAnchor = KitPopup.answer(press, follows: true)
        let onEscape = KitPopup.answer(key: 53, follows: true)

        #expect(onAnchor == PopupAnswer(closes: false, eats: false))
        #expect(onEscape == PopupAnswer(closes: false, eats: false))
    }

    @Test func escapeInTheWindowClosesItsPopup() throws {
        moving(true)
        defer { still() }
        let (window, anchor) = world()
        defer { window.close() }
        var closed = false
        let popup = try #require(KitPopup.show(NSView(), size: NSSize(width: 200, height: 100), from: anchor.bounds, of: anchor,
                                               onClose: { closed = true }))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))

        let eaten = KitPopup.heard(escape)

        #expect(eaten)
        #expect(closed)
        #expect(!popup.isShown)
    }

    @Test func aPressOutsideInTheWindowClosesItsPopup() throws {
        moving(true)
        defer { still() }
        let (window, anchor) = world()
        defer { window.close() }
        let popup = try #require(KitPopup.show(NSView(), size: NSSize(width: 200, height: 100), from: anchor.bounds, of: anchor))
        let press = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 500, y: 50), modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))

        let eaten = KitPopup.heard(press)

        #expect(!eaten)
        #expect(!popup.isShown)
    }

    @Test func openingASecondPopupInAWindowClosesTheFirst() throws {
        moving(true)
        defer { still() }
        let (window, anchor) = world()
        defer { window.close() }
        var firstClosed = false
        let first = try #require(KitPopup.show(NSView(), size: NSSize(width: 200, height: 100), from: anchor.bounds, of: anchor,
                                               onClose: { firstClosed = true }))

        let second = try #require(KitPopup.show(NSView(), size: NSSize(width: 100, height: 50), from: anchor.bounds, of: anchor))
        defer { second.close() }

        #expect(firstClosed)
        #expect(!first.isShown)
        #expect(KitPopup.current(in: window) === second)
        #expect(window.childWindows?.count == 1)
    }

    @Test func aPressOnTheAnchorOfAPopupThatFollowsItReachesTheAnchor() throws {
        moving(true)
        defer { still() }
        let (window, anchor) = world()
        defer { window.close() }
        let popup = try #require(KitPopup.show(NSView(), size: NSSize(width: 200, height: 100), from: anchor.bounds, of: anchor,
                                               follows: true))
        defer { popup.close() }
        let inside = anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
        let press = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: inside, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))

        let eaten = KitPopup.heard(press)

        #expect(!eaten)
        #expect(popup.isShown)
    }

    @Test func growingWhileItGlidesKeepsTheSurfaceInsideThePanel() throws {
        moving(false)
        defer { still() }
        let (window, anchor) = world()
        defer { window.close() }
        let other = NSView(frame: CGRect(x: 40, y: 100, width: 80, height: 24))
        window.contentView?.addSubview(other)
        let popup = try #require(KitPopup.show(NSView(), size: NSSize(width: 200, height: 60), from: anchor.bounds, of: anchor))
        defer { popup.close(animated: false) }
        popup.move(to: other.bounds, of: other)

        popup.resize(to: NSSize(width: 200, height: 160))
        let panel = try #require(popup.panel)
        let surface = popup.stage.surface.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)

        #expect(popup.gliding)
        #expect(surface.height == 172)
        #expect(panel.frame.contains(surface))
        #expect(surface == popup.placement?.frame)
    }

    @Test func theBookmarkCardIsAPopupThatTakesTheKeyboard() async throws {
        moving(true)
        defer { still() }
        let (window, _) = world()
        defer { window.close() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let url = try #require(URL(string: "https://popup-card.example/"))
        let mark = try #require(browser.bookmarks.add(url, title: "Card"))
        defer { browser.bookmarks.remove(mark.id) }
        let door = BookmarksAnchorView(browser: browser)
        door.frame = NSRect(x: 40, y: 300, width: 26, height: 26)
        window.contentView?.addSubview(door)

        browser.bookmarkCard = mark.id
        browser.bookmarksOpen = true
        try await Task.sleep(for: .milliseconds(200))
        let card = KitPopup.current(in: window)
        defer { card?.close() }

        #expect(card != nil)
        #expect(card?.focus == true)
        #expect(browser.bookmarksOpen)
    }
}
