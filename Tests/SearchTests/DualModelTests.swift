import AppKit
import Combine
import Testing
@testable import Search

private final class Reader: NSView {
    let read: () -> Any
    var layouts = 0

    init(_ read: @escaping () -> Any) {
        self.read = read
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        _ = read()
        layouts += 1
    }
}

@MainActor
private final class Watch {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
    let reader: Reader

    init(read: @escaping () -> Any) {
        reader = Reader(read)
        let root = NSView(frame: window.contentLayoutRect)
        root.addSubview(reader)
        window.contentView = root
        window.layoutIfNeeded()
    }

    var invalidated: Bool { reader.needsLayout }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct DualModelTests {
    init() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    private func turn() async {
        for _ in 0..<3 { await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } } }
    }

    @Test func aPropertyInvalidatesOnlyItsReadersAndIsHeardAfterItIsStored() async {
        let tab = Tab()
        let failure = Watch { tab.failure as Any }
        let other = Watch { tab.muted }
        var heard: [String?] = []
        var stored: [String?] = []
        let watch = kitObserve(initial: false, { tab.failure }) { value in
            heard.append(value)
            stored.append(tab.failure)
        }

        tab.failure = "gone"
        let invalidated = failure.invalidated
        let otherInvalidated = other.invalidated
        await turn()

        #expect(invalidated)
        #expect(!otherInvalidated)
        #expect(heard == ["gone"])
        #expect(stored == ["gone"])
        _ = watch
    }

    @Test func anIgnoredPropertyIsNotTracked() {
        let tab = Tab()
        let quiet = Watch { tab.popup }

        tab.popup = true

        #expect(!quiet.invalidated)
    }

    @Test func aPreferenceIsTracked() async {
        let prefs = Shared.prefs
        let saved = prefs.showsTabShortcuts
        let watch = Watch { prefs.showsTabShortcuts }
        var heard: [Bool] = []
        let bag = kitObserve(initial: false, { prefs.showsTabShortcuts }) { heard.append($0) }

        prefs.showsTabShortcuts = !saved
        let invalidated = watch.invalidated
        await turn()

        #expect(invalidated)
        #expect(heard == [!saved])
        prefs.showsTabShortcuts = saved
        _ = bag
    }

    @Test func duskHeardMovesWhatItTells() {
        let dusk = Dusk.shared
        let watch = Watch { dusk.told }

        dusk.heard()

        #expect(watch.invalidated)
    }

    @Test func siteNotificationsChangesAreTracked() {
        let notifications = SiteNotifications.shared
        let watch = Watch { notifications.revision }

        SiteNotifications.forget("https://dual.example")

        #expect(watch.invalidated)
    }

    @Test func historyVisitsAreTracked() throws {
        let history = Shared.history
        let url = try #require(URL(string: "https://dual-history.example/page"))
        history.record(url, title: "Before")
        let watch = Watch { history.revision }

        history.retitle(url, "After")

        #expect(watch.invalidated)
        history.forget(History.identity(for: url))
    }

    @Test func aPausedSiteIsTracked() {
        let shield = Shield.shared
        let host = "dual-shield.example"
        let watch = Watch { shield.isPaused(on: host) }

        shield.pause(host, true)

        #expect(watch.invalidated)
        shield.pause(host, false)
    }

    @Test func forgettingACaptureGrantIsTracked() {
        let watch = Watch { ExtensionCapture.allowedIDs }

        ExtensionCapture.forget("dual-capture")

        #expect(watch.invalidated)
    }

    @Test func browsersDrawnAgainBumpsTheRevision() {
        let browser = Browser(record: WindowRecord())
        let watch = Watch { browser.revision }
        let before = browser.revision

        browser.pinsChanged(in: browser.spaceID)

        #expect(browser.revision != before)
        #expect(watch.invalidated)
        browser.closeAll()
    }

    @Test func aBrowserIsNotDrawnAgainForItsSources() {
        let browser = Browser(record: WindowRecord())
        let watch = Watch { browser.revision }

        Dusk.shared.heard()

        #expect(!watch.invalidated)
        browser.closeAll()
    }
}
