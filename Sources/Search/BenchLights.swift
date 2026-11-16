import AppKit

@MainActor
enum BenchLights {
    static func run(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "lights only works on a --test run"]) }
        answer(report())
    }

    static func name(_ window: NSWindow?) -> String {
        guard let window else { return "" }
        return "\(type(of: window)) \(window.windowNumber)"
    }

    static func report() -> [String: Any] {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        return [
            "active": NSApp.isActive, "hidden": NSApp.isHidden,
            "keyWindow": name(NSApp.keyWindow), "mainWindow": name(NSApp.mainWindow),
            "screen": [Int(screen.minX), Int(screen.minY), Int(screen.width), Int(screen.height)],
            "browsers": Browsers.all.compactMap { browser -> [String: Any]? in
                guard let window = browser.window else { return nil }
                return [
                    "number": window.windowNumber, "key": window.isKeyWindow, "main": window.isMainWindow,
                    "buttons": [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type -> [String: Any]? in
                        guard let button = window.standardWindowButton(type), !button.isHiddenOrHasHiddenAncestor else { return nil }
                        let frame = button.convert(button.bounds, to: nil)
                        return ["frame": [Int(frame.minX), Int(window.frame.height - frame.maxY), Int(frame.width), Int(frame.height)]]
                    },
                ]
            },
        ]
    }
}
