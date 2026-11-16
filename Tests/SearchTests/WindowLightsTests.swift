import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct WindowLightsTests {
    private static let asked = ["_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus", "hasKeyAppearance",
                                "hasMainAppearance", "_hasActiveAppearanceForStandardWindowButton:"]

    private func appKits(_ type: AnyClass, _ selector: String) -> Bool {
        guard class_getInstanceMethod(type, NSSelectorFromString(selector)) != nil else { return true }
        let address = unsafeBitCast(class_getMethodImplementation(type, NSSelectorFromString(selector)), to: UnsafeRawPointer.self)
        var info = Dl_info()
        guard dladdr(address, &info) != 0, let file = info.dli_fname else { return false }
        return String(cString: file).hasSuffix("/AppKit")
    }

    private func active(_ window: NSWindow) -> Bool {
        let name = NSSelectorFromString("_hasActiveAppearance")
        typealias Ask = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(window.method(for: name), to: Ask.self)(window, name)
    }

    @Test func aBrowserWindowLeavesTheActiveLookToAppKit() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            ContentView.forget(browser)
            browser.closeAll()
            window.contentView = nil
            window.close()
        }
        window.contentView = ContentView(browser: browser)
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(window.titlebarAppearsTransparent)
        for selector in Self.asked {
            #expect(appKits(NSWindow.self, selector), "\(selector) is answered by something other than AppKit")
        }
        #expect(!window.isKeyWindow && !window.isMainWindow)
        #expect(!active(window))
    }
}
