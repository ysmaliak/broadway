import AppKit
import Testing
import WebKit
@testable import Search

@MainActor
@Suite("Private windows", .sharedWorld, .timeLimit(.minutes(5)))
struct PrivateWindowTests {
    init() {
        setenv("SEARCH_PROBE", "private-window-\(getpid())", 1)
        _ = NSApplication.shared
    }

    private func quiet() -> Browser {
        Browser(record: WindowRecord(), privateStore: .nonPersistent())
    }

    @Test func twoFingersAcrossThePrivateColumnDoNotSwitchSpaces() {
        let browser = quiet()
        defer { browser.closeAll() }
        let swipe = SpaceSwipe.shared
        swipe.start(for: browser)

        let taken = swipe.take(SpaceSwipe.Scroll(phase: .began, dx: 40), over: true)
        let followed = swipe.take(SpaceSwipe.Scroll(phase: .changed, dx: 80), over: true)
        swipe.began()
        let driven = swipe.moved(dx: 120, dy: 0)
        swipe.ended(cancelled: true)

        #expect(!taken && !followed && !driven)
        #expect(browser.spaceNext == nil)
        #expect(!browser.spaceMotion.moving)
    }

    @Test func everyTabSharesTheWindowsOwnStore() throws {
        let browser = quiet()
        defer { browser.closeAll() }

        browser.open(URL(string: "https://a.example/")!, foreground: true)
        browser.open(URL(string: "https://b.example/")!, foreground: false)
        browser.newTab()

        let store = try #require(browser.privateStore)
        #expect(browser.tabs.count == 3)
        let allShy = browser.tabs.allSatisfy(\.shy)
        #expect(allShy)
        let shared = browser.tabs.allSatisfy { $0.store === store }
        #expect(shared)
        #expect(!store.isPersistent)
    }

    @Test func twoPrivateWindowsKeepApart() {
        let first = quiet(), second = quiet()
        defer { first.closeAll(); second.closeAll() }

        #expect(first.privateStore !== second.privateStore)
        #expect(first.active?.store !== second.active?.store)
    }

    @Test func aNormalWindowMakesNoPrivateTabs() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }

        browser.newTab()
        browser.open(URL(string: "https://a.example/")!, foreground: true)

        #expect(!browser.isPrivate)
        let kept = browser.tabs.allSatisfy { !$0.shy }
        #expect(kept)
    }

    @Test func nothingOfItIsWrittenDown() {
        let browser = quiet()
        defer { browser.closeAll() }
        browser.open(URL(string: "https://private.example/page")!, foreground: true)

        browser.writeSession(now: true)
        browser.takeFiles()

        #expect(!browser.usesFiles)
        #expect(browser.record.rows.isEmpty)
        #expect(browser.tabsInSession.isEmpty)
    }

    @Test func itShowsOnePlainSpaceWithoutPins() {
        let browser = quiet()
        defer { browser.closeAll() }

        #expect(browser.space.name == "Private")
        #expect(browser.space.look == SpaceLook.onyx)
        #expect(!browser.showsSpaces)
        #expect(!browser.stacked)
        let unpinned = browser.tabs.allSatisfy { $0.pin == nil }
        #expect(unpinned)
        #expect(browser.tabGroups.isEmpty)
    }

    @Test func itIsOnyxBlackInLightAndDark() {
        let look = SpaceLook.onyx

        let grounds = [true, false].map { look.ground(dark: $0) }

        #expect(Space.privateWindow.look == look)
        #expect(look == SpaceLook.themes.first { $0.id == "onyx" }?.look)
        #expect(grounds.allSatisfy { $0.stops.map(\.hex) == ["000000"] })
        #expect(look.inkLight(dark: true))
        #expect(look.inkLight(dark: false))
        let readable = grounds.allSatisfy { ground in
            Paint.contrast(ink: ground.lightInk ? Paint.lightInk : Paint.darkInk, alpha: Paint.title, on: ground.average) >= Paint.titleContrast
        }
        #expect(readable)
    }

    @Test func aTabStaysOnItsSideOfThePrivacyLine() {
        let normal = Browser(record: WindowRecord())
        let browser = quiet()
        defer { normal.closeAll(); browser.closeAll() }
        let tab = browser.open(URL(string: "https://private.example/")!, foreground: true)
        let count = normal.tabs.count

        browser.moveToWindow(tab, normal)

        #expect(normal.tabs.count == count)
        let stayed = browser.tabs.contains { $0.id == tab.id }
        #expect(stayed)
    }

    @Test func itsSidePanelTakesNoWebsite() {
        let browser = quiet()
        defer { browser.closeAll() }

        let shown = browser.showSiteInPanel(PanelSites.offered[0].url)

        #expect(!shown)
        #expect(!browser.sidePanelShown)
    }

    @Test func aVideoFloatsOnItsOwnOnlyOutsidePrivateWindows() {
        let quiet = quiet()
        let open = Browser(record: WindowRecord())
        let prefs = quiet.prefs
        let saved = prefs.floatsOnLeave
        prefs.floatsOnLeave = true
        defer {
            quiet.closeAll()
            open.closeAll()
            prefs.floatsOnLeave = saved
        }
        quiet.sightForBench = false

        quiet.leaving()
        quiet.judgeSight()

        #expect(!quiet.floatsOnItsOwn)
        #expect(open.floatsOnItsOwn)
        #expect(quiet.floating == nil)
        #expect(quiet.pictured == nil)
        #expect(!quiet.floater.showing)
    }

    @Test func theCommandIsNewPrivateWindowOnShiftCommandN() throws {
        let command = try #require(Command.named("file.newPrivateWindow"))

        #expect(command.title == "New Private Window")
        #expect(command.defaultKey == KeyCombo("n", shift: true))
        #expect(Command.named("file.newPrivateTab") == nil)
    }
}
