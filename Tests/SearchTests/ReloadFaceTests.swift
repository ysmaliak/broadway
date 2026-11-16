import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ReloadFaceTests {
    @Test func idleShowsReloadAndAPressReloads() {
        let face = ReloadFace(loading: false)

        let press = face.press

        #expect(face.phase == .idle)
        #expect(face.symbol == "arrow.clockwise")
        #expect(face.label == "Reload")
        #expect(press == .reload)
    }

    @Test func aLoadJustStartedKeepsTheArrowAndAPressReloadsAgain() {
        var face = ReloadFace(loading: false)

        face.see(loading: true, reloads: 0, stops: 0)

        #expect(face.phase == .starting)
        #expect(face.symbol == "arrow.clockwise")
        #expect(face.label == "Reload")
        #expect(face.press == .reload)
    }

    @Test func aLoadStillGoingAfterTheGraceShowsStopAndAPressStops() {
        var face = ReloadFace(loading: false)
        face.see(loading: true, reloads: 0, stops: 0)

        face.waited()

        #expect(face.phase == .loading)
        #expect(face.symbol == "xmark")
        #expect(face.label == "Stop")
        #expect(face.press == .stop)
    }

    @Test func aQuickLoadThatLandsInsideTheGraceNeverShowsStop() {
        var face = ReloadFace(loading: false)
        face.see(loading: true, reloads: 1, stops: 0)

        face.see(loading: false, reloads: 1, stops: 0)
        face.waited()

        #expect(face.phase == .idle)
        #expect(!face.showsStop)
    }

    @Test func aLoadThatLandsTurnsStopBackIntoReload() {
        var face = ReloadFace(loading: true)

        face.see(loading: false, reloads: 0, stops: 0)

        #expect(face.phase == .idle)
        #expect(face.symbol == "arrow.clockwise")
        #expect(face.press == .reload)
    }

    @Test func aStoppedLoadShowsReloadAndAPressReloads() {
        var face = ReloadFace(loading: true)

        face.see(loading: true, reloads: 0, stops: 1)

        #expect(face.phase == .stopped)
        #expect(face.symbol == "arrow.clockwise")
        #expect(face.label == "Reload")
        #expect(face.press == .reload)
    }

    @Test func aStoppedLoadStaysStoppedWhenTheLoadEnds() {
        var face = ReloadFace(loading: true)
        face.see(loading: true, reloads: 0, stops: 1)

        face.see(loading: false, reloads: 0, stops: 1)
        face.waited()

        #expect(face.phase == .stopped)
        #expect(!face.showsStop)
    }

    @Test func aNewLoadAfterAStopStartsAgain() {
        var face = ReloadFace(loading: true)
        face.see(loading: false, reloads: 0, stops: 1)

        face.see(loading: true, reloads: 1, stops: 1)

        #expect(face.phase == .starting)
    }

    @Test func reloadingWhileStopShowsTurnsBackToTheArrow() {
        var face = ReloadFace(loading: true, reloads: 3)

        face.see(loading: true, reloads: 4, stops: 0)

        #expect(face.phase == .starting)
        #expect(face.symbol == "arrow.clockwise")
    }

    @Test func aTabThatIsAlreadyLoadingShowsStopAtOnce() {
        let face = ReloadFace(loading: true, reloads: 7, stops: 2)

        let press = face.press

        #expect(face.phase == .loading)
        #expect(face.symbol == "xmark")
        #expect(press == .stop)
    }

    @Test func theGraceDoesNothingWhenNoLoadIsStarting() {
        var idle = ReloadFace(loading: false)
        var loading = ReloadFace(loading: true)

        idle.waited()
        loading.waited()

        #expect(idle.phase == .idle)
        #expect(loading.phase == .loading)
    }

    @Test func countsCarriedInFromTheTabAreNotAPress() {
        var face = ReloadFace(loading: false, reloads: 5, stops: 2)

        face.see(loading: false, reloads: 5, stops: 2)

        #expect(face.phase == .idle)
    }
}
