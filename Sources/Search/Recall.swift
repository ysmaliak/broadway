import AppKit
import Combine

enum When {
    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func said(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return "just now" }
        return ago.localizedString(for: date, relativeTo: now)
    }

    private static let hour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let plain: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM"
        return formatter
    }()

    static func clock(_ date: Date) -> String { hour.string(from: date) }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return plain.string(from: date)
    }
}

@MainActor
class RecallPage: KitFlippedView {
    let content = RecallBody()
    private let footing = RecallFooting()
    private let plate: KitPlatePage

    var foot: NSView? {
        get { footing.child }
        set {
            footing.child = newValue
            plate.needsLayout = true
        }
    }

    init(_ title: String) {
        plate = KitPlatePage(title, content: content, foot: footing)
        super.init(frame: .zero)
        addSubview(plate)
        content.onLayout = { [weak self] in self?.placeBody() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        plate.frame = bounds
    }

    func footChanged() {
        footing.invalidateIntrinsicContentSize()
        footing.needsLayout = true
        plate.needsLayout = true
    }

    func placeBody() {}
}

@MainActor
final class RecallBody: KitFlippedView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

@MainActor
final class RecallFooting: KitFlippedView {
    var child: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let child { addSubview(child) }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: child?.intrinsicContentSize.height ?? 0)
    }

    override func layout() {
        super.layout()
        child?.frame = bounds
    }
}

@MainActor
enum RecallQuick {
    static func make(_ title: String, destructive: Bool = false, enabled: Bool = true, help: String? = nil, act: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        if destructive {
            button.contentTintColor = .systemRed
            button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed, .font: button.font as Any])
        }
        button.isEnabled = enabled
        button.kitOnChange { _ in act() }
        if let help { button.toolTip = help }
        return button
    }
}

@MainActor
final class RecallTable: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Line {
        case header(String)
        case row(NSView & RecallRow)
    }

    let scroll = NSScrollView()
    let table = RecallList()
    private(set) var lines: [(id: String, line: Line)] = []
    var picks: ((NSView & RecallRow) -> Bool)? {
        didSet { table.selectionHighlightStyle = picks == nil ? .none : .regular }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.floatsGroupRows = false
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.copyRow = { [weak self] in self?.copySelected() ?? false }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        table.sizeLastColumnToFit()
    }

    func set(_ made: [(id: String, line: Line)]) {
        let old = lines.map(\.id)
        let new = made.map(\.id)
        guard old != new else { return }
        let motion: NSTableView.AnimationOptions = Motion.reduced || window == nil ? [] : .effectFade
        if !old.isEmpty, let gone = Self.dropped(from: old, to: new) {
            lines = lines.filter { new.contains($0.id) }
            table.removeRows(at: gone, withAnimation: motion.isEmpty ? [] : [.effectFade, .slideUp])
            markRules()
            return
        }
        if !old.isEmpty, let added = Self.dropped(from: new, to: old) {
            let had = Dictionary(lines.map { ($0.id, $0.line) }, uniquingKeysWith: { first, _ in first })
            lines = made.map { line in (line.id, had[line.id] ?? line.line) }
            table.insertRows(at: added, withAnimation: motion.isEmpty ? [] : [.effectFade, .slideDown])
            markRules()
            return
        }
        lines = made
        markRules()
        table.reloadData()
    }

    private static func dropped(from longer: [String], to shorter: [String]) -> IndexSet? {
        guard longer.count > shorter.count else { return nil }
        var gone = IndexSet()
        var next = 0
        for (index, id) in longer.enumerated() {
            if next < shorter.count, shorter[next] == id { next += 1 } else { gone.insert(index) }
        }
        return next == shorter.count ? gone : nil
    }

    private func markRules() {
        for (index, line) in lines.enumerated() {
            if case .row(let view) = line.line { view.rule.isHidden = index == lines.count - 1 }
        }
    }

    func heightsChanged() {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<lines.count))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch lines[row].line {
        case .header: return KitPageRow.header + (row == 0 ? 0 : KitPageRow.headerAir)
        case .row(let view): return view.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard let picks, lines.indices.contains(row), case .row(let view) = lines[row].line else { return false }
        return picks(view)
    }

    func copySelected() -> Bool {
        let row = table.selectedRow
        guard lines.indices.contains(row), case .row(let view) = lines[row].line else { return false }
        return view.copyFile()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch lines[row].line {
        case .header(let title):
            return RecallHeader(title)
        case .row(let view):
            view.resized = { [weak self] in self?.heightsChanged() }
            return view
        }
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard lines.indices.contains(row), case .row(let view) = lines[row].line else { return }
        view.open()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard lines.indices.contains(row), case .row(let view) = lines[row].line else { return }
        if let items = view.fileMenuItems() {
            for item in items { menu.addItem(item) }
            return
        }
        for item in view.menuItems() { menu.addItem(KitMenu.item(item)) }
    }
}

