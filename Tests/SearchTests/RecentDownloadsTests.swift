import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class RecentDownloadsTests {
    private func keep(_ name: String, _ date: Date) -> Keep {
        Keep(name: name, from: "", path: "/tmp/\(name)", date: date)
    }

    private func after(_ loot: Loot, _ seconds: TimeInterval) -> Date {
        max(loot.clearedAt, Date()).addingTimeInterval(seconds)
    }

    init() {
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        Store.settings.removeObject(forKey: "downloads.cleared")
    }

    @Test func clearingEmptiesRecentAndLeavesTheFullList() {
        let loot = Loot()
        let cleared = loot.kept.count
        loot.add(keep("recent-one.zip", after(loot, 3600)))
        #expect(loot.recent.contains { $0.name == "recent-one.zip" })

        loot.clearRecent(at: after(loot, 7200))

        #expect(loot.recent.isEmpty)
        #expect(loot.kept.count == (cleared + 1))
        loot.forget(loot.kept[0])
    }

    @Test func onlyTheNewestFewAreRecent() {
        let loot = Loot()
        let start = after(loot, 3600)

        for index in 0..<(Loot.recentRoom + 2) {
            loot.add(keep("recent-\(index).zip", start.addingTimeInterval(Double(index))))
        }

        #expect(loot.recent.count == Loot.recentRoom)
        #expect(loot.recent.first?.name == "recent-\(Loot.recentRoom + 1).zip")
        loot.recent.forEach(loot.forget)
        loot.kept.filter { $0.name.hasPrefix("recent-") }.forEach(loot.forget)
    }
}
