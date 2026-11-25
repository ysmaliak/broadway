import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class DownloadMenuTests {
    private let folder: URL

    init() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("download-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        DownloadMenu.asked = []
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func made(_ name: String) -> URL {
        let file = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: file.path, contents: Data("hello".utf8))
        return file
    }

    private func titles(_ items: [NSMenuItem]) -> [String] {
        items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    private func board() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("broadway.download-menu-tests.\(UUID().uuidString)"))
    }

    @Test func aFinishedFilesMenuReadsOpenOpenWithShowInFinderCopyShareAndRemoveInThatOrder() {
        let file = made("notes.txt")
        let items = DownloadMenu.items(for: file, there: true, open: {}, reveal: {}, forget: {}, from: NSView())

        #expect(titles(items) == ["Open", "Open With", "Show in Finder", "-", "Copy File", "Share…", "-", "Remove from List"])
    }

    @Test func aFileThatIsGoneOffersOnlyRemoveFromList() {
        let gone = folder.appendingPathComponent("gone.zip")
        let items = DownloadMenu.items(for: gone, there: false, open: {}, reveal: {}, forget: {}, from: NSView())

        #expect(titles(items) == ["Remove from List"])
    }

    @Test func withoutARemoveActionTheMenuEndsAtShare() {
        let entries = DownloadMenu.entries(there: true, forgets: false)

        #expect(entries == [.open, .openWith, .reveal, .separator, .copy, .share])
    }

    @Test func openWithIsLeftOutWhenNoAppCanOpenTheFile() {
        let entries = DownloadMenu.entries(there: true, forgets: true, apps: 0)

        #expect(!entries.contains(.openWith))
        #expect(entries.first == .open)
    }

    @Test func openWithListsTheDefaultAppFirstAndTheRestByName() {
        let zed = URL(fileURLWithPath: "/Applications/Zed.app")
        let atlas = URL(fileURLWithPath: "/Applications/Atlas.app")
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")

        let ordered = DownloadMenu.ordered([zed, preview, atlas, zed], first: preview)

        #expect(ordered == [preview, atlas, zed])
    }

    @Test func openWithMarksTheDefaultAppAndOpensTheFileInTheChosenOne() throws {
        let file = made("page.html")
        let items = DownloadMenu.items(for: file, there: true, open: {}, reveal: {}, forget: {}, from: NSView())
        let submenu = try #require(items.first { $0.title == "Open With" }?.submenu)
        let apps = submenu.items.filter { !$0.isSeparatorItem }
        try #require(!apps.isEmpty)

        #expect(apps[0].title.hasSuffix(" (default)"))
        #expect(apps.dropFirst().allSatisfy { !$0.title.hasSuffix(" (default)") })
        let first = try #require(apps.first)
        _ = (first.target as AnyObject?)?.perform(first.action, with: first)
        #expect(DownloadMenu.asked.last?.hasPrefix("open page.html with ") == true)
    }

    @Test func copyFilePutsTheFileItselfOnThePasteboard() throws {
        let file = made("report.pdf")
        let pasteboard = board()

        let copied = DownloadMenu.copy(file, to: pasteboard)

        #expect(copied)
        let urls = try #require(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        #expect(urls.map(\.standardizedFileURL) == [file.standardizedFileURL])
    }

    @Test func copyingAFileThatIsGoneLeavesThePasteboardAlone() {
        let pasteboard = board()
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)

        let copied = DownloadMenu.copy(folder.appendingPathComponent("gone.pdf"), to: pasteboard)

        #expect(!copied)
        #expect(pasteboard.string(forType: .string) == "before")
    }

    @Test func shareAsksTheSystemPickerForTheFile() throws {
        let file = made("photo.png")
        let items = DownloadMenu.items(for: file, there: true, open: {}, reveal: {}, forget: {}, from: NSView())
        let share = try #require(items.first { $0.title == "Share…" })

        _ = (share.target as AnyObject?)?.perform(share.action, with: share)

        #expect(DownloadMenu.asked == ["share photo.png"])
    }

    @Test func theRecentDownloadsPanelListsTheFullMenuForAFinishedRow() {
        let file = made("here.pdf")
        let present = Keep(name: "here.pdf", from: "example.com", path: file.path, date: Date())
        let gone = Keep(name: "gone.pdf", from: "example.com", path: folder.appendingPathComponent("gone.pdf").path, date: Date())

        #expect(RecentDownloadsView.menuNames(for: .kept(present)) == ["open", "openWith", "reveal", "copy", "share", "forget"])
        #expect(RecentDownloadsView.menuNames(for: .kept(gone)) == ["forget"])
    }

    @Test func copyFileOnAFinishedRowInTheDownloadsPlaceCopiesTheFile() throws {
        let file = made("selected.zip")
        let browser = Browser(record: WindowRecord())
        defer { browser.loot.forget(Keep(name: "selected.zip", from: "example.com", path: file.path, date: Date())) }
        browser.loot.add(Keep(name: "selected.zip", from: "example.com", path: file.path, date: Date()))
        browser.edit()
        browser.enterPlace(.downloads)
        let item = try #require(browser.offers.compactMap(\.placed).first { $0.title == "selected.zip" })
        let menu = try #require(browser.downloadsContextMenu(item, from: NSView()))
        let copy = try #require(menu.items.first { $0.accessibilityIdentifier() == "field.downloads.row.copy" })
        DownloadMenu.board.clearContents()

        _ = (copy.target as AnyObject?)?.perform(copy.action, with: copy)

        let urls = DownloadMenu.board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        #expect(urls.map(\.standardizedFileURL) == [file.standardizedFileURL])
        browser.quitField()
    }

    @Test func aDownloadedRowInFilesOpensTheFileMenuAndAnUploadedRowOpensNone() throws {
        let file = made("song.mp3")
        let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let downloaded = FileRowView(frame: NSRect(x: 0, y: 0, width: 600, height: 44))
        downloaded.show(FileItem(id: "d|\(file.path)", kind: .downloaded, name: "song.mp3", source: "example.com", path: file.path, date: Date()), last: true)
        let uploaded = FileRowView(frame: NSRect(x: 0, y: 0, width: 600, height: 44))
        uploaded.show(FileItem(id: "u|\(file.path)|example.com", kind: .uploaded, name: "song.mp3", source: "example.com", path: file.path, date: Date()), last: true)

        let menu = try #require(downloaded.menu(for: click))

        #expect(titles(menu.items) == ["Open", "Open With", "Show in Finder", "-", "Copy File", "Share…", "-", "Remove from List"])
        #expect(uploaded.menu(for: click) == nil)
    }
}