@MainActor
protocol RecallRow: AnyObject {
    var rowHeight: CGFloat { get }
    var rule: KitBox { get }
    var ruleStart: CGFloat { get }
    var resized: (() -> Void)? { get set }
    func open()
    func menuItems() -> [KitMenuItem]
    func fileMenuItems() -> [NSMenuItem]?
    func copyFile() -> Bool
}

extension RecallRow {
    func fileMenuItems() -> [NSMenuItem]? { nil }
    func copyFile() -> Bool { false }
}

final class RecallList: NSTableView {
    var copyRow: (() -> Bool)?

    @objc func copy(_ sender: Any?) {
        guard copyRow?() == true else { return NSSound.beep() }
    }
}

@MainActor
private final class RecallHeader: NSView {
    private let label: NSTextField

    init(_ title: String) {
        label = NSTextField(labelWithString: title)
        label.font = KitPageRow.headerFont
        label.textColor = .secondaryLabelColor
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private let line = KitBox(fill: .separatorColor)

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if line.superview == nil { addSubview(line) }
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        let band = bounds.height - KitPageRow.header
        label.frame = NSRect(x: -2, y: band + ((KitPageRow.header - size.height) / 2).rounded(), width: bounds.width + 4, height: size.height)
        let hair = KitPageRow.hair(self)
        line.frame = NSRect(x: 0, y: bounds.height - hair, width: bounds.width, height: hair)
    }
}

@MainActor
final class HistoryLineView: KitHoverView, RecallRow {
    private let mark: MarkView
    private let title: KitLabel
    private let sub: KitLabel
    private let time: KitLabel
    private let remove: NSButton
    private let go: () -> Void
    private let forget: () -> Void
    let rule = KitBox(fill: .separatorColor)
    let ruleStart = KitPageRow.textX
    var resized: (() -> Void)?

    init(trace: History.Trace, note: String?, go: @escaping () -> Void, forget: @escaping () -> Void) {
        self.go = go
        self.forget = forget
        mark = MarkView(icon: Favicons.shared.cached(for: trace.url), letter: trace.address.first.map { String($0).uppercased() } ?? "•", size: 16)
        title = KitLabel(trace.title.isEmpty ? Address.withoutWWW(trace.address) : trace.title, font: KitPageRow.titleFont, color: .labelColor)
        sub = KitLabel(note ?? Address.withoutWWW(trace.address), font: KitPageRow.detailFont, color: .secondaryLabelColor)
        sub.overflow = note == nil ? .middle : .tail
        time = KitLabel(When.clock(trace.last), font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: .secondaryLabelColor)
        remove = RecallQuick.make("Remove", destructive: true, act: forget)
        super.init(frame: .zero)
        remove.isHidden = true
        for view in [mark, title, sub, time, remove, rule] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title.text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var rowHeight: CGFloat { KitPageRow.height }

    func open() { go() }

    func menuItems() -> [KitMenuItem] {
        [.action("Open", run: go), .action("Remove", run: forget)]
    }

    override func hoverChanged() {
        remove.isHidden = !hovering
        time.isHidden = hovering
        needsLayout = true
    }

    override func layout() {
        super.layout()
        rule.frame = KitPageRow.rule(in: bounds, hair: KitPageRow.hair(self))
        let middle = bounds.height / 2
        mark.frame = kitSnap(KitPageRow.icon(NSSize(width: 16, height: 16), in: bounds.height))
        let trailing: NSView = hovering ? remove : time
        let size = trailing.intrinsicContentSize
        let edge = bounds.width + (hovering ? KitPageRow.overhang(remove) : 0)
        trailing.frame = kitSnap(NSRect(x: edge - size.width, y: middle - size.height / 2, width: size.width, height: size.height))
        let x = KitPageRow.textX
        let room = max(0, trailing.frame.minX - KitPageRow.gap - x)
        let titleSize = title.intrinsicContentSize
        let subSize = sub.intrinsicContentSize
        let tops = KitPageRow.lines(titleSize, subSize, in: bounds.height)
        title.frame = kitSnap(NSRect(x: x, y: tops.title, width: min(room, titleSize.width), height: titleSize.height))
        sub.frame = kitSnap(NSRect(x: x, y: tops.detail, width: min(room, subSize.width), height: subSize.height))
    }
}

@MainActor
final class HistoryPage: RecallPage {
    private weak var browser: Browser?
    private let hunt = KitSearchField(prompt: "Search everywhere you have been", takesFocus: true)
    private let list = RecallTable()
    private var empty: KitEmptyView?
    private let count = KitLabel("", font: KitPageRow.footFont, color: .secondaryLabelColor)
    private lazy var clear = KitBroadwayButton("Clear…") { [weak self] in self?.setMode(.clearing) }
    private var traces: [History.Trace] = []
    private var hits: [PageHit] = []
    private var asking: Task<Void, Never>?
    private var shownHunt: String?
    private var shownClearing: Bool?

