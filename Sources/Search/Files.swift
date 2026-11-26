import AppKit
import Combine
import Observation

struct Upload: Codable, Identifiable, Equatable {
    var name: String
    var site: String
    var path: String
    var date: Date

    var id: String { "\(path)|\(site)" }
}

@MainActor
@Observable
final class Uploads {
    static let shared = Uploads()
    static let cap = 500

    private(set) var kept: [Upload] = []

    @ObservationIgnored private let file: URL

    init(file: URL = Store.file("uploads.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            if let list = try? JSONDecoder().decode([Upload].self, from: data) { kept = list } else { Store.quarantine(file) }
        }
    }

    func add(_ urls: [URL], to site: String, at date: Date = Date()) {
        var list = kept
        for url in urls {
            let upload = Upload(name: url.lastPathComponent, site: site, path: url.path, date: date)
            list.removeAll { $0.id == upload.id }
            list.insert(upload, at: 0)
        }
        if list.count > Self.cap { list.removeLast(list.count - Self.cap) }
        kept = list
        save()
    }

    func forget(_ id: String) {
        kept.removeAll { $0.id == id }
        save()
    }

    func forgetAll() {
        kept = []
        save()
    }

    func restore(_ list: [Upload]) {
        kept = list
        save()
    }

    private func save() {
        let snapshot = kept
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }
}

struct FileItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case downloaded, uploaded
    }

    let id: String
    let kind: Kind
    let name: String
    let source: String
    let path: String
    let date: Date

    static func merged(downloads: [Keep], uploads: [Upload]) -> [FileItem] {
        let down = downloads.map {
            FileItem(id: "d|\($0.id)", kind: .downloaded, name: $0.name, source: $0.from, path: $0.path, date: $0.date)
        }
        let up = uploads.map {
            FileItem(id: "u|\($0.id)", kind: .uploaded, name: $0.name, source: $0.site, path: $0.path, date: $0.date)
        }
        return (down + up).sorted { $0.date > $1.date }
    }

    static func found(_ items: [FileItem], matching typed: String) -> [FileItem] {
        let words = typed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let haystack = item.name + " " + item.source
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    var said: String {
        let verb = kind == .downloaded ? "From" : "Given to"
        let from = source.isEmpty ? "" : "\(verb) \(source) \u{00B7} "
        return from + When.said(date)
    }
}

final class FilesPageView: KitFlippedView {
    let browser: Browser
    let loot: Loot
    let uploads: Uploads
    let asTab: Bool

    private let body: FilesBody
    private var plate: KitPlatePage!
    var onPress: (() -> Void)?

