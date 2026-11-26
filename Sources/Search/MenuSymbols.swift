import AppKit

enum MenuSymbol {
    static let pin = "pin"
    static let unpin = "pin.slash"
    static let rename = "pencil"
    static let bookmark = "bookmark"
    static let bookmarked = "bookmark.fill"
    static let copy = "doc.on.doc"
    static let link = "link"
    static let split = "rectangle.split.2x1"
    static let move = "arrow.up.and.down.and.arrow.left.and.right"
    static let close = "xmark"
    static let newTab = "plus.square.on.square"
    static let newFolder = "folder.badge.plus"
    static let newSpace = "rectangle.stack.badge.plus"
    static let folderFromSearch = "text.magnifyingglass"
    static let liveFolder = "dot.radiowaves.left.and.right"
    static let newWindow = "macwindow"
    static let delete = "trash"
    static let reload = "arrow.clockwise"
    static let sidebar = "sidebar.left"
    static let open = "arrow.up.forward.square"
    static let share = "square.and.arrow.up"
    static let download = "arrow.down.circle"
    static let translate = "translate"
    static let print = "printer"
    static let find = "magnifyingglass"
    static let settings = "gearshape"
    static let look = "paintpalette"
    static let moveUp = "arrow.up"
    static let moveDown = "arrow.down"
    static let moveLeft = "arrow.left"
    static let moveRight = "arrow.right"
    static let shutFolders = "rectangle.compress.vertical"
    static let openFolders = "rectangle.expand.vertical"
    static let downloadsFolder = "arrow.down.circle"
    static let settingsFolder = "arrow.uturn.backward"
    static let languages = "globe"
    static let icon = "face.smiling"

    static func mute(_ muted: Bool) -> String { muted ? "speaker.wave.2" : "speaker.slash" }
}

extension NSMenuItem {
    @MainActor @discardableResult
    func symbol(_ name: String) -> NSMenuItem {
        image = KitGlyph.plain(name)
        preferredImageVisibility = .visible
        return self
    }

    @MainActor @discardableResult
    func leadingSymbol(_ name: String) -> NSMenuItem {
        offStateImage = KitGlyph.plain(name)
        return self
    }
}

@MainActor
enum MenuIcons {
    private static var watchers: [Any] = []
    private static let open = NSHashTable<NSMenu>.weakObjects()
    private static var pending = false

    static func start() {
        guard watchers.isEmpty else { return }
        let center = NotificationCenter.default
        watchers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu, ours(menu) else { return }
                open.add(menu)
                show(menu)
            }
        })
        watchers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                if let menu = note.object as? NSMenu { open.remove(menu) }
            }
        })
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            watchers.append(center.addObserver(forName: name, object: nil, queue: nil) { note in
                MainActor.assumeIsolated {
                    guard let menu = note.object as? NSMenu, open.contains(root(of: menu)), !pending else { return }
                    pending = true
                    RunLoop.main.perform(inModes: [.eventTracking, .default]) {
                        MainActor.assumeIsolated {
                            pending = false
                            for menu in open.allObjects { show(menu) }
                        }
                    }
                }
            })
        }
    }

    private static func root(of menu: NSMenu) -> NSMenu {
        var root = menu
        while let up = root.supermenu { root = up }
        return root
    }

    private static func ours(_ menu: NSMenu) -> Bool {
        let top = root(of: menu)
        return menu !== leave && top !== NSApp.mainMenu && top !== leave
    }

    static weak var leave: NSMenu?

    static let blank = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true }

    static func show(_ menu: NSMenu) {
        guard !menu.items.contains(where: { $0.identifier?.rawValue.hasPrefix("WKMenuItem") == true }) else { return }
        let pictured = menu.items.contains { $0.image != nil && $0.preferredImageVisibility != .hidden }
        for item in menu.items {
            if item.image != nil, item.preferredImageVisibility == .automatic { item.preferredImageVisibility = .visible }
            if pictured, item.image == nil, item.offStateImage == nil, !item.isSeparatorItem, !item.isSectionHeader {
                item.image = blank
                item.preferredImageVisibility = .visible
            }
            if let sub = item.submenu { show(sub) }
        }
    }
}
