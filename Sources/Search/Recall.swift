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
    let table = NSTableView()
    private(set) var lines: [(id: String, line: Line)] = []

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

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

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
final class KeptLineView: KitHoverView, RecallRow {
    private let icon: KitSymbol
    private let name: KitLabel
    private let sub: KitLabel
    private let reveal: NSButton
    private let remove: NSButton
    private let keep: Keep
    private let opening: () -> Void
    private let revealing: () -> Void
    private let forget: () -> Void
    let rule = KitBox(fill: .separatorColor)
    let ruleStart = KitPageRow.textX
    var resized: (() -> Void)?

    init(keep: Keep, open: @escaping () -> Void, reveal: @escaping () -> Void, forget: @escaping () -> Void) {
        self.keep = keep
        opening = open
        revealing = reveal
        self.forget = forget
        let there = keep.stillThere
        icon = KitSymbol(there ? "doc" : "doc.badge.ellipsis", style: KitSymbol.Style(size: 13), tint: there ? .secondaryLabelColor : .tertiaryLabelColor)
        name = KitLabel(keep.name, font: KitPageRow.titleFont, color: there ? .labelColor : .tertiaryLabelColor)
        name.overflow = .middle
        sub = KitLabel(keep.from.isEmpty ? When.said(keep.date) : "\(keep.from) · \(When.said(keep.date))", font: KitPageRow.detailFont, color: .secondaryLabelColor)
        self.reveal = RecallQuick.make("Show in Finder", act: reveal)
        remove = RecallQuick.make("Remove", destructive: true, act: forget)
        super.init(frame: .zero)
        self.reveal.isHidden = true
        remove.isHidden = true
        for view in [icon, name, sub, self.reveal, remove, rule] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(keep.name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var rowHeight: CGFloat { KitPageRow.height }

    func open() { if keep.stillThere { opening() } }

    func menuItems() -> [KitMenuItem] {
        (keep.stillThere ? [.action("Open", run: opening), .action("Show in Finder", run: revealing)] : []) + [.action("Remove", run: forget)]
    }

    override func hoverChanged() {
        reveal.isHidden = !hovering || !keep.stillThere
        remove.isHidden = !hovering
        needsLayout = true
    }

    override func layout() {
        super.layout()
        rule.frame = KitPageRow.rule(in: bounds, hair: KitPageRow.hair(self))
        let middle = bounds.height / 2
        icon.frame = kitSnap(KitPageRow.icon(icon.intrinsicContentSize, in: bounds.height))
        var right = bounds.width + KitPageRow.overhang(remove)
        for button in [remove, reveal] where !button.isHidden {
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: right - size.width, y: middle - size.height / 2, width: size.width, height: size.height)
            right -= size.width + KitPageRow.gap
        }
        let x = KitPageRow.textX
        let room = max(0, right - KitPageRow.gap - x)
        let nameSize = name.intrinsicContentSize
        let subSize = sub.intrinsicContentSize
        let tops = KitPageRow.lines(nameSize, subSize, in: bounds.height)
        name.frame = kitSnap(NSRect(x: x, y: tops.title, width: min(room, nameSize.width), height: nameSize.height))
        sub.frame = kitSnap(NSRect(x: x, y: tops.detail, width: min(room, subSize.width), height: subSize.height))
    }
}

@MainActor
final class FetchLineView: NSView, RecallRow {
    private let entry: FetchEntry
    private let icon = KitSymbol("arrow.down.circle", style: KitSymbol.Style(size: 14), tint: .secondaryLabelColor)
    private let name = KitLabel("", font: KitPageRow.titleFont, color: .labelColor)
    private let progress = NSProgressIndicator()
    private let state = KitLabel("", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: .secondaryLabelColor)
    private let failure = NSTextField(wrappingLabelWithString: "")
    private var controls: [NSButton] = []
    private let pause: () -> Void
    private let resume: () -> Void
    private let retry: () -> Void
    private let cancel: () -> Void
    private var watch: AnyCancellable?
    let rule = KitBox(fill: .separatorColor)
    let ruleStart = KitPageRow.textX
    var resized: (() -> Void)?
    private var shownHeight: CGFloat = 0

