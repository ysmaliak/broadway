import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class QuitConfirmationTests {
    private var previous: Any?

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        previous = Store.settings.object(forKey: Preferences.confirmQuitKey)
        Store.settings.set(true, forKey: Preferences.confirmQuitKey)
    }

    private func tearDown() async {
        Store.settings.set(previous, forKey: Preferences.confirmQuitKey)
    }

    @Test func offByDefaultAndPreferencePersists() {
        Store.settings.removeObject(forKey: Preferences.confirmQuitKey)
        let prefs = Preferences()
        #expect(!prefs.confirmsQuit)
        #expect(Links.shouldQuit())
        prefs.confirmsQuit = true
        #expect(Preferences().confirmsQuit)
        prefs.confirmsQuit = false
        #expect(Links.shouldQuit())
        #expect(NSApp.modalWindow == nil)
    }

    @Test func cancelDeclinesQuitAndCanAskAgain() {
        #expect(!answer("Cancel"))
        #expect(answer("Quit"))
    }

    @Test func cancelIsTheDefaultAndQuitHasNoKeyEquivalent() {
        let answered = answer("Cancel") {
            #expect(NSApp.modalWindow?.defaultButtonCell?.title == "Cancel")
            let quit = self.buttons(NSApp.modalWindow?.contentView).first { $0.title == "Quit" }
            #expect(quit?.keyEquivalent == "")
        }
        #expect(!answered)
    }

    @Test func escapeDeclinesQuit() {
        let answered = answer {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: NSApp.modalWindow!.windowNumber, context: nil,
                                        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                        isARepeat: false, keyCode: 53)!
            NSApp.sendEvent(event)
        }
        #expect(!answered)
    }

    @Test func repeatedQuitDoesNotOpenAnotherQuestion() {
        let answered = answer("Cancel") {
            let window = NSApp.modalWindow
            #expect(!Links.shouldQuit())
            #expect(NSApp.modalWindow === window)
        }
        #expect(!answered)
    }

    @Test func confirmationWithoutBrowserWindowsAndOverExistingSheet() {
        #expect(answer("Quit"))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 200),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: .titled, backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet)
        #expect(!answer("Cancel"))
        #expect(window.attachedSheet === sheet)
        window.endSheet(sheet)
        sheet.close()
        window.close()
    }

    private func answer(_ title: String? = nil, whileAsking: (() -> Void)? = nil) -> Bool {
        var answered = false
        let fallback = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated {
                if !answered { NSApp.stopModal(withCode: .abort) }
            }
        }
        RunLoop.main.add(fallback, forMode: .common)
        var problem: Comment?
        let press = Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.modalWindow else { problem = "No quit confirmation"; return }
                whileAsking?()
                guard let title else { return }
                if let button = self.buttons(window.contentView).first(where: { $0.title == title }) {
                    button.performClick(nil)
                } else {
                    problem = "No \(title) button"
                }
            }
        }
        RunLoop.main.add(press, forMode: .common)
        let result = Links.shouldQuit()
        answered = true
        press.invalidate()
        if let problem { Issue.record(problem) }
        #expect(fallback.isValid, "The native action must dismiss the confirmation")
        fallback.invalidate()
        return result
    }

    private func buttons(_ view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
    }
}
