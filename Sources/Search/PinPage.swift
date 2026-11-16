import AppKit

extension Browser {
    func pinMovedOff(_ tab: Tab) -> Bool {
        guard tab.pin != nil, let home = tab.home else { return false }
        return !Browser.samePage(home, tab.address)
    }

    func setPinnedPage(_ tab: Tab) {
        guard pinMovedOff(tab), let here = tab.address else { return }
        tab.home = here
        writeSession(now: true)
    }

    func goBackToPinnedPage(_ tab: Tab) {
        guard pinMovedOff(tab) else { return }
        goHome(tab)
    }

    static func pinnedAddress(_ typed: String) -> URL? {
        guard let url = Address.url(from: typed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host()?.isEmpty == false else { return nil }
        return url
    }

    @discardableResult
    func setPinnedAddress(_ typed: String, for tab: Tab) -> Bool {
        guard tab.pin != nil, let url = Browser.pinnedAddress(typed) else { return false }
        let wasHome = !pinMovedOff(tab)
        tab.home = url
        if wasHome, !Browser.samePage(url, tab.address) { tab.go(to: url) }
        writeSession(now: true)
        return true
    }

    func editPinnedAddress(_ tab: Tab) {
        guard tab.pin != nil else { return }
        var typed = (tab.home ?? tab.address)?.absoluteString ?? ""
        let sheet = SettingsSheet(title: "Edit Pinned Address", width: 420)
        sheet.field("Address", text: typed) { typed = $0 }
        sheet.finish(save: "Save", ready: { Browser.pinnedAddress(typed) != nil }) { [weak self, weak tab] in
            guard let self, let tab else { return true }
            return self.setPinnedAddress(typed, for: tab)
        }
        sheet.show(over: window ?? Links.window)
    }
}
