import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct ClosedTabMediaTests {
    enum Leaving: String, CaseIterable {
        case closed, pinPutDown, putAway, closedBelow, windowClosed
    }

    @Test(arguments: Leaving.allCases)
    func aPageLeavingStopsItsMediaEvenWhileItsViewIsHeld(_ leaving: Leaving) async throws {
        try await withPlayingPage { browser, tab, web in
            #expect(await stillPlaying(web))

            switch leaving {
            case .closed:
                browser.closeTab(tab)
            case .pinPutDown:
                browser.pin(tab)
                browser.closeTab(tab)
                browser.unpin(tab)
            case .putAway:
                let group = browser.addTabGroup(containing: tab)
                browser.setFolderPinned(group, true)
                #expect(browser.putsAway(tab))
                browser.closeTab(tab)
            case .closedBelow:
                browser.closeTabsBelow(browser.tabs[0])
            case .windowClosed:
                browser.closeAll()
            }

            #expect(tab.built == nil)
            try? await Task.sleep(for: .milliseconds(300))
            #expect(await !stillPlaying(web))
        }
    }

    @Test func stoppingMediaPausesSuspendsAndClosesPresentations() {
        let web = MediaSpy(frame: .zero, configuration: WKWebViewConfiguration())

        web.stopAllMedia()

        #expect(web.calls == ["pause", "suspend", "close"])
    }

    private func stillPlaying(_ web: WKWebView) async -> Bool {
        let answer = Answer()
        web.evaluateJavaScript("!document.getElementById('v').paused") { value, _ in answer.value = value as? Bool ?? false }
        for _ in 0..<40 where answer.value == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return answer.value ?? false
    }

    private func withPlayingPage(_ body: (Browser, Tab, WKWebView) async throws -> Void) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("closed-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.tone().write(to: folder.appendingPathComponent("tone.wav"))
        let page = folder.appendingPathComponent("page.html")
        try """
            <!doctype html><video id=v loop playsinline src="tone.wav"></video>
            <script>window.ready = true</script>
            """.write(to: page, atomically: true, encoding: .utf8)

        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = prefs.floatsOnLeave
        prefs.floatsOnLeave = false
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            browser.closeAll()
            window.close()
            prefs.floatsOnLeave = saved
        }
        browser.active?.restore(url: URL(string: "about:blank#first")!, title: "First")
        let tab = browser.benchOpen(page)
        tab.bench = false
        let web = tab.web
        web.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(web)
        web.loadFileURL(page, allowingReadAccessTo: folder)
        try await waitUntil("the page loads") {
            (try? await web.evaluateJavaScript("window.ready === true")) as? Bool == true
        }
        _ = try? await web.evaluateJavaScript("document.getElementById('v').volume = 0.01; document.getElementById('v').play(); true")
        try await waitUntil("the page plays") { await web.requestMediaPlaybackState() == .playing }
        try await body(browser, tab, web)
    }

    private func waitUntil(_ message: String, _ predicate: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out waiting for \(message)")
        throw NSError(domain: "ClosedTabMediaTests", code: 1)
    }

    private static func tone() -> Data {
        let rate = 22050
        var samples = Data()
        for index in 0..<(rate * 2) {
            var value = Int16(24 * sin(2 * Double.pi * 440 * Double(index) / Double(rate))).littleEndian
            samples.append(Data(bytes: &value, count: 2))
        }
        var data = Data("RIFF".utf8)
        func put<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: MemoryLayout<T>.size))
        }
        put(UInt32(36 + samples.count))
        data.append(Data("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(Data("data".utf8))
        put(UInt32(samples.count))
        data.append(samples)
        return data
    }
}

@MainActor
private final class Answer {
    var value: Bool?
}

private final class MediaSpy: WKWebView {
    var calls: [String] = []

    override func pauseAllMediaPlayback(completionHandler: (@MainActor @Sendable () -> Void)? = nil) {
        calls.append("pause")
    }

    override func setAllMediaPlaybackSuspended(_ suspended: Bool, completionHandler: (@MainActor @Sendable () -> Void)? = nil) {
        if suspended { calls.append("suspend") }
    }

    override func closeAllMediaPresentations(completionHandler: (@MainActor @Sendable () -> Void)? = nil) {
        calls.append("close")
    }
}
