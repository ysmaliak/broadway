import AppKit
import Foundation
import WebKit
import Testing
@testable import Search

private typealias BrowserTab = Search.Tab

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SaveAskTests {
    private var browser: Browser!
    private var fixture: LocalDownloadServer!
    private var root: URL!
    private var downloadFolder: URL!
    private var picked: URL!
    private var window: NSWindow!
    private var page: BrowserTab?
    private var restore: (() -> Void)?
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
        let folders = Store.settings.object(forKey: SaveAsk.foldersKey)
        restore = {
            (prefs.downloads, prefs.asksWhereToSave) = saved
            Store.settings.set(folders, forKey: SaveAsk.foldersKey)
        }
        Store.settings.removeObject(forKey: SaveAsk.foldersKey)
        browser.history.forget()
        browser.loot.forgetAll()

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Search-save-ask-\(UUID().uuidString)", isDirectory: true)
        downloadFolder = root.appendingPathComponent("Downloads", isDirectory: true)
        picked = root.appendingPathComponent("Picked", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        browser.prefs.downloads = downloadFolder
        browser.prefs.asksWhereToSave = true

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
        SaveAsk.shared.cancelAll()
        SaveAsk.shared.realNext = 0
        if let browser {
            for entry in browser.fetches.entries { browser.cancelDownload(entry) }
            try? await waitUntil { browser.fetches.entries.isEmpty && browser.downloading.isEmpty }
            browser.closeAll()
            browser.loot.forgetAll()
            browser.history.forget()
        }
        fixture?.stop()
        window?.contentView = nil
        window?.orderOut(nil)
        window?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
        restore?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        page = nil
        browser = nil
        window = nil
        fixture = nil
    }

    @Test func askingOffSendsTheFileToTheDownloadsFolderWithoutAQuestion() async throws {
        browser.prefs.asksWhereToSave = false
        let tab = try await openFixturePage()
        _ = try await requestDownload("/off.bin", from: tab.web)
        try await waitUntil { browser.loot.kept.contains { $0.name.hasPrefix("fixture") } }
        let keep = try #require(browser.loot.kept.first)
        #expect(keep.url.deletingLastPathComponent().standardizedFileURL == downloadFolder.standardizedFileURL)
        #expect(try Data(contentsOf: keep.url) == fixture.expectedBytes())
        #expect(SaveAsk.shared.questions.isEmpty)
    }

    @Test func aLinkDownloadAsksAndTheAnsweredPathGetsTheFile() async throws {
        let tab = try await openFixturePage()
        tab.fileClicks.clicked(tab.popupGesture.interaction + 1, at: ProcessInfo.processInfo.systemUptime)
        _ = try await tab.web.evaluateJavaScript("var a = document.createElement('a'); a.href = '/link.bin'; document.body.appendChild(a); a.click(); 1")
        let question = try await waitForQuestion()
        #expect(question.name == "fixture.bin")
        #expect(question.tab == tab.id)
        #expect(question.folder.standardizedFileURL == downloadFolder.standardizedFileURL)
        let target = picked.appendingPathComponent("chosen.bin")
        #expect(SaveAsk.shared.answer(target))
        try await waitUntil { browser.loot.kept.contains { $0.path == target.path } }
        #expect(try Data(contentsOf: target) == fixture.expectedBytes())
        #expect((try? FileManager.default.contentsOfDirectory(atPath: downloadFolder.path))?.isEmpty == true)
    }

    @Test func thePDFBarSaveAsks() async throws {
        let tab = try await openFixturePage()
        let data = Data("an invented report".utf8)
        browser.webView(tab.web, saveDataToFile: data, suggestedFilename: "report.pdf", mimeType: "application/pdf",
                        originatingURL: fixture.url("/report.pdf"))
        let question = try await waitForQuestion()
        #expect(question.name == "report.pdf")
        let target = picked.appendingPathComponent("report.pdf")
        #expect(SaveAsk.shared.answer(target))
        try await waitUntil { browser.loot.kept.contains { $0.path == target.path } }
        #expect(try Data(contentsOf: target) == data)
    }

    @Test func cancelLeavesNothingInTheListAndNoFile() async throws {
        let tab = try await openFixturePage()
        let download = try await requestDownload("/cancelled.bin", from: tab.web)
        _ = try await waitForQuestion()
        #expect(browser.fetches.entry(for: download) != nil)
        #expect(SaveAsk.shared.cancel())
        try await waitUntil { browser.fetches.entries.isEmpty && browser.downloading.isEmpty }
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(browser.fetches.entries.isEmpty)
        #expect(browser.loot.kept.isEmpty)
        #expect(browser.announcement != "That download didn't finish")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: downloadFolder.path))?.isEmpty == true)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: picked.path))?.isEmpty == true)
    }

    @Test func anExistingFileAtTheAnsweredPathIsReplaced() async throws {
        let target = picked.appendingPathComponent("already.bin")
        try Data("an older file".utf8).write(to: target)
        let tab = try await openFixturePage()
        _ = try await requestDownload("/replace.bin", from: tab.web)
        _ = try await waitForQuestion()
        #expect(SaveAsk.shared.answer(target))
        try await waitUntil { browser.loot.kept.contains { $0.path == target.path } }
        #expect(try Data(contentsOf: target) == fixture.expectedBytes())
        #expect(try FileManager.default.contentsOfDirectory(atPath: picked.path) == ["already.bin"])
    }

    @Test func aSecondQuestionWaitsForTheFirst() async throws {
        let tab = try await openFixturePage()
        _ = try await requestDownload("/first.bin", from: tab.web)
        _ = try await requestDownload("/second.bin", from: tab.web)
        try await waitUntil { SaveAsk.shared.questions.count == 2 }
        let first = SaveAsk.shared.questions[0]
        let second = SaveAsk.shared.questions[1]
        #expect(first.up)
        #expect(!second.up)
        #expect(!SaveAsk.shared.answer(picked.appendingPathComponent("early.bin"), id: second.id))
        #expect(SaveAsk.shared.answer(picked.appendingPathComponent("one.bin"), id: first.id))
        #expect(second.up)
        #expect(SaveAsk.shared.answer(picked.appendingPathComponent("two.bin"), id: second.id))
        try await waitUntil { browser.loot.kept.count == 2 }
        #expect(Set(browser.loot.kept.map(\.name)) == ["one.bin", "two.bin"])
    }

    @Test func theTabClosingUnderAWaitingQuestionCancelsOnce() async throws {
        let tab = try await openFixturePage()
        let other = browser.open(fixture.url("/page"), foreground: false)
        try await waitUntil { other.committed != nil && !other.loading }
        var calls = 0
        var answered: URL? = URL(fileURLWithPath: "/")
        SaveAsk.shared.ask("held.bin", from: other.web, in: browser) { file in
            calls += 1
            answered = file
        }
        let question = try #require(SaveAsk.shared.questions.first)
        #expect(question.tab == other.id)
        _ = try await requestDownload("/closing.bin", from: other.web)
        try await waitUntil { SaveAsk.shared.questions.count == 2 }
        browser.close(other)
        #expect(calls == 1)
        #expect(answered == nil)
        #expect(SaveAsk.shared.questions.isEmpty)
        SaveAsk.shared.cancelAll()
        #expect(calls == 1)
        try await waitUntil { browser.fetches.entries.isEmpty && browser.downloading.isEmpty }
        #expect(browser.loot.kept.isEmpty)
        #expect(browser.tabs.contains { $0.id == tab.id })
    }

    @Test func theWindowClosingUnderAWaitingQuestionCancelsOnce() async throws {
        let tab = try await openFixturePage()
        var calls = 0
        var answered: URL? = URL(fileURLWithPath: "/")
        SaveAsk.shared.ask("held.bin", from: tab.web, in: browser) { file in
            calls += 1
            answered = file
        }
        #expect(SaveAsk.shared.questions.first?.window === window)
        window.close()
        #expect(calls == 1)
        #expect(answered == nil)
        #expect(SaveAsk.shared.questions.isEmpty)
    }

    @Test func aDownloadCancelledFromTheListWithdrawsItsQuestion() async throws {
        let tab = try await openFixturePage()
        let download = try await requestDownload("/withdrawn.bin", from: tab.web)
        _ = try await waitForQuestion()
        let entry = try #require(browser.fetches.entry(for: download))
        browser.cancelDownload(entry)
        try await waitUntil { SaveAsk.shared.questions.isEmpty && browser.fetches.entries.isEmpty && browser.downloading.isEmpty }
        #expect(browser.loot.kept.isEmpty)
    }

    @Test func aPrivateWindowAsksAndRecordsNoLastFolder() async throws {
        let earlier = root.appendingPathComponent("Earlier", isDirectory: true)
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        SaveAsk.remember(earlier, for: browser.spaceID.uuidString)
        let before = Store.settings.dictionary(forKey: SaveAsk.foldersKey) as? [String: String]
        browser.window = nil
        browser = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        browser.window = window
        let tab = browser.open(URL(string: "about:blank")!, foreground: true)
        #expect(tab.shy)
        page = tab
        window.contentView = tab.web
        tab.go(to: fixture.url("/page"))
        try await waitUntil { tab.committed == fixture.url("/page") && !tab.loading }

        _ = try await requestDownload("/private.bin", from: tab.web)
        let question = try await waitForQuestion()
        #expect(!question.keepsFolder)
        #expect(question.folder.standardizedFileURL == earlier.standardizedFileURL)
        let target = picked.appendingPathComponent("quiet.bin")
        #expect(SaveAsk.shared.answer(target))
        try await waitUntil { FileManager.default.fileExists(atPath: target.path) && browser.downloading.isEmpty }
        #expect(browser.loot.kept.isEmpty)
        #expect(Store.settings.dictionary(forKey: SaveAsk.foldersKey) as? [String: String] == before)
    }

    @Test func theLastFolderStartsTheNextQuestionInItsSpace() async throws {
        let space = browser.spaceID.uuidString
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let tab = try await openFixturePage()
        _ = try await requestDownload("/one.bin", from: tab.web)
        #expect(try await waitForQuestion().folder.standardizedFileURL == downloadFolder.standardizedFileURL)
        #expect(SaveAsk.shared.answer(picked.appendingPathComponent("one.bin")))
        try await waitUntil { browser.loot.kept.count == 1 }
        let kept = Store.settings.dictionary(forKey: SaveAsk.foldersKey) as? [String: String]
        #expect(kept?[space] == picked.path)

        SaveAsk.remember(elsewhere, for: UUID().uuidString)
        _ = try await requestDownload("/two.bin", from: tab.web)
        #expect(try await waitForQuestion().folder.standardizedFileURL == picked.standardizedFileURL)
        #expect(SaveAsk.shared.cancel())
        #expect(SaveAsk.lastFolder(for: UUID().uuidString) == nil)
    }

    @Test func anAgentsDownloadNeverAsks() async throws {
        let tab = try await openFixturePage()
        AgentDownloadWatch.expect(tab, person: true, seconds: 30)
        defer { AgentDownloadWatch.unexpect(tab) }
        _ = try await requestDownload("/agent.bin", from: tab.web)
        try await waitUntil { browser.loot.kept.contains { $0.name.hasPrefix("fixture") } }
        let keep = try #require(browser.loot.kept.first)
        #expect(keep.url.deletingLastPathComponent().standardizedFileURL == downloadFolder.standardizedFileURL)
        #expect(SaveAsk.shared.questions.isEmpty)
    }

    @Test func aDownloadFromAnAgentsTabNeverAsks() async throws {
        let tab = try await openFixturePage()
        tab.agent = true
        defer { tab.agent = false }
        let download = try await requestDownload("/own.bin", from: tab.web)
        let entry = try #require(browser.fetches.entry(for: download))
        try await waitUntil { entry.destination != nil }
        #expect(SaveAsk.shared.questions.isEmpty)
        #expect(entry.destination?.path.contains("Agent Downloads") == true)
    }

    @Test func aFolderChosenInSettingsBecomesTheDownloadsFolderAndStopsTheAsking() throws {
        let control = SettingsFolderPopUp(prefs: browser.prefs)
        #expect(control.indexOfSelectedItem == 2)
        control.chose(picked)
        #expect(browser.prefs.downloads.standardizedFileURL == picked.standardizedFileURL)
        #expect(!browser.prefs.asksWhereToSave)
        #expect(control.indexOfSelectedItem == 0)
        #expect(control.titleOfSelectedItem == "Picked")
        control.chose(nil)
        #expect(browser.prefs.downloads.standardizedFileURL == picked.standardizedFileURL)
        #expect(control.indexOfSelectedItem == 0)
    }

    @Test func retryGoesWhereTheFirstAttemptWentWithoutAsking() async throws {
        let tab = try await openFixturePage()
        let download = try await requestDownload("/retry.bin", from: tab.web)
        let entry = try #require(browser.fetches.entry(for: download))
        _ = try await waitForQuestion()
        #expect(SaveAsk.shared.answer(picked.appendingPathComponent("again.bin")))
        try await waitUntil { entry.state == .failed }
        #expect(entry.canRetry)

        browser.retryDownload(entry)
        try await waitUntil { browser.loot.kept.contains { $0.name.hasPrefix("again") } }
        #expect(SaveAsk.shared.questions.isEmpty)
        let keep = try #require(browser.loot.kept.first { $0.name.hasPrefix("again") })
        #expect(keep.url.deletingLastPathComponent().standardizedFileURL == picked.standardizedFileURL)
        #expect(try Data(contentsOf: keep.url) == fixture.expectedBytes())
    }

    private func openFixturePage() async throws -> BrowserTab {
        let tab = browser.open(URL(string: "about:blank")!, foreground: true)
        page = tab
        window.contentView = tab.web
        tab.go(to: fixture.url("/page"))
        try await waitUntil { tab.committed == fixture.url("/page") && !tab.loading }
        return tab
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

    private func waitForQuestion(sourceLocation: SourceLocation = #_sourceLocation) async throws -> SaveAsk.Question {
        try await waitUntil(sourceLocation: sourceLocation) { SaveAsk.shared.questions.contains { $0.up } }
        return try #require(SaveAsk.shared.questions.first { $0.up })
    }

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
        let entries = browser.fetches.entries.map { "\($0.name): \($0.state)" }
        Issue.record("Timed out; entries: \(entries); kept: \(browser.loot.kept.map(\.path)); questions: \(SaveAsk.shared.questions.map(\.name))", sourceLocation: sourceLocation)
        throw WaitError.timedOut
    }

    private enum WaitError: Error { case timedOut }
}
