import AppKit
import WebKit
import Testing
@testable import Search

/// File › Save Page As…: one web archive of the tab it was asked for, that
/// opens again.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PageSaveTests {
    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    private func tearDown() async {
        #expect(NSApp.windows.allSatisfy { !$0.isVisible }, "a window was shown")
        #expect(!NSApp.isActive)
    }

    @Test func saveKeepsRequestedTabAfterActiveTabChanges() async throws {
        let browser = Browser(record: WindowRecord())
        let requested = try await page("Requested page", in: browser)
        let other = try await page("Different active page", in: browser)
        browser.activeID = requested.id
        let captured = try #require(browser.active)
        browser.activeID = other.id

        let file = try await save(captured, in: browser)
        defer { try? FileManager.default.removeItem(at: file) }
        let archive = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        let main = try #require(archive["WebMainResource"] as? [String: Any])
        let html = String(decoding: try #require(main["WebResourceData"] as? Data), as: UTF8.self)
        #expect(html.contains("Requested page"), "Saved the wrong tab: \(html)")
        #expect(!html.contains("Different active page"))
    }

    @Test func savedArchiveOpensAgain() async throws {
        let browser = Browser(record: WindowRecord())
        let tab = try await page("Kept for later", in: browser)
        let file = try await save(tab, in: browser)
        defer { try? FileManager.default.removeItem(at: file) }

        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        web.load(try Data(contentsOf: file), mimeType: "application/x-webarchive", characterEncodingName: "utf-8",
                 baseURL: try #require(URL(string: "https://example.invalid/")))
        try await waitFor("Kept for later", in: web)
    }

    private func save(_ tab: Search.Tab, in browser: Browser) async throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Search-Page-\(UUID().uuidString).webarchive")
        let worked = await withCheckedContinuation { continuation in
            browser.savePage(tab, to: file) { continuation.resume(returning: $0) }
        }
        #expect(worked)
        return file
    }

    private func page(_ text: String, in browser: Browser) async throws -> Search.Tab {
        let tab = browser.open(try #require(URL(string: "about:blank")), foreground: true)
        tab.web.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        tab.web.loadHTMLString("<html><body><h1>\(text)</h1></body></html>", baseURL: URL(string: "https://example.invalid/"))
        try await waitFor(text, in: tab.web)
        #expect(!tab.isBlank)
        return tab
    }

    private func waitFor(_ text: String, in web: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !web.isLoading,
               let body = try? await web.evaluateJavaScript("document.body.innerText"),
               (body as? String)?.contains(text) == true {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "PageSaveTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\"\(text)\" did not load"])
    }
}