    init(browser: Browser) {
        self.browser = browser
        super.init("History")
        hunt.onChange = { [weak self] text in self?.browser?.recallHunt = text }
        content.addSubview(hunt)
        content.addSubview(list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(hunt words: String, clearing: Bool) {
        if hunt.stringValue != words { hunt.stringValue = words }
        if shownHunt != words {
            shownHunt = words
            refresh()
        }
        if shownClearing != clearing {
            let first = shownClearing == nil
            shownClearing = clearing
            if !first { layer?.kitTransition(Motion.kitSettle) }
            foot = clearing ? sweeps() : footLine()
        }
    }

    private func setMode(_ mode: Browser.RecallMode) {
        browser?.recallMode = mode
    }

    private func footLine() -> NSView {
        let line = RecallFootLine(left: count, right: clear)
        return line
    }

    private func sweeps() -> NSView {
        RecallSweeps(rows: [
            ("History", "Everywhere you have been, and what you typed into forms", KitBroadwayButton("Clear", kind: .destructive, small: true) { [weak self] in
                self?.browser?.clearHistory()
                self?.refresh()
                self?.setMode(.history)
            }),
            ("Cookies and sign-ins", "Signs you out of every site", KitBroadwayButton("Sign Out of Everything", kind: .destructive, small: true) { [weak self] in
                self?.browser?.clearSites()
            }),
            ("Cache", "Only what was fetched to draw pages", KitBroadwayButton("Clear", kind: .destructive, small: true) { [weak self] in
                self?.browser?.clearCache()
            }),
        ], back: KitBroadwayButton("Back") { [weak self] in self?.setMode(.history) })
    }

    private func refresh() {
        guard let browser else { return }
        traces = browser.history.everything(matching: browser.recallHunt)
        hits = []
        draw()
        asking?.cancel()
        let words = browser.recallHunt
        guard browser.prefs.remembersPageText, let query = PageQuery(words, minimumWords: 1) else { return }
        asking = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let browser = self?.browser else { return }
            let found = await browser.history.pages.search(query, limit: 30)
            guard !Task.isCancelled, browser.recallHunt == words, let self else { return }
            hits = found
            draw()
        }
    }

    private func draw() {
        guard let browser else { return }
        count.text = traces.isEmpty ? "" : traces.count == 1 ? "1 page" : "\(traces.count) pages"
        count.isHidden = traces.isEmpty
        footChanged()
        let calendar = Calendar.current
        var lines: [(id: String, line: RecallTable.Line)] = []
        func row(_ trace: History.Trace, _ hit: PageHit?) -> (id: String, line: RecallTable.Line) {
            (hit.map { "passage " + $0.key } ?? trace.id, .row(HistoryLineView(trace: trace, note: hit?.snippet, go: { [weak browser] in
                guard let browser else { return }
                (browser.pageTab(.history) ?? browser.active)?.go(to: hit?.opening ?? trace.url)
            }, forget: { [weak self, weak browser] in
                browser?.history.forget(trace.key)
                self?.refresh()
            })))
        }
        if !hits.isEmpty {
            lines.append(("day passages", .header("In page text")))
            for hit in hits {
                let trace = History.Trace(key: hit.key, address: Address.editable(hit.url), title: hit.title, url: hit.url, last: hit.visited, count: 0)
                lines.append(row(trace, hit))
            }
        }
        let grouped = Dictionary(grouping: traces) { calendar.startOfDay(for: $0.last) }
        for day in grouped.keys.sorted(by: >) {
            lines.append(("day \(day)", .header(When.day(day))))
            for trace in grouped[day]!.sorted(by: { $0.last > $1.last }) { lines.append(row(trace, nil)) }
        }
        list.set(lines)
        empty?.removeFromSuperview()
        empty = nil
        list.isHidden = traces.isEmpty && hits.isEmpty
        if list.isHidden {
            let none = browser.recallHunt.isEmpty
            let made = KitEmptyView(none ? "No history yet" : "Nothing matches",
                                   line: none ? "Everywhere you go gathers here, so you can find it again" : "Try fewer words, or part of the address",
                                   symbol: none ? "clock" : "magnifyingglass")
            content.addSubview(made)
            empty = made
        }
        content.needsLayout = true
    }

    override func placeBody() {
        let field = hunt.intrinsicContentSize.height
        hunt.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: field)
        let gap = KitPlatePage.fieldGap
        let rest = NSRect(x: 0, y: field + gap, width: content.bounds.width, height: max(0, content.bounds.height - field - gap))
        list.frame = rest
        if let empty { empty.frame = KitPageRow.emptyFrame(for: empty, in: content, fieldHeight: field) }
    }
}

@MainActor
final class RecallFootLine: NSView {
    private let left: NSView
    private let right: NSView

