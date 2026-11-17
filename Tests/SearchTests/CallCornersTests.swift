import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct CallCornersTests {
    private func corners(close: @escaping () -> Void = {}, back: @escaping () -> Void = {}) -> CallCorners {
        let made = CallCorners(frame: NSRect(origin: .zero, size: CallFloat.size), close: close, back: back)
        made.layoutSubtreeIfNeeded()
        return made
    }

    @Test func theBarHasNoGoToTab() {
        let status = CallButtons.Status(mic: true, camera: false, leaves: true)

        let keys = CallButtons.keys(status)

        #expect(keys == [.mic, .camera, .leave])
    }

    @Test func aCallWithNothingToPressHasAnEmptyBar() {
        let status = CallButtons.Status()

        let keys = CallButtons.keys(status)

        #expect(keys.isEmpty)
    }

    @Test func theCornersSitWhereTheVideosDo() {
        let view = corners()

        let close = view.close.frame
        let back = view.back.frame

        #expect(close == FloatLayout.close(in: view.bounds))
        #expect(back == FloatLayout.back(in: view.bounds))
        #expect(close.maxX == view.bounds.maxX - FloatLayout.inset && close.maxY == view.bounds.maxY - FloatLayout.inset)
        #expect(back.minX == view.bounds.minX + FloatLayout.inset && back.maxY == view.bounds.maxY - FloatLayout.inset)
    }

    @Test func backToTabArrivesFromTheTopLeftAndCloseFromTheTopRight() {
        let view = corners()

        let back = view.back.frame
        let close = view.close.frame

        #expect(back.maxX < view.bounds.midX)
        #expect(close.minX > view.bounds.midX)
    }

    @Test func theRoomForTheTilesLeavesTheBarBelowInPagePixels() {
        let zoom: CGFloat = 0.5

        let room = CallFloat.room(zoom: zoom)

        #expect(room.top == CallFloat.stage.top * 2 && room.left == CallFloat.stage.left * 2 && room.right == CallFloat.stage.right * 2)
        #expect(room.bottom == CallFloat.stage.bottom * 2)
        #expect(CallFloat.stage.bottom >= 10 + 40)
    }

    @Test func theTilesArePinnedToTheRoomAndFittedByMeasuring() {
        let room = NSEdgeInsets(top: 16, left: 16, bottom: 116, right: 16)

        let script = CallTiles.enter(room: room)

        #expect(script.contains("top: 16.00px !important") && script.contains("bottom: 116.00px !important"))
        #expect(script.contains("transform-origin: 0 0 !important"))
        #expect(!script.contains("transform: none !important; }"))
        #expect(script.contains("broadway-call-fit") && script.contains("requestAnimationFrame"))
        #expect(CallTiles.leave.contains("broadway-call-fit"))
    }

    @Test func aSharedScreenIsPinnedAloneAndTheRestOfThePageIsHidden() {
        let room = NSEdgeInsets(top: 16, left: 16, bottom: 116, right: 16)

        let script = CallTiles.enter(room: room, corner: 12)

        #expect(script.contains("function shared()") && script.contains("data-broadway-tiles-screen"))
        #expect(script.contains("body *:not([data-broadway-tiles-screen])"))
        #expect(script.contains("border-radius: 12.00px !important"))
    }

    @Test func landingForgetsTheSharedScreen() {
        let script = CallTiles.leave

        #expect(script.contains("data-broadway-tiles-screen"))
        #expect(script.contains("__broadwayCallScreen = null"))
    }

    @Test func theSharedScreensCornerNestsInsideTheWindows() {
        let zoom: CGFloat = 0.5

        let corner = CallFloat.corner(zoom: zoom)

        #expect(corner == (CallFloat.radius - CallFloat.stage.top) / zoom)
        #expect(corner > 0)
    }

    @Test func theCornersAreNamedButtons() {
        let view = corners()

        let close = view.close.key
        let back = view.back.key

        #expect(close.accessibilityLabel() == "Close")
        #expect(back.accessibilityLabel() == "Back to Tab")
        #expect(close.accessibilityRole() == .button)
        #expect(back.accessibilityRole() == .button)
        #expect(close.symbol?.name == "xmark")
        #expect(back.symbol?.name == "pip.exit")
    }

    @Test func theBarsKeysAreNamedWithoutTheirShortcutAndKeepItInTheTooltip() {
        let bar = CallFloat.surface(mic: true, camera: false, leaves: true)
        bar.layoutSubtreeIfNeeded()

        let keys = bar.kitSubviews(of: KitButton.self)

        #expect(keys.map { $0.accessibilityLabel() } == ["Mute", "Start Camera", "Leave Call"])
        #expect(keys.map(\.toolTip) == ["Mute   ⌘D", "Start Camera   ⌘E", "Leave Call"])
    }

    @Test func theCornersStayAwayAndLetClicksThroughUntilThePointerComes() {
        let view = corners()
        let point = NSPoint(x: view.close.frame.midX, y: view.close.frame.midY)

        let hit = view.hitTest(point)

        #expect(!view.chrome.shown)
        #expect(hit == nil)
        #expect(!view.close.isHidden && !view.back.isHidden)
    }

    @Test func thePointerComingInShowsThemAndTheyTakeTheClick() {
        let view = corners()
        let point = NSPoint(x: view.back.frame.midX, y: view.back.frame.midY)

        view.hover(true)

        #expect(view.chrome.shown)
        let hit = view.hitTest(point)
        #expect(hit === view.back.key || hit?.isDescendant(of: view.back.key) == true)
        #expect(view.hitTest(NSPoint(x: view.bounds.midX, y: view.bounds.midY)) == nil)
    }

    @Test func pressingThemRunsTheirActions() {
        var pressed: [String] = []
        let view = corners(close: { pressed.append("close") }, back: { pressed.append("back") })

        _ = view.close.key.accessibilityPerformPress()
        _ = view.back.key.accessibilityPerformPress()

        #expect(pressed == ["close", "back"])
    }

    @Test func returnGoesToTheTabAndEscapePutsTheWindowAway() {
        let none: NSEvent.ModifierFlags = []

        let back = CallKey.read(code: 36, flags: none, characters: "\r")
        let enter = CallKey.read(code: 76, flags: .numericPad, characters: "\u{3}")
        let away = CallKey.read(code: 53, flags: none, characters: "\u{1b}")

        #expect(back == .back)
        #expect(enter == .back)
        #expect(away == .away)
    }

    @Test func theMicAndCameraKeysStay() {
        let command: NSEvent.ModifierFlags = .command

        let mic = CallKey.read(code: 2, flags: command, characters: "d")
        let camera = CallKey.read(code: 14, flags: [.command, .capsLock], characters: "E")
        let close = CallKey.read(code: 13, flags: command, characters: "w")
        let shifted = CallKey.read(code: 53, flags: .shift, characters: "\u{1b}")

        #expect(mic == .mic)
        #expect(camera == .camera)
        #expect(close == nil)
        #expect(shifted == nil)
    }

    @Test func aCallPutAwayStaysAwayWhileItGoesOn() {
        let tab = UUID()
        var away = CallAway()
        away.put(tab)

        for _ in 0..<10 { away.heard(onCall: true) }

        #expect(away.keeps(tab))
        #expect(!away.keeps(UUID()))
    }

    @Test func theNextCallFloatsAgainOnceThisOneEnds() {
        let tab = UUID()
        var away = CallAway()
        away.put(tab)

        away.heard(onCall: false)
        away.heard(onCall: false)
        let stillAway = away.keeps(tab)
        away.heard(onCall: false)

        #expect(stillAway)
        #expect(!away.keeps(tab))
        #expect(away.tab == nil)
    }

    @Test func aBlipInTheCallDoesNotEndIt() {
        let tab = UUID()
        var away = CallAway()
        away.put(tab)

        away.heard(onCall: false)
        away.heard(onCall: false)
        away.heard(onCall: true)
        away.heard(onCall: false)
        away.heard(onCall: false)

        #expect(away.keeps(tab))
    }

    @Test func aClosedTabTakesItsAwayWithIt() {
        let tab = UUID()
        var away = CallAway()
        away.put(tab)

        away.gone()

        #expect(!away.keeps(tab))
    }
}
