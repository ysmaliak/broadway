import Foundation

enum ClickedWindow {
    static func blank(_ url: URL?) -> Bool {
        guard let url else { return true }
        return url.scheme?.lowercased() == "about" && url.absoluteString.lowercased().hasPrefix("about:blank")
    }

    static func takesOpenersClick(committed: URL?, shownPage: Bool, byClick: Bool) -> Bool {
        committed == nil || (byClick && !shownPage)
    }
}

extension Tab {
    var takesOpenersClick: Bool {
        ClickedWindow.takesOpenersClick(committed: committed, shownPage: shownPage, byClick: openedByClick)
    }
}
