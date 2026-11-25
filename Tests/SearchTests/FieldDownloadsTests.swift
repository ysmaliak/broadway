import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FieldDownloadsTests {
    private var browser: Browser!
    private var folder: URL!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.loot.forgetAll()
        browser.fetches.benchStage("empty", loot: browser.loot)
        PlaceFiles.done = []
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("field-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func tearDown() async {
        browser.fetches.benchStage("empty", loot: browser.loot)
        browser.loot.forgetAll()
        browser.closeAll()
        browser = nil
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func keep(_ name: String, minutesAgo: Double, from host: String = "files.example", there: Bool = true) -> Keep {
        let file = folder.appendingPathComponent(name)
        if there { try? Data("x".utf8).write(to: file) }
        let keep = Keep(name: name, from: host, path: file.path, date: Date().addingTimeInterval(-minutesAgo * 60))
        browser.loot.add(keep)
        return keep
    }

    private func titles() -> [String] { browser.offers.map(\.primary) }

    private func item(_ title: String) throws -> FieldPlaceItem {
        try #require(browser.offers.compactMap(\.placed).first { $0.title == title })
    }

    private func pick(_ title: String) throws {
        browser.picked = try #require(browser.offers.firstIndex { $0.primary == title })
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<100 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func onDownloads(tabs: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(browser.fieldShowing, sourceLocation: sourceLocation)
        #expect(browser.fieldPlace == .downloads, sourceLocation: sourceLocation)
        #expect(browser.hoarding, sourceLocation: sourceLocation)
        #expect(browser.pageTab(.downloads) == nil, sourceLocation: sourceLocation)
        #expect(!browser.tabs.contains { $0.page?.kind == .downloads }, sourceLocation: sourceLocation)
        #expect(browser.tabs.count == tabs, sourceLocation: sourceLocation)
    }

    @Test func currentDownloadsComeFirstThenFilesNewestFirst() {
        browser.fetches.benchStage("many", loot: browser.loot)
        let running = browser.fetches.entries.map(\.name)

        browser.edit()
        browser.enterPlace(.downloads)

        #expect(Array(titles().prefix(running.count)) == running)
        let files = Array(titles().dropFirst(running.count))
        #expect(files.first == "Screenshot 2026-11-13.png")
        #expect(files.last == "Notes.txt")
        #expect(files.count == 6)
        #expect(browser.picked == 0)
        #expect(browser.offers.prefix(running.count).allSatisfy { $0.placed?.fetch != nil })
        #expect(browser.offers.dropFirst(running.count).allSatisfy { $0.placed?.fetch == nil })
    }

    @Test func typingFiltersCurrentDownloadsAndFilesAlike() {
        browser.fetches.benchStage("many", loot: browser.loot)
        browser.edit()
        browser.enterPlace(.downloads)

        browser.typed = "ubuntu"
        #expect(titles() == ["ubuntu-26.10-desktop-arm64.iso"])

        browser.typed = "dataset gz"
        #expect(titles() == ["dataset.tar.gz"])

        browser.typed = "example.org"
        #expect(titles() == ["broadway-press-kit.zip"])

        browser.typed = "nothing like this"
        #expect(titles().isEmpty)
        #expect(browser.returnIsIdle)
    }

    @Test func theListIsNotCappedAndKeepsItsOrder() {
        for index in 0..<(FieldPlace.most + 15) { keep("file-\(index).txt", minutesAgo: Double(index)) }

        browser.edit()
        browser.enterPlace(.downloads)

        #expect(browser.offers.count == FieldPlace.most + 15)
        #expect(titles().first == "file-0.txt")
        #expect(titles().last == "file-\(FieldPlace.most + 14).txt")
    }

    @Test func eachStateOffersItsOwnVerbsAndKeys() throws {
        browser.fetches.benchStage("many", loot: browser.loot)
        browser.edit()
        browser.enterPlace(.downloads)

        let running = try item("Xcode_27.1.xip")
        #expect(running.hints(splits: true).map { $0.keys + " " + $0.word } == ["⌘P Pause", "⌃X Cancel"])
        #expect(!running.returns)

        let paused = try item("dataset.tar.gz")
        #expect(paused.hints(splits: true).map { $0.keys + " " + $0.word } == ["⌃X Remove"])
        #expect(paused.returns)
        #expect(paused.returnWord == "Resume")

        let failed = try item("ubuntu-26.10-desktop-arm64.iso")
        #expect(failed.hints(splits: true).map { $0.keys + " " + $0.word } == ["⌃X Remove"])
        #expect(failed.returnWord == "Retry")
        #expect(failed.fetch?.entry.detailText == "The network connection was lost.")

        let kept = try item("Installer.dmg")
        #expect(kept.hints(splits: true).map(\.keys) == ["⌘R", "⇧⌘C", "⌃X"])
        #expect(kept.returns)
        #expect(kept.returnWord == "Open")

        let gone = try item("Gone already.pdf")
        #expect(gone.missing)
        #expect(gone.aside == "Moved or deleted")
        #expect(gone.hints(splits: true).map { $0.keys + " " + $0.word } == ["⌃X Remove"])
        #expect(!gone.returns)
    }

    @Test func returnIsIdleOnARunningDownloadAndAGoneFile() throws {
        browser.fetches.benchStage("many", loot: browser.loot)
        browser.edit()
        browser.enterPlace(.downloads)

        try pick("Xcode_27.1.xip")
        #expect(browser.returnIsIdle)
        browser.submit()
        #expect(browser.fieldPlace == .downloads)

        try pick("dataset.tar.gz")
        #expect(!browser.returnIsIdle)

        try pick("Gone already.pdf")
        #expect(browser.returnIsIdle)
        browser.submit()
        #expect(PlaceFiles.done.isEmpty)
        #expect(browser.fieldPlace == .downloads)
    }

    @Test func controlXRemovesAFailedDownloadAndTheNextRowIsLit() async throws {
        browser.fetches.benchStage("many", loot: browser.loot)
        browser.edit()
        browser.enterPlace(.downloads)
        try pick("ubuntu-26.10-desktop-arm64.iso")
        let at = try #require(browser.picked)

        #expect(browser.placeKey(KeyCombo("x", command: false, control: true)))
        await settle { !titles().contains("ubuntu-26.10-desktop-arm64.iso") }

        #expect(!browser.fetches.entries.contains { $0.name == "ubuntu-26.10-desktop-arm64.iso" })
        #expect(!titles().contains("ubuntu-26.10-desktop-arm64.iso"))
        #expect(browser.picked == at)
        #expect(browser.fieldPlace == .downloads)
    }

    @Test func commandPAndCommandRBelongToTheDownload() throws {
        browser.fetches.benchStage("many", loot: browser.loot)
        browser.edit()
        browser.enterPlace(.downloads)

        try pick("Gone already.pdf")
        #expect(browser.placeKey(KeyCombo("c", shift: true)))
        #expect(browser.announcement != "Path copied")

        try pick("ubuntu-26.10-desktop-arm64.iso")
        #expect(browser.placeKey(KeyCombo("p")))
        #expect(browser.placeKey(KeyCombo("c", shift: true)))
        #expect(!browser.placeKey(KeyCombo("y")))
        #expect(browser.fieldPlace == .downloads)
    }

    @Test func theActionsMenuNamesEveryVerbWithItsKey() throws {
        browser.fetches.benchStage("many", loot: browser.loot)
        browser.edit()
        browser.enterPlace(.downloads)

        try pick("Xcode_27.1.xip")
        #expect(browser.fieldMenuItems(for: browser.pickedOffer).map { $0.title + " " + $0.keys } == ["Pause ⌘P", "Cancel ⌃X", "Clear List "])

        try pick("dataset.tar.gz")
        #expect(browser.fieldMenuItems(for: browser.pickedOffer).map { $0.title + " " + $0.keys } == ["Resume ↩", "Remove ⌃X", "Clear List "])

        try pick("ubuntu-26.10-desktop-arm64.iso")
        #expect(browser.fieldMenuItems(for: browser.pickedOffer).map { $0.title + " " + $0.keys } == ["Retry ↩", "Remove ⌃X", "Clear List "])

        try pick("Installer.dmg")
        #expect(browser.fieldMenuItems(for: browser.pickedOffer).map(\.title) == ["Open", "Show in Finder", "Copy Path", "Remove from List", "Clear List"])

        try pick("Gone already.pdf")
        #expect(browser.fieldMenuItems(for: browser.pickedOffer).map(\.title) == ["Remove from List", "Clear List"])

        #expect(browser.fieldMenuItems(for: nil).map(\.title) == ["Clear List"])
        #expect(!browser.fieldMenuItems(for: nil).contains { $0.title.contains("Page") })
    }

    @Test func aRowsOwnMenuIsTheDownloadMenu() throws {
        browser.fetches.benchStage("many", loot: browser.loot)
        let file = keep("menu-file.txt", minutesAgo: 0)
        browser.edit()
        browser.enterPlace(.downloads)
        let view = NSView()

        let running = try #require(browser.downloadsContextMenu(try item("Xcode_27.1.xip"), from: view))
        #expect(running.items.map(\.title) == ["Pause", "Cancel"])

        let gone = try #require(browser.downloadsContextMenu(try item("Gone already.pdf"), from: view))
        #expect(gone.items.map(\.title) == ["Remove from List"])

        let kept = try #require(browser.downloadsContextMenu(try item("menu-file.txt"), from: view))
        let titles = kept.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles.first == "Open")
        #expect(titles.contains("Show in Finder"))
        #expect(titles.contains("Copy File"))
        #expect(titles.last == "Remove from List")

        let copy = try #require(kept.items.first { $0.accessibilityIdentifier() == "field.downloads.row.copy" })
        DownloadMenu.board.clearContents()
        _ = (copy.target as AnyObject?)?.perform(copy.action, with: copy)
        let urls = DownloadMenu.board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        #expect(urls.map(\.standardizedFileURL) == [file.url.standardizedFileURL])

        #expect(browser.downloadsContextMenu(FieldPlaceItem(place: .history, id: "h", title: "H", detail: "", aside: "",
                                                            url: URL(string: "https://example.com/")!), from: view) == nil)
    }

    @Test func aNewDownloadKeepsTheLitRow() async throws {
        keep("older.txt", minutesAgo: 30)
        keep("lit.txt", minutesAgo: 20)
        keep("newer.txt", minutesAgo: 10)
        browser.edit()
        browser.enterPlace(.downloads)
        try pick("lit.txt")

        keep("newest.txt", minutesAgo: 0)
        await settle { titles().first == "newest.txt" }

        #expect(titles() == ["newest.txt", "newer.txt", "lit.txt", "older.txt"])
        #expect(browser.pickedOffer?.primary == "lit.txt")
    }

    @Test func clearListEmptiesItAndUndoBringsItBack() async {
        keep("one.txt", minutesAgo: 2)
        keep("two.txt", minutesAgo: 1)
        browser.edit()
        browser.enterPlace(.downloads)

        browser.clearDownloadsList()

        #expect(browser.loot.kept.isEmpty)
        #expect(titles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("one.txt").path))
        #expect(browser.announcement == "Cleared the list. The files stay where they are.")

        browser.undoAnnounced()

        #expect(browser.loot.kept.map(\.name) == ["two.txt", "one.txt"])
        #expect(titles() == ["two.txt", "one.txt"])
    }

    @Test func everyDoorOpensTheFieldOnDownloadsAndNoTab() throws {
        _ = browser.open(URL(string: "about:blank#page")!, foreground: true)
        keep("door.txt", minutesAgo: 1)
        let tabs = browser.tabs.count

        browser.hoarding = true
        onDownloads(tabs: tabs)
        #expect(browser.picked == 0)
        browser.quitField()

        let menu = try #require(Command.named("history.downloads"))
        menu.run(browser)
        onDownloads(tabs: tabs)
        browser.quitField()

        browser.show(InternalPage(.downloads))
        onDownloads(tabs: tabs)
        browser.quitField()

        _ = browser.open(try #require(URL(string: "broadway://downloads")), foreground: true)
        onDownloads(tabs: tabs)
        browser.quitField()

        browser.edit()
        browser.typed = "broadway://downloads"
        browser.submit()
        onDownloads(tabs: tabs)
        #expect(browser.picked == 0)
        browser.quitField()

        browser.edit()
        browser.take(.command(.downloads))
        onDownloads(tabs: tabs)
        browser.quitField()

        browser.downloadsOpen = true
        browser.hoarding = true
        #expect(!browser.downloadsOpen)
        onDownloads(tabs: tabs)
        browser.quitField()

        let tab = try #require(browser.active)
        tab.go(to: try #require(URL(string: "broadway://downloads")))
        onDownloads(tabs: tabs)
        #expect(tab.page == nil)
        browser.quitField()

        browser.hoarding = true
        browser.hoarding = false
        #expect(browser.fieldPlace == nil)
    }

    @Test func historyStillOpensItsTab() {
        let tabs = browser.tabs.count

        browser.show(InternalPage(.history))

        #expect(browser.pageTab(.history) != nil)
        #expect(browser.tabs.count >= tabs)
    }

    @Test func aSavedDownloadsTabIsDroppedAndNeverRaisesTheField() throws {
        let page = try #require(URL(string: "broadway://downloads"))
        #expect(InternalPage.retired(page))
        #expect(!InternalPage.retired(try #require(URL(string: "broadway://history"))))
        #expect(!InternalPage.retired(try #require(URL(string: "https://example.com/"))))
        #expect(InternalPage(url: page)?.kind == .downloads)

        let tab = browser.open(URL(string: "about:blank#rest")!, foreground: true)
        browser.quitField()
        tab.restore(url: page, title: "Downloads")

        #expect(tab.page == nil)
        #expect(browser.fieldPlace == nil)
    }

    @Test func theAddressCommandKeepsTheField() {
        #expect(AddressCommand.downloads.keepsField)
        #expect(!AddressCommand.history.keepsField)
    }

    @Test func aLongListMakesOnlyTheRowsNearTheScreen() throws {
        for index in 0..<300 { keep("long-\(index).txt", minutesAgo: Double(index)) }
        browser.edit()
        browser.enterPlace(.downloads)
        let list = FieldListView(browser: browser, rowHeight: 38, headerHeight: 28, room: OmniboxView.barRoom)
        list.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        list.layoutSubtreeIfNeeded()

        let built = list.kitSubviews(of: FieldRowSlot.self).filter { $0.superview != nil }
        #expect(built.count < 120)
        #expect(built.count > 10)

        let scroll = try #require(list.kitSubviews(of: NSScrollView.self).first)
        let page = try #require(scroll.documentView)
        #expect(page.frame.height >= 300 * 38)
        page.scroll(NSPoint(x: 0, y: page.frame.height - scroll.contentView.bounds.height))
        list.layoutSubtreeIfNeeded()

        let after = list.kitSubviews(of: FieldRowSlot.self).filter { $0.superview != nil }
        let lowest = after.map(\.frame.maxY).max() ?? 0
        #expect(after.count < 120)
        #expect(lowest >= page.frame.height - 38)
    }
}
