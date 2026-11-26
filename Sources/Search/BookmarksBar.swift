import AppKit

@MainActor
final class BookmarksBar: NSView {
    static let height: CGFloat = 30

    let browser: Browser
    var onFrame = false { didSet { if onFrame != oldValue { needsLayout = true } } }

    private let ground = KitBox(fill: nil)
    private let line = KitBox(fill: KitColor.hairline)
    private let scroll = NSScrollView()
    private let strip = BarStrip()
    private var items: [BookmarksBarItem] = []
    private var shown: [Shown] = []

    private struct Shown: Equatable {
        let id: UUID
        let title: String
        let url: String?
        let folder: Bool
        let unnamed: Bool
        let icon: ObjectIdentifier?
    }

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Self.height))
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .allowed
        scroll.documentView = strip
        addSubview(ground)
        addSubview(scroll)
        addSubview(line)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func refresh() {
        let roots = browser.bookmarks.roots
        let now = roots.map { node in
            Shown(id: node.id, title: node.title, url: node.url, folder: node.isFolder, unnamed: node.unnamed,
                  icon: node.isFolder ? nil : Favicons.shared.cached(for: node.address).map(ObjectIdentifier.init))
        }
        if now != shown {
            shown = now
            items.forEach { $0.removeFromSuperview() }
            items = roots.map { node in
                let item = BookmarksBarItem(node: node, icon: node.isFolder ? nil : Favicons.shared.cached(for: node.address))
                item.act = { [weak self] in self?.open(node) }
                item.middle = { [weak self] in
                    guard let self, let url = node.url.flatMap(URL.init(string:)) else { return }
                    browser.pickBookmark(url, inNewTab: true)
                }
                item.menuItems = { [weak self] in self?.menu(for: node) ?? [] }
                strip.addSubview(item)
                return item
            }
        }
        needsLayout = true
    }

    private func open(_ node: Bookmark) {
        if node.isFolder {
            BookmarkMenu.shared.popUp(node)
        } else if let text = node.url, let url = URL(string: text) {
            browser.openBookmark(url)
        }
    }

    override func layout() {
        super.layout()
        let base = superview?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let look = KitGround.ink(browser, on: onFrame, dark: base)
        let wanted = KitGround.appearance(dark: look.dark)
        if appearance?.name != wanted?.name { appearance = wanted }
        ground.fill = onFrame ? nil : Palette.NS.ground
        ground.frame = bounds
        line.isHidden = onFrame
        line.ink = look.ink
        line.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.height)
        var x: CGFloat = 10
        for item in items {
            item.ink = look.ink
            let size = item.fitting
            item.frame = kitSnap(NSRect(x: x, y: (Self.height - size.height) / 2, width: size.width, height: size.height))
            x += size.width + 2
        }
        strip.frame = NSRect(x: 0, y: 0, width: max(bounds.width, x - 2 + 10), height: Self.height)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        KitMenu.make([
            .action("New Folder…") { [browser] in browser.bookmarks.askNewFolder(in: nil) },
            .separator,
            .action("Show Bookmarks") { [browser] in browser.bookmarking = true },
            .action("Hide Bookmarks Bar") { [browser] in browser.prefs.bookmarksBar = false },
        ])
    }

    private func menu(for node: Bookmark) -> [KitMenuItem] {
        let bookmarks = browser.bookmarks
        let browser = browser
        if node.isFolder {
            var items: [KitMenuItem] = []
            let urls = (node.children ?? []).compactMap { $0.url.flatMap(URL.init(string:)) }
            if !urls.isEmpty {
                items.append(.action("Open All in New Tabs", symbol: MenuSymbol.newTab) {
                    for url in urls { browser.open(url, foreground: false, atEnd: true, from: browser.active, mayWait: true) }
                })
                items.append(.action("Open All in New Window") { browser.openInNewWindow(urls) })
                items.append(.action("Open All in Folder") { browser.openInTabGroup(urls, named: node.title) })
                items.append(.separator)
            }
            items.append(.action("Rename…", symbol: MenuSymbol.rename) { bookmarks.askRename(node) })
            items.append(.action("New Folder Inside…") { bookmarks.askNewFolder(in: node.id) })
            items.append(.separator)
            items += move(node)
            items.append(.action("Remove", symbol: MenuSymbol.delete) { bookmarks.askRemove(node) })
            return items
        }
        guard let url = node.url.flatMap(URL.init(string:)) else { return [] }
        var items: [KitMenuItem] = [
            .action("Open in New Tab", symbol: MenuSymbol.newTab) { browser.pickBookmark(url, inNewTab: true) },
            .action("Open in New Window") { browser.openInNewWindow([url]) },
        ]
        if browser.prefs.splitView {
            items.append(.action("Open in Split View", symbol: MenuSymbol.split) { browser.openInSplit(url) })
        }
        items += [
            .action("Open in Private Window") { Browsers.openPrivate(url) },
            .separator,
            .action("Rename…", symbol: MenuSymbol.rename) { bookmarks.askRename(node) },
            .action("Edit Address…") { bookmarks.askAddress(node) },
            .action("Copy Link", symbol: MenuSymbol.link) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            },
            .separator,
        ]
        items += move(node)
        items.append(.action("Remove", symbol: MenuSymbol.delete) { bookmarks.askRemove(node) })
        return items
    }

    private func move(_ node: Bookmark) -> [KitMenuItem] {
        let bookmarks = browser.bookmarks
        let targets = Bookmarks.folders(bookmarks.roots).filter { !Bookmarks.holds($0.node.id, node) }
        guard !targets.isEmpty else { return [] }
        return [.submenu("Move", symbol: MenuSymbol.move, targets.map { target in
            .action(String(repeating: "   ", count: target.depth) + target.node.title) {
                bookmarks.move(node.id, into: target.node.id)
            }
        })]
    }
}

