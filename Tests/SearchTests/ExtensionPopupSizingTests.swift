import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionPopupSizingTests {
    @Test func scrollbarDoesNotBecomeThePopupsExplicitWidth() async throws {
        let (web, window) = try await page("""
            html { overflow-y: scroll; } ::-webkit-scrollbar { width: 15px; }
            footer { width: 400px; padding: 10px; }
            """, "<footer>Translation options</footer>")
        defer { window.close() }
        let viewport = try await web.evaluateJavaScript("[innerWidth, document.documentElement.clientWidth]") as? [Double]
        #expect(viewport == [25, 10], "the fixture must reserve space for a scrollbar")
        for _ in 0..<3 {
            let size = try await measure(web)
            #expect(size[0] == 435, "the footer, not the scrollbar-reduced viewport, determines the width")
        }
        let fits = try await web.evaluateJavaScript("document.documentElement.scrollWidth <= document.documentElement.clientWidth && document.documentElement.scrollHeight <= document.documentElement.clientHeight") as? Bool
        #expect(fits == true, "the scrollbar must not hide the footer")
        let reach = try await web.evaluateJavaScript("\(ExtensionPopup.reach)('width')") as? Double
        #expect(reach == 435)
        let style = try await web.evaluateJavaScript("document.documentElement.style.cssText") as? String
        #expect(style == "", "measurement must restore the page's own styling")
    }

    @Test func explicitWidthCanShrinkAndGrowWithScrollbars() async throws {
        for doctype in [true, false] {
            let (web, window) = try await page("""
                html { width: 360px; overflow-y: scroll; } ::-webkit-scrollbar { width: 15px; }
                """, "<p>Vault</p>", doctype: doctype)
            defer { window.close() }
            for width in [360, 280, 480, 280] {
                _ = try await web.evaluateJavaScript("document.documentElement.style.width = '\(width)px'")
                for _ in 0..<2 {
                    let size = try await measure(web)
                    #expect(size[0] == Double(width + 15))
                }
            }
        }
    }

    @Test func flexibleDelayedAndOversizedContent() async throws {
        let (web, window) = try await page("#content { display:flex; }", "<div id=content><div style='width:240px;flex:none;height:80px'>Loading</div></div>")
        defer { window.close() }
        var size = try await measure(web)
        #expect(size == [240, 80])
        _ = try await web.evaluateJavaScript("document.querySelector('#content').innerHTML = '<div style=\"width:460px;flex:none;height:200px\">Ready</div>'")
        size = try await measure(web)
        #expect(size == [460, 200])
        _ = try await web.evaluateJavaScript("document.querySelector('#content').innerHTML = '<div style=\"width:1000px;flex:none;height:900px\">Large</div>'")
        size = try await measure(web)
        #expect(size == [800, 600])
    }

    private func page(_ css: String, _ body: String, doctype: Bool = true) async throws -> (WKWebView, NSWindow) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 25, height: 25), configuration: config)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 25, height: 25),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontRegardless()
        web.loadHTMLString("\(doctype ? "<!doctype html>" : "")<style>body { margin:0 } \(css)</style>\(body)<script>window.ready=true</script>", baseURL: nil)
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("window.ready")) as? Bool == true { return (web, window) }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        window.close()
        throw NSError(domain: "Popup fixture did not load", code: 1)
    }

    private func measure(_ web: WKWebView) async throws -> [Double] {
        let value = try await web.evaluateJavaScript("(\(ExtensionPopup.preferred))()")
        let size = try #require(value as? [Double])
        #expect(size.count == 2)
        web.setFrameSize(NSSize(width: size[0], height: size[1]))
        try await Task.sleep(nanoseconds: 30_000_000)
        return size
    }
}
