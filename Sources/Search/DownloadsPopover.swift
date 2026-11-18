import AppKit
import Combine
import UniformTypeIdentifiers

final class DownloadsLayerView: NSView, NSPopoverDelegate {
    let browser: Browser
    private let list: RecentDownloadsView
    private var popover: NSPopover?
    private var seen: (Bool, CGRect) = (false, .zero)
    private var shown: (door: CGRect, above: Bool)?
    private var watch: Set<AnyCancellable> = []

    init(browser: Browser) {
        self.browser = browser
        list = RecentDownloadsView(browser: browser, loot: browser.loot, fetches: browser.fetches)
        super.init(frame: .zero)
        list.resized = { [weak self] in
            guard let self, let popover = self.popover else { return }
            let size = self.fitted
            if popover.contentSize != size { popover.contentSize = size }
        }
        kitObserve(initial: false, { [weak browser] in browser?.spaceID }) { [weak self] _ in
            guard let self, self.browser.downloadsOpen else { return }
            self.browser.downloadsOpen = false
        }.store(in: &watch)
        NotificationCenter.default.publisher(for: KitPopup.willShow).sink { [weak self] note in
            guard let self, let window = self.window, note.object as? NSWindow === window, self.browser.downloadsOpen else { return }
            self.browser.downloadsOpen = false
        }.store(in: &watch)
    }

    func sync() {
        let now = (browser.downloadsOpen, browser.downloadsDoor)
        guard now != seen else { return }
        seen = now
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    nonisolated static let pointer: CGFloat = 13
    nonisolated static let corner: CGFloat = 17
    nonisolated static let pointerHalf: CGFloat = 14
    nonisolated static let straight: CGFloat = 2
    nonisolated static let screenInset: CGFloat = 13
    nonisolated static let leastRoom: CGFloat = 120
    nonisolated static var clearance: CGFloat { corner + pointerHalf + straight }

    nonisolated static func opensAbove(door: CGRect, window: CGRect) -> Bool {
        window.maxY - door.maxY >= door.minY - window.minY
    }

    nonisolated static func room(door: CGRect, window: CGRect, screen: CGRect, above: Bool) -> CGFloat {
        let top = min(window.maxY, screen.maxY) - PopupLook.margin
        let bottom = max(window.minY, screen.minY) + PopupLook.margin
        return max(above ? top - door.maxY - pointer : door.minY - pointer - bottom, leastRoom)
    }

    nonisolated static func aim(door: CGRect, screen: CGRect) -> CGFloat {
        let low = screen.minX + screenInset + clearance
        let high = screen.maxX - screenInset - clearance
        return min(max(door.midX, low), high)
    }

    nonisolated static func body(aim: CGFloat, width: CGFloat, screen: CGRect) -> (minX: CGFloat, maxX: CGFloat) {
        let lowest = screen.minX + screenInset
        let highest = screen.maxX - screenInset - width
        let minX = min(max(aim - width / 2, lowest), max(lowest, highest))
        return (minX, minX + width)
    }

    override func layout() {
        super.layout()
        let wanted = browser.downloadsOpen
        guard wanted != (popover != nil) else { return }
        guard wanted else {
            let going = popover
            popover = nil
            going?.close()
            return
        }
        guard let window, let content = window.contentView else { return }
        KitPopup.closeAll(in: window)
        let anchor: NSView
        let spot: NSRect
        if let door = browser.downloadsAnchor, door.window === window {
            anchor = door
            spot = door.bounds
        } else {
            let door = browser.downloadsDoor
            anchor = content
            spot = content.isFlipped ? door : NSRect(x: door.minX, y: content.bounds.height - door.maxY, width: door.width, height: door.height)
        }
        let door = window.convertToScreen(anchor.convert(spot, to: nil))
        let screen = window.screen?.visibleFrame ?? window.frame
        let above = Self.opensAbove(door: door, window: window.frame)
        shown = (door, above)
        let holder = NSViewController()
        let ground = KitBox(fill: Palette.NS.glassGround)
        list.removeFromSuperview()
        list.frame = ground.bounds
        list.autoresizingMask = [.width, .height]
        ground.addSubview(list)
        holder.view = ground
        let made = NSPopover()
        made.contentViewController = holder
        made.behavior = .transient
        made.animates = !Motion.reduced
        made.delegate = self
        list.prepare()
        made.contentSize = fitted
        popover = made
        var aimed = NSRect(x: spot.midX + Self.aim(door: door, screen: screen) - door.midX - 1, y: spot.minY, width: 2, height: spot.height)
        var host = anchor
        if !anchor.bounds.contains(aimed) {
            aimed = content.convert(aimed, from: anchor)
            host = content
        }
        let edge: NSRectEdge = above == host.isFlipped ? .minY : .maxY
        made.show(relativeTo: aimed, of: host, preferredEdge: edge)
        if Store.testing, !Store.shownOnScreen, window.level < .normal { list.window?.level = window.level }
        list.shown()
    }

    private var pressOnDoor: NSEvent? {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
              let door = browser.downloadsAnchor, let window = door.window, event.window === window,
              door.bounds.contains(door.convert(event.locationInWindow, from: nil)) else { return nil }
        return event
    }

    func popoverWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPopover, closing === popover else { return }
        browser.downloadsShutBy = pressOnDoor?.timestamp
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        popover = nil
        if browser.downloadsOpen { browser.downloadsOpen = false }
    }