    init(left: NSView, right: NSView) {
        self.left = left
        self.right = right
        super.init(frame: .zero)
        addSubview(left)
        addSubview(right)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(right.intrinsicContentSize.height, left.isHidden ? 0 : left.intrinsicContentSize.height))
    }

    override func layout() {
        super.layout()
        let middle = bounds.height / 2
        let rightSize = right.intrinsicContentSize
        right.frame = NSRect(x: bounds.width - rightSize.width, y: middle - rightSize.height / 2, width: rightSize.width, height: rightSize.height)
        let leftSize = left.intrinsicContentSize
        left.frame = kitSnap(NSRect(x: 0, y: middle - leftSize.height / 2, width: min(leftSize.width, max(0, right.frame.minX - 8)), height: leftSize.height))
    }
}

@MainActor
final class RecallSweeps: NSView {
    private let card = KitBox(fill: .controlBackgroundColor, stroke: .separatorColor, corners: .radius(8))
    private var lines: [(KitLabel, KitLabel, NSView)] = []
    private var rules: [KitBox] = []
    private let back: NSView

    init(rows: [(String, String, NSView)], back: NSView) {
        self.back = back
        super.init(frame: .zero)
        addSubview(card)
        for (index, row) in rows.enumerated() {
            let title = KitLabel(row.0, font: KitPageRow.titleFont, color: .labelColor)
            let detail = KitLabel(row.1, font: KitPageRow.detailFont, color: .secondaryLabelColor)
            for view in [title, detail, row.2] { addSubview(view) }
            lines.append((title, detail, row.2))
            if index > 0 {
                let rule = KitBox(fill: .separatorColor)
                addSubview(rule)
                rules.append(rule)
            }
        }
        addSubview(back)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static let rowHeight: CGFloat = 52
    static let pad: CGFloat = 12

    private var cardHeight: CGFloat { Self.rowHeight * CGFloat(lines.count) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: cardHeight + Self.pad + back.intrinsicContentSize.height)
    }

    override func layout() {
        super.layout()
        let pad = Self.pad
        let rowHeight = Self.rowHeight
        card.frame = NSRect(x: 0, y: 0, width: bounds.width, height: cardHeight)
        for (index, line) in lines.enumerated() {
            let top = card.frame.minY + CGFloat(index) * rowHeight
            let titleSize = line.0.intrinsicContentSize
            let detailSize = line.1.intrinsicContentSize
            let start = top + (rowHeight - titleSize.height - 2 - detailSize.height) / 2
            let size = line.2.intrinsicContentSize
            line.2.frame = NSRect(x: card.frame.maxX - pad - size.width, y: top + (rowHeight - size.height) / 2, width: size.width, height: size.height)
            let room = max(0, line.2.frame.minX - KitPageRow.gap - pad)
            line.0.frame = kitSnap(NSRect(x: pad, y: start, width: min(titleSize.width, room), height: titleSize.height))
            line.1.frame = kitSnap(NSRect(x: pad, y: start + titleSize.height + 2, width: min(detailSize.width, room), height: detailSize.height))
            if index > 0 { rules[index - 1].frame = NSRect(x: pad, y: top, width: max(0, card.frame.width - pad * 2), height: KitPageRow.hair(self)) }
        }
        let size = back.intrinsicContentSize
        back.frame = NSRect(x: bounds.width - size.width, y: cardHeight + pad, width: size.width, height: size.height)
    }
}

@MainActor
enum RecallSurface {
    static let day = Date(timeIntervalSince1970: 1_790_000_000)

    static func history() -> NSView {
        let browser = Browsers.acting
        let sites = [("https://example.com/articles/orchids", "Growing orchids indoors"), ("https://news.example.org/today", "Today's news"),
                     ("https://docs.example.dev/guide/start", ""), ("https://shop.example.net/cart", "Your cart")]
        for (index, site) in sites.enumerated() {
            if let url = URL(string: site.0) {
                browser.history.take(url, title: site.1, count: 1, last: day.addingTimeInterval(TimeInterval(-index * 3000) - (index > 1 ? 90_000 : 0)))
            }
        }
        let page = HistoryPage(browser: browser)
        page.show(hunt: browser.recallHunt, clearing: false)
        return surface(page, height: 520)
    }

    private static func surface(_ page: NSView, height: CGFloat) -> NSView {
        let stage = KitBox(fill: .windowBackgroundColor)
        stage.frame = NSRect(x: 0, y: 0, width: 720, height: height)
        page.frame = stage.bounds
        stage.addSubview(page)
        return KitFixedView(stage)
    }
}
