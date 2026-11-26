import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PageScriptNamesTests {
    private func open() async throws -> (Browser, Tab, LocalPageServer) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let server = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><p>Fixture</p>")])
        let browser = Browser(record: WindowRecord())
        let tab = browser.benchOpen(server.url("/page"))
        for _ in 0..<300 where tab.loading || tab.committed == nil { try await Task.sleep(for: .milliseconds(10)) }
        return (browser, tab, server)
    }

    private func read(_ js: String, in tab: Tab) async -> String? {
        await withCheckedContinuation { done in
            tab.web.evaluateInSearch("String(\(js))") { done.resume(returning: $0 as? String) }
        }
    }

    private func value(_ js: String, in tab: Tab, until wanted: String) async throws -> String? {
        var said: String?
        for _ in 0..<100 {
            said = await read(js, in: tab)
            if said == wanted { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if said == nil {
            let plain = await read("1 + 1", in: tab)
            Issue.record("nothing read: \(tab.web.url?.absoluteString ?? "no address"), loading \(tab.loading), plain \(plain ?? "nil")")
        }
        return said
    }

    @Test func theSwipeAndPullScriptsSpeakToTheScrollRelayUnderBroadwaysName() async throws {
        let (browser, tab, server) = try await open()
        defer {
            browser.closeAll()
            server.stop()
        }

        tab.web.evaluateInSearch(Swipe.watch)
        let found = try await value("[window.__broadwaySwipe === true, !!window.webkit.messageHandlers.\(ScrollRelay.name)]", in: tab, until: "true,true")

        #expect(found == "true,true")
        #expect(ScrollRelay.name == "broadwayScroll")
        for script in [Swipe.watch, PullRefresh.watch] {
            #expect(script.contains("messageHandlers.\(ScrollRelay.name).postMessage"))
            #expect(!script.contains("office"))
        }
    }

    @Test func thePickerAnswersTheTabsCallsUnderBroadwaysName() async throws {
        let (browser, tab, server) = try await open()
        defer {
            browser.closeAll()
            server.stop()
        }

        tab.web.evaluateInSearch(Veiling.picker)
        tab.web.evaluateInSearch(Veiling.style("p { display: none !important; }"))
        tab.startPicking()
        let picking = try await value("document.documentElement.style.cursor", in: tab, until: "crosshair")
        tab.peek("p", keeping: "p { display: none !important; }")
        let sheets = try await value("[!!document.getElementById('broadway-veil'), !!document.getElementById('broadway-peek')]", in: tab, until: "true,true")
        tab.stopPicking()
        let stopped = try await value("document.documentElement.style.cursor", in: tab, until: "")

        #expect(picking == "crosshair")
        #expect(sheets == "true,true")
        #expect(stopped == "")
        #expect(VeilRelay.name == "broadwayVeil")
        #expect(Veiling.picker.contains("messageHandlers.\(VeilRelay.name).postMessage"))
        #expect(!(Veiling.picker + Veiling.style("")).contains("office"))
    }
}
