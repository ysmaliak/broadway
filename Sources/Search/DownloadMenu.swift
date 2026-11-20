import AppKit

@MainActor
enum DownloadMenu {
    enum Entry: String, Equatable {
        case open, openWith, reveal, copy, share, forget, separator
    }

    static var asked: [String] = []

    static let board: NSPasteboard = Store.testing ? NSPasteboard(name: NSPasteboard.Name("broadway.downloads.\(getpid())")) : .general

    static func entries(there: Bool, forgets: Bool, apps: Int = 1) -> [Entry] {
        var made: [Entry] = []
        if there {
            made = [.open] + (apps > 0 ? [.openWith] : []) + [.reveal, .separator, .copy, .share]
        }
        if forgets {
            if !made.isEmpty { made.append(.separator) }
            made.append(.forget)
        }
        return made
    }

    nonisolated static func ordered(_ apps: [URL], first: URL?) -> [URL] {
        var seen = Set<String>()
        let unique = apps.filter { seen.insert($0.standardizedFileURL.path).inserted }
        let lead = first.flatMap { first in unique.first { $0.standardizedFileURL.path == first.standardizedFileURL.path } }
        let rest = unique.filter { $0.standardizedFileURL.path != lead?.standardizedFileURL.path }
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        return (lead.map { [$0] } ?? []) + rest
    }

    nonisolated static func name(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
    }

    static func apps(for file: URL) -> (all: [URL], first: URL?) {
        let first = NSWorkspace.shared.urlForApplication(toOpen: file)
        let all = ordered(NSWorkspace.shared.urlsForApplications(toOpen: file), first: first)
        return (all, first.flatMap { first in all.first { $0.standardizedFileURL.path == first.standardizedFileURL.path } })
    }

    static func menu(for file: URL, there: Bool, open: @escaping () -> Void, reveal: @escaping () -> Void, forget: (() -> Void)?,
                     from view: NSView, id: String = "downloads.row") -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items(for: file, there: there, open: open, reveal: reveal, forget: forget, from: view, id: id) { menu.addItem(item) }
        return menu
    }

    static func items(for file: URL, there: Bool, open: @escaping () -> Void, reveal: @escaping () -> Void, forget: (() -> Void)?,
                      from view: NSView, id: String = "downloads.row") -> [NSMenuItem] {
        let found: (all: [URL], first: URL?) = there ? apps(for: file) : ([], nil)
        return entries(there: there, forgets: forget != nil, apps: found.all.count).map { entry in
            switch entry {
            case .open: return action("Open", id + ".open", open)
            case .openWith: return openWith(file, apps: found.all, first: found.first, id: id)
            case .reveal: return action("Show in Finder", id + ".reveal", reveal)
            case .copy: return action("Copy File", id + ".copy") { copy(file) }
            case .share: return action("Share…", id + ".share") { [weak view] in share(file, from: view) }
            case .forget: return action("Remove from List", id + ".forget") { forget?() }
            case .separator: return .separator()
            }
        }
    }

    private static func action(_ title: String, _ id: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let made = KitMenuAction(title, key: "", run: run)
        made.setAccessibilityIdentifier(id)
        return made
    }

    private static func openWith(_ file: URL, apps: [URL], first: URL?, id: String) -> NSMenuItem {
        let menu = NSMenu(title: "Open With")
        menu.autoenablesItems = false
        for (index, app) in apps.enumerated() {
            let lead = index == 0 && first != nil
            let made = action(lead ? name(app) + " (default)" : name(app), id + ".openWith." + name(app)) { openWith(file, app: app) }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            made.image = icon
            menu.addItem(made)
            if lead, apps.count > 1 { menu.addItem(.separator()) }
        }
        let made = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        made.setAccessibilityIdentifier(id + ".openWith")
        made.submenu = menu
        return made
    }

    static func openWith(_ file: URL, app: URL) {
        guard !Store.testing else { return asked.append("open \(file.lastPathComponent) with \(name(app))") }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @discardableResult
    static func copy(_ file: URL, to board: NSPasteboard = DownloadMenu.board) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        board.clearContents()
        return board.writeObjects([file as NSURL])
    }

    static func share(_ file: URL, from view: NSView?) {
        guard !Store.testing else { return asked.append("share \(file.lastPathComponent)") }
        guard let view, view.window != nil else { return }
        NSSharingServicePicker(items: [file]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}
