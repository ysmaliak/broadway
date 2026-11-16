import AppKit
import PDFKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PDFExportTests {
    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    private func tearDown() async {
        #expect(NSApp.windows.allSatisfy { !$0.isVisible }, "a window was shown")
        #expect(!NSApp.isActive)
    }

    @Test func exportKeepsRequestedTabAfterActiveTabChanges() async throws {
        let browser = Browser(record: WindowRecord())
        let requested = try await page("Requested page", in: browser)
        let other = try await page("Different active page", in: browser)
        browser.activeID = requested.id
        let captured = try #require(browser.active)
        browser.activeID = other.id

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Search-PDF-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let worked = await withCheckedContinuation { continuation in
            browser.exportPDF(captured, to: file) { continuation.resume(returning: $0) }
        }
        #expect(worked)
        let text = try #require(PDFDocument(url: file)?.string)
        #expect(text.contains("Requested page"), "Exported the wrong tab: \(text)")
        #expect(!text.contains("Different active page"))
    }

    private func page(_ text: String, in browser: Browser) async throws -> Search.Tab {
        let tab = browser.open(try #require(URL(string: "about:blank")), foreground: true)
        tab.web.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        tab.web.loadHTMLString("<html><body><h1>\(text)</h1></body></html>", baseURL: URL(string: "https://example.invalid/"))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !tab.web.isLoading,
               let body = try? await tab.web.evaluateJavaScript("document.body.innerText"),
               (body as? String)?.contains(text) == true {
                #expect(!tab.isBlank)
                return tab
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "PDFExportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Page did not load"])
    }
}
