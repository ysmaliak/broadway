import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct HintsSettingTests {
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
        for _ in 0..<10 { await Task.yield() }
    }

    private func page(_ number: Int) -> URL { URL(string: "http://127.0.0.1:9/page-\(number)")! }

    private func line(_ id: HintID) throws -> String {
        try #require(id.line(key: id.command.flatMap { ShortcutStore.shared.key(for: $0) }))
    }

    private func fresh(pages: Int = 1, hints: Bool = true) -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        keepSetting(prefs, \.hints, Preferences.hintsKey)
        keepSetting(prefs, \.newTabPlace, "tabs.newPlace")
        keepSetting(prefs, \.splitView)
        prefs.hints = hints
        prefs.newTabPlace = .end
        prefs.splitView = true
        HintBook.shared.forget()
        HintClock.advance(Hints.afterStart + 24 * 60 * 60)
        let browser = Browser(record: WindowRecord())
        for number in 0..<pages {
            if number > 0 { browser.newTab() }
            browser.tabs.last?.restore(url: page(number), title: "Page \(number)")
        }
        _ = browser.hints
        addTeardownBlock {
            browser.closeAll()
            HintClock.rewind()
            HintBook.shared.forget()
        }
        return browser
    }

    @Test("Hints is on unless turned off, and remembered")
    func onUnlessTurnedOff() {
        let prefs = Shared.prefs
        keepSetting(prefs, \.hints, Preferences.hintsKey)
        Store.settings.removeObject(forKey: Preferences.hintsKey)

        let first = Preferences().hints
        prefs.hints = false

        #expect(first)
        #expect(Store.settings.object(forKey: Preferences.hintsKey) as? Bool == false)
        #expect(!Preferences().hints)
    }

    @Test("Hints is a switch in Settings › General that Find a setting and broadway settings reach")
    func foundAndSet() throws {
        let prefs = Shared.prefs
        keepSetting(prefs, \.hints, Preferences.hintsKey)
        prefs.hints = true
        let item = try #require(SettingsIndex.item(Preferences.hintsKey))

        #expect(item.title == "Hints")
        #expect(item.detail == "A line now and then when there is a faster way")
        #expect(item.page == .general && item.kind == .control && !item.findOnly)
        for words in ["hints", "tips", "faster way"] {
            #expect(SettingsIndex.find(words).contains { $0.id == Preferences.hintsKey }, "\(words)")
        }
        #expect(SettingsIndex.apply(Preferences.hintsKey, false, to: prefs))
        #expect(SettingsIndex.values(prefs)[Preferences.hintsKey] as? Bool == false)
        #expect(PersonSettings.refusal(Preferences.hintsKey, value: "true") == nil)
        #expect(PersonSettings.table[Preferences.hintsKey]?.write?(prefs, "true") == true)
        #expect(prefs.hints)
    }

    @Test("Keyboard Shortcuts still comes first when looking for keys")
    func keysStillLeadToShortcuts() {
        for words in ["keyboard shortcuts", "shortcuts"] {
            #expect(SettingsIndex.find(words).first?.id != Preferences.hintsKey, "\(words)")
        }
    }

    @Test("a due hint is announced as its line alone and a click sends it away")
    func shownThroughAnnounce() async throws {
        let browser = fresh()

        for _ in 0..<3 { browser.hints.closedByPointer() }
        await settle()

        #expect(browser.announcement == (try line(.close)))
        #expect(HintBook.shared.record.shown == [.close])

        browser.hints.pressed()

        #expect(browser.announcement == nil)
    }

    @Test("with Hints off nothing is counted and nothing is shown")
    func offCountsNothing() async {
        let browser = fresh(hints: false)

        for _ in 0..<3 { browser.hints.closedByPointer() }
        browser.hints.used("file.reopen")
        await settle()

        #expect(browser.hints.trail.pointerCloses.isEmpty)
        #expect(browser.announcement == nil)
        #expect(HintBook.shared.record == HintRecord())
    }

    @Test("a click on any other line leaves it to go on its own time")
    func otherLinesStay() {
        let browser = fresh()
        browser.announce("Copied")

        browser.hints.pressed()

        #expect(browser.announcement == "Copied")
    }

    @Test("a tab closed and its address typed again soon after brings the reopen line")
    func typedAfterClose() async throws {
        let browser = fresh(pages: 2)
        let tabs = browser.tabs
        browser.select(tabs[0])
        await settle()

        browser.close(tabs[1])
        await settle()
        browser.hints.typed(page(1))
        await settle()

        #expect(browser.announcement == (try line(.reopen)))
    }

    @Test("bringing a closed tab back is not counted as closing one")
    func reopenIsNotAClose() async {
        let browser = fresh(pages: 3)
        let tabs = browser.tabs
        browser.select(tabs[0])
        await settle()
        browser.close(tabs[2])
        await settle()
        browser.close(tabs[1])
        await settle()
        HintClock.advance(Hints.reopenWithin + 10)

        browser.reopen()
        await settle()
        browser.hints.typed(page(2))
        await settle()

        #expect(HintBook.shared.record.shown.isEmpty)
    }

    @Test("the clean line waits for the copy's own line to go, then shows")
    func cleanWaitsForTheCopyLine() async throws {
        let browser = fresh()
        browser.announce("Copied")

        browser.hints.copied(URL(string: "http://127.0.0.1:9/notes?id=2&utm_source=letter")!)
        await settle()

        #expect(browser.announcement == "Copied")

        browser.dismissAnnounced()
        await settle()

        #expect(browser.announcement == (try line(.clean)))
    }

    @Test("an address copied without tracking says nothing")
    func cleanAddressSaysNothing() async {
        let browser = fresh()

        browser.hints.copied(URL(string: "http://127.0.0.1:9/notes?id=2")!)
        await settle()

        #expect(browser.announcement == nil)
    }

    @Test("going back and forth between two tabs brings the split line")
    func backAndForth() async throws {
        let browser = fresh(pages: 2)
        let tabs = browser.tabs

        for step in 0..<7 {
            browser.select(tabs[step % 2])
            await settle()
        }

        #expect(browser.announcement == (try line(.split)))
    }

    @Test("three presses of Find's next arrow bring the next line, and a new search starts again")
    func findNext() async throws {
        let browser = fresh()

        browser.hints.findNextPressed()
        browser.hints.findNextPressed()
        browser.hints.searchChanged()
        browser.hints.findNextPressed()
        browser.hints.findNextPressed()
        await settle()

        #expect(browser.announcement == nil)

        browser.hints.findNextPressed()
        await settle()

        #expect(browser.announcement == (try line(.next)))
    }

    @Test("a fast way used once means that hint never comes")
    func usedNeverComes() async {
        let browser = fresh()

        browser.hints.used("file.closeTab")
        for _ in 0..<3 { browser.hints.closedByPointer() }
        await settle()

        #expect(browser.announcement == nil)
        #expect(HintBook.shared.record.used == [.close])
    }
}
