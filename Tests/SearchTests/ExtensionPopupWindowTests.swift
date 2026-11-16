import AppKit
import WebKit
import Testing
@testable import Search

/// An extension's popup window (windows.create with type "popup"), on the
/// model only: no window is ever made here.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class ExtensionPopupWindowTests {
    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    private func tearDown() async {
        #expect(NSApp.windows.allSatisfy { !$0.isVisible }, "a window was shown")
        #expect(!NSApp.isActive)
    }

    @Test func popupsAreNeverWrittenDown() {
        let first = Browser(record: WindowRecord())
        let second = Browser(record: WindowRecord())
        let popup = Browser(record: WindowRecord())
        popup.extensionPopup = "some-extension"
        Browsers.register(first)
        Browsers.register(popup)
        Browsers.register(second)
        #expect(Browsers.saved.contains { $0 === first })
        #expect(Browsers.saved.contains { $0 === second })
        #expect(!Browsers.saved.contains { $0 === popup })
    }

    @Test func extensionsSeeAPopupAsOne() async throws {
        let popup = Browser(record: WindowRecord())
        popup.extensionPopup = "some-extension"
        let plain = Browser(record: WindowRecord())
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: Self.extensionFolder()))
        #expect(ExtensionWindow(owner: Extensions.shared, browser: popup).windowType(for: context) == .popup)
        #expect(ExtensionWindow(owner: Extensions.shared, browser: plain).windowType(for: context) == .normal)
    }

    @Test func aPopupWithASizeButNoPlaceIsCentred() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let sized = try #require(Extensions.popupFrame(asked: CGRect(x: CGFloat.nan, y: .nan, width: 800, height: 850), on: screen))
        #expect(sized == CGRect(x: 320, y: 25, width: 800, height: 850))
        let tall = try #require(Extensions.popupFrame(asked: CGRect(x: CGFloat.nan, y: .nan, width: 400, height: 2000), on: screen))
        #expect(tall.height == 900, "a popup taller than the screen is kept on it")
        #expect(Extensions.popupFrame(asked: CGRect(x: CGFloat.nan, y: .nan, width: CGFloat.nan, height: .nan), on: screen) == nil)
        #expect(Extensions.popupFrame(asked: CGRect(x: 0, y: 0, width: 50, height: 50), on: screen) == nil)
    }

    private static func extensionFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("popup-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"manifest_version": 3, "name": "Popup test", "version": "1.0"}"#.write(
            to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return folder
    }
}
