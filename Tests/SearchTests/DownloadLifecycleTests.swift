import AppKit
import Darwin
import Foundation
import WebKit
import Testing
@testable import Search

private typealias BrowserTab = Search.Tab

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class DownloadLifecycleTests {
    private var browser: Browser!
    private var fixture: LocalDownloadServer!
    private var downloadFolder: URL!
    private var window: NSWindow!
    private var page: BrowserTab?

    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    init() async throws {
        addTeardownBlock { try await self.tearDown() }
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)

        fixture = try LocalDownloadServer()
        browser = Browser(record: WindowRecord())
        browser.closeAll()
        let prefs = browser.prefs
        let saved = (prefs.downloads, prefs.asksWhereToSave)
        restorePreferences = { (prefs.downloads, prefs.asksWhereToSave) = saved }
        browser.history.forget()
        browser.loot.forgetAll()

        downloadFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Search-download-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
        browser.prefs.downloads = downloadFolder
        browser.prefs.asksWhereToSave = false

        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        browser.window = window
    }

    private func tearDown() async throws {
        try? nothingShown()
        if let browser {
            for entry in browser.fetches.entries { browser.cancelDownload(entry) }
            try? await waitUntil {
                browser.fetches.entries.isEmpty && browser.downloading.isEmpty
            }
            browser.closeAll()
            browser.loot.forgetAll()
            browser.history.forget()
        }
        fixture?.stop()
        try? nothingShown()
        window?.contentView = nil
        window?.orderOut(nil)
        window?.close()
        if let downloadFolder { try? FileManager.default.removeItem(at: downloadFolder) }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        page = nil
        browser = nil
        window = nil
        fixture = nil
    }

    @Test func webKitFailureWithResumeDataResumesSameEntryAndDestination() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/failure.bin", in: tab)
        try await waitUntil { entry.state == .failed }

        let originalID = entry.id
        let reason = try #require(entry.errorDescription)
        let destination = try #require(entry.destination)
        #expect(!reason.isEmpty)
        #expect(entry.canResume, "WebKit should return resume data for the ranged fixture")
        #expect(entry.canRetry)

        if let snapshotPath = ProcessInfo.processInfo.environment["SEARCH_DOWNLOAD_SNAPSHOT"], !snapshotPath.isEmpty {
            let paused = try await startDownload("/range.bin", in: tab)
            try await waitUntil { paused.completedBytes >= 64 * 1024 && paused.destination != nil }
            browser.pauseDownload(paused)
            try await waitUntil { paused.state == .paused }
            #expect(paused.canResume)
            #expect(FileManager.default.fileExists(atPath: try #require(paused.destination).path))

            let active = try await startDownload("/range.bin", in: tab)
            try await waitUntil { active.completedBytes >= 32 * 1024 }
            try writePanelSnapshot(to: URL(fileURLWithPath: snapshotPath))
        }

        browser.resumeDownload(entry)
        // A repeated click while WebKit is creating the resumed download must
        // not start a second attempt or replace the row.
        browser.resumeDownload(entry)
        try await waitUntil {
            entry.state == .downloading || browser.loot.kept.contains { $0.path == entry.destination?.path }
        }
        #expect(entry.id == originalID)
        #expect(entry.destination == destination)

        try await waitUntil {
            browser.loot.kept.contains { $0.path == destination.path }
        }
        #expect(!browser.fetches.entries.contains { $0.id == originalID })
        #expect(try Data(contentsOf: destination) == fixture.expectedBytes())
        #expect(fixture.ranges("/failure.bin").contains { Self.rangeOffset($0) > 0 })
        #expect(fixture.cookies("/failure.bin").allSatisfy { $0?.contains("download-session=fixture-cookie") == true })
    }

    @Test func pauseResumeKeepsBytesAndDestination() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/range.bin", in: tab)
        try await waitUntil { entry.completedBytes >= 64 * 1024 && entry.destination != nil }

        let originalID = entry.id
        let destination = try #require(entry.destination)
        browser.pauseDownload(entry)
        // The second request arrives while the first cancellation is pending.
        // It must not ask WebKit to stop twice.
        browser.pauseDownload(entry)
        try await waitUntil { entry.state == .paused }
        let pausedBytes = entry.completedBytes
        #expect(entry.canResume)
        #expect(entry.id == originalID)
        #expect(entry.destination == destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))

        browser.resumeDownload(entry)
        browser.resumeDownload(entry)
        try await waitUntil {
            entry.state == .downloading || browser.loot.kept.contains { $0.path == entry.destination?.path }
        }
        // The row, the ring and Finder's bar go on from what had come in,
        // not from nothing: the first measure after the resume already
        // counts the bytes on disk.
        var ring: Double?
        try await waitUntil {
            if ring == nil, let value = browser.fetches.fraction { ring = value }
            return entry.completedBytes > 0 && ring != nil || browser.loot.kept.contains { $0.path == destination.path }
        }
        #expect(entry.completedBytes >= pausedBytes, "the row started over after the resume")
        if let ring, entry.totalBytes > 0 {
            #expect(ring >= (Double(pausedBytes) / Double(entry.totalBytes) - 0.02), "the ring started over after the resume")
        }
        #expect(entry.id == originalID)
        #expect(entry.destination == destination)
        try await waitUntil { browser.loot.kept.contains { $0.path == destination.path } }

        #expect(!browser.fetches.entries.contains { $0.id == originalID })
        #expect(try Data(contentsOf: destination) == fixture.expectedBytes())
        #expect(fixture.ranges("/range.bin").contains { Self.rangeOffset($0) > 0 })
        #expect(fixture.cookies("/range.bin").allSatisfy { $0?.contains("download-session=fixture-cookie") == true })
    }

    @Test func failureWithoutResumeDataKeepsReasonAndCanRetryFromStart() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/retry.bin", in: tab)
        try await waitUntil { entry.state == .failed }

        let originalID = entry.id
        let reason = try #require(entry.errorDescription)
        #expect(!reason.isEmpty)
        #expect(!entry.canResume)
        #expect(entry.canRetry)

        browser.retryDownload(entry)
        #expect(entry.id == originalID)
        try await waitUntil {
            entry.state == .downloading || browser.loot.kept.contains { $0.path == entry.destination?.path }
        }
        #expect(entry.errorDescription == nil)
        try await waitUntil { browser.loot.kept.contains { $0.name.hasPrefix("fixture") } }

        let keep = try #require(browser.loot.kept.first { $0.name.hasPrefix("fixture") })
        #expect(try Data(contentsOf: keep.url) == fixture.expectedBytes())
        #expect(fixture.count("/retry.bin") == 2)
        #expect(fixture.ranges("/retry.bin").allSatisfy { $0 == nil })
        #expect(fixture.cookies("/retry.bin").allSatisfy { $0?.contains("download-session=fixture-cookie") == true })
    }

    @Test func deletedSpaceTakesItsRunningDownloadWithIt() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/cancel.bin", in: tab)
        try await waitUntil { entry.completedBytes >= 64 * 1024 && entry.destination != nil }
        let destination = try #require(entry.destination)
        let store = try #require(entry.store)
        let id = entry.id

        browser.forgetDownloads(of: store)
        try await waitUntil {
            !browser.fetches.entries.contains { $0.id == id } && browser.downloading.isEmpty
        }

        #expect(entry.store == nil, "a forgotten store is still kept by its row")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cancelRemovesEntryAndPartialFile() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/cancel.bin", in: tab)
        try await waitUntil { entry.completedBytes >= 64 * 1024 && entry.destination != nil }
        let destination = try #require(entry.destination)
        let id = entry.id

        browser.cancelDownload(entry)
        browser.cancelDownload(entry)
        try await waitUntil {
            !browser.fetches.entries.contains { $0.id == id } && browser.downloading.isEmpty
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(browser.loot.kept.isEmpty)
    }

    @Test func removingPausedDownloadPreservesAReplacementFile() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/range.bin", in: tab)
        try await waitUntil { entry.completedBytes >= 64 * 1024 && entry.destination != nil }
        let destination = try #require(entry.destination)

        browser.pauseDownload(entry)
        try await waitUntil { entry.state == .paused }
        #expect(FileManager.default.fileExists(atPath: destination.path))

        let replacement = Data("a file placed here after the pause".utf8)
        try replacement.write(to: destination, options: .atomic)
        browser.cancelDownload(entry)
        try await waitUntil { !browser.fetches.entries.contains { $0.id == entry.id } }

        #expect(try Data(contentsOf: destination) == replacement)
    }

    @Test func privateDownloadNeverEntersSharedEntriesHistoryOrCompletedList() async throws {
        browser.window = nil
        browser = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        browser.window = window
        let tab = browser.open(URL(string: "about:blank")!, foreground: true)
        #expect(tab.shy)
        page = tab
        window.contentView = tab.web
        tab.go(to: fixture.url("/page"))
        try await waitUntil { tab.committed == fixture.url("/page") && !tab.loading }
        try await waitUntil { fixture.completed("/page") == 1 }

        _ = try await requestDownload("/private.bin", from: tab.web)
        #expect(browser.fetches.entries.isEmpty)

        try await waitUntil {
            fixture.completed("/private.bin") == 1 && browser.downloading.isEmpty
        }
        #expect(browser.fetches.entries.isEmpty)
        #expect(browser.loot.kept.isEmpty)
        #expect(!browser.history.everything(matching: "127.0.0.1").contains { $0.url == fixture.url("/page") })
        #expect(fixture.cookies("/private.bin").contains { $0?.contains("download-session=fixture-cookie") == true })
    }

    private func openFixturePage() async throws -> BrowserTab {
        let tab = browser.open(URL(string: "about:blank")!, foreground: true)
        page = tab
        window.contentView = tab.web
        tab.go(to: fixture.url("/page"))
        try await waitUntil { tab.committed == fixture.url("/page") && !tab.loading }
        try await waitUntil { fixture.completed("/page") == 1 }
        return tab
    }

    private func startDownload(_ path: String, in tab: BrowserTab) async throws -> FetchEntry {
        let download = try await requestDownload(path, from: tab.web)
        return try #require(browser.fetches.entry(for: download))
    }

    private func requestDownload(_ path: String, from webView: WKWebView) async throws -> WKDownload {
        let request = URLRequest(url: fixture.url(path))
        let received = Expectation(description: "WebKit creates a download for \(path)")
        let browser = try #require(browser)
        var result: WKDownload?
        webView.startDownload(using: request) { download in
            browser.keep(download, from: webView)
            result = download
            received.fulfill()
        }
        await fulfillment(of: [received], timeout: 30)
        return try #require(result)
    }

    private func writePanelSnapshot(to destination: URL) throws {
        browser.edit()
        browser.enterPlace(.downloads)
        defer { browser.quitField() }
        let host = FieldPicture(browser: browser, menu: browser.fieldMenu, size: NSSize(width: 640, height: 474))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 474)
        let snapshotWindow = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 474),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        snapshotWindow.isReleasedWhenClosed = false
        snapshotWindow.contentView = host
        snapshotWindow.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw SnapshotError.couldNotRender
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.couldNotEncode
        }
        try data.write(to: destination, options: .atomic)
        snapshotWindow.close()
    }

    /// These tests never put a window in, nor bring the app forward: one
    /// that did would be on someone's screen. It fails the test, and
    /// everything is put away at once.
    private func nothingShown(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let shown = NSApp.windows.filter(\.isVisible)
        guard !shown.isEmpty || NSApp.isActive else { return }
        for window in NSApp.windows { window.orderOut(nil); window.close() }
        NSApp.hide(nil)
        Issue.record("a window was shown or the app came forward: \(shown)", sourceLocation: sourceLocation)
        throw WaitError.timedOut
    }

    private func waitUntil(
        timeout: TimeInterval = 60,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            try nothingShown(sourceLocation: sourceLocation)
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let entries = browser.fetches.entries.map { "\($0.name): \($0.state), \($0.completedBytes) bytes" }
        let served = ["/page", "/private.bin"].map { "\($0) \(fixture.completed($0))" }
        Issue.record("Timed out waiting for the download state; entries: \(entries); completed: \(browser.loot.kept.map(\.name)); downloading: \(browser.downloading.count); served: \(served)", sourceLocation: sourceLocation)
        throw WaitError.timedOut
    }

    private static func rangeOffset(_ header: String?) -> Int {
        guard let header, let equals = header.firstIndex(of: "="), let dash = header.firstIndex(of: "-") else { return 0 }
        return Int(header[header.index(after: equals)..<dash]) ?? 0
    }

    private enum WaitError: Error { case timedOut }
    private enum SnapshotError: Error { case couldNotRender, couldNotEncode }
}
