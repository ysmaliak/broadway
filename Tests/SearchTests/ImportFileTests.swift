import Foundation
import Testing
import Darwin
import AppKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
struct ImportFileTests {
    @MainActor init() {
        keepSettings("bookmarks.top")
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        addTeardownBlock { Disk.drain() }
    }

    @Test @MainActor func bookmarksParserKeepsNetscapeFoldersAndDecodedTitles() {
        let html = #"""
        <DL><p>
          <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Bar</H3><DL><p>
            <DT><A HREF="https://example.com/?a=1&amp;b=2">A &amp; B</A>
          </DL><p>
          <DT><H3>Folder &amp; one</H3><DL><p>
            <DT><A HREF="https://inside.example/">Nested</A>
          </DL><p>
        </DL>
        """#

        let bookmarks = BookmarksFile.parse(html)
        #expect(bookmarks.map(\.title) == ["A & B", "Folder & one"])
        #expect(bookmarks[0].url == "https://example.com/?a=1&b=2")
        #expect(bookmarks[1].children?.map(\.title) == ["Nested"])
    }

    @Test @MainActor func folderReadsOnlyRootAndImmediateFilesInLexicographicOrder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefixFolder = root.appendingPathComponent("a", isDirectory: true)
        let siblingFolder = root.appendingPathComponent("a-branch", isDirectory: true)
        let deepFolder = prefixFolder.appendingPathComponent("deep", isDirectory: true)
        let hiddenFolder = root.appendingPathComponent(".hidden", isDirectory: true)
        let outside = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: prefixFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deepFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: true)

        try writeBookmark("Root", url: "https://root.example/", to: root.appendingPathComponent("a.html"))
        try writeBookmark("Inside", url: "https://inside.example/", to: prefixFolder.appendingPathComponent("inside.html"))
        try writeBookmark("Sibling", url: "https://sibling.example/", to: siblingFolder.appendingPathComponent("inside.html"))
        try writeBookmark("Deep", url: "https://deep.example/", to: deepFolder.appendingPathComponent("too-deep.html"))
        try writeBookmark("Hidden", url: "https://hidden.example/", to: root.appendingPathComponent(".hidden.html"))
        try writeBookmark("Hidden folder", url: "https://hidden-folder.example/", to: hiddenFolder.appendingPathComponent("hidden.html"))
        let unreadable = root.appendingPathComponent("unreadable.csv")
        try "unreadable fixture".write(to: unreadable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        let canReadUnreadable: Bool
        do {
            let handle = try FileHandle(forReadingFrom: unreadable)
            _ = try handle.read(upToCount: 1)
            try handle.close()
            canReadUnreadable = true
        } catch {
            canReadUnreadable = false
        }
        let outsideFile = outside.appendingPathComponent("outside.html")
        try writeBookmark("Symlink", url: "https://outside.example/", to: outsideFile)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.html"), withDestinationURL: outsideFile)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-folder", isDirectory: true), withDestinationURL: outside)

        let first = try ImportFile.read(root)
        let second = try ImportFile.read(root)
        let expected = ["Sibling", "Root", "Inside"]
        #expect(first.bookmarks.map(\.title) == expected)
        #expect(second.bookmarks.map(\.title) == expected)
        if !canReadUnreadable {
            #expect(first.passwords.isEmpty, "an unreadable folder member must not discard the valid bookmarks or become a password file")
        }
    }

    @Test @MainActor func progressResetsForNewStagesAndThrottlesRepeatedUpdates() {
        let lock = NSLock()
        var updates: [ImportFile.Progress] = []
        let control = ImportFile.Control { update in
            lock.lock()
            updates.append(update)
            lock.unlock()
        }

        let started = ProcessInfo.processInfo.systemUptime
        control.report(.init(message: "Reading file", completed: 0, total: 100_000))
        for count in 1...10_000 {
            control.report(.init(message: "Reading file", completed: count, total: 100_000))
        }
        Thread.sleep(forTimeInterval: 0.12)
        control.report(.init(message: "Saving passwords", completed: 0, total: 3))
        Thread.sleep(forTimeInterval: 0.12)
        control.report(.init(message: "Saving passwords", completed: 3, total: 3))

        lock.lock()
        let captured = updates
        lock.unlock()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        #expect(captured.count <= (Int(elapsed / 0.1) + 1))
        #expect(captured.first?.completed == 0)
        let savingStage = captured.first { $0.message == "Saving passwords" }
        #expect(savingStage?.completed == 0, "a new phase should reset its displayed count")
        #expect(captured.last?.completed == 3)
        #expect(captured.last?.total == 3)
    }

    @Test @MainActor func progressThrottleBoundsRapidDistinctFileMessages() {
        let lock = NSLock()
        var updates: [ImportFile.Progress] = []
        let control = ImportFile.Control { update in
            lock.lock()
            updates.append(update)
            lock.unlock()
        }

        let started = ProcessInfo.processInfo.systemUptime
        control.report(.init(message: "Folder: Scanning", completed: 0))
        for index in 1...5_000 {
            control.report(.init(message: "file-\(index): File complete", completed: 1))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        lock.lock()
        let count = updates.count
        lock.unlock()

        #expect(count <= (Int(elapsed / 0.1) + 1), "filename and finished-file changes must share the global throttle")
    }

    @Test @MainActor func htmlParserProgressCanCancelDuringRegexEnumeration() throws {
        let html = "<DL>" + (0..<2_000).map { index in
            #"<DT><A HREF="https://example.com/\#(index)">Bookmark \#(index)</A>"#
        }.joined() + "</DL>"
        let control = ImportFile.Control()
        var progressThrough = 0
        let error = #expect(throws: (any Error).self) { try BookmarksFile.parse(html, control: control, progress: { stage, completed, _ in
            if stage == "Parsing bookmarks" {
                progressThrough = completed
                if completed > 1_000 { control.cancel() }
            }
        }) }
        #expect(error is CancellationError)
        #expect(progressThrough > 1_000)
        #expect(progressThrough < (html as NSString).length)
    }

    @Test @MainActor func passwordCSVPrecancelAndProgressNeverContainsItsContents() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("passwords.csv")
        let secret = "private-test-password-91c"
        let csv = "url,username,password\nhttps://example.com,alice,\(secret)\n"
        try csv.write(to: file, atomically: true, encoding: .utf8)
        let cancelled = ImportFile.Control()
        cancelled.cancel()
        let error = #expect(throws: (any Error).self) { try ImportFile.read(file, control: cancelled) }
        #expect(error is CancellationError)

        var updates: [ImportFile.Progress] = []
        let control = ImportFile.Control { updates.append($0) }
        let imported = try ImportFile.read(file, control: control)
        #expect(imported.passwords == [csv])
        #expect(updates.contains { $0.message == "passwords.csv: Reading CSV" })
        #expect(updates.allSatisfy { !$0.message.contains(secret) })
        #expect(updates.contains { $0.total != nil })

        updates.removeAll()
        let safeToSkip = "url,username,password\n,alice,\(secret)\n"
        let vaultControl = ImportFile.Control { updates.append($0) }
        let result = Vault.take(csv: safeToSkip, control: vaultControl)
        #expect(result.kept == 0)
        #expect(result.skipped == 1)
        #expect(updates.contains { $0.message == "Reading passwords…" })
        #expect(updates.allSatisfy { !$0.message.contains(secret) })
    }

    @MainActor
    @Test func bookmarkMergeKeepsAConcurrentEditAndDeduplicates() async throws {
        let bookmarks = Bookmarks()
        let existingURL = URL(string: "https://already.example/")!
        let existing = Bookmark.site("Already here", existingURL)
        _ = bookmarks.take([existing], from: "Other")
        let incoming = [Bookmark.site("Duplicate", existingURL)] + (0..<20_000).map { index in
            Bookmark.site("Imported \(index)", URL(string: "https://imported-\(index).example/")!)
        }
        let started = Expectation(description: "merge captured its snapshot")
        let task = Task { @MainActor in
            started.fulfill()
            return try await bookmarks.takeFile(incoming, from: "Other", control: ImportFile.Control())
        }
        await fulfillment(of: [started], timeout: 5)
        let concurrentURL = URL(string: "https://concurrent.example/")!
        _ = bookmarks.add(concurrentURL, title: "Concurrent edit")

        let result = try await task.value

        #expect(result.already == 1)
        #expect(result.added == 20_000)
        #expect(Bookmarks.urls(bookmarks.roots).contains(concurrentURL))
        #expect(Bookmarks.count(bookmarks.roots) == 20_002)
        _ = bookmarks.withdraw([existing.id] + incoming.map(\.id))
        Disk.drain()
    }

    @MainActor
    @Test func replaceWithReadableEmptyProfileRemovesOnlyThatSourcesBookmarks() throws {
        let browser = makeImportTestBrowser()
        let bookmarks = browser.bookmarks
        let previousTop = Store.settings.string(forKey: "bookmarks.top")
        let previousRecords = Store.settings.data(forKey: "import.records")
        let (source, root) = try makeChromiumSource(name: "Replace Empty \(UUID().uuidString)")
        defer {
            if let record = ImportRecords.of(source.name) { _ = bookmarks.withdraw(record.bookmarkIDs) }
            try? FileManager.default.removeItem(at: root)
            if let previousTop { Store.settings.set(previousTop, forKey: "bookmarks.top") }
            else { Store.settings.removeObject(forKey: "bookmarks.top") }
            if let previousRecords { Store.settings.set(previousRecords, forKey: "import.records") }
            else { Store.settings.removeObject(forKey: "import.records") }
            Disk.drain()
        }

        let profile = try makeProfile("Default", under: root)
        let sourceURL = "https://replace-source.example/"
        try writeChromiumBookmarks([chromiumURL("From source", sourceURL)], to: profile)
        let first = browser.takeBookmarks(from: .chromium(source))
        #expect(first.added == 1)
        #expect(!first.kept)
        let priorRecord = try #require(ImportRecords.of(source.name))
        #expect(priorRecord.bookmarks == 1)
        #expect(Bookmarks.urls(bookmarks.roots).map { $0.absoluteString }.filter { $0 == sourceURL }.count == 1)

        let manualURL = URL(string: "https://manual-bookmark.example/")!
        let manual = try #require(bookmarks.add(manualURL, title: "Manual"))
        defer { _ = bookmarks.withdraw([manual.id]) }
        let otherSource = try makeChromiumSource(name: "Other Browser \(UUID().uuidString)")
        defer {
            if let record = ImportRecords.of(otherSource.0.name) { _ = bookmarks.withdraw(record.bookmarkIDs) }
            try? FileManager.default.removeItem(at: otherSource.1)
        }
        let otherProfile = try makeProfile("Default", under: otherSource.1)
        let otherURL = "https://other-browser.example/"
        try writeChromiumBookmarks([chromiumURL("Other browser", otherURL)], to: otherProfile)
        #expect(browser.takeBookmarks(from: .chromium(otherSource.0)).added == 1)
        let otherRecordBefore = try #require(ImportRecords.of(otherSource.0.name))

        try writeChromiumBookmarks([], to: profile)
        let replacement = browser.takeBookmarks(from: .chromium(source), replacing: true)

        #expect(replacement.added == 0)
        #expect(replacement.already == 0)
        #expect(!replacement.kept)
        let urls = Set(Bookmarks.urls(bookmarks.roots).map(\.absoluteString))
        #expect(!urls.contains(sourceURL), "a clean empty profile replaces its earlier import with nothing")
        #expect(urls.contains(manualURL.absoluteString), "manual bookmarks must survive source replacement")
        #expect(urls.contains(otherURL), "bookmarks from another browser must survive source replacement")
        let sourceRecord = try #require(ImportRecords.of(source.name))
        #expect(sourceRecord.bookmarks == 0)
        #expect(sourceRecord.bookmarkIDs.isEmpty)
        #expect(ImportRecords.of(otherSource.0.name)?.bookmarkIDs == otherRecordBefore.bookmarkIDs)
    }

    @MainActor
    @Test func replaceWithMissingOrMalformedProfilePreservesEarlierImportAndProvenance() throws {
        let browser = makeImportTestBrowser()
        let bookmarks = browser.bookmarks
        let previousTop = Store.settings.string(forKey: "bookmarks.top")
        let previousRecords = Store.settings.data(forKey: "import.records")
        let (source, root) = try makeChromiumSource(name: "Replace Partial \(UUID().uuidString)")
        defer {
            if let record = ImportRecords.of(source.name) { _ = bookmarks.withdraw(record.bookmarkIDs) }
            try? FileManager.default.removeItem(at: root)
            if let previousTop { Store.settings.set(previousTop, forKey: "bookmarks.top") }
            else { Store.settings.removeObject(forKey: "bookmarks.top") }
            if let previousRecords { Store.settings.set(previousRecords, forKey: "import.records") }
            else { Store.settings.removeObject(forKey: "import.records") }
            Disk.drain()
        }

        let usual = try makeProfile("Default", under: root)
        let broken = try makeProfile("Profile 1", under: root)
        let originalURL = "https://original-profile.example/"
        try writeChromiumBookmarks([chromiumURL("Original", originalURL)], to: usual)
        #expect(browser.takeBookmarks(from: .chromium(source), profile: "Default").added == 1)
        let originalRecord = try #require(ImportRecords.of(source.name))

        let missing = browser.takeBookmarks(from: .chromium(source), profile: "Missing profile", replacing: true)
        #expect(missing.kept)
        #expect(Bookmarks.urls(bookmarks.roots).map { $0.absoluteString }.contains(originalURL))
        let afterMissing = try #require(ImportRecords.of(source.name))
        #expect(afterMissing.bookmarks == originalRecord.bookmarks)
        #expect(afterMissing.bookmarkIDs == originalRecord.bookmarkIDs)

        let readableURL = "https://readable-profile.example/"
        try writeChromiumBookmarks([chromiumURL("Updated", readableURL)], to: usual)
        try Data("malformed profile bookmarks".utf8).write(to: broken.appendingPathComponent("Bookmarks"))
        let partial = browser.takeBookmarks(from: .chromium(source), replacing: true)

        #expect(partial.kept, "a malformed profile means the set was not completely read")
        let urls = Set(Bookmarks.urls(bookmarks.roots).map(\.absoluteString))
        #expect(urls.contains(originalURL), "unreadable replacement must preserve prior source bookmarks")
        #expect(urls.contains(readableURL), "readable profiles still contribute their current bookmarks")
        let afterMalformed = try #require(ImportRecords.of(source.name))
        #expect(afterMalformed.bookmarks == 2)
        #expect(originalRecord.bookmarkIDs.allSatisfy(afterMalformed.bookmarkIDs.contains), "prior source provenance must remain attached")
    }

    @MainActor
    @Test func asyncFileMergeOverlappingEmptyReplaceKeepsFileAndReplacementState() async throws {
        let browser = makeImportTestBrowser()
        let bookmarks = browser.bookmarks
        let previousTop = Store.settings.string(forKey: "bookmarks.top")
        let previousRecords = Store.settings.data(forKey: "import.records")
        let (source, root) = try makeChromiumSource(name: "Replace During File \(UUID().uuidString)")
        let fileName = "Concurrent File \(UUID().uuidString)"
        let manualURL = URL(string: "https://manual-during-file-merge.example/")!
        let manual = try #require(bookmarks.add(manualURL, title: "Manual"))
        let fileBookmarks = (0..<10_000).map { index in
            Bookmark.site("File bookmark \(index)", URL(string: "https://file-\(index).example/")!)
        }
        defer {
            if let record = ImportRecords.of(source.name) { _ = bookmarks.withdraw(record.bookmarkIDs) }
            try? FileManager.default.removeItem(at: root)
            _ = bookmarks.withdraw([manual.id])
            _ = bookmarks.withdraw(fileBookmarks.map(\.id))
            if let folder = bookmarks.roots.first(where: { $0.isFolder && $0.title == fileName }) { _ = bookmarks.withdraw([folder.id]) }
            if let previousTop { Store.settings.set(previousTop, forKey: "bookmarks.top") }
            else { Store.settings.removeObject(forKey: "bookmarks.top") }
            if let previousRecords { Store.settings.set(previousRecords, forKey: "import.records") }
            else { Store.settings.removeObject(forKey: "import.records") }
            Disk.drain()
        }

        let profile = try makeProfile("Default", under: root)
        let sourceURL = "https://to-be-replaced.example/"
        try writeChromiumBookmarks([chromiumURL("Old source bookmark", sourceURL)], to: profile)
        #expect(browser.takeBookmarks(from: .chromium(source)).added == 1)
        try writeChromiumBookmarks([], to: profile)

        let started = Expectation(description: "file merge started preparing its snapshot")
        let merge = Task { @MainActor in
            started.fulfill()
            return try await bookmarks.takeFile(fileBookmarks, from: fileName, control: ImportFile.Control())
        }
        await fulfillment(of: [started], timeout: 5)
        let replacement = browser.takeBookmarks(from: .chromium(source), replacing: true)
        let merged = try await merge.value

        #expect(!replacement.kept)
        #expect(merged.added == fileBookmarks.count)
        let urls = Set(Bookmarks.urls(bookmarks.roots).map(\.absoluteString))
        #expect(!urls.contains(sourceURL), "a prepared async merge must not resurrect a source bookmark removed by Replace")
        #expect(urls.contains(manualURL.absoluteString))
        #expect(urls.contains("https://file-0.example/"))
        #expect(urls.contains("https://file-9999.example/"))
        #expect(urls.intersection(Set(fileBookmarks.compactMap { $0.url })).count == fileBookmarks.count)
        let sourceRecord = try #require(ImportRecords.of(source.name))
        #expect(sourceRecord.bookmarkIDs.isEmpty, "the file import must not acquire the replaced browser's provenance")
    }

    @MainActor
    @Test func arcImportKeepsSpacesFoldersPinsAndImportRecordCounts() throws {
        let browser = makeImportTestBrowser()
        let previousRecords = Store.settings.data(forKey: "import.records")
        let previousUsesSpaces = browser.prefs.usesSpaces
        let previousUsesTabGroups = browser.prefs.usesTabGroups
        let previousSpaces = browser.spaces
        let suffix = UUID().uuidString
        let workName = "Arc Engineering \(suffix)"
        let personalName = "Arc Personal \(suffix)"
        let oldArcFolder = Arc.file.deletingLastPathComponent()
        let oldArcFolderExisted = FileManager.default.fileExists(atPath: oldArcFolder.path)
        let oldArcFile = try? Data(contentsOf: Arc.file)
        try FileManager.default.createDirectory(at: oldArcFolder, withIntermediateDirectories: true)
        defer {
            for space in Spaces.read() where space.name == workName || space.name == personalName {
                Pins.forget(space.id)
                Session.erase(space: space.id)
            }
            browser.spaces = previousSpaces
            Spaces.write(previousSpaces)
            browser.prefs.usesSpaces = previousUsesSpaces
            browser.prefs.usesTabGroups = previousUsesTabGroups
            if let oldArcFile { try? oldArcFile.write(to: Arc.file, options: .atomic) }
            else {
                try? FileManager.default.removeItem(at: Arc.file)
                if !oldArcFolderExisted { try? FileManager.default.removeItem(at: oldArcFolder) }
            }
            if let previousRecords { Store.settings.set(previousRecords, forKey: "import.records") }
            else { Store.settings.removeObject(forKey: "import.records") }
            Disk.drain()
        }

        let source = ImportSource.chromium(Chromium.Source(
            name: "Arc", folder: "Arc/User Data", service: "Arc Safe Storage", account: "Arc", app: "Arc.app"))
        let sidebar = try makeArcSidebarFixture(workName: workName, personalName: personalName)
        try sidebar.write(to: Arc.file, options: .atomic)
        browser.prefs.usesSpaces = false
        browser.prefs.usesTabGroups = true

        let imported = try #require(source.arcSidebar(profile: nil))
        #expect(source.arcCounts(profile: nil)?.spaces == 2)
        #expect(source.arcCounts(profile: nil)?.pinned == 5)
        #expect(imported.spaces.map(\.name) == [workName, personalName])
        #expect(imported.spaces[0].pinned.count == 1, "Arc folders remain folders until Search places their tabs in a group")
        if case .folder(let folder) = imported.spaces[0].pinned[0] {
            #expect(folder.title == "Research")
            #expect(Arc.count([imported.spaces[0].pinned[0]]) == 2)
        } else {
            Issue.record("Arc's pinned folder was flattened while reading the sidebar")
        }

        let result = browser.takeArc(imported)
        ImportRecords.note(source.name, spaces: result.spaces, pinned: result.pins + result.tabs)
        #expect(result.spaces == 2)
        #expect(result.pins == 2, "each space gets the favourites from its own profile")
        #expect(result.tabs == 3, "pinned tabs from nested folders are restored asleep")

        let again = browser.takeArc(imported)
        #expect(again.spaces == 0)
        #expect(again.pins == 0)
        #expect(again.tabs == 0)

        let work = try #require(browser.spaces.first { $0.name == workName })
        let personal = try #require(browser.spaces.first { $0.name == personalName })
        #expect(work.sharesSignIns == true)
        #expect(personal.sharesSignIns == true)
        #expect(Pins.defs(work.id).map(\.home) == ["https://favorite-work.example/"])
        #expect(Pins.defs(personal.id).map(\.home) == ["https://favorite-personal.example/"])
        let workSession = browser.readRow(work.id)
        #expect(workSession.tabs.map(\.url) == ["https://work-one.example/", "https://work-two.example/"])
        let research = try #require(workSession.groups?.first { $0.name == "Research" })
        #expect(workSession.tabs.map(\.groupID) == [research.id, research.id])
        #expect(browser.readRow(personal.id).tabs.map(\.url) == ["https://personal.example/"])
        let record = try #require(ImportRecords.of(source.name))
        #expect(record.spaces == 2)
        #expect(record.pinned == 5)
    }

    @Test @MainActor func zipReadCleansExtractionAndOnlyZIPHistoryMarksSafari() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let export = root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try writeBookmark("From zip", url: "https://zip.example/", to: export.appendingPathComponent("bookmarks.html"))
        let history: [String: Any] = [
            "metadata": ["data_type": "history"],
            "history": [["url": "https://history.example/", "title": "History", "time_usec": 1_000_000, "visits_count": 1]],
        ]
        let historyData = try JSONSerialization.data(withJSONObject: history)
        try historyData.write(to: export.appendingPathComponent("history.json"))

        let archive = root.appendingPathComponent("export.zip")
        try runDitto(arguments: ["-c", "-k", "--sequesterRsrc", export.path, archive.path])
        let tempBefore = officeImportFolders()
        let preCancelled = ImportFile.Control()
        preCancelled.cancel()
        let error = #expect(throws: (any Error).self) { try ImportFile.read(archive, control: preCancelled) }
        #expect(error is CancellationError)
        #expect(officeImportFolders() == tempBefore)
        let found = try ImportFile.read(archive)
        #expect(found.bookmarks.map(\.title) == ["From zip"])
        #expect(found.places.count == 1)
        #expect(found.fromSafari)
        #expect(officeImportFolders() == tempBefore)

        let ordinary = root.appendingPathComponent("ordinary", isDirectory: true)
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        try historyData.write(to: ordinary.appendingPathComponent("history.json"))
        #expect(try !ImportFile.read(ordinary).fromSafari)

        let invalidArchive = root.appendingPathComponent("broken.zip")
        try Data("not a zip".utf8).write(to: invalidArchive)
        #expect(try ImportFile.read(invalidArchive).isEmpty)
        #expect(officeImportFolders() == tempBefore)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-import-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private func makeImportTestBrowser() -> Browser {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    return Browser(record: WindowRecord())
}

private func makeChromiumSource(name: String) throws -> (Chromium.Source, URL) {
    let folder = "SearchTests/\(UUID().uuidString)"
    let root = Chromium.base.appendingPathComponent(folder, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (Chromium.Source(name: name, folder: folder, service: "Test Safe Storage", account: "Test", app: "Test.app"), root)
}

private func makeProfile(_ name: String, under root: URL) throws -> URL {
    let profile = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    return profile
}

private func chromiumURL(_ title: String, _ url: String) -> [String: Any] {
    ["type": "url", "name": title, "url": url]
}

private func writeChromiumBookmarks(_ entries: [[String: Any]], to profile: URL) throws {
    let bar: [String: Any] = ["children": entries]
    let other: [String: Any] = ["children": [] as [[String: Any]]]
    let synced: [String: Any] = ["children": [] as [[String: Any]]]
    let roots: [String: Any] = ["bookmark_bar": bar, "other": other, "synced": synced]
    let data = try JSONSerialization.data(withJSONObject: ["roots": roots])
    try data.write(to: profile.appendingPathComponent("Bookmarks"), options: .atomic)
}

private func makeArcSidebarFixture(workName: String, personalName: String) throws -> Data {
    func tab(_ id: String, _ title: String, _ url: String) -> [String: Any] {
        ["id": id, "title": title, "data": ["tab": ["savedURL": url, "savedTitle": title]]]
    }

    let items: [[String: Any]] = [
        ["id": "work-pins", "childrenIds": ["work-folder"]],
        ["id": "work-folder", "title": "Research", "data": ["list": [String: Any]()], "childrenIds": ["work-one", "work-two"]],
        tab("work-one", "One", "https://work-one.example/"),
        tab("work-two", "Two", "https://work-two.example/"),
        ["id": "personal-pins", "childrenIds": ["personal-tab"]],
        tab("personal-tab", "Personal page", "https://personal.example/"),
        ["id": "default-favorites", "childrenIds": ["favorite-work"]],
        tab("favorite-work", "Work favourite", "https://favorite-work.example/"),
        ["id": "profile-favorites", "childrenIds": ["favorite-personal"]],
        tab("favorite-personal", "Personal favourite", "https://favorite-personal.example/"),
    ]
    let profileOne: [String: Any] = ["custom": ["_0": ["directoryBasename": "Profile 1"]]]
    let spaces: [[String: Any]] = [
        ["title": workName, "profile": ["default": [String: Any]()],
         "customInfo": ["iconType": ["emoji_v2": "💻"]], "newContainerIDs": ["pinned", "work-pins"]],
        ["title": personalName, "profile": profileOne, "newContainerIDs": ["pinned", "personal-pins"]],
    ]
    let main: [String: Any] = [
        "items": items,
        "spaces": spaces,
        "topAppsContainerIDs": [["default": [String: Any]()], "default-favorites", profileOne, "profile-favorites"],
    ]
    return try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": [main]]])
}

private func writeBookmark(_ title: String, url: String, to file: URL) throws {
    let html = #"<DL><DT><A HREF="\#(url)">\#(title)</A></DL>"#
    try html.write(to: file, atomically: true, encoding: .utf8)
}

private func runDitto(arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

private func officeImportFolders() -> Set<String> {
    let items = (try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
    return Set(items.filter { $0.lastPathComponent.hasPrefix("office-import-") }.map(\.lastPathComponent))
}
