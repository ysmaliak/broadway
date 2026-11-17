import AppKit

@MainActor
enum BenchSmall {
    static func handle(_ request: [String: Any], browser: Browser) -> [String: Any] {
        guard Store.testing else { return ["error": "small only works on a --test run"] }
        switch request["action"] as? String {
        case "row":
            return row(request)
        case "find":
            return ["needle": browser.needle, "finding": browser.finding, "status": browser.findStatus ?? "",
                    "board": FindBoard.board.string(forType: .string) ?? ""]
        case "sound":
            let ids = Set((request["noisy"] as? [String] ?? []).map { $0.lowercased() })
            for tab in browser.tabs where ids.contains(where: { tab.id.uuidString.lowercased().hasPrefix($0) }) { tab.noisy = true }
            let menu = TabMenuItems.items(browser: browser, tab: browser.active ?? browser.tabs[0], close: {}).map(\.title)
            return ["tabs": browser.tabs.map { ["id": Bench.short($0), "noisy": $0.noisy, "muted": $0.muted] as [String: Any] },
                    "menu": menu]
        case "ontop":
            return ["asked": KeepOnTop.asked, "on": KeepOnTop.isOn(browser), "level": browser.window?.level.rawValue ?? -1]
        case "login":
            if let refuses = request["refuses"] as? Bool { OpenAtLogin.standIn.refuses = refuses }
            return ["on": OpenAtLogin.standIn.on, "said": browser.announcement ?? ""]
        case "board":
            return ["links": LinkCopy.board.string(forType: .string) ?? ""]
        case "handoff":
            if let text = request["away"] as? String, let url = URL(string: text) {
                browser.newTab()
                browser.active?.restore(url: url, title: url.host() ?? text)
            }
            return ["offered": Handoff.standIn.offered?.absoluteString ?? "", "current": Handoff.current()?.absoluteString ?? "",
                    "active": browser.active.map(Bench.short) ?? ""]
        default:
            return ["error": "small takes row, find, sound, ontop, login, board or handoff"]
        }
    }

    private static func row(_ request: [String: Any]) -> [String: Any] {
        let title = request["menu"] as? String ?? ""
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == title })?.submenu else {
            return ["error": "no \(title) menu"]
        }
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        let name = request["item"] as? String ?? ""
        guard let at = menu.items.firstIndex(where: { $0.title == name }) else {
            return ["error": "no “\(name)” in \(title)", "titles": titles]
        }
        let item = menu.items[at]
        let enabled = (item as? MenuCommand)?.allowed ?? item.isEnabled
        let on = item.state == .on
        let chosen = request["choose"] as? Bool == true && enabled
        if chosen { menu.performActionForItem(at: at) }
        return ["enabled": enabled, "on": on, "chosen": chosen, "titles": titles]
    }
}
