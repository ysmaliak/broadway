import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct OmniboxTransitionTests {
    init() {
        keepSettings("newtab.floating")
    }

    @Test func floatingFieldReopensAndDismissesWithAndWithoutSplitView() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let prefs = browser.prefs
        let saved = (prefs.floatingNewTab, prefs.splitView)
        defer {
            browser.closeAll()
            prefs.floatingNewTab = saved.0
            prefs.splitView = saved.1
        }
        prefs.floatingNewTab = true
        browser.newTab()
        let tab = try #require(browser.active)
        tab.go(to: URL(string: "about:blank")!)
        // The empty fixture has no non-empty WebKit frame to reveal it.
        tab.web.showFirstFrame()

        for splitView in [false, true] {
            prefs.splitView = splitView
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = ContentView(browser: browser)
            window.orderFrontRegardless()
            defer {
                ContentView.forget(browser)
                window.contentView = nil
                window.close()
            }
            try await waitUntil("the page mounts") { tab.web.window === window && tab.web.bounds.width > 0 }
            let count = browser.tabs.count
            for _ in 0..<2 {
                browser.launch()
                try await waitUntil("the floating field becomes first responder") {
                    guard let content = window.contentView, let field = addressField(in: content),
                          let editor = field.currentEditor() as? NSTextView else { return false }
                    return browser.launching && window.firstResponder === editor
                }
                #expect(browser.launching)
                #expect(browser.tabs.count == count)
                #expect(browser.activeID == tab.id)
                let content = try #require(window.contentView)
                let field = try #require(addressField(in: content))
                let editor = try #require(field.currentEditor() as? NSTextView)
                #expect(window.firstResponder === editor)

                browser.dismiss()
                try await waitUntil("the floating field hides and returns focus to the page") {
                    !browser.launching && field.isHiddenOrHasHiddenAncestor && window.firstResponder === tab.web
                }
                #expect(!browser.launching)
                #expect(field.isHiddenOrHasHiddenAncestor)
                #expect(field.currentEditor() == nil)
                #expect(window.firstResponder === tab.web)
                let point = tab.web.convert(NSPoint(x: tab.web.bounds.midX, y: tab.web.bounds.midY), to: content.superview)
                let hit = content.hitTest(point)
                #expect(hit === tab.web || hit?.isDescendant(of: tab.web) == true, "The mounted, empty omnibox must not intercept page clicks (split: \(splitView))")
            }
        }
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool,
                           sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for \(message)", sourceLocation: sourceLocation)
        throw WaitError.timedOut
    }

    private enum WaitError: Error { case timedOut }

    private func addressField(in view: NSView) -> AddressTextField? {
        if let field = view as? AddressTextField, !field.isHiddenOrHasHiddenAncestor { return field }
        return view.subviews.compactMap { addressField(in: $0) }.first
    }
}
