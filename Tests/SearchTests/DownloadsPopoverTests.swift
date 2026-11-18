import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class DownloadsPopoverTests {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    init() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    private func rows(_ list: RecentDownloadsView, until done: ([[String: Any]]) -> Bool) async -> [[String: Any]] {
        for _ in 0..<100 {
            let found = list.benchRows()
            if done(found) { return found }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return list.benchRows()
    }

    private func placed(door: CGRect, width: CGFloat = 340) -> (tip: CGFloat, body: (minX: CGFloat, maxX: CGFloat)) {
        let tip = DownloadsLayerView.aim(door: door, screen: screen)
        return (tip, DownloadsLayerView.body(aim: tip, width: width, screen: screen))
    }

    private func clearOfCorners(_ placed: (tip: CGFloat, body: (minX: CGFloat, maxX: CGFloat))) -> Bool {
        let least = DownloadsLayerView.corner + DownloadsLayerView.pointerHalf
        return placed.tip - placed.body.minX >= least && placed.body.maxX - placed.tip >= least
    }

    @Test func opensAboveAButtonAtTheFootOfTheSidebar() {
        let window = CGRect(x: 300, y: 200, width: 1100, height: 720)
        let left = CGRect(x: 312, y: 207, width: 26, height: 26)
        let right = CGRect(x: 1362, y: 207, width: 26, height: 26)
        let aboveLeft = DownloadsLayerView.opensAbove(door: left, window: window)
        let aboveRight = DownloadsLayerView.opensAbove(door: right, window: window)
        #expect(aboveLeft)
        #expect(aboveRight)
    }

    @Test func thePointerIsOverTheButtonAndClearOfBothCorners() {
        let doors = [
            CGRect(x: 312, y: 207, width: 26, height: 26),
            CGRect(x: 1362, y: 207, width: 26, height: 26),
            CGRect(x: 316, y: 211, width: 26, height: 26),
            CGRect(x: 1080, y: 207, width: 26, height: 26),
        ]
        for door in doors {
            let found = placed(door: door)
            #expect(found.tip >= door.minX && found.tip <= door.maxX)
            #expect(found.tip == door.midX)
            #expect(clearOfCorners(found))
        }
    }

    @Test func onADisplaysEdgeThePointerMovesInJustFarEnoughToClearTheCorner() {
        let door = CGRect(x: 8, y: 7, width: 26, height: 26)
        let found = placed(door: door)
        #expect(clearOfCorners(found))
        #expect(found.body.minX == screen.minX + DownloadsLayerView.screenInset)
        #expect(found.tip > door.maxX)
        #expect(found.tip - door.maxX <= 12)
    }

    @Test func onTheRightDisplayEdgeTheBodyReachesLeftAndThePointerStaysOverTheButton() {
        let door = CGRect(x: 1440, y: 11, width: 26, height: 26)
        let found = placed(door: door)
        #expect(found.tip == door.midX)
        #expect(found.body.maxX == screen.maxX - DownloadsLayerView.screenInset)
        #expect(clearOfCorners(found))
    }

    @Test func aLongListGrowsUpwardOnlyAsFarAsTheWindowsTop() {
        let window = CGRect(x: 300, y: 200, width: 1100, height: 720)
        let door = CGRect(x: 312, y: 207, width: 26, height: 26)
        let room = DownloadsLayerView.room(door: door, window: window, screen: screen, above: true)
        #expect(room == window.maxY - PopupLook.margin - door.maxY - DownloadsLayerView.pointer)
        #expect(door.maxY + DownloadsLayerView.pointer + room <= window.maxY)
    }

    @Test func theSmallestWindowStillLeavesTheListRoomAboveTheButton() {
        let window = CGRect(x: 300, y: 200, width: 640, height: 420)
        let door = CGRect(x: 312, y: 207, width: 26, height: 26)
        let room = DownloadsLayerView.room(door: door, window: window, screen: screen, above: true)
        let found = placed(door: door)
        #expect(room >= DownloadsLayerView.leastRoom)
        #expect(door.maxY + DownloadsLayerView.pointer + room <= window.maxY)
        #expect(clearOfCorners(found))
    }

    @Test func aRowOffersTheControlsItsStateAllows() {
        let running = FetchEntry.bench("a.zip", .downloading, done: 10, total: 100)
        let pausing = FetchEntry.bench("b.zip", .pausing, done: 10, total: 100)
        let paused = FetchEntry.bench("c.zip", .paused, done: 10, total: 100)
        let failed = FetchEntry.bench("d.zip", .failed, done: 10, total: 100, error: "The network connection was lost.")

        #expect(running.verbs == [.pause, .cancel])
        #expect(pausing.verbs == [.cancel])
        #expect(paused.verbs == [.resume, .remove])
        #expect(failed.verbs == [.retry, .remove])
    }

    @Test func aRowSaysWhereItsDownloadStands() {
        let sized = FetchEntry.bench("a.zip", .downloading, done: 1_000_000, total: 4_000_000)
        let unsized = FetchEntry.bench("b.mov", .downloading, done: 1_000_000, total: 0)
        let paused = FetchEntry.bench("c.zip", .paused, done: 1_000_000, total: 4_000_000)
        let failed = FetchEntry.bench("d.zip", .failed, done: 1_000_000, total: 4_000_000, error: "The network connection was lost.")
        let silent = FetchEntry.bench("e.zip", .failed, done: 0, total: 0)

        #expect(sized.detailText.contains(" of "))
        #expect(unsized.detailText.hasSuffix(" downloaded"))
        #expect(paused.detailText == "Paused · \(paused.sizeText)")
        #expect(failed.detailText == "The network connection was lost.")
        #expect(silent.detailText == "The download failed")
        #expect(sized.showsBar && paused.showsBar && !failed.showsBar)
    }

    @Test func aKeptFileThatIsGoneOnlyOffersRemoval() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-popover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let here = folder.appendingPathComponent("here.pdf")
        FileManager.default.createFile(atPath: here.path, contents: Data(count: 8))
        let present = Keep(name: "here.pdf", from: "example.com", path: here.path, date: Date())
        let gone = Keep(name: "gone.pdf", from: "example.com", path: folder.appendingPathComponent("gone.pdf").path, date: Date())

        #expect(RecentDownloadsView.menuVerbs(for: .kept(present)) == [.open, .reveal, .forget])
        #expect(RecentDownloadsView.menuVerbs(for: .kept(gone)) == [.forget])
        #expect(RecentDownloadsView.menuVerbs(for: .none).isEmpty)
    }

    @Test func aWordRowAtTheFootTakesAClickOverItsWhole24Points() throws {
        let loot = Loot()
        let fetches = Fetches(loot: loot)
        defer { fetches.benchStage("empty", loot: loot) }
        fetches.benchStage("many", loot: loot)
        let list = RecentDownloadsView(browser: Browser(record: WindowRecord()), loot: loot, fetches: fetches)
        list.prepare()
        let size = list.fitting(maxHeight: .greatestFiniteMagnitude)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let stage = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = stage
        list.frame = stage.bounds
        stage.addSubview(list)
        stage.layoutSubtreeIfNeeded()
        let foot = try #require(list.kitSubviews(of: DownloadsTable.self).first { $0.accessibilityLabel() == "Downloads Actions" })

        for index in RecentDownloadsView.footTitles.indices {
            let row = foot.rect(ofRow: index)
            let word = try #require(foot.view(atColumn: 0, row: index, makeIfNecessary: false) as? DownloadsWordCell)
            #expect(row.height == 24)
            #expect((word.textField?.frame.height ?? 24) < 24)
            for y in [row.minY + 0.5, row.midY, row.maxY - 0.5] {
                let hit = stage.hitTest(stage.convert(NSPoint(x: row.midX, y: y), from: foot))
                #expect(hit === foot || hit?.isDescendant(of: foot) == true)
                #expect(foot.row(at: NSPoint(x: row.midX, y: y)) == index)
            }
        }
        #expect(foot.action != nil)
    }

    @Test func manyRowsScrollInsideAFixedRoom() {
        let loot = Loot()
        let fetches = Fetches(loot: loot)
        defer { fetches.benchStage("empty", loot: loot) }
        fetches.benchStage("many", loot: loot)
        let list = RecentDownloadsView(browser: Browser(record: WindowRecord()), loot: loot, fetches: fetches)

        list.prepare()
        let whole = list.fitting(maxHeight: .greatestFiniteMagnitude)
        let squeezed = list.fitting(maxHeight: 260)
        let found = list.benchRows()

        #expect(found.count == 5 + min(6, loot.recent.count) + RecentDownloadsView.footTitles.count)
        #expect(found.compactMap { $0["height"] as? Double }.reduce(0, +) > Double(RecentDownloadsView.listRoom))
        #expect(whole.width == RecentDownloadsView.width)
        #expect(whole.height < RecentDownloadsView.listRoom + 80)
        #expect(squeezed.height <= 260)
    }

    @Test func aRunningRowFollowsItsDownload() async throws {
        let loot = Loot()
        let fetches = Fetches(loot: loot)
        defer { fetches.benchStage("empty", loot: loot) }
        fetches.benchStage("running", loot: loot)
        let entry = try #require(fetches.entries.first)
        let list = RecentDownloadsView(browser: Browser(record: WindowRecord()), loot: loot, fetches: fetches)
        list.prepare()
        let before = try #require(list.benchRows().first)

        let progress = Progress(totalUnitCount: 4_600_000_000)
        progress.completedUnitCount = 3_450_000_000
        entry.record(progress, trackFile: false)
        let moved = await rows(list) { ($0.first?["fraction"] as? Double) == 0.75 }
        entry.failed(NSError(domain: "DownloadFixture", code: 1), resumeData: nil)
        let failed = await rows(list) { ($0.first?["bar"] as? Bool) == false }

        #expect(before["keys"] as? [String] == ["pause", "cancel"])
        #expect(moved.first?["fraction"] as? Double == 0.75)
        #expect(moved.first?["detail"] as? String == "3.45 GB of 4.6 GB")
        #expect(failed.first?["bar"] as? Bool == false)
        #expect(failed.first?["keys"] as? [String] == ["retry", "remove"])
        #expect(failed.first?["height"] as? Double == Double(DownloadCell.short))
    }

    @Test func voiceOverCanPressTheRowsThatDoSomething() {
        let loot = Loot()
        let fetches = Fetches(loot: loot)
        loot.clearRecent(at: max(loot.clearedAt, Date()).addingTimeInterval(1))
        defer { Store.settings.removeObject(forKey: "downloads.cleared") }
        let browser = Browser(record: WindowRecord())
        let list = RecentDownloadsView(browser: browser, loot: loot, fetches: fetches)
        list.prepare()
        browser.downloadsOpen = true

        let line = list.benchAccessPress(0)
        let clear = list.benchAccessPress(2)
        let showAll = list.benchAccessPress(1)

        #expect(!line)
        #expect(!clear)
        #expect(showAll)
        #expect(browser.hoarding)
        #expect(!browser.downloadsOpen)
    }

    @Test func theEmptyListSaysSoAndCannotBeCleared() {
        let loot = Loot()
        let fetches = Fetches(loot: loot)
        loot.clearRecent(at: max(loot.clearedAt, Date()).addingTimeInterval(1))
        defer { Store.settings.removeObject(forKey: "downloads.cleared") }
        let list = RecentDownloadsView(browser: Browser(record: WindowRecord()), loot: loot, fetches: fetches)

        list.prepare()
        let found = list.benchRows()

        #expect(found.count == 3)
        #expect(found[0]["name"] as? String == "No Recent Downloads")
        #expect(found[0]["clickable"] as? Bool == false)
        #expect(found[1]["name"] as? String == "Show All Downloads")
        #expect(found[1]["clickable"] as? Bool == true)
        #expect(found[2]["clickable"] as? Bool == false)
    }
}
