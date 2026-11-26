import AppKit
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PrivateZoomTests {
    @Test func aPrivateTabKeepsItsZoomForTheSiteOnTheNextPageAndWritesNothing() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { browser.closeAll() }
        let tab = browser.open(URL(string: "https://shop.example/one")!, foreground: true)
        #expect(tab.shy)
        tab.restore(url: URL(string: "https://shop.example/one")!, title: "One")

        tab.magnify(to: 1.5)
        tab.web.pageZoom = 1
        tab.applyRememberedZoom()

        #expect(abs(tab.zoom - 1.5) < 0.01)
        #expect(abs(tab.web.pageZoom - 1.5) < 0.01)
        #expect(Store.settings.object(forKey: "zoom.shop.example") == nil)
    }

    @Test func aPrivateTabZoomedBackToTheDefaultStaysAtTheDefault() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Store.settings.set(2.0, forKey: "zoom.shop.example")
        defer { Store.settings.removeObject(forKey: "zoom.shop.example") }
        let browser = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { browser.closeAll() }
        let tab = browser.open(URL(string: "https://shop.example/one")!, foreground: true)
        tab.restore(url: URL(string: "https://shop.example/one")!, title: "One")
        tab.web.pageZoom = 2
        tab.applyRememberedZoom()

        tab.magnify(to: Tab.defaultZoom)
        tab.web.pageZoom = 2
        tab.applyRememberedZoom()

        #expect(abs(tab.zoom - Tab.defaultZoom) < 0.01)
        #expect(Store.settings.double(forKey: "zoom.shop.example") == 2.0)
    }
}
