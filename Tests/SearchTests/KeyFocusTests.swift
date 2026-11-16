import AppKit
import Testing
@testable import Search

@MainActor
@Suite("Tab reaches the kit's controls with Full Keyboard Access", .sharedWorld, .timeLimit(.minutes(5)), .serialized)
struct KeyFocusTests {
    init() {
        _ = NSApplication.shared
    }

    private func window(_ views: [NSView]) -> NSWindow {
        let stack = NSStackView.kit(.vertical, spacing: 8, views)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        window.contentView = stack
        window.layoutIfNeeded()
        window.orderFront(nil)
        return window
    }

    private func walk(_ window: NSWindow, steps: Int) -> [NSResponder] {
        if let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\t",
                                      charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) {
            NSApp.postEvent(tab, atStart: true)
            _ = NSApp.nextEvent(matching: .keyDown, until: .distantPast, inMode: .default, dequeue: true)
        }
        window.recalculateKeyViewLoop()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        var cursor = window.contentView.flatMap { all($0).first { $0.canBecomeKeyView } }
        var seen: [NSResponder] = cursor.map { [$0] } ?? []
        for _ in 0..<steps {
            cursor = cursor?.nextValidKeyView
            if let cursor { seen.append(cursor) }
        }
        return seen
    }

    private func withKeyboardAccess<T>(_ on: Bool, _ body: () throws -> T) rethrows -> T {
        let before = KitFocus.keyboardAccess
        KitFocus.keyboardAccess = { on }
        defer { KitFocus.keyboardAccess = before }
        return try body()
    }

    @Test func withKeyboardAccessTabVisitsEveryKitControl() {
        let button = KitButton(.pill(.secondary), label: "Clear") {}
        let toggle = KitSwitch(isOn: false, label: "Block pop-ups")
        let choice = KitChoice("Look", options: [.init(title: "Light"), .init(title: "Dark")], picked: 0)
        let field = NSTextField(string: "")
        let window = window([field, button, toggle, choice])
        defer { window.close() }

        let seen = withKeyboardAccess(true) { walk(window, steps: 8) }

        #expect(seen.contains { $0 === button })
        #expect(seen.contains { $0 === toggle })
        #expect(seen.contains { $0 === choice })
    }

    @Test func withoutKeyboardAccessTabSkipsButtonsAndSwitches() {
        let button = KitButton(.pill(.secondary), label: "Clear") {}
        let toggle = KitSwitch(isOn: false, label: "Block pop-ups")
        let field = NSTextField(string: "")
        let window = window([field, button, toggle])
        defer { window.close() }

        let seen = withKeyboardAccess(false) { walk(window, steps: 6) }

        #expect(!seen.contains { $0 === button })
        #expect(!seen.contains { $0 === toggle })
    }

    @Test func aButtonWithNothingToDoIsSkipped() {
        let idle = KitButton(.pill(.secondary), label: "Nothing")
        let off = KitButton(.pill(.secondary), label: "Off") {}
        off.isEnabled = false

        let taken = withKeyboardAccess(true) { (idle.acceptsFirstResponder, off.acceptsFirstResponder) }

        #expect(taken == (false, false))
    }

    @Test func spaceAndReturnPressAFocusedButton() throws {
        var pressed = 0
        let button = KitButton(.pill(.secondary), label: "Clear") { pressed += 1 }
        let window = window([button])
        defer { window.close() }
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: " ",
                                                  charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                  charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))

        withKeyboardAccess(true) { _ = window.makeFirstResponder(button) }
        button.keyDown(with: space)
        button.keyDown(with: enter)

        #expect(window.firstResponder === button)
        #expect(pressed == 2)
    }

    @Test func aClickNeverTakesTheKeysFromAField() throws {
        let button = KitButton(.pill(.secondary), label: "Clear") {}
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.postEvent(down, atStart: true)
        _ = NSApp.nextEvent(matching: .leftMouseDown, until: .distantPast, inMode: .default, dequeue: true)

        let taken = withKeyboardAccess(true) { button.acceptsFirstResponder }

        #expect(NSApp.currentEvent?.type == .leftMouseDown)
        #expect(!taken)
    }

    @Test func tabReachesTheSettingsPageControls() async throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let window = SettingsWindow.frame(browser, asked: "general")
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        defer {
            window.contentViewController = nil
            window.close()
        }
        window.orderFront(nil)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        let seen = withKeyboardAccess(true) { walk(window, steps: 80) }

        #expect(seen.contains { $0 is KitSwitch }, "\(seen.map { String(describing: type(of: $0)) })")
        #expect(seen.contains { $0 is KitChoice || $0 is NSPopUpButton || $0 is KitButton })
    }
}
