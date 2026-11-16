import AppKit
import Foundation
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FetchEntryTests {
    init() async throws {        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    @Test func failedResumeDataAllowsResumeWithoutOriginalRequest() async throws {
        let webView = makeWebView()
        let entry = FetchEntry(name: "archive.zip", request: nil, webView: webView)
        entry.failed(NSError(domain: "DownloadFixture", code: 1), resumeData: Data([1, 2, 3]))

        #expect(entry.state == .failed)
        #expect(entry.canResume)
        #expect(!entry.canRetry)
        #expect(try #require(Fetches().beginResume(entry)?.resumeData) == Data([1, 2, 3]))
    }

    @Test func pauseWithoutResumeDataBecomesRetryableWithVisibleReason() async throws {
        let webView = makeWebView()
        let request = URLRequest(url: URL(string: "https://example.test/archive.zip")!)
        let entry = FetchEntry(name: "archive.zip", request: request, webView: webView)

        entry.stopped(.pause, data: nil)

        #expect(entry.state == .failed)
        #expect(!entry.canResume)
        #expect(entry.canRetry)
        #expect(try #require(entry.errorDescription).contains("doesn't support pausing this download"))
    }

    @Test func beginResumeRejectsDuplicateActionWhileWebKitStarts() async throws {
        let webView = makeWebView()
        let entry = FetchEntry(name: "archive.zip", request: nil, webView: webView)
        entry.failed(NSError(domain: "DownloadFixture", code: 1), resumeData: Data([1]))
        let fetches = Fetches()

        let first = try #require(fetches.beginResume(entry))

        #expect(fetches.accepts(first))
        #expect(fetches.beginResume(entry) == nil)
    }

    @Test func removingPendingStartInvalidatesItsCallback() async throws {
        let webView = makeWebView()
        let request = URLRequest(url: URL(string: "https://example.test/archive.zip")!)
        let entry = FetchEntry(name: "archive.zip", request: request, webView: webView)
        entry.failed(NSError(domain: "DownloadFixture", code: 1), resumeData: nil)
        let fetches = Fetches()
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("retry.zip")
        let start = try #require(fetches.beginRetry(entry, destination: { target }))

        #expect(fetches.accepts(start))
        fetches.removeStarting(entry)

        #expect(!fetches.accepts(start))
        #expect(entry.request == nil)
        #expect(entry.webView == nil)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }
}