    init(browser: Browser, loot: Loot, uploads: Uploads? = nil, asTab: Bool = true) {
        let uploads = uploads ?? .shared
        self.browser = browser
        self.loot = loot
        self.uploads = uploads
        self.asTab = asTab
        body = FilesBody(loot: loot, uploads: uploads, asTab: asTab)
        super.init(frame: .zero)
        let foot = FilesFoot(listed: { FileItem.merged(downloads: loot.kept, uploads: uploads.kept).count }) { [weak self] in self?.clearList() }
        plate = KitPlatePage("Files", content: body, foot: foot)
        kitPin(plate)
        let press = NSClickGestureRecognizer(target: self, action: #selector(pressed))
        press.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(press)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Files")
    }

    @objc private func pressed() { onPress?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func type(_ text: String) { body.typed(text) }

    func clearList() {
        let given = uploads.kept
        let fetched = loot.kept
        guard !given.isEmpty || !fetched.isEmpty else { return }
        uploads.forgetAll()
        loot.forgetAll()
        browser.keptThere = [:]
        browser.announce(Browser.clearedList, undo: { [weak uploads, weak loot] in
            uploads?.restore(given)
            for keep in fetched.reversed() { loot?.restore(keep) }
        })
    }
}

final class FilesFoot: KitFlippedView {
    private let listed: () -> Int
    let count = KitLabel("", font: KitPageRow.footFont, color: .secondaryLabelColor)
    let clear: KitBroadwayButton

    init(listed: @escaping () -> Int, clear: @escaping () -> Void) {
        self.listed = listed
        self.clear = KitBroadwayButton("Clear List", action: clear)
        super.init(frame: .zero)
        addSubview(count)
        addSubview(self.clear)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: clear.intrinsicContentSize.height) }

    override func layout() {
        super.layout()
        let files = listed()
        clear.isEnabled = files > 0
        count.text = files == 1 ? "1 file" : "\(files) files"
        count.isHidden = files == 0
        let size = clear.intrinsicContentSize
        clear.frame = NSRect(x: bounds.width - size.width, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        let said = count.intrinsicContentSize
        count.frame = kitSnap(NSRect(x: 0, y: (bounds.height - said.height) / 2, width: min(said.width, max(0, clear.frame.minX - 8)), height: said.height))
    }
}

final class FilesBody: KitFlippedView {
    let loot: Loot
    let uploads: Uploads
    let asTab: Bool

    private let field = KitSearchField(prompt: "Search by name or site")
    private let none = KitEmptyView("No files yet", line: "Files you download, and files you give to sites, show up here", symbol: "doc")
    private let nothing = KitEmptyView("Nothing matches", line: "No file by that name, or from that site", symbol: "magnifyingglass")
    private let list = FileListView()
    private var typed = ""
    private(set) var shown: [FileItem] = []

    init(loot: Loot, uploads: Uploads, asTab: Bool) {
        self.loot = loot
        self.uploads = uploads
        self.asTab = asTab
        super.init(frame: .zero)
        for view in [field, none, nothing, list] as [NSView] { addSubview(view) }
        field.onChange = { [weak self] in self?.typed($0) }
        list.forget = { [weak self] in self?.forget($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func typed(_ text: String) {
        if field.stringValue != text { field.stringValue = text }
        typed = text
        needsLayout = true
    }

    private func forget(_ item: FileItem) {
        list.animateNext = true
        switch item.kind {
        case .downloaded:
            if let keep = loot.kept.first(where: { "d|\($0.id)" == item.id }) { loot.forget(keep) }
        case .uploaded:
            uploads.forget(String(item.id.dropFirst(2)))
        }
    }

    override func layout() {
        super.layout()
        let all = FileItem.merged(downloads: loot.kept, uploads: uploads.kept)
        shown = FileItem.found(all, matching: typed)
        none.isHidden = !all.isEmpty
        nothing.isHidden = all.isEmpty || !shown.isEmpty
        list.isHidden = all.isEmpty || shown.isEmpty
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = NSRect(x: 0, y: 0, width: bounds.width, height: fieldHeight)
        let below = KitPageRow.emptyFrame(in: bounds, fieldHeight: fieldHeight)
        none.frame = KitPageRow.emptyFrame(for: none, in: self, fieldHeight: fieldHeight)
        nothing.frame = KitPageRow.emptyFrame(for: nothing, in: self, fieldHeight: fieldHeight)
        list.frame = asTab ? below : NSRect(x: below.minX, y: below.minY, width: below.width, height: min(below.height, 440))
        list.show(shown)
    }
}

final class FileListView: NSScrollView {
    static let rowHeight = KitPageRow.height
    static let top: CGFloat = 0
    static let inset: CGFloat = 0

    var forget: ((FileItem) -> Void)?
    var animateNext = false

    private let document = KitFlippedView()
    private var rows: [String: FileRowView] = [:]

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder
        scrollerStyle = .overlay
        drawsBackground = false
        contentView.drawsBackground = false
        automaticallyAdjustsContentInsets = false
        documentView = document
        document.wantsLayer = true
        setAccessibilityRole(.list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ items: [FileItem]) {
        let animate = animateNext && !Motion.reduced && !rows.isEmpty
        animateNext = false
        let width = contentSize.width
        let height = Self.top * 2 + CGFloat(items.count) * Self.rowHeight
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(height, contentSize.height))
        let ids = Set(items.map(\.id))
        for (id, row) in rows where !ids.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }
        for (index, item) in items.enumerated() {
            let made = rows[item.id] == nil
            let row = rows[item.id] ?? FileRowView()
            if made {
                rows[item.id] = row
                document.addSubview(row)
            }
            row.forget = { [weak self] in self?.forget?(item) }
            row.show(item, last: index == items.count - 1)
            let frame = NSRect(x: Self.inset, y: Self.top + CGFloat(index) * Self.rowHeight, width: width - Self.inset * 2, height: Self.rowHeight)
            let old = row.frame
            row.frame = frame
            guard animate, let layer = row.layer else { continue }
            if made {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.2
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "arrive")
            } else if old.minY != frame.minY, let move = Motion.kitSettle.animation("transform.translation.y", from: old.minY - frame.minY, to: 0) as? CAPropertyAnimation {
                move.isAdditive = true
                layer.add(move, forKey: "move")
            }
        }
    }
}

final class FileRowView: KitHoverView {
    var forget: (() -> Void)?

    private var item: FileItem?
    private var there = false
    private var last = false
    private let icon = NSImageView()
    private let name = KitLabel("", font: KitPageRow.titleFont, color: .labelColor)
    private let said = KitLabel("", font: KitPageRow.detailFont, color: .secondaryLabelColor)
    private let rule = KitBox(fill: .separatorColor)
    private lazy var finder = Self.quick("Show in Finder", destructive: false) { [weak self] in self?.reveal() }
    private lazy var remove = Self.quick("Remove", destructive: true) { [weak self] in self?.forget?() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.overflow = .middle
        name.setAccessibilityElement(false)
        said.setAccessibilityElement(false)
        for view in [icon, name, said, rule, finder, remove] as [NSView] { addSubview(view) }
        finder.isHidden = true
        remove.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static func quick(_ title: String, destructive: Bool, act: @escaping () -> Void) -> NSButton {
        let button = KitPushButton(title, size: .small, action: act)
        button.isBordered = false
        if destructive {
            button.contentTintColor = .systemRed
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small)),
            ])
        }
        return button
    }

    func show(_ item: FileItem, last: Bool) {
        self.item = item
        self.last = last
        there = FileManager.default.fileExists(atPath: item.path)
        icon.image = NSWorkspace.shared.icon(forFile: item.path)
        icon.alphaValue = there ? 1 : 0.4
        name.text = item.name
        name.color = there ? .labelColor : .tertiaryLabelColor
        said.text = item.said
        rule.isHidden = last
        setAccessibilityLabel(item.name)
        setAccessibilityValue(item.said)
        showButtons()
        needsLayout = true
    }

    override func hoverChanged() { showButtons() }

    private func showButtons() {
        finder.isHidden = !(hovering && there)
        remove.isHidden = !hovering
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let side = KitPageRow.iconSlot
        icon.frame = KitPageRow.icon(NSSize(width: side, height: side), in: h)
        var right = bounds.width + KitPageRow.overhang(remove)
        for button in [remove, finder] where !button.isHidden {
            let size = button.intrinsicContentSize
            right -= size.width
            button.frame = NSRect(x: right, y: ((h - size.height) / 2).rounded(), width: size.width, height: size.height)
            right -= KitPageRow.gap
        }
        if right < bounds.width { right += KitPageRow.gap }
        let textX = KitPageRow.textX
        let room = max(0, right - KitPageRow.gap - textX)
        let nameSize = name.intrinsicContentSize
        let saidSize = said.intrinsicContentSize
        let tops = KitPageRow.lines(nameSize, saidSize, in: h)
        name.frame = kitSnap(NSRect(x: textX, y: tops.title, width: min(nameSize.width, room), height: nameSize.height))
        said.frame = kitSnap(NSRect(x: textX, y: tops.detail, width: min(saidSize.width, room), height: saidSize.height))
        rule.frame = KitPageRow.rule(in: bounds, hair: KitPageRow.hair(self))
    }

    override func mouseUp(with event: NSEvent) {
        guard let item, there, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
    }

    override func mouseDown(with event: NSEvent) {}

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item, item.kind == .downloaded else { return nil }
        let file = URL(fileURLWithPath: item.path)
        return DownloadMenu.menu(for: file, there: there, open: { NSWorkspace.shared.open(file) }, reveal: { [weak self] in self?.reveal() },
                                 forget: { [weak self] in self?.forget?() }, from: self, id: "files.row")
    }

    override func accessibilityPerformPress() -> Bool {
        guard let item, there else { return false }
        NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        return true
    }

    private func reveal() {
        guard let item else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }
}