    private var fitted: NSSize {
        guard let window, let shown else { return list.fitting(maxHeight: 900) }
        let screen = window.screen?.visibleFrame ?? window.frame
        return list.fitting(maxHeight: Self.room(door: shown.door, window: window.frame, screen: screen, above: shown.above))
    }
}

enum DownloadLine {
    case entry(FetchEntry)
    case kept(Keep)
    case none

    var id: String {
        switch self {
        case .entry(let entry): "fetch " + entry.id.uuidString
        case .kept(let keep): "keep " + keep.id
        case .none: "none"
        }
    }
}

enum DownloadVerb: String, CaseIterable {
    case open, reveal, pause, resume, retry, cancel, remove, forget

    var title: String {
        switch self {
        case .open: "Open"
        case .reveal: "Show in Finder"
        case .pause: "Pause"
        case .resume: "Resume"
        case .retry: "Retry"
        case .cancel: "Cancel"
        case .remove: "Remove"
        case .forget: "Remove from List"
        }
    }

    var symbol: String? {
        switch self {
        case .reveal: "magnifyingglass.circle.fill"
        case .pause: "pause.circle.fill"
        case .resume: "play.circle.fill"
        case .retry: "arrow.clockwise.circle.fill"
        case .cancel, .remove: "xmark.circle.fill"
        case .open, .forget: nil
        }
    }

    var help: String {
        self == .retry ? "Start the download again from the beginning" : title
    }
}

extension FetchEntry {
    var verbs: [DownloadVerb] {
        switch state {
        case .downloading: (canPause ? [.pause] : []) + [.cancel]
        case .pausing, .resuming: [.cancel]
        case .paused: (canResume ? [.resume] : canRetry ? [.retry] : []) + [.remove]
        case .failed: (canResume ? [.resume] : []) + (canRetry ? [.retry] : []) + [.remove]
        }
    }

    var sizeText: String {
        let received = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
        guard totalBytes > 0 else { return received + " downloaded" }
        return "\(received) of \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
    }

    var detailText: String {
        switch state {
        case .downloading: sizeText
        case .pausing: "Pausing…"
        case .paused: "Paused · \(sizeText)"
        case .resuming: "Resuming…"
        case .failed: errorDescription ?? "The download failed"
        }
    }

    var showsBar: Bool { state != .failed }
}

extension Keep {
    var verbs: [DownloadVerb] { [.reveal] }
}

