import Foundation
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct NotificationForgetTests {
    private let origin = "https://example.com"

    private func permission(in web: WKWebView) async throws -> String? {
        let loaded = Loaded()
        web.navigationDelegate = loaded
        web.loadHTMLString("<p>notifications</p>", baseURL: URL(string: origin + "/"))
        for _ in 0..<500 where !loaded.done { try await Task.sleep(for: .milliseconds(10)) }
        return try await web.evaluateJavaScript("typeof Notification === 'undefined' ? 'none' : Notification.permission") as? String
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    }

    @Test func forgettingASitesNotificationChoiceReachesThePageOnItsNextLoad() async throws {
        let key = SiteNotifications.key(origin)
        Store.settings.set(true, forKey: key)
        defer { Store.settings.removeObject(forKey: key) }
        let web = PageView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: Web.configuration())
        Web.pages.add(web)
        PageNotifications.provide(web)

        let before = try await permission(in: web)
        SiteNotifications.forget(origin)
        let after = try await permission(in: web)

        #expect(before == "granted")
        #expect(after == "default")
    }
}
