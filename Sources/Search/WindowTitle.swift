import AppKit

@MainActor
enum WindowTitle {
    static func name(page: String, private shy: Bool) -> String {
        if shy { return "Private Window" }
        let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Broadway" : trimmed
    }

    static func title(of tab: Tab) -> String {
        name(page: tab.isBlank ? tab.name ?? "" : tab.label, private: tab.shy)
    }

    static func set(_ tab: Tab, in window: NSWindow) {
        let title = title(of: tab)
        guard window.title != title else { return }
        window.title = title
        Lights.refreshIfMoved(window)
        DispatchQueue.main.async { Lights.refreshIfMoved(window) }
    }
}
