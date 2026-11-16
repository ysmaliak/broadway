import AppKit

final class SettingsFrame: NSWindow {
    var back: (() -> Bool)?
    var forward: (() -> Bool)?
    var up: (() -> Bool)?
    var find: (() -> Void)?
    var benchKeyed = false

    override var isKeyWindow: Bool { benchKeyed || super.isKeyWindow }
    override var isMainWindow: Bool { benchKeyed || super.isMainWindow }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "[": if back?() == true { return true }
            case "]": if forward?() == true { return true }
            case "f": find?(); return true
            default: break
            }
        }
        if flags.isEmpty, event.keyCode == 53, !(firstResponder is NSText), up?() == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if up?() == true { return }
        super.cancelOperation(sender)
    }
}

final class SettingsPaper: NSScrollView {
    private var floor: NSLayoutConstraint?

    func hold(_ page: NSView) {
        page.translatesAutoresizingMaskIntoConstraints = false
        documentView = page
        let floor = page.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            page.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            page.topAnchor.constraint(equalTo: contentView.topAnchor),
            floor,
        ])
        self.floor = floor
    }

    override func tile() {
        super.tile()
        let room = max(0, contentView.bounds.height - contentInsets.top - contentInsets.bottom)
        if let floor, floor.constant != room { floor.constant = room }
    }

    var top: CGFloat { -contentInsets.top }

    func rise() {
        contentView.scroll(to: NSPoint(x: 0, y: top))
        reflectScrolledClipView(contentView)
    }

    func center(_ y: CGFloat) {
        guard let page = documentView else { return }
        let room = contentView.bounds.height - contentInsets.top
        let lowest = max(top, page.frame.height - contentView.bounds.height + contentInsets.bottom)
        let target = min(max(y - contentInsets.top - room / 2, top), lowest)
        contentView.scroll(to: NSPoint(x: 0, y: target))
        reflectScrolledClipView(contentView)
    }
}

final class SettingsSearch: NSSplitViewItemAccessoryViewController {
    let field = NSSearchField()

    override func loadView() {
        let view = NSView()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "Search"
        field.controlSize = .large
        preferredScrollEdgeEffectStyle = .soft
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        view.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            field.topAnchor.constraint(equalTo: view.topAnchor),
            field.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.view = view
    }
}

@MainActor
final class SettingsToolbar: NSObject, NSToolbarDelegate {
    static let arrows = NSToolbarItem.Identifier("settings.arrows")

    let toolbar = NSToolbar(identifier: "settings")
    private let back = NSToolbarItem(itemIdentifier: .init("settings.back"))
    private let forward = NSToolbarItem(itemIdentifier: .init("settings.forward"))
    private lazy var group = NSToolbarItemGroup(itemIdentifier: Self.arrows)
    var goBack: (() -> Void)?
    var goForward: (() -> Void)?

    override init() {
        super.init()
        for (item, symbol, title, action) in [(back, "chevron.left", "Back", #selector(stepBack)),
                                              (forward, "chevron.right", "Forward", #selector(stepForward))] {
            item.image = KitGlyph.plain(symbol, label: title)
            item.label = title
            item.toolTip = title
            item.isBordered = true
            item.autovalidates = false
            item.target = self
            item.action = action
        }
        group.subitems = [back, forward]
        group.controlRepresentation = .expanded
        group.selectionMode = .momentary
        group.isNavigational = true
        group.label = "Back/Forward"
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
    }

    func update(canGoBack: Bool, canGoForward: Bool) {
        back.isEnabled = canGoBack
        forward.isEnabled = canGoForward
    }

    @objc private func stepBack() { goBack?() }
    @objc private func stepForward() { goForward?() }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, Self.arrows]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.arrows: return group
        default: return nil
        }
    }
}

final class SettingsRail: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row: Equatable {
        case page(SettingsPage)
        case gap
    }

    static let symbol = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    static let tile: CGFloat = 22

    let table = NSTableView()
    var picked: ((SettingsPage) -> Void)?
    private let rows: [Row] = SettingsPage.blocks.enumerated().flatMap { index, block in
        (index > 0 ? [Row.gap] : []) + block.map(Row.page)
    }
    private var chosen: SettingsPage?
    private var counts: [SettingsPage: Int] = [:]
    private var searching = false
    private var quiet = false

    override func loadView() {
        let scroll = NSScrollView()
        let column = NSTableColumn(identifier: .init("page"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.style = .sourceList
        table.headerView = nil
        table.focusRingType = .none
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Settings pages")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view = scroll
    }

    func show(chosen: SettingsPage?, counts: [SettingsPage: Int], searching: Bool) {
        let changed = counts != self.counts || searching != self.searching
        self.counts = counts
        self.searching = searching
        self.chosen = chosen
        quiet = true
        defer { quiet = false }
        if changed { table.reloadData() }
        if let chosen, let index = rows.firstIndex(of: .page(chosen)) {
            if table.selectedRow != index {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                table.scrollRowToVisible(index)
            }
        } else if table.selectedRow >= 0 {
            table.deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row] == .gap ? 10 : 30
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row] != .gap
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard case .page(let page) = rows[row] else { return NSView() }
        let cell = tableView.makeView(withIdentifier: .init("page"), owner: self) as? SettingsRailCell ?? SettingsRailCell()
        cell.identifier = .init("page")
        cell.show(page, count: searching ? counts[page] ?? 0 : 0)
        cell.alphaValue = searching && counts[page] == nil ? 0.4 : 1
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !quiet, table.selectedRow >= 0, case .page(let page) = rows[table.selectedRow] else { return }
        chosen = page
        picked?(page)
    }
}

final class SettingsRailCell: NSTableCellView {
    private let icon = NSImageView()
    private let tile = SettingsTile()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = SettingsRail.symbol
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        count.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        count.alignment = .right
        imageView = icon
        textField = title
        for view in [tile, icon, title, count] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: SettingsRail.tile),
            tile.heightAnchor.constraint(equalToConstant: SettingsRail.tile),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ page: SettingsPage, count: Int) {
        icon.image = KitGlyph.plain(page.icon)
        icon.contentTintColor = .labelColor
        title.stringValue = page.title
        self.count.stringValue = count > 0 ? "\(count)" : ""
        self.count.isHidden = count == 0
        setAccessibilityLabel(page.title)
    }
}
