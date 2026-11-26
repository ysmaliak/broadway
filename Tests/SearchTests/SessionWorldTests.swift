import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SessionWorldTests {
    private static var earlier: [Browser] = []

    private func fresh() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        addTeardownBlock { @MainActor in Self.leaveAMess(with: browser) }
        return browser
    }

    private static func leaveAMess(with browser: Browser) {
        browser.newTab()
        if let tab = browser.active {
            tab.restore(url: URL(string: "https://left.example/")!, title: "Left behind")
            browser.pin(tab)
        }
        browser.newTab()
        browser.active?.restore(url: URL(string: "https://loose.example/")!, title: "Loose")
        browser.writeSession(now: true)
        Session.write(now: true, browser.allRows()[Space.firstID.uuidString] ?? Session.Shape(tabs: [], active: 0))
        Spaces.write(Spaces.read() + [Space(id: UUID(), name: "Left", colour: 1)])
        Store.settings.set(UUID().uuidString, forKey: "space.current")
        earlier.append(browser)
    }

    private func expectClean(_ browser: Browser) {
        #expect(browser.tabs.count == 1)
        #expect(browser.tabs.allSatisfy { $0.pin == nil && $0.isBlank })
        #expect(browser.spaces.map(\.id) == [Space.firstID])
        #expect(browser.tabGroups.isEmpty)
        #expect(Pins.defs(Space.firstID).isEmpty)
        #expect(Pins.shared().isEmpty)
    }

    @Test func aBrowserStartsWithoutTheSessionAnEarlierTestLeft() {
        for browser in Self.earlier { browser.writeSession(now: true) }

        let browser = fresh()

        expectClean(browser)
    }

    @Test func aBrowserStartsWithoutThePinsAnEarlierTestLeft() {
        for browser in Self.earlier {
            browser.rememberSession()
            browser.flushSession()
        }

        let browser = fresh()

        expectClean(browser)
    }

    @Test func everySuiteThatMakesABrowserIsInTheSharedWorld() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        let makers = ["Browser(record:", "Browser()", "Browsers.newWindow(", "Browsers.newPrivateWindow("]

        let outside = try names.filter { name in
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            return makers.contains { text.contains($0) } && !text.contains(".sharedWorld")
        }

        #expect(outside.isEmpty, "suites making a Browser outside the shared world: \(outside.sorted())")
    }

    @Test func noSharedWorldSuiteHasATimeLimitItsWaitForTheWorldCanSpend() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        let short = try Regex(#"@Suite\([^\n]*\.sharedWorld[^\n]*\.timeLimit\(\.minutes\([1-4]\)\)|@Suite\([^\n]*\.timeLimit\(\.minutes\([1-4]\)\)[^\n]*\.sharedWorld"#)

        let hurried = try names.filter { name in
            try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8).contains(short)
        }

        #expect(hurried.isEmpty, """
        a time limit runs while a test queues for the shared world, so a limit under five minutes fails \
        a quick test late in a long shard: \(hurried.sorted())
        """)
    }
}
