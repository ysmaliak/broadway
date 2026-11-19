import AppKit
import QuartzCore
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class HelmFadeTests {
    private var browser: Browser!
    private var window: NSWindow!
    private var helm: HelmView!
    private var work = UUID()
    private var home = UUID()
    private var source: Tab!
    private var child: Tab!
    private var other: Tab!
    private var blank: Tab!

    init() {
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        keepSetting(Shared.prefs, \.splitView, "splitView")
        keepSettings("motion.testReduced", "motion.testLowPower")
        Store.settings.set(false, forKey: "motion.testReduced")
        Store.settings.set(false, forKey: "motion.testLowPower")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.closeAll()
        browser.prefs.usesSpaces = true
        browser.prefs.splitView = false
        work = browser.spaceID
        browser.spaces = [Space(id: work, name: "Work", colour: 0, icon: TabIcon(emoji: "💼")),
                          Space(id: home, name: "Home", colour: 1, icon: TabIcon(emoji: "🏠"))]
        source = page("Source", in: work)
        child = page("Child", in: work)
        child.opener = source.id
        other = page("Other", in: home)
        blank = Tab(configuration: Web.configuration(space: home))
        blank.space = home
        browser.switchSpace(to: work)
        browser.showRow([source, child], active: child.id)
        browser.switchSpace(to: home)
        browser.showRow([other, blank], active: blank.id)
        browser.switchSpace(to: work)
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 240, height: 40),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        helm = HelmView(browser: browser)
        helm.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        window.contentView = helm
        helm.layoutSubtreeIfNeeded()
    }

    private func tearDown() {
        window?.contentView = nil
        window?.close()
        browser?.switchSpace(to: work)
        browser?.closeAll()
        browser = nil
    }

    private func page(_ name: String, in space: UUID) -> Tab {
        let tab = Tab(configuration: Web.configuration(space: space))
        tab.space = space
        tab.restore(url: URL(string: "about:blank#\(name)")!, title: name)
        return tab
    }

    private func door(_ icon: String) throws -> DoorView {
        try #require(helm.kitSubviews(of: DoorView.self).first { $0.icon == icon })
    }

    private func reload() throws -> ReloadDoorView {
        try #require(helm.kitSubviews(of: ReloadDoorView.self).first)
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        CATransaction.flush()
    }

    private func fade(_ view: NSView) -> (from: Swift.Float, to: Swift.Float)? {
        guard let fade = view.layer?.animation(forKey: "lit") as? CABasicAnimation,
              let from = fade.fromValue as? Swift.Float, let to = fade.toValue as? Swift.Float else { return nil }
        return (from, to)
    }

    private func near(_ value: Swift.Float?, _ wanted: Swift.Float) -> Bool {
        guard let value else { return false }
        return abs(value - wanted) < 0.001
    }

    private func clear(_ views: [NSView]) {
        for view in views { view.layer?.removeAllAnimations() }
    }

    @Test func aSpaceSwitchToATabWithoutHistoryFadesBackDown() async throws {
        await settle()
        let back = try door("arrow.left")
        #expect(near(back.layer?.opacity, 1))
        clear([back])

        browser.switchSpace(to: home)
        await settle()

        let seen = try #require(fade(back))
        #expect(near(seen.from, 1))
        #expect(near(seen.to, 0.3))
        #expect(near(back.layer?.opacity, 0.3))
        #expect(near(Swift.Float(back.alphaValue), 0.3))
    }

    @Test func aSpaceSwitchToATabWithHistoryFadesBackUp() async throws {
        browser.switchSpace(to: home)
        await settle()
        let back = try door("arrow.left")
        #expect(near(back.layer?.opacity, 0.3))
        clear([back])

        browser.switchSpace(to: work)
        await settle()

        let seen = try #require(fade(back))
        #expect(near(seen.from, 0.3))
        #expect(near(seen.to, 1))
        #expect(near(back.layer?.opacity, 1))
        #expect(near(Swift.Float(back.alphaValue), 1))
    }

    @Test func reloadFadesWithTheSwitch() async throws {
        await settle()
        let reload = try reload()
        #expect(near(reload.layer?.opacity, 1))
        clear([reload])

        browser.switchSpace(to: home)
        await settle()

        let down = try #require(fade(reload))
        #expect(near(down.from, 1))
        #expect(near(down.to, 0.3))
        clear([reload])

        browser.switchSpace(to: work)
        await settle()

        let up = try #require(fade(reload))
        #expect(near(up.from, 0.3))
        #expect(near(up.to, 1))
    }

    @Test func aTabSwitchWithinASpaceFadesToo() async throws {
        await settle()
        let back = try door("arrow.left")
        clear([back])

        browser.select(source)
        await settle()

        let seen = try #require(fade(back))
        #expect(near(seen.from, 1))
        #expect(near(seen.to, 0.3))
    }

    @Test func aFadeUnderWayIsTakenUpFromWhereItIs() async throws {
        await settle()
        let back = try door("arrow.left")
        let layer = try #require(back.layer)
        layer.speed = 0.1

        browser.switchSpace(to: home)
        await settle()
        try await Task.sleep(for: .milliseconds(50))
        let midway = try #require(layer.presentation()?.opacity)
        #expect(midway < 1 && midway > 0.3)

        browser.switchSpace(to: work)
        await settle()

        let seen = try #require(fade(back))
        #expect(seen.from < 1 && seen.from > 0.3)
        #expect(seen.from <= midway + 0.0001)
        #expect(near(seen.to, 1))
    }

    @Test func reduceMotionSetsTheKeysAtOnce() async throws {
        Store.settings.set(true, forKey: "motion.testReduced")
        await settle()
        let back = try door("arrow.left")
        let reload = try reload()
        clear([back, reload])

        browser.switchSpace(to: home)
        await settle()

        #expect(back.layer?.animation(forKey: "lit") == nil)
        #expect(reload.layer?.animation(forKey: "lit") == nil)
        #expect(near(back.layer?.opacity, 0.3))
        #expect(near(reload.layer?.opacity, 0.3))
    }

    @Test func theKeysFadeAsSoonAsASlideHeadsForTheOtherSpace() async throws {
        browser.switchSpace(to: home)
        await settle()
        let back = try door("arrow.left")
        let reload = try reload()
        clear([back, reload])

        browser.spaceNeighbour.heading = 0
        await settle()

        let up = try #require(fade(back))
        #expect(near(up.from, 0.3))
        #expect(near(up.to, 1))
        #expect(near(fade(reload)?.to, 1))
        #expect(helm.hitTest(helm.convert(NSPoint(x: back.frame.midX, y: back.frame.midY), to: helm.superview)) == nil)
        clear([back, reload])

        browser.switchSpace(to: work)
        browser.spaceNeighbour.heading = nil
        await settle()

        #expect(fade(back) == nil)
        #expect(fade(reload) == nil)
        #expect(near(back.layer?.opacity, 1))
        #expect(helm.hitTest(helm.convert(NSPoint(x: back.frame.midX, y: back.frame.midY), to: helm.superview)) != nil)
    }

    @Test func aSlideThatTurnsBackFadesBackFromWhereItIs() async throws {
        await settle()
        let back = try door("arrow.left")
        clear([back])

        browser.spaceNeighbour.heading = 1
        await settle()
        #expect(near(fade(back)?.to, 0.3))

        browser.spaceNeighbour.heading = nil
        await settle()

        let seen = try #require(fade(back))
        #expect(near(seen.to, 1))
        #expect(near(back.layer?.opacity, 1))
        #expect(browser.spaceID == work)
    }

    @Test func aSlideTowardsANewSpaceDimsAllThree() async throws {
        await settle()
        let keys: [NSView] = [try door("arrow.left"), try door("arrow.right"), try reload()]
        browser.spaceNeighbour.heading = browser.spaces.count
        await settle()

        for key in keys { #expect(near(key.layer?.opacity, 0.3)) }
        browser.spaceNeighbour.heading = nil
    }

    @Test func aSlideCaughtOnTheOtherSpaceShowsThatSpacesKeys() async throws {
        await settle()
        let back = try door("arrow.left")
        clear([back])

        browser.spaceShown = 1
        await settle()

        #expect(near(fade(back)?.to, 0.3))
        #expect(browser.spaceID == work)
        browser.spaceShown = nil
        await settle()
        #expect(near(back.layer?.opacity, 1))
    }
}
