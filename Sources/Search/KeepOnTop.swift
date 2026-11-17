import AppKit

@MainActor
enum KeepOnTop {
    private static let kept = NSHashTable<NSWindow>.weakObjects()
    private static let recorded = NSHashTable<Browser>.weakObjects()
    private(set) static var asked: [Bool] = []

    static let above = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    static var panelLevel: NSWindow.Level { kept.allObjects.isEmpty ? .floating : above }

    private static var records: Bool { Store.testing && !Store.shownOnScreen }

    static func allowed(fullScreen: Bool, popup: Bool) -> Bool { !fullScreen && !popup }

    static func allowed(_ browser: Browser) -> Bool {
        allowed(fullScreen: browser.fullScreen, popup: browser.isPopup) && (records || browser.window != nil)
    }

    static func isOn(_ browser: Browser) -> Bool {
        if records { return recorded.contains(browser) }
        return browser.window.map(kept.contains) ?? false
    }

    static func toggle(_ browser: Browser) {
        guard allowed(browser) else { return }
        let on = !isOn(browser)
        if records {
            asked.append(on)
            if on { recorded.add(browser) } else { recorded.remove(browser) }
            return
        }
        guard let window = browser.window else { return }
        if on { kept.add(window) } else { kept.remove(window) }
        window.level = on ? .floating : .normal
        lift()
    }

    static func lift() {
        let level = panelLevel
        for window in NSApp.windows where window is NSPanel && !kept.contains(window)
            && (window.level == .floating || window.level == above) {
            window.level = level
        }
    }
}
