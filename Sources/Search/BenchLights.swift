import AppKit

@MainActor
enum BenchLights {
    static func run(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "lights only works on a --test run"]) }
        if let hold = request["hold"] as? Bool { KitLitPanel.benchHold = hold }
        answer(report())
    }

    static func name(_ window: NSWindow?) -> String {
        guard let window else { return "" }
        return "\(type(of: window)) \(window.windowNumber)"
    }

    static func active(_ window: NSWindow, _ selector: String) -> Bool? {
        let name = NSSelectorFromString(selector)
        guard window.responds(to: name) else { return nil }
        typealias Ask = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(window.method(for: name), to: Ask.self)(window, name)
    }

    static func panels() -> [[String: Any]] {
        NSApp.windows.map { window in
            [
                "kind": String(describing: type(of: window)), "number": window.windowNumber, "visible": window.isVisible,
                "key": window.isKeyWindow, "buttons": window.standardWindowButton(.closeButton) != nil,
                "held": (window as? KitLitPanel)?.heldLit ?? false,
                "lit": active(window, "_hasActiveAppearance") as Any,
                "litIgnoringKey": active(window, "_hasActiveAppearanceIgnoringKeyFocus") as Any,
            ]
        }
    }

    static func report() -> [String: Any] {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        return [
            "active": NSApp.isActive, "hidden": NSApp.isHidden,
            "hold": KitLitPanel.benchHold, "asked": KitLitPanel.asked, "panels": panels(),
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
