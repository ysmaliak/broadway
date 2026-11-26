import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class KeyBoxTests {
    private let browser: Browser
    private let store = ShortcutStore()
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)

    init() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
    }

    private func box(_ id: String) -> KeyBoxView {
        let box = KeyBoxView(browser: browser, store: store, id: id)
        box.frame = NSRect(x: 10, y: 10, width: 80, height: 22)
        window.contentView?.addSubview(box)
        return box
    }

    @Test func aBoxStopsListeningWhenItsWindowStopsBeingKey() {
        let first = box("view.reload")
        first.listen()
        #expect(store.recording)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)

        #expect(!store.recording)
        #expect(first.label != "Type a shortcut")
    }

    @Test func aListeningBoxWritesInTheInkOfItsDarkPill() {
        let first = box("view.reload")
        let words = first.kitSubviews(of: KitLabel.self).first
        first.listen()

        #expect(words?.color == KitPill.ink(.primary))

        first.stop()
        #expect(words != nil)
        #expect(words?.color != KitPill.ink(.primary))
    }

    @Test func startingAnotherBoxStopsTheFirst() {
        let first = box("view.reload")
        let second = box("tabs.duplicate")
        first.listen()

        second.listen()

        #expect(first.label != "Type a shortcut")
        #expect(second.label == "Type a shortcut")
        #expect(store.recording)
        second.stop()
    }

    @Test func aKeyFromAnotherWindowPassesThroughAndEndsListening() throws {
        let first = box("view.reload")
        first.listen()
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w",
                                                isARepeat: false, keyCode: 13))

        #expect(!first.swallows(key))

        #expect(!store.recording)
        #expect(store.key(for: "view.reload") == Command.named("view.reload")?.defaultKey)
    }

    @Test func aClickOutsideTheBoxEndsListening() throws {
        let first = box("view.reload")
        first.listen()
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 300, y: 150), modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

        #expect(!first.swallows(click))

        #expect(!store.recording)
    }
}
