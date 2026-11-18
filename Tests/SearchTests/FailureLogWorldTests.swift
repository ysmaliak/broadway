import AppKit
import Foundation
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct FailureLogWorldTests {
    @Test func aPrivateWindowsPagesAndDownloadsAreTracedPrivately() throws {
        _ = NSApplication.shared
        let normal = Browser(record: WindowRecord())
        let secret = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer {
            normal.closeAll()
            secret.closeAll()
        }
        let open = normal.open(URL(string: "about:blank#open")!, foreground: true)
        let shut = secret.open(URL(string: "about:blank#shut")!, foreground: true)

        #expect(!normal.tracesPrivately(open.web))
        #expect(!normal.tracesPrivately(open))
        #expect(!normal.tracesPrivately(nil as WKWebView?))
        #expect(secret.tracesPrivately(shut.web))
        #expect(secret.tracesPrivately(shut))
        #expect(secret.tracesPrivately(nil as WKWebView?))
    }

    @Test func anOrdinaryPageLoadTracesOneStep() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/plain": .init(type: "text/html", body: "<title>Plain</title><img src=/dot.png><script src=/a.js></script><iframe src=/inner></iframe><p>plain</p>"),
            "/inner": .init(type: "text/html", body: "<p>inner</p>"),
            "/a.js": .init(type: "text/javascript", body: "window.a = 1"),
        ])
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let port = ":\(server.port)/"
        let mine = { DownloadTrace.events.filter { ($0["url"] ?? "").contains(port) } }

        let tab = browser.open(server.url("/plain"), foreground: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline, tab.committed == nil || tab.web.isLoading {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(500))

        let kinds = mine().map { $0["kind"] ?? "" }
        #expect(tab.committed != nil)
        #expect(kinds.sorted() == ["response-show", "response-show"], "\(kinds)")
    }
}
