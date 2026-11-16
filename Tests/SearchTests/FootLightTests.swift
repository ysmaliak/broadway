import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FootLightTests {
    @Test func atRestOnlyTheSpaceOnScreenIsLit() {
        let here = FootLight(here: true, next: false, going: false, progress: 0)
        let other = FootLight(here: false, next: false, going: false, progress: 0)

        let lit = (here.lit, other.lit)

        #expect(lit.0 == 1)
        #expect(lit.1 == 0)
    }

    @Test func theLightPassesFromOneDotToTheNextWithTheProgress() {
        for step in 0...10 {
            let progress = CGFloat(step) / 10

            let leaving = FootLight(here: true, next: false, going: true, progress: progress)
            let coming = FootLight(here: false, next: true, going: true, progress: progress)

            #expect(abs((leaving.lit + coming.lit) - 1) <= 0.0001)
            #expect(abs(coming.lit - progress) <= 0.0001)
        }
    }

    @Test func everyPropertyFollowsTheLightWithoutSteps() {
        let samples = (0...100).map { FootLight(here: false, next: true, going: true, progress: CGFloat($0) / 100) }

        let pairs = zip(samples, samples.dropFirst())

        for (a, b) in pairs {
            #expect(abs(a.scale - b.scale) <= 0.001)
            #expect(abs(a.saturation - b.saturation) <= 0.0101)
            #expect(abs(a.ink - b.ink) <= 0.0101)
            #expect(abs(a.opacity(hovering: false) - b.opacity(hovering: false)) <= 0.005)
        }
    }

    @Test func landingHandsOverWhereTheSlideLeftIt() {
        let width: CGFloat = 240
        let handover = 1 - 2.5 / width

        let comingBefore = FootLight(here: false, next: true, going: true, progress: handover)
        let landed = FootLight(here: true, next: false, going: false, progress: 0)
        let leavingBefore = FootLight(here: true, next: false, going: true, progress: handover)
        let left = FootLight(here: false, next: false, going: false, progress: 0)

        #expect(abs(comingBefore.lit - landed.lit) <= 0.011)
        #expect(abs(leavingBefore.lit - left.lit) <= 0.011)
    }

    @Test func aRubberBandAtTheEndLeavesTheDotLit() {
        let progress: CGFloat = 0.1

        let here = FootLight(here: true, next: false, going: false, progress: progress)

        #expect(here.lit == 1)
    }

    @Test func theFootIconsSitBetweenTheirLooksInProportionToTheSwipe() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let prefs = browser.prefs
        let previous = (prefs.usesSpaces, prefs.stackedSpaces)
        (prefs.usesSpaces, prefs.stackedSpaces) = (true, false)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 280, height: SpaceFootView.height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        defer {
            browser.spaceMotion.rest()
            browser.spaceNext = nil
            window.contentView = nil
            window.close()
            browser.closeAll()
            (prefs.usesSpaces, prefs.stackedSpaces) = previous
            NSApp.setActivationPolicy(policy)
        }
        let first = browser.spaceID
        browser.addSpace(named: "Second")
        try await until("the second space is on screen") { browser.spaceID != first }
        let foot = SpaceFootView(browser: browser)
        window.contentView = foot
        window.orderFrontRegardless()
        foot.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        try await until("the foot is at rest") { !foot.needsLayout && !window.viewsNeedDisplay }
        func light(_ id: UUID) -> SpaceLitView? {
            foot.kitSubviews(of: SpaceSpotView.self).first { $0.accessibilityIdentifier() == "space-" + id.uuidString }?
                .kitSubviews(of: SpaceLitView.self).first
        }
        func opacity(_ view: SpaceLitView) -> CGFloat { CGFloat(view.content.layer?.opacity ?? -1) }
        func saturation(_ view: SpaceLitView) -> CGFloat {
            view.content.layer?.value(forKeyPath: "filters.saturate.inputSaturation") as? CGFloat ?? 1
        }
        let second = browser.spaceID
        let target = try #require(browser.spaces.firstIndex { $0.id == first })
        _ = try #require(light(first))
        _ = try #require(light(second))
        let width: CGFloat = 240
        let progress: CGFloat = 0.3

        browser.spaceNext = target
        browser.spaceMotion.follow(progress * width, width: width)
        try await until("the foot follows the swipe") { light(first).map { abs(saturation($0) - progress) <= 0.01 } ?? false }

        let coming = try #require(light(first)), leaving = try #require(light(second))
        let comingLook = FootLight(here: false, next: true, going: true, progress: progress)
        let leavingLook = FootLight(here: true, next: false, going: true, progress: progress)
        #expect(abs(saturation(coming) - comingLook.saturation) <= 0.01)
        #expect(abs(saturation(leaving) - leavingLook.saturation) <= 0.01)
        #expect(abs(opacity(coming) - comingLook.opacity(hovering: false)) <= 0.01)
        #expect(abs(opacity(leaving) - leavingLook.opacity(hovering: false)) <= 0.01)
        #expect(abs((coming.layer?.sublayerTransform.m11 ?? 0) - comingLook.scale) <= 0.001)
        #expect(abs((leaving.layer?.sublayerTransform.m11 ?? 0) - leavingLook.scale) <= 0.001)
    }

    private func until(_ what: String, within seconds: TimeInterval = 5, sourceLocation: SourceLocation = #_sourceLocation,
                       _ done: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !done() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("timed out: \(what)", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
