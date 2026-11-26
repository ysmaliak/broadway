import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct LongLifeLeakTests {
    private func browser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        return Browser(record: WindowRecord())
    }

    @Test func aClosedTabLeavesNoObserversBehind() {
        let browser = browser()
        defer { browser.closeAll() }
        let tab = browser.open(URL(string: "https://example.com/1")!, foreground: false)
        #expect(tab.watchers.count == 4)

        browser.close(tab)

        #expect(tab.watchers.isEmpty)
    }

    @Test func aTabMovedToAnotherWindowIsWatchedOnlyByThatWindow() {
        let from = browser(), to = browser()
        defer {
            from.closeAll()
            to.closeAll()
        }
        from.newTab()
        let tab = from.open(URL(string: "https://example.com/2")!, foreground: false)
        let before = tab.watchers.map(ObjectIdentifier.init)

        from.moveToWindow(tab, to)

        #expect(tab.watchers.count == 4)
        #expect(Set(tab.watchers.map(ObjectIdentifier.init)).isDisjoint(with: before))
    }

    @Test func aClosedWindowStopsItsSleepTimerAndMemoryWatch() {
        let browser = browser()
        browser.watchForSleep()
        let timer = browser.dozing
        let source = browser.pressure
        #expect(timer?.isValid == true)

        browser.closeAll()

        #expect(timer?.isValid == false)
        #expect(source?.isCancelled == true)
        #expect(browser.dozing == nil)
        #expect(browser.pressure == nil)
    }

    @Test func printCancelsOfTabsNoLongerOpenAreLetGo() {
        let gone = UUID(), here = UUID()
        PrintSheet.note(PrintSheet.Cancels(site: "https://shop.example:"), for: gone)
        PrintSheet.note(PrintSheet.Cancels(site: "https://shop.example:"), for: here)

        #expect(PrintSheet.cancelled[gone] == nil)
        #expect(PrintSheet.cancelled[here] != nil)
    }
}
