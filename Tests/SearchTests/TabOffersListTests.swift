import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct TabOffersListTests {
    @Test func theCardKeepsSixPointsUnderItsLastRowAfterALayoutAtNoSize() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let offers = ["a", "b", "c"].map {
            Suggestion(key: "\($0).example", title: $0, url: URL(string: "https://\($0).example/")!, kind: .visited)
        }
        let list = TabOffersListView(browser: browser, width: 360, offers: offers, picked: 1)
        list.layoutSubtreeIfNeeded()

        let fitted = list.fittingSize
        list.frame = NSRect(origin: .zero, size: fitted)
        list.layoutSubtreeIfNeeded()

        let rows = rowFrames(in: list)
        let lowest = rows.map(\.minY).min() ?? 0
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.height == 34 })
        #expect(fitted.height == 114)
        #expect(lowest == 6)
    }

    private func rowFrames(in list: NSView) -> [NSRect] {
        var found: [NSRect] = []
        var queue = list.subviews
        while let view = queue.popLast() {
            if String(describing: type(of: view)) == "TabOfferRowView" { found.append(list.convert(view.bounds, from: view)) }
            queue += view.subviews
        }
        return found
    }
}
