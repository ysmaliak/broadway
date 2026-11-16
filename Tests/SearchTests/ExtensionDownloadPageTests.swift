import AppKit
import WebKit
import Testing
@testable import Search

/// An extension's downloads.download never goes through a private tab.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionDownloadPageTests {
    @Test func aPrivateTabInFrontIsPassedOver() {
        let shy = Tab(shy: true), plain = Tab()
        _ = shy.web
        _ = plain.web
        #expect(ExtensionShims.downloadPage(active: shy, tabs: [shy, plain]) === plain.built)
        #expect(ExtensionShims.downloadPage(active: plain, tabs: [shy, plain]) === plain.built)
        #expect(ExtensionShims.downloadPage(active: shy, tabs: [shy]) == nil)
    }
}