    init(entry: FetchEntry, pause: @escaping () -> Void, resume: @escaping () -> Void, retry: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.entry = entry
        self.pause = pause
        self.resume = resume
        self.retry = retry
        self.cancel = cancel
        super.init(frame: .zero)
        name.overflow = .middle
        state.overflow = .middle
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        failure.font = KitPageRow.detailFont
        failure.textColor = .secondaryLabelColor
        failure.isSelectable = true
        for view in [icon, name, progress, state, failure, rule] as [NSView] { addSubview(view) }
        watch = kitObserve({ [weak entry] in
            entry.map { ($0.state, $0.name, $0.fraction, $0.completedBytes, $0.totalBytes, $0.errorDescription) }
        }) { [weak self] _ in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func open() {}
    func menuItems() -> [KitMenuItem] { [] }

    private var bytes: String {
        let received = ByteCountFormatter.string(fromByteCount: entry.completedBytes, countStyle: .file)
        guard entry.totalBytes > 0 else { return received + " downloaded" }
        return "\(received) of \(ByteCountFormatter.string(fromByteCount: entry.totalBytes, countStyle: .file))"
    }

    private var stateLabel: String {
        switch entry.state {
        case .downloading: return "Downloading"
        case .pausing: return "Pausing…"
        case .paused: return "Paused"
        case .resuming: return "Resuming…"
        case .failed: return "Failed"
        }
    }

    private func refresh() {
        icon.name = switch entry.state {
        case .downloading, .pausing, .resuming: "arrow.down.circle"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.circle"
        }
        name.text = entry.name
        state.text = "\(stateLabel) · \(bytes)"
        progress.isHidden = entry.fraction == nil
        progress.doubleValue = min(1, max(0, entry.fraction ?? 0))
        failure.isHidden = entry.state != .failed
        failure.stringValue = entry.errorDescription ?? "The download failed"
        controls.forEach { $0.removeFromSuperview() }
        let retryHelp = "Start the download again from the beginning"
        switch entry.state {
        case .downloading:
            controls = (entry.canPause ? [RecallQuick.make("Pause", act: pause)] : []) + [RecallQuick.make("Cancel", act: cancel)]
        case .pausing:
            controls = [RecallQuick.make("Pausing…", enabled: false) {}, RecallQuick.make("Cancel", act: cancel)]
        case .paused:
            controls = (entry.canResume ? [RecallQuick.make("Resume", act: resume)]
                        : entry.canRetry ? [RecallQuick.make("Retry", help: retryHelp, act: retry)] : []) + [RecallQuick.make("Remove", act: cancel)]
        case .resuming:
            controls = [RecallQuick.make("Resuming…", enabled: false) {}, RecallQuick.make("Cancel", act: cancel)]
        case .failed:
            controls = (entry.canResume ? [RecallQuick.make("Resume", act: resume)] : [])
                + (entry.canRetry ? [RecallQuick.make("Retry", help: retryHelp, act: retry)] : []) + [RecallQuick.make("Remove", act: cancel)]
        }
        controls.forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(entry.name)
        needsLayout = true
        if rowHeight != shownHeight {
            shownHeight = rowHeight
            resized?()
        }
    }

    static let failureGap: CGFloat = 4

    var rowHeight: CGFloat {
        guard !failure.isHidden else { return KitPageRow.height }
        let said = ceil(failure.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 360, height: 1000)).height ?? 14)
        return KitPageRow.height + Self.failureGap + said
    }

    override func layout() {
        super.layout()
        rule.frame = KitPageRow.rule(in: bounds, hair: KitPageRow.hair(self))
        let band = KitPageRow.height
        var right = bounds.width + (controls.last.map(KitPageRow.overhang) ?? 0)
        for button in controls.reversed() {
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: right - size.width, y: ((band - size.height) / 2).rounded(), width: size.width, height: size.height)
            right -= size.width + KitPageRow.gap
        }
        let nameSize = name.intrinsicContentSize
        let stateSize = state.intrinsicContentSize
        let tops = KitPageRow.lines(nameSize, stateSize, in: band)
        let iconSize = icon.intrinsicContentSize
        icon.frame = kitSnap(KitPageRow.icon(iconSize, in: band))
        let start = KitPageRow.textX
        let room = max(0, right - KitPageRow.gap - start)
        name.frame = kitSnap(NSRect(x: start, y: tops.title, width: min(room, nameSize.width), height: nameSize.height))
        var x = start
        if !progress.isHidden {
            progress.frame = NSRect(x: x, y: tops.detail + (stateSize.height - 12) / 2, width: 68, height: 12)
            x += 68 + KitPageRow.gap
        }
        state.frame = kitSnap(NSRect(x: x, y: tops.detail, width: min(stateSize.width, max(0, right - KitPageRow.gap - x)), height: stateSize.height))
        if !failure.isHidden {
            let height = ceil(failure.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: room, height: 1000)).height ?? 14)
            failure.frame = NSRect(x: start - 2, y: tops.detail + stateSize.height + Self.failureGap, width: room + 4, height: height)
        }
    }
}