final class RecentDownloadsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let browser: Browser
    let loot: Loot
    let fetches: Fetches
    var resized: (() -> Void)?
    private(set) static weak var front: RecentDownloadsView?

    private let scroll = NSScrollView()
    private let list = DownloadsTable()
    private let foot = DownloadsTable()
    private let rule = NSBox()
    private var lines: [DownloadLine] = [.none]
    private var watch: AnyCancellable?

    static let width: CGFloat = 340
    static let gap: CGFloat = 5
    static let footRow: CGFloat = 24
    static let listRoom: CGFloat = 392
    static let footTitles = ["Show All Downloads", "Clear"]

    init(browser: Browser, loot: Loot, fetches: Fetches) {
        self.browser = browser
        self.loot = loot
        self.fetches = fetches
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = list
        rule.boxType = .separator
        for table in [list, foot] {
            table.dataSource = self
            table.delegate = self
            table.target = self
            table.action = #selector(pressed(_:))
            table.act = { [weak self, weak table] row in
                guard let self, let table else { return }
                self.act(row, in: table)
            }
            table.hoverable = { [weak self, weak table] row in
                guard let self, let table else { return false }
                return self.clickable(row, in: table)
            }
        }
        list.menuFor = { [weak self] row in self?.menu(for: row) }
        list.leave = { [weak self] down in self?.step(from: true, down: down) ?? false }
        foot.leave = { [weak self] down in self?.step(from: false, down: down) ?? false }
        list.setAccessibilityLabel("Recent Downloads")
        foot.setAccessibilityLabel("Downloads Actions")
        for view in [scroll, rule, foot] as [NSView] { addSubview(view) }
        kitAccess(label: "Recent Downloads", role: .group)
        watch = kitObserve({ [weak fetches, weak loot] in
            (fetches?.entries.map(\.id) ?? [], loot?.recent ?? [], fetches?.showing ?? false)
        }) { [weak self] _ in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var rowsHeight: CGFloat {
        lines.map(Self.height).reduce(0, +)
    }

    static func height(for line: DownloadLine) -> CGFloat {
        switch line {
        case .entry(let entry): entry.showsBar ? DownloadCell.tall : DownloadCell.short
        case .kept: DownloadCell.short
        case .none: footRow
        }
    }

    private var footHeight: CGFloat { CGFloat(Self.footTitles.count) * Self.footRow }

    private func inset(of table: NSTableView) -> CGFloat {
        table.numberOfRows > 0 ? max(0, table.rect(ofRow: 0).minY) : 0
    }

    private var tail: CGFloat { 1 + Self.gap + footHeight + inset(of: foot) }

    func fitting(maxHeight: CGFloat) -> NSSize {
        let body = min(inset(of: list) + rowsHeight + Self.gap, Self.listRoom, max(Self.footRow, maxHeight - tail))
        return NSSize(width: Self.width, height: body + tail)
    }

    override var fittingSize: NSSize { fitting(maxHeight: .greatestFiniteMagnitude) }

    private var clearable: Bool { !(loot.recent.isEmpty && !fetches.showing) }

    func refresh() {
        let entries = fetches.entries.map(DownloadLine.entry)
        let recent = loot.recent.map(DownloadLine.kept)
        let next = entries.isEmpty && recent.isEmpty ? [DownloadLine.none] : entries + recent
        let chosen = list.selectedRow >= 0 && list.selectedRow < lines.count ? lines[list.selectedRow].id : nil
        let same = next.map(\.id) == lines.map(\.id)
        lines = next
        if same {
            for row in 0..<list.numberOfRows {
                (list.view(atColumn: 0, row: row, makeIfNecessary: false) as? DownloadCell)?.show(lines[row])
            }
        } else {
            list.reloadData()
            if let chosen, let row = lines.firstIndex(where: { $0.id == chosen }) {
                list.selectRowIndexes([row], byExtendingSelection: false)
            }
        }
        foot.reloadData()
        needsLayout = true
        resized?()
    }

    func prepare() {
        refresh()
    }

    func shown() {
        Self.front = self
        list.deselectAll(nil)
        foot.deselectAll(nil)
        list.scrollRowToVisible(0)
        window?.makeFirstResponder(list)
    }

    override func layout() {
        super.layout()
        let top = inset(of: list)
        let footTop = inset(of: foot)
        let ruleY = max(0, bounds.height - tail)
        let whole = top + rowsHeight + top
        let scrolls = top + rowsHeight + Self.gap > ruleY + 0.5
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: scrolls ? ruleY : whole)
        scroll.verticalScrollElasticity = scrolls ? .automatic : .none
        rule.frame = NSRect(x: DownloadCell.edge, y: ruleY, width: bounds.width - DownloadCell.edge * 2, height: 1)
        foot.frame = NSRect(x: 0, y: ruleY + 1 + Self.gap - footTop, width: bounds.width, height: footTop + footHeight + footTop)
        if list.frame.width != scroll.contentSize.width { list.setFrameSize(NSSize(width: scroll.contentSize.width, height: list.frame.height)) }
        list.sizeLastColumnToFit()
        foot.sizeLastColumnToFit()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === list ? lines.count : Self.footTitles.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        tableView === list ? Self.height(for: lines[row]) : Self.footRow
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        DownloadsRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === list else {
            let cell = DownloadsWordCell()
            cell.press = { [weak self] in
                guard let self, self.clickable(row, in: self.foot) else { return false }
                self.act(row, in: self.foot)
                return true
            }
            cell.show(Self.footTitles[row], enabled: row == 0 || clearable)
            return cell
        }
        if case .none = lines[row] {
            let cell = DownloadsWordCell()
            cell.show("No Recent Downloads", enabled: false)
            return cell
        }
        let cell = DownloadCell()
        cell.run = { [weak self, weak cell] verb in
            guard let self, let line = cell?.line else { return }
            self.run(verb, on: line)
        }
        cell.press = { [weak self, weak cell] in
            guard let self, let cell else { return false }
            let row = self.list.row(for: cell)
            guard row >= 0, self.acts(row) else { return false }
            self.act(row, in: self.list)
            return true
        }
        cell.resized = { [weak self, weak cell] in
            guard let self, let cell else { return }
            let row = self.list.row(for: cell)
            guard row >= 0 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                self.list.noteHeightOfRows(withIndexesChanged: [row])
            }
            self.needsLayout = true
            self.resized?()
        }
        cell.show(lines[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView === list {
            guard lines.indices.contains(row) else { return false }
            if case .none = lines[row] { return false }
            return true
        }
        return row == 0 || (row == 1 && clearable)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, table.selectedRow >= 0 else { return }
        (table === list ? foot : list).deselectAll(nil)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableView === list else { return Self.footTitles[row] }
        switch lines[row] {
        case .entry(let entry): return entry.name
        case .kept(let keep): return keep.name
        case .none: return nil
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableView === list, case .kept(let keep) = lines[row], keep.stillThere else { return nil }
        return keep.url as NSURL
    }

    private func clickable(_ row: Int, in table: NSTableView) -> Bool {
        guard table === list else { return row == 0 || clearable }
        guard lines.indices.contains(row), case .kept(let keep) = lines[row] else { return false }
        return keep.stillThere
    }

    @objc private func pressed(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, clickable(row, in: sender) else { return }
        act(row, in: sender)
    }

    private func acts(_ row: Int) -> Bool {
        guard lines.indices.contains(row) else { return false }
        switch lines[row] {
        case .kept(let keep): return keep.stillThere
        case .entry(let entry): return entry.verbs.contains { $0 == .resume || $0 == .retry }
        case .none: return false
        }
    }

    private func act(_ row: Int, in table: NSTableView) {
        guard table === list else {
            if row == 0 { showAll() } else if clearable { clear() }
            return
        }
        guard lines.indices.contains(row) else { return }
        switch lines[row] {
        case .kept(let keep): if keep.stillThere { run(.open, on: lines[row]) }
        case .entry(let entry):
            if let verb = entry.verbs.first(where: { $0 == .resume || $0 == .retry }) { run(verb, on: lines[row]) }
        case .none: break
        }
    }

    private func step(from top: Bool, down: Bool) -> Bool {
        guard top == down, let window else { return false }
        let next = top ? foot : list
        let rows = (0..<next.numberOfRows).filter { tableView(next, shouldSelectRow: $0) }
        guard let row = top ? rows.first : rows.last else { return false }
        window.makeFirstResponder(next)
        next.selectRowIndexes([row], byExtendingSelection: false)
        next.scrollRowToVisible(row)
        return true
    }

    private func showAll() {
        browser.downloadsOpen = false
        browser.hoarding = true
    }

    private func clear() {
        loot.clearRecent()
        fetches.cleared()
        browser.downloadsOpen = false
    }

    func run(_ verb: DownloadVerb, on line: DownloadLine) {
        switch (line, verb) {
        case (.kept(let keep), .open):
            browser.downloadsOpen = false
            loot.open(keep)
        case (.kept(let keep), .reveal):
            browser.downloadsOpen = false
            loot.reveal(keep)
        case (.kept(let keep), .forget): loot.forget(keep)
        case (.entry(let entry), .pause): browser.pauseDownload(entry)
        case (.entry(let entry), .resume): browser.resumeDownload(entry)
        case (.entry(let entry), .retry): browser.retryDownload(entry)
        case (.entry(let entry), .cancel), (.entry(let entry), .remove): browser.cancelDownload(entry)
        default: break
        }
    }

    static func menuVerbs(for line: DownloadLine) -> [DownloadVerb] {
        switch line {
        case .kept(let keep): (keep.stillThere ? [.open, .reveal] : []) + [.forget]
        case .entry(let entry): entry.verbs
        case .none: []
        }
    }

    private func menu(for row: Int) -> NSMenu? {
        guard lines.indices.contains(row) else { return nil }
        let line = lines[row]
        let verbs = Self.menuVerbs(for: line)
        guard !verbs.isEmpty else { return nil }
        var items: [KitMenuItem] = []
        for verb in verbs {
            if verb == .forget, !items.isEmpty { items.append(.separator) }
            items.append(.action(verb.title, id: "downloads.row." + verb.rawValue) { [weak self] in self?.run(verb, on: line) })
        }
        return KitMenu.make(items)
    }

    func benchRows() -> [[String: Any]] {
        let top = lines.enumerated().map { row, line -> [String: Any] in
            let cell = list.view(atColumn: 0, row: row, makeIfNecessary: true)
            let rect = list.convert(list.rect(ofRow: row), to: self)
            var out: [String: Any] = ["id": line.id, "height": Double(Self.height(for: line)), "selected": list.selectedRow == row,
                                      "rect": [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)],
                                      "clickable": clickable(row, in: list), "menu": Self.menuVerbs(for: line).map(\.rawValue)]
            if let cell = cell as? DownloadCell { out.merge(cell.bench) { _, new in new } }
            if let cell = cell as? DownloadsWordCell { out.merge(cell.bench) { _, new in new } }
            return out
        }
        let bottom = Self.footTitles.indices.map { row -> [String: Any] in
            let rect = foot.convert(foot.rect(ofRow: row), to: self)
            return ["id": "foot \(row)", "name": Self.footTitles[row], "selected": foot.selectedRow == row, "clickable": clickable(row, in: foot),
                    "rect": [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]]
        }
        return top + bottom
    }

    func benchSelect(_ row: Int?) {
        list.deselectAll(nil)
        foot.deselectAll(nil)
        guard let row, row >= 0 else { return }
        let (table, index) = row < lines.count ? (list, row) : (foot, row - lines.count)
        guard index < table.numberOfRows, tableView(table, shouldSelectRow: index) else { return }
        table.selectRowIndexes([index], byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    func benchPress(_ row: Int, verb: String?) -> Bool {
        if row >= lines.count {
            let index = row - lines.count
            guard index < Self.footTitles.count, clickable(index, in: foot) else { return false }
            act(index, in: foot)
            return true
        }
        guard lines.indices.contains(row) else { return false }
        guard let verb else {
            guard clickable(row, in: list) else { return false }
            act(row, in: list)
            return true
        }
        guard let found = DownloadVerb(rawValue: verb), Self.menuVerbs(for: lines[row]).contains(found)
                || (list.view(atColumn: 0, row: row, makeIfNecessary: true) as? DownloadCell)?.verbs.contains(found) == true else { return false }
        run(found, on: lines[row])
        return true
    }

    func benchSpot(_ row: Int, verb: String?) -> NSPoint? {
        if row >= lines.count {
            let index = row - lines.count
            guard index < foot.numberOfRows else { return nil }
            let rect = foot.rect(ofRow: index)
            return foot.convert(NSPoint(x: rect.minX + 60, y: rect.midY), to: nil)
        }
        guard lines.indices.contains(row) else { return nil }
        list.scrollRowToVisible(row)
        guard let verb else {
            let rect = list.rect(ofRow: row)
            return list.convert(NSPoint(x: rect.minX + 90, y: rect.midY), to: nil)
        }
        guard let cell = list.view(atColumn: 0, row: row, makeIfNecessary: true) as? DownloadCell else { return nil }
        cell.layoutSubtreeIfNeeded()
        return cell.benchSpot(verb)
    }

    func benchAccessPress(_ row: Int) -> Bool {
        let table = row >= lines.count ? foot : list
        let index = row >= lines.count ? row - lines.count : row
        guard index >= 0, index < table.numberOfRows,
              let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true) else { return false }
        return cell.accessibilityPerformPress()
    }

    func benchKey(_ code: UInt16) {
        let named: [UInt16: String] = [125: "\u{F701}", 126: "\u{F700}", 36: "\r", 49: " "]
        let characters = named[code] ?? ""
        guard let window, let table = window.firstResponder as? DownloadsTable,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        table.keyDown(with: event)
    }
}

final class DownloadsTable: NSTableView {
    var act: ((Int) -> Void)?
    var hoverable: ((Int) -> Bool)?
    var leave: ((Bool) -> Bool)?
    var menuFor: ((Int) -> NSMenu?)?
    private var area: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.resizingMask = .autoresizingMask
        addTableColumn(column)
        headerView = nil
        style = .inset
        backgroundColor = .clear
        intercellSpacing = .zero
        columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        allowsEmptySelection = true
        allowsMultipleSelection = false
        allowsTypeSelect = true
        focusRingType = .none
        gridStyleMask = []
        setDraggingSourceOperationMask(.copy, forLocal: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let made = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(made)
        area = made
    }

    private func hover(_ event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, hoverable?(row) == true {
            if selectedRow != row { selectRowIndexes([row], byExtendingSelection: false) }
        } else if selectedRow >= 0 {
            deselectAll(nil)
        }
    }

    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseExited(with event: NSEvent) { deselectAll(nil) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        return menuFor?(row)
    }

    private var pickable: [Int] {
        (0..<numberOfRows).filter { delegate?.tableView?(self, shouldSelectRow: $0) != false }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 49:
            if selectedRow >= 0 { act?(selectedRow) }
        case 125, 126:
            let down = event.keyCode == 125
            let rows = pickable
            let now = selectedRow
            let next = down ? rows.first { $0 > now } : rows.last { now < 0 || $0 < now }
            guard let next else {
                _ = leave?(down)
                return
            }
            selectRowIndexes([next], byExtendingSelection: false)
            scrollRowToVisible(next)
        default:
            super.keyDown(with: event)
        }
    }
}

final class DownloadsRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

final class DownloadsWordCell: NSTableCellView {
    private let word = NSTextField(labelWithString: "")
    var press: (() -> Bool)?

    init() {
        super.init(frame: .zero)
        word.font = .menuFont(ofSize: 0)
        word.lineBreakMode = .byTruncatingTail
        addSubview(word)
        textField = word
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ text: String, enabled: Bool) {
        word.stringValue = text
        word.textColor = enabled ? .labelColor : Palette.NS.glassFaint
        if press != nil {
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(text)
            setAccessibilityEnabled(enabled)
            word.setAccessibilityElement(false)
        }
        needsLayout = true
    }

    override func accessibilityPerformPress() -> Bool { press?() ?? false }

    var bench: [String: Any] { ["name": word.stringValue, "frame": [Double(frame.minX), Double(frame.width)]] }

    override func layout() {
        super.layout()
        let height = word.intrinsicContentSize.height
        word.frame = NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
    }
}

final class DownloadCell: NSTableCellView {
    static let short: CGFloat = 44
    static let tall: CGFloat = 58
    static let edge: CGFloat = 16
    static let icon: CGFloat = 32
    static let wordInset: CGFloat = 2

    private(set) var line: DownloadLine = .none
    private(set) var verbs: [DownloadVerb] = []
    var run: ((DownloadVerb) -> Void)?
    var press: (() -> Bool)?
    var resized: (() -> Void)?
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private var keys: [NSButton] = []
    private var watch: AnyCancellable?
    private var watched: UUID?
    private var height: CGFloat = 0
    private var gone = false

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        name.lineBreakMode = .byTruncatingMiddle
        detail.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detail.textColor = Palette.NS.glassMuted
        detail.lineBreakMode = .byTruncatingTail
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = false
        for view in [icon, name, bar, detail] as [NSView] { addSubview(view) }
        imageView = icon
        textField = name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { tint() }
    }

    func show(_ line: DownloadLine) {
        self.line = line
        switch line {
        case .entry(let entry):
            if watched != entry.id {
                watched = entry.id
                watch = kitObserve({ [weak entry] in
                    entry.map { ($0.state, $0.name, $0.fraction, $0.completedBytes, $0.totalBytes, $0.errorDescription) }
                }) { [weak self] _ in self?.fill() }
                return
            }
        case .kept, .none:
            watched = nil
            watch = nil
        }
        fill()
    }

    private func fill() {
        var next: [DownloadVerb] = []
        var tall = false
        switch line {
        case .entry(let entry):
            let type = UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
            icon.image = NSWorkspace.shared.icon(for: type)
            icon.alphaValue = 1
            name.stringValue = entry.name
            name.textColor = .labelColor
            detail.stringValue = entry.detailText
            detail.toolTip = entry.state == .failed ? entry.detailText : nil
            detail.isHidden = false
            tall = entry.showsBar
            bar.isHidden = !tall
            if let fraction = entry.fraction {
                if bar.isIndeterminate {
                    bar.stopAnimation(nil)
                    bar.isIndeterminate = false
                }
                bar.doubleValue = min(1, max(0, fraction))
            } else if tall, entry.state == .downloading || entry.state == .resuming {
                if !bar.isIndeterminate {
                    bar.isIndeterminate = true
                    bar.startAnimation(nil)
                }
            } else {
                if bar.isIndeterminate {
                    bar.stopAnimation(nil)
                    bar.isIndeterminate = false
                }
                bar.doubleValue = 0
            }
            gone = false
            next = entry.verbs
            setAccessibilityLabel("\(entry.name), \(entry.detailText)")
        case .kept(let keep):
            let there = keep.stillThere
            icon.image = NSWorkspace.shared.icon(forFile: keep.path)
            icon.alphaValue = there ? 1 : 0.45
            name.stringValue = keep.name
            gone = !there
            detail.stringValue = keep.from
            detail.toolTip = nil
            detail.isHidden = keep.from.isEmpty
            bar.isHidden = true
            next = keep.verbs
            setAccessibilityLabel(keep.from.isEmpty ? keep.name : "\(keep.name), \(keep.from)")
        case .none:
            break
        }
        name.toolTip = name.stringValue
        if next != verbs || keys.isEmpty != next.isEmpty {
            keys.forEach { $0.removeFromSuperview() }
            verbs = next
            keys = next.map(key)
            keys.forEach(addSubview)
        }
        if case .kept(let keep) = line { keys.forEach { $0.isEnabled = keep.stillThere } }
        setAccessibilityCustomActions(actions)
        tint()
        needsLayout = true
        let wanted = tall ? Self.tall : Self.short
        if height != 0, height != wanted { resized?() }
        height = wanted
    }

    override func accessibilityPerformPress() -> Bool { press?() ?? false }

    func benchSpot(_ verb: String) -> NSPoint? {
        guard let index = verbs.firstIndex(where: { $0.rawValue == verb }), keys.indices.contains(index) else { return nil }
        let key = keys[index]
        return key.convert(NSPoint(x: key.bounds.midX, y: key.bounds.midY), to: nil)
    }

    private var actions: [NSAccessibilityCustomAction] {
        var all = verbs
        if case .kept(let keep) = line { all = (keep.stillThere ? [.open, .reveal] : []) + [.forget] }
        return all.map { verb in
            NSAccessibilityCustomAction(name: verb.title) { [weak self] in
                self?.run?(verb)
                return true
            }
        }
    }

    private func key(_ verb: DownloadVerb) -> NSButton {
        let made = NSButton()
        made.isBordered = false
        made.bezelStyle = .accessoryBarAction
        made.imagePosition = .imageOnly
        made.imageScaling = .scaleNone
        made.image = NSImage(systemSymbolName: verb.symbol ?? "circle.fill", accessibilityDescription: verb.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        made.kitAccess(id: "downloads.key." + verb.rawValue, label: verb.title, help: verb.help)
        made.kitOnChange { [weak self] _ in self?.run?(verb) }
        return made
    }

    private func tint() {
        let lit = backgroundStyle == .emphasized
        for key in keys { key.contentTintColor = lit ? .alternateSelectedControlTextColor : Palette.NS.glassFaint }
        name.textColor = lit ? .alternateSelectedControlTextColor : gone ? Palette.NS.glassFaint : .labelColor
        detail.textColor = lit ? .alternateSelectedControlTextColor : Palette.NS.glassMuted
    }

    var bench: [String: Any] {
        ["name": name.stringValue, "detail": detail.isHidden ? "" : detail.stringValue, "bar": !bar.isHidden,
         "indeterminate": bar.isIndeterminate, "fraction": bar.doubleValue, "keys": verbs.map(\.rawValue),
         "enabled": keys.allSatisfy(\.isEnabled), "frame": [Double(frame.minX), Double(frame.width)],
         "nameWidth": Double(name.frame.width), "icon": icon.image != nil]
    }

    override func layout() {
        super.layout()
        var right = bounds.width
        for key in keys.reversed() {
            key.frame = NSRect(x: right - 20, y: ((bounds.height - 20) / 2).rounded(), width: 20, height: 20)
            right -= 22
        }
        icon.frame = NSRect(x: 0, y: ((bounds.height - Self.icon) / 2).rounded(), width: Self.icon, height: Self.icon)
        let x = Self.icon + 8
        let room = max(0, right - (keys.isEmpty ? 0 : 6) - x)
        let nameHeight = name.intrinsicContentSize.height
        let detailHeight = detail.intrinsicContentSize.height
        if !bar.isHidden {
            let barHeight = bar.intrinsicContentSize.height
            let whole = nameHeight + 2 + barHeight + 2 + detailHeight
            var y = ((bounds.height - whole) / 2).rounded()
            name.frame = NSRect(x: x, y: y, width: room, height: nameHeight)
            y += nameHeight + 2
            bar.frame = NSRect(x: x + Self.wordInset, y: y, width: max(0, room - Self.wordInset * 2), height: barHeight)
            y += barHeight + 2
            detail.frame = NSRect(x: x, y: y, width: room, height: detailHeight)
        } else if detail.isHidden {
            name.frame = NSRect(x: x, y: ((bounds.height - nameHeight) / 2).rounded(), width: room, height: nameHeight)
        } else {
            let whole = nameHeight + 1 + detailHeight
            let y = ((bounds.height - whole) / 2).rounded()
            name.frame = NSRect(x: x, y: y, width: room, height: nameHeight)
            detail.frame = NSRect(x: x, y: y + nameHeight + 1, width: room, height: detailHeight)
        }
    }
}
