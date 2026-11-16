import AppKit

extension SettingsShell {
    func openLanguages(space: UUID?) {
        query = ""
        walk { $0.open(.languages, space: space) }
    }
}

enum LanguageWords {
    static let settingsFoot = "Sites get your first language when they pick one for you, in every space and in private windows. Broadway never offers to translate a page in any language here. Pages open now change when you reload them."
    static let relaunch = "Quit and reopen Broadway for sites to get your first language with every request"
    static let spaceFoot = "Pages in this space see these when they read your languages. Sites still get the first language in Settings with every request. Pages open now change when you reload them."
}

extension SettingsPageView {
    func languagesRow() {
        let prefs = LanguagePrefs.shared
        let id = PreferredLanguages.key
        let item = SettingsIndex.item(id)
        let made = SettingsDrillRow(id: id, symbol: item?.icon ?? SettingsDetail.languages.symbol, title: item?.title ?? "Languages",
                                    line: item?.detail, tiled: false) { [weak self] in self?.shell.drill(.languages) }
        made.lit = shell.lit == id
        made.identifier = NSUserInterfaceItemIdentifier("detail." + SettingsDetail.languages.rawValue)
        update { [weak made] in
            made?.mark.show(count: nil, value: PreferredLanguages.summary(chosen: prefs.chosen, mac: PreferredLanguages.mac))
        }
        put(made)
    }

    func languages() {
        let browser = browser
        let prefs = LanguagePrefs.shared
        let spaceID = shell.trail.space.flatMap { id in browser.spaces.contains { $0.id == id } ? id : nil }

        func own() -> [String]? { spaceID.flatMap { id in browser.spaces.first { $0.id == id }?.languages } }
        func shown() -> [String] { spaceID == nil ? prefs.list : own() ?? prefs.list }
        func set(_ list: [String]?) {
            if let spaceID { browser.setSpaceLanguages(spaceID, to: list) } else { prefs.chosen = list }
        }

        if spaceID != nil {
            shape { own() == nil }
            section {
                let same = toggle("languages.same", get: { own() == nil }, set: { on in set(on ? nil : prefs.list) })
                let row = line("Same as Settings", nil, id: "languages.same", control: same)
                update { [weak row] in row?.say(PreferredLanguages.names(prefs.list)) }
            }
            guard own() != nil else { return }
        }

        shape { shown() }
        shape { spaceID == nil && prefs.chosen != nil }
        shape { spaceID == nil && prefs.waitsForRelaunch }
        let list = shown()
        var foot = spaceID == nil ? LanguageWords.settingsFoot : LanguageWords.spaceFoot
        if spaceID == nil, prefs.waitsForRelaunch { foot += "\n\n" + LanguageWords.relaunch }
        let drag = SettingsLanguageDrag()
        section(footer: foot) {
            for (index, code) in list.enumerated() {
                let row = SettingsLanguageRow(code: code, removable: list.count > 1) { [weak self] in
                    SettingsQuestion.language(PreferredLanguages.name(code)).ask(over: self?.window) {
                        var next = shown()
                        next.removeAll { $0 == code }
                        if !next.isEmpty { set(next) }
                    }
                }
                row.handle.began = { drag.begin(index, rows: drag.rows) }
                row.handle.moved = { point in drag.move(to: point) }
                row.handle.ended = { point in
                    guard let to = drag.end(at: point) else { return }
                    let next = Spaces.moved(shown(), from: index, to: to)
                    if next != shown() { set(next) }
                }
                drag.rows.append(row)
                put(row, name: "language." + code)
            }
            let buttons = NSStackView()
            buttons.orientation = .horizontal
            buttons.spacing = 8
            let adding = button("Add Language…") {}
            adding.kitAccess(id: "settings.languages.add", label: "Add Language…")
            adding.action = { [weak adding] in
                guard let adding else { return }
                SettingsLanguagePicker.show(from: adding, leaving: shown()) { code in set(shown() + [code]) }
            }
            buttons.addArrangedSubview(adding)
            if spaceID == nil, prefs.chosen != nil {
                let mac = button("Use My Mac's Languages") { prefs.chosen = nil }
                mac.kitAccess(id: "settings.languages.mac", label: "Use My Mac's Languages")
                buttons.addArrangedSubview(mac)
            }
            fitted(buttons, name: "languages.add")
        }
    }
}

@MainActor
final class SettingsLanguageDrag {
    var rows: [SettingsLanguageRow] = []
    private var from: Int?
    private var mark: NSView?

    func begin(_ index: Int, rows: [SettingsLanguageRow]) {
        from = index
        rows[safe: index]?.alphaValue = 0.55
        NSCursor.closedHand.push()
    }

    func move(to point: NSPoint) {
        guard from != nil, let holder = rows.first?.superview else { return }
        let at = target(holder.convert(point, from: nil), in: holder)
        let line = mark ?? {
            let made = NSView()
            made.wantsLayer = true
            made.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            made.layer?.cornerRadius = 1
            holder.addSubview(made)
            mark = made
            return made
        }()
        let edge: CGFloat
        if at < rows.count {
            edge = holder.isFlipped ? rows[at].frame.minY : rows[at].frame.maxY
        } else {
            edge = holder.isFlipped ? rows[rows.count - 1].frame.maxY : rows[rows.count - 1].frame.minY
        }
        line.frame = NSRect(x: SettingsMetrics.inset, y: edge - 1, width: holder.bounds.width - SettingsMetrics.inset * 2, height: 2)
    }

