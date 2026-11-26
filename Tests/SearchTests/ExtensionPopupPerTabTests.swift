import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionPopupPerTabTests {
    private func made() async throws -> (URL, WKWebExtensionContext) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("popup-per-tab-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Popups", "version": "1", "action": ["default_popup": "popup.html"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return (folder, WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder)))
    }

    private func window(at frame: NSRect) -> (Browser, Tab) {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        let tab = Tab()
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
        browser.select(tab)
        Browsers.register(browser)
        return (browser, tab)
    }

    private func place(of tab: Tab, in browser: Browser, for context: WKWebExtensionContext) throws -> [String: Any] {
        let index = try #require(Extensions.shared.visibleTabs(of: browser, for: context).firstIndex { $0 === tab })
        let frame = try #require(browser.window?.frame)
        let height = NSScreen.screens.first?.frame.height ?? 0
        return ["i": index, "w": ["left": frame.minX, "top": height - frame.maxY, "width": frame.width, "height": frame.height]]
    }

    @Test func aPopupSetForATabInTheSecondWindowIsSetForThatTab() async throws {
        let (folder, context) = try await made()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (one, first) = window(at: NSRect(x: 40, y: 40, width: 500, height: 400))
        let (two, second) = window(at: NSRect(x: 620, y: 60, width: 520, height: 420))
        defer { one.closeAll(); two.closeAll(); one.window = nil; two.window = nil }
        let id = context.uniqueIdentifier
        defer { ExtensionShims.popups[id] = nil }
        let where_ = try place(of: second, in: two, for: context)
        _ = try await ExtensionShims.answer(["api": "action.popup", "args": ["unlocked.html", where_]], from: context, owner: Extensions.shared)
        #expect(ExtensionShims.popups[id]?[second.id.uuidString] == "unlocked.html")
        #expect(ExtensionShims.popups[id]?[first.id.uuidString] == nil)
    }

    @Test func settingTheGeneralPopupKeepsEveryPopupSetForALiveTab() async throws {
        let (folder, context) = try await made()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (browser, tab) = window(at: NSRect(x: 40, y: 40, width: 500, height: 400))
        defer { browser.closeAll(); browser.window = nil }
        let id = context.uniqueIdentifier
        defer { ExtensionShims.popups[id] = nil }
        ExtensionShims.popups[id] = [tab.id.uuidString: "locked.html", UUID().uuidString: "gone.html"]
        _ = try await ExtensionShims.answer(["api": "action.popup", "args": ["general.html", -1]], from: context, owner: Extensions.shared)
        #expect(ExtensionShims.popups[id] == [tab.id.uuidString: "locked.html", "*": "general.html"])
    }

    @Test func aBareTabIndexWithTwoWindowsSetsNoPopup() async throws {
        let (folder, context) = try await made()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (one, _) = window(at: NSRect(x: 40, y: 40, width: 500, height: 400))
        let (two, _) = window(at: NSRect(x: 620, y: 60, width: 520, height: 420))
        defer { one.closeAll(); two.closeAll(); one.window = nil; two.window = nil }
        let id = context.uniqueIdentifier
        defer { ExtensionShims.popups[id] = nil }
        _ = try await ExtensionShims.answer(["api": "action.popup", "args": ["tab.html", 0]], from: context, owner: Extensions.shared)
        #expect((ExtensionShims.popups[id] ?? [:]).isEmpty)
    }
}