@MainActor
final class DownloadsPage: RecallPage {
    private weak var browser: Browser?
    private let loot: Loot
    private let list = RecallTable()
    private var empty: KitEmptyView?
    private let said = KitLabel("", font: KitPageRow.footFont, color: .secondaryLabelColor)
    private lazy var clear = KitBroadwayButton("Clear List") { [weak self] in self?.loot.forgetAll() }
    private var shown: ([UUID], [Keep])?

    init(browser: Browser, loot: Loot) {
        self.browser = browser
        self.loot = loot
        super.init("Downloads")
        content.addSubview(list)
        foot = RecallFootLine(left: said, right: clear)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(entries: [FetchEntry], kept: [Keep]) {
        guard let browser else { return }
        said.text = !kept.isEmpty ? "Clearing the list leaves the files where they are"
            : browser.prefs.asksWhereToSave ? "Broadway asks where to save each file"
            : "Files land in \(browser.downloadsFolder.lastPathComponent)"
        let key = (entries.map(\.id), kept)
        if let shown, shown.0 == key.0, shown.1 == key.1 { return }
        shown = key
        clear.isHidden = kept.isEmpty
        var lines: [(id: String, line: RecallTable.Line)] = []
        let had = Dictionary(list.lines.map { ($0.id, $0.line) }, uniquingKeysWith: { first, _ in first })
        if !entries.isEmpty {
            lines.append(("current", .header("Current downloads")))
            for entry in entries {
                let id = "fetch " + entry.id.uuidString
                if let line = had[id] { lines.append((id, line)); continue }
                lines.append((id, .row(FetchLineView(entry: entry, pause: { [weak browser] in browser?.pauseDownload(entry) },
                                                resume: { [weak browser] in browser?.resumeDownload(entry) },
                                                retry: { [weak browser] in browser?.retryDownload(entry) },
                                                cancel: { [weak browser] in browser?.cancelDownload(entry) }))))
            }
        }
        if !kept.isEmpty {
            lines.append(("completed", .header("Completed")))
            for keep in kept {
                lines.append(("keep \(keep.id)", .row(KeptLineView(keep: keep, open: { [weak loot] in loot?.open(keep) }, reveal: { [weak loot] in loot?.reveal(keep) },
                                               forget: { [weak loot] in loot?.forget(keep) }))))
            }
        }
        list.set(lines)
        list.isHidden = lines.isEmpty
        empty?.removeFromSuperview()
        empty = nil
        if lines.isEmpty {
            let made = KitEmptyView("No downloads yet", line: "Files you download land here, and in your Downloads folder", symbol: "arrow.down.circle")
            content.addSubview(made)
            empty = made
        }
        footChanged()
        content.needsLayout = true
    }

    override func placeBody() {
        list.frame = content.bounds
        if let empty { empty.frame = KitPageRow.emptyFrame(for: empty, in: content, fieldHeight: KitPageRow.fieldHeight) }
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

    static func downloads() -> NSView {
        let browser = Browsers.acting
        let now = Date()
        browser.loot.add(Keep(name: "quarterly report.pdf", from: "example.com", path: "/nonexistent/quarterly report.pdf", date: now.addingTimeInterval(-3 * 86_400 - 60)))
        browser.loot.add(Keep(name: "photo.png", from: "", path: "/nonexistent/photo.png", date: now.addingTimeInterval(-5 * 86_400 - 60)))
        let page = DownloadsPage(browser: browser, loot: browser.loot)
        page.show(entries: browser.fetches.entries, kept: browser.loot.kept)
        return surface(page, height: 420)
    }

    private static func surface(_ page: NSView, height: CGFloat) -> NSView {
        let stage = KitBox(fill: .windowBackgroundColor)
        stage.frame = NSRect(x: 0, y: 0, width: 720, height: height)
        page.frame = stage.bounds
        stage.addSubview(page)
        return KitFixedView(stage)
    }
}