    func end(at point: NSPoint) -> Int? {
        NSCursor.pop()
        mark?.removeFromSuperview()
        mark = nil
        guard let start = from, let holder = rows.first?.superview else { return nil }
        from = nil
        rows[safe: start]?.alphaValue = 1
        let at = target(holder.convert(point, from: nil), in: holder)
        let to = at > start ? at - 1 : at
        return to == start ? nil : to
    }

    private func target(_ point: NSPoint, in holder: NSView) -> Int {
        rows.filter { holder.isFlipped ? $0.frame.midY < point.y : $0.frame.midY > point.y }.count
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

final class SettingsLanguageHandle: NSView {
    var began: (() -> Void)?
    var moved: ((NSPoint) -> Void)?
    var ended: ((NSPoint) -> Void)?
    private let glyph = KitSymbol("line.3.horizontal", style: KitSymbol.Style(size: 12, weight: .medium), tint: .tertiaryLabelColor)

    init(label: String) {
        super.init(frame: .zero)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = "Drag to reorder"
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { began?() }
    override func mouseDragged(with event: NSEvent) { moved?(event.locationInWindow) }
    override func mouseUp(with event: NSEvent) { ended?(event.locationInWindow) }
}

final class SettingsLanguageRow: SettingsRowView {
    let code: String
    let handle: SettingsLanguageHandle
    private let remove = NSButton()
    private let removable: Bool
    private var hover: NSTrackingArea?

    init(code: String, removable: Bool, onRemove: @escaping () -> Void) {
        self.code = code
        self.removable = removable
        let name = PreferredLanguages.name(code)
        handle = SettingsLanguageHandle(label: "Reorder \(name)")
        remove.image = KitGlyph.plain("xmark.circle.fill", label: "Remove \(name)")
        remove.isBordered = false
        remove.contentTintColor = .tertiaryLabelColor
        remove.kitOnChange { _ in onRemove() }
        remove.kitAccess(id: "settings.languages.remove." + code, label: "Remove \(name)")
        remove.alphaValue = 0
        remove.isHidden = !removable
        let controls = NSStackView(views: [remove, handle])
        controls.orientation = .horizontal
        controls.spacing = 6
        super.init(id: "languages." + code, symbol: nil, title: name, control: controls, centered: true)
        let words = NSMutableAttributedString(string: name, attributes: [.font: SettingsMetrics.titleFont, .foregroundColor: NSColor.labelColor])
        if let own = PreferredLanguages.ownName(code) {
            words.append(NSAttributedString(string: " · " + own, attributes: [.font: SettingsMetrics.titleFont,
                                                                              .foregroundColor: NSColor.secondaryLabelColor]))
        }
        title.attributedStringValue = words
        title.setAccessibilityLabel(words.string)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hover { removeTrackingArea(hover) }
        let made = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(made)
        hover = made
    }

    override func mouseEntered(with event: NSEvent) { if removable { remove.alphaValue = 1 } }
    override func mouseExited(with event: NSEvent) { remove.alphaValue = 0 }
}

@MainActor
final class SettingsLanguagePicker: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let field = KitSearchField(prompt: "Search languages", takesFocus: true)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let listed: [String]
    private var found: [String]
    private let pick: (String) -> Void
    private weak var popup: KitPopup?

    static let size = NSSize(width: 300, height: 320)

    static func show(from view: NSView, leaving listed: [String], pick: @escaping (String) -> Void) {
        let picker = SettingsLanguagePicker(leaving: listed, pick: pick)
        picker.frame = NSRect(origin: .zero, size: size)
        picker.popup = KitPopup.show(picker, size: size, from: view.bounds, of: view, edge: .below, focus: true)
    }

    init(leaving listed: [String], pick: @escaping (String) -> Void) {
        self.listed = listed
        self.pick = pick
        found = PreferredLanguages.choices(leaving: listed)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("settings.languages.picker")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.onChange = { [weak self] typed in self?.filter(typed) }
        field.onSubmit = { [weak self] in self?.choose(0) }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityLabel("Languages")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func filter(_ typed: String) {
        found = PreferredLanguages.choices(leaving: listed, matching: typed)
        table.reloadData()
    }

    @objc private func clicked() { choose(table.clickedRow) }

    private func choose(_ row: Int) {
        guard found.indices.contains(row) else { return }
        let code = found[row]
        popup?.close()
        pick(code)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { found.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let code = found[row]
        let cell = NSTableCellView()
        let words = NSMutableAttributedString(string: PreferredLanguages.name(code),
                                              attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        if let own = PreferredLanguages.ownName(code) {
            words.append(NSAttributedString(string: " · " + own, attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                                              .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let label = NSTextField(labelWithAttributedString: words)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
