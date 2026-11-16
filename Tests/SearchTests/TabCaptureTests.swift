import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)),
       .enabled("WebKit gives this Mac no navigator.mediaDevices (no camera)") { await MediaDevices.present() })
@MainActor
final class TabCaptureTests {
    private var browser: Browser!
    private var windows: [NSWindow] = []
    private var activationPolicy: NSApplication.ActivationPolicy!
    private let permission = CapturePermission()

    init() {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.closeAll()
    }

    private func tearDown() {
        browser.closeAll()
        browser = nil
        for window in windows {
            if let web = window.contentView as? WKWebView {
                web.setCameraCaptureState(.none, completionHandler: nil)
                web.setMicrophoneCaptureState(.none, completionHandler: nil)
            }
            window.close()
        }
        windows = []
        NSApp.setActivationPolicy(activationPolicy)
    }

    @Test func closingTabEndsCaptureWithoutStoppingAnotherTab() async throws {
        let tab = try await capture()
        let other = try await capture()
        let web = tab.web
        let otherWeb = other.web
        browser.close(tab)
        try await ended(web)
        #expect(browser.tabs.contains { $0 === other })
        #expect(otherWeb.cameraCaptureState == .active)
        #expect(otherWeb.microphoneCaptureState == .active)
    }

    @Test func closingLastTabEndsCaptureAndLeavesBlankTab() async throws {
        let tab = try await capture()
        let web = tab.web
        #expect(browser.tabs.count == 1)
        browser.close(tab)
        try await ended(web)
        #expect(browser.tabs.count == 1)
        #expect(browser.tabs[0].isBlank)
    }

    @Test func closingPinnedTabEndsCaptureAndKeepsPin() async throws {
        let tab = try await capture()
        tab.pin = "C"
        let web = tab.web
        browser.close(tab)
        try await ended(web)
        #expect(browser.tabs.contains { $0 === tab })
        #expect(tab.asleep)
        #expect(tab.pin == "C")
    }

    @Test func closingAllTabsEndsItsCapture() async throws {
        let tab = try await capture()
        let web = tab.web
        browser.closeAll()
        try await ended(web)
        #expect(browser.tabs.isEmpty)
    }

    private func capture() async throws -> Tab {
        let configuration = Web.configuration(shy: true)
        // Refuse to use real hardware if WebKit removes its mock-device seam.
        guard configuration.preferences.responds(to: NSSelectorFromString("_setMockCaptureDevicesEnabled:")) else {
            try Test.cancel("WebKit mock capture devices are unavailable")
        }
        let tab = Tab(shy: true, configuration: configuration)
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
        let web = tab.web
        web.uiDelegate = permission
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        #expect(!Bench.onScreen(window))
        window.orderBack(nil)
        #expect(!Bench.onScreen(window))
        windows.append(window)
        web.loadHTMLString("<title>Capture fixture</title>", baseURL: URL(string: "http://localhost"))
        try await waitUntil("load") { web.title == "Capture fixture" && !web.isLoading }
        _ = try await web.evaluateJavaScript("""
            window.captureResult = 'pending';
            navigator.mediaDevices.getUserMedia({video: true, audio: true}).then(stream => {
                window.captureStream = stream;
                window.captureResult = 'started';
            }, error => { window.captureResult = error.name; });
            void 0;
            """)
        try await waitUntil("capture starts") { web.cameraCaptureState == .active && web.microphoneCaptureState == .active }
        try await waitUntil("stream returned") { try await web.evaluateJavaScript("window.captureResult !== 'pending'") as? Bool == true }
        let result = try await web.evaluateJavaScript("window.captureResult") as? String
        #expect(result == "started")
        return tab
    }

    private func ended(_ web: WKWebView) async throws {
        // Retaining the old view makes teardown independent of deallocation.
        try await waitUntil("capture ends") { web.cameraCaptureState == .none && web.microphoneCaptureState == .none }
        let states = try? await web.evaluateJavaScript("window.captureStream.getTracks().map(track => track.readyState)") as? [String]
        if let states { #expect(states.sorted() == ["ended", "ended"]) }
    }

    private func waitUntil(_ description: String, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while try await condition() == false {
            guard Date() < deadline else {
                Issue.record("Timed out: \(description)")
                throw NSError(domain: "TabCaptureTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for WebKit capture state"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class CapturePermission: NSObject, WKUIDelegate {
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }
}

@MainActor
enum MediaDevices {
    private static var known: Bool?

    static func present() async -> Bool {
        if let known { return known }
        _ = NSApplication.shared
        let web = WKWebView(frame: .zero, configuration: Web.configuration(shy: true))
        web.loadHTMLString("<title>Media probe</title>", baseURL: URL(string: "http://localhost"))
        let deadline = Date().addingTimeInterval(10)
        while web.title != "Media probe" || web.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let found = try? await web.evaluateJavaScript("typeof navigator.mediaDevices?.getUserMedia === 'function'")
        known = found as? Bool == true
        return known == true
    }
}
