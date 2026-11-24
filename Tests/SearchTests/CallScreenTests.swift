import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct CallScreenTests {
    private let script = CallTiles.enter(room: NSEdgeInsets(top: 16, left: 16, bottom: 116, right: 16))

    @Test func aCameraIsNeverPickedAsTheSharedScreen() {
        #expect(script.contains("gone(el, unit) || own(el) || cropped(el, unit)"))
        #expect(script.contains("data-layout') === 'roi-crop'"))
        #expect(script.contains("!!s.deviceId && !s.displaySurface"))
        #expect(script.contains("&& !camera(el)"))
    }

    @Test func aPickWaitsTwoSecondsAndIsDroppedWhenItStopsLeading() {
        #expect(script.contains("var hold = 2000"))
        #expect(script.contains("now - state.since < hold"))
        #expect(script.contains("state.dropped.push(kept.el, unit)"))
    }

    @Test func theFloatSaysWhyAndHowManyItFound() {
        #expect(script.contains("tell(lone);"))
        #expect(script.contains("setAttribute('data-broadway-tiles-screen', reason)"))
        #expect(script.contains("setAttribute('data-broadway-tiles-found', String(tiles.length))"))
    }

    @Test func controlsInTheGridAreHidden() {
        #expect(script.contains(":is(button, [role=button], [role=menu], [role=tooltip]):not(:has(video, canvas, [data-participant-id]))"))
    }

    @Test func landingForgetsThePickAndTheCount() {
        #expect(CallTiles.leave.contains("__broadwayCallPick = null"))
        #expect(CallTiles.leave.contains("removeAttribute('data-broadway-tiles-found')"))
    }
}
