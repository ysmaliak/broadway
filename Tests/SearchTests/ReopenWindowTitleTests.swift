import Foundation
import Testing
@testable import Search

@Suite
@MainActor
struct ReopenWindowTitleTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func aWindowClosedAfterTheLastTabIsWhatReopenBringsBack() {
        #expect(Browser.reopensWindow(closedWindow: now, closedTab: now.addingTimeInterval(-5)))
        #expect(Browser.reopensWindow(closedWindow: now, closedTab: nil))
    }

    @Test func aTabClosedAfterTheLastWindowIsWhatReopenBringsBack() {
        #expect(!Browser.reopensWindow(closedWindow: now, closedTab: now.addingTimeInterval(5)))
        #expect(!Browser.reopensWindow(closedWindow: nil, closedTab: now))
        #expect(!Browser.reopensWindow(closedWindow: nil, closedTab: nil))
    }

    @Test func aClosedWindowIsListedByItsCountOfTabsLeavingPinsOut() {
        func entry(_ path: String, pin: String? = nil) -> Session.Entry {
            Session.Entry(url: "https://example.com/" + path, title: path, pin: pin)
        }
        var record = WindowRecord()
        record.rows = ["a": Session.Shape(tabs: [entry("1"), entry("2"), entry("p", pin: "P")], active: 0),
                       "b": Session.Shape(tabs: [entry("3")], active: 0)]
        #expect(Browsers.closedTitle(record) == "Window with 3 Tabs")
        record.rows = ["a": Session.Shape(tabs: [entry("1")], active: 0)]
        #expect(Browsers.closedTitle(record) == "Window with 1 Tab")
        record.rows = ["a": Session.Shape(tabs: [entry("p", pin: "P")], active: 0)]
        #expect(Browsers.tabCount(record) == 0)
    }
}
