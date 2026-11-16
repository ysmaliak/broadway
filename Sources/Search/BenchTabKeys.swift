import AppKit

@MainActor
enum BenchTabKeys {
    static func run(_ ask: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let board = LinkCopy.board
        if ask["clearBoard"] as? Bool == true { board.clearContents() }
        if ask["pickAll"] as? Bool == true { browser.pickAllTabs() }
        if let number = ask["send"] as? Int { browser.sendToSpace(index: number - 1) }
        if let way = ask["move"] as? String { browser.moveTab(by: way == "up" ? -1 : 1) }
        if let name = ask["copy"] as? String, let style = LinkCopy.Style(rawValue: name) {
            if let folder = (ask["folder"] as? String).flatMap({ name in browser.tabGroups.first { $0.name == name }?.id }) {
                browser.copyFolderLinks(folder, as: style)
            } else if ask["page"] as? Bool == true {
                browser.copyPage(style)
            } else {
                browser.copyLinks(style)
            }
        }
        if let act = ask["menu"] as? String, let tab = tab(ask["id"], in: browser) {
            let chosen = browser.menuTabs(for: tab)
            switch act {
            case "pin": browser.togglePin(chosen, like: tab)
            case "duplicate": browser.duplicate(chosen)
            case "space":
                if let index = ask["space"] as? Int, browser.spaces.indices.contains(index) {
                    browser.move(chosen, toSpace: browser.spaces[index].id)
                }
            case "folder":
                let folder = (ask["folder"] as? String).flatMap { name in browser.tabGroups.first { $0.name == name }?.id }
                browser.move(chosen, toGroup: folder)
            default: break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            answer(report(browser, board: board))
        }
    }

    private static func tab(_ ref: Any?, in browser: Browser) -> Tab? {
        guard let ref = (ref as? String)?.lowercased(), !ref.isEmpty else { return nil }
        return browser.tabs.first { $0.id.uuidString.lowercased().hasPrefix(ref) }
    }

    static func report(_ browser: Browser, board: NSPasteboard) -> [String: Any] {
        let types = (board.types ?? []).map(\.rawValue)
        let picked = browser.pickedTabs
        return [
            "tabs": browser.tabs.map { tab in
                ["id": Bench.short(tab), "url": tab.address?.absoluteString ?? "", "pinned": tab.pin != nil,
                 "group": browser.group(of: tab).flatMap { id in browser.tabGroups.first { $0.id == id }?.name } ?? ""]
            },
            "picked": picked.map(Bench.short),
            "keyTabs": browser.keyTabs.map(Bench.short),
            "active": browser.active.map(Bench.short) ?? "",
            "spaceID": browser.spaceID.uuidString,
            "spaces": browser.spaces.map { ["id": $0.id.uuidString, "name": $0.name] },
            "parked": Dictionary(uniqueKeysWithValues: browser.parked.map { ($0.key.uuidString, $0.value.tabs.compactMap { $0.address?.absoluteString }) }),
            "announcement": browser.announcement ?? "",
            "board": [
                "types": types,
                "string": board.string(forType: .string) ?? "",
                "html": board.string(forType: .html) ?? "",
                "rtf": board.data(forType: .rtf)?.count ?? 0,
            ] as [String: Any],
        ]
    }
}