extension BookmarksBar {
    static func seen(in root: NSView?) -> [String: Any] {
        func find(_ view: NSView) -> BookmarksBar? {
            if let bar = view as? BookmarksBar { return bar }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        guard let root, let bar = find(root) else { return [:] }
        func box(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) } }
        return ["frame": box(bar.frame), "hidden": bar.isHidden, "alpha": Double(bar.alphaValue),
                "opacity": Double(bar.layer?.opacity ?? -1),
                "shownOpacity": Double(bar.layer?.presentation()?.opacity ?? bar.layer?.opacity ?? -1),
                "scroll": box(bar.scroll.frame), "strip": box(bar.strip.frame),
                "items": bar.items.map { item in
                    ["frame": box(item.frame), "inBar": box(item.convert(item.bounds, to: bar)), "hidden": item.isHiddenOrHasHiddenAncestor]
                }]
    }
}

private final class BarStrip: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class BookmarksBarItem: KitHoverView {
    var act: () -> Void = {}
    var middle: () -> Void = {}
    var menuItems: () -> [KitMenuItem] = { [] }
    var ink: KitInk = .flat {
        didSet {
            guard ink != oldValue else { return }
            label.ink = ink
            mark?.ink = ink
            folder?.ink = ink
            chevron?.ink = ink
            back.ink = ink
        }
    }

    private let node: Bookmark
    private let back = KitBox(fill: nil, corners: .radius(6))
    private let label = KitLabel()
    private var mark: KitMark?
    private var folder: KitSymbol?
    private var chevron: KitSymbol?
    private var pressed = false
    private var middlePressed = false

    init(node: Bookmark, icon: NSImage?) {
        self.node = node
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(back)
        if node.isFolder {
            let symbol = KitSymbol("folder", style: .init(size: 10.5), tint: KitColor.muted)
            folder = symbol
            addSubview(symbol)
        } else {
            let made = KitMark(icon: icon ?? (Tab.bareHost(node.address) ? Tab.networkMark : nil),
                               letter: String((node.host ?? "•").prefix(1)).uppercased(), side: 13)
            mark = made
            addSubview(made)
        }
        if !node.unnamed {
            label.text = node.title
            label.font = .systemFont(ofSize: 12)
            label.color = KitColor.ink
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        if node.isFolder {
            let symbol = KitSymbol("chevron.down", style: .init(size: 7.5, weight: .semibold), tint: KitColor.faint)
            chevron = symbol
            addSubview(symbol)
        }
        let help = node.url ?? node.title
        kitAccess(label: node.unnamed ? help : node.title, role: .button, help: help)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var textWidth: CGFloat {
        node.unnamed ? 0 : min(150, ceil(label.measure(width: .greatestFiniteMagnitude).width))
    }

    var fitting: NSSize {
        let icon: CGFloat = node.isFolder ? (folder?.intrinsicContentSize.width ?? 0) : 13
        var width = icon
        if !node.unnamed { width += 6 + textWidth }
        if let chevron { width += 6 + chevron.intrinsicContentSize.width }
        width += node.unnamed ? 0 : 16
        return NSSize(width: max(node.unnamed ? 22 : 0, width), height: 22)
    }

    override func hoverChanged() {
        back.fill = hovering ? Palette.NS.hover : nil
    }

    override func layout() {
        super.layout()
        back.frame = bounds
        let size = fitting
        var x = (bounds.width - (size.width - (node.unnamed ? 0 : 16))) / 2
        if !node.unnamed { x = 8 }
        let mid = bounds.height / 2
        if let folder {
            let side = folder.intrinsicContentSize
            folder.frame = kitSnap(NSRect(x: x, y: mid - side.height / 2, width: side.width, height: side.height))
            x += side.width
        } else if let mark {
            mark.frame = kitSnap(NSRect(x: x, y: mid - 6.5, width: 13, height: 13))
            x += 13
        }
        if !node.unnamed {
            x += 6
            let height = ceil(label.measure(width: .greatestFiniteMagnitude).height)
            label.frame = kitSnap(NSRect(x: x, y: mid - height / 2, width: textWidth, height: height))
            x += textWidth
        }
        if let chevron {
            x += 6
            let side = chevron.intrinsicContentSize
            chevron.frame = kitSnap(NSRect(x: x, y: mid - side.height / 2, width: side.width, height: side.height))
        }
    }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
    }

    override func otherMouseDown(with event: NSEvent) {
        middlePressed = event.buttonNumber == 2 && node.url != nil
    }

    override func otherMouseUp(with event: NSEvent) {
        guard middlePressed else { return }
        middlePressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { middle() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let items = menuItems()
        return items.isEmpty ? nil : KitMenu.make(items)
    }

    override func accessibilityPerformPress() -> Bool {
        act()
        return true
    }
}