@MainActor
enum FilesSurface {
    private static let uploads = Uploads(file: Store.file("visual-uploads.json"))

    static func make(_ request: [String: Any]) -> NSView? {
        guard let browser = Browsers.front else { return nil }
        for upload in uploads.kept { uploads.forget(upload.id) }
        if request["empty"] as? Bool != true {
            let day: TimeInterval = 86_400
            let base = Date(timeIntervalSince1970: 1_600_000_000)
            uploads.add([URL(fileURLWithPath: "/nonexistent/visual/holiday-photo.png")], to: "shop.example", at: base)
            uploads.add([URL(fileURLWithPath: "/nonexistent/visual/quarterly-report-final-final-v3-with-the-long-name.pdf")],
                        to: "docs.example", at: base + 40 * day)
            uploads.add([URL(fileURLWithPath: "/nonexistent/visual/notes.txt")], to: "", at: base + 80 * day)
        }
        let width = CGFloat(request["width"] as? Double ?? 760)
        let height = CGFloat(request["height"] as? Double ?? 600)
        let ground = KitBox(fill: .windowBackgroundColor)
        let page = FilesPageView(browser: browser, loot: browser.loot, uploads: uploads)
        ground.kitPin(page)
        ground.kitSize(width: width, height: height)
        return ground
    }
}
