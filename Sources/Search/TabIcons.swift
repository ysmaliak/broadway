import AppKit
import Combine
import Observation

struct TabIcon: Codable, Equatable, Hashable {
    var emoji: String? = nil
    var symbol: String? = nil

    private static var made: [TabIcon: NSImage] = [:]

    init(saved: String) {
        if saved.unicodeScalars.allSatisfy(\.isASCII) { symbol = saved } else { emoji = saved }
    }

    init(emoji: String? = nil, symbol: String? = nil) {
        self.emoji = emoji
        self.symbol = symbol
    }

    var saved: String { emoji ?? symbol ?? "" }

    @MainActor
    var image: NSImage? {
        if let held = TabIcon.made[self] { return held }
        let drawn: NSImage?
        if let emoji, !emoji.isEmpty {
            drawn = TabIcon.draw(emoji)
        } else if let symbol {
            drawn = KitGlyph.image(symbol, .init(size: 32, weight: .regular))
        } else {
            drawn = nil
        }
        if let drawn { TabIcon.made[self] = drawn }
        return drawn
    }

    private static func draw(_ text: String) -> NSImage {
        let side: CGFloat = 64
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            let words = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 50)])
            let size = words.size()
            words.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
            return true
        }
    }
}

enum IconChoices {
    struct Choice: Identifiable, Hashable {
        let icon: TabIcon
        let words: String
        var id: TabIcon { icon }
    }

    static let symbols: [Choice] = zip(Spaces.icons, Spaces.iconNames).map { Choice(icon: TabIcon(symbol: $0), words: "\($1.lowercased()) \($0.replacingOccurrences(of: ".", with: " "))") } + [
        ("star", "star favourite"), ("bookmark", "bookmark"), ("flag", "flag"), ("bell", "bell alert"), ("bolt", "bolt lightning"),
        ("flame", "flame fire"), ("globe", "globe world web"), ("envelope", "mail envelope"), ("calendar", "calendar date"),
        ("clock", "clock time"), ("doc.text", "document text"), ("folder", "folder"), ("tray", "inbox tray"), ("checkmark.circle", "done check"),
        ("creditcard", "card money payment"), ("chart.bar", "chart stats"), ("person", "person"), ("person.2", "people team"),
        ("bubble.left", "chat message"), ("phone", "phone call"), ("video", "video meeting"), ("map", "map"), ("wrench.and.screwdriver", "tools"),
        ("hammer", "build hammer"), ("gearshape", "settings gear"), ("lock", "lock private"), ("cloud", "cloud"), ("sun.max", "sun"), ("moon", "moon"),
    ].map { Choice(icon: TabIcon(symbol: $0.0), words: $0.1) }

    static let emoji: [Choice] = {
        let blocks: [ClosedRange<UInt32>] = [0x1F600...0x1F64F, 0x1F300...0x1F5FF, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x2600...0x27BF]
        return blocks.flatMap { $0 }.compactMap { value -> Choice? in
            guard let scalar = Unicode.Scalar(value), scalar.properties.isEmojiPresentation,
                  !scalar.properties.isEmojiModifier else { return nil }
            return Choice(icon: TabIcon(emoji: String(Character(scalar))), words: (scalar.properties.name ?? "").lowercased())
        }
    }()

    static func typed(_ text: String) -> TabIcon? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let first = trimmed.unicodeScalars.first,
              first.properties.isEmoji, first.value > 0x238C else { return nil }
        return TabIcon(emoji: trimmed)
    }

    static func found(_ list: [Choice], _ text: String) -> [Choice] {
        let words = SearchFolders.words(of: text)
        return words.isEmpty ? list : list.filter { SearchFolders.matchesAll($0.words, words: words) }
    }

    static func sections(_ text: String, space: Bool) -> [(String, [Choice])] {
        var shown: [(String, [Choice])] = []
        if let typed = typed(text) { shown.append(("Typed", [Choice(icon: typed, words: text)])) }
        let symbols = found(self.symbols, text)
        let emoji = found(self.emoji, text)
        if !symbols.isEmpty { shown.append((space ? "Icons" : "Symbols", symbols)) }
        if !emoji.isEmpty { shown.append(("Emoji", emoji)) }
        return shown
    }

    static func first(_ text: String, space: Bool) -> TabIcon? {
        sections(text, space: space).first?.1.first?.icon
    }
}

@MainActor
@Observable
final class IconPicker {
    enum Target: Equatable {
        case tab(Tab.ID)
        case folder(UUID)
        case space(UUID)
        case draft
    }

    var target: Target?
    var query = ""
    @ObservationIgnored var draft: TabIcon?
    @ObservationIgnored var drafted: ((TabIcon) -> Void)?

    func pick(_ next: Target) {
        query = ""
        target = next
    }

    func pick(draft icon: TabIcon, then done: @escaping (TabIcon) -> Void) {
        draft = icon
        drafted = done
        pick(.draft)
    }

    func close() {
        target = nil
        drafted = nil
    }
}

extension Browser {
    func icon(of target: IconPicker.Target) -> TabIcon? {
        switch target {
        case .tab(let id): return tabs.first { $0.id == id }?.customIcon
        case .folder(let id): return tabGroups.first { $0.id == id }?.icon
        case .space(let id): return spaces.first { $0.id == id }?.shownIcon
        case .draft: return iconPicker.draft
        }
    }

    func setIcon(_ icon: TabIcon?, of target: IconPicker.Target) {
        switch target {
        case .tab(let id):
            tabs.first { $0.id == id }?.customIcon = icon
        case .folder(let id):
            guard let index = tabGroups.firstIndex(where: { $0.id == id }) else { return }
            tabGroups[index].icon = icon
            tabGroups[index].userIcon = true
        case .space(let id):
            setSpaceIcon(id, to: icon)
            return
        case .draft:
            if let icon { iconPicker.drafted?(icon) }
            return
        }
        writeSession(now: true)
    }
}


final class IconPickerView: NSView {
    let browser: Browser
    private let card: IconPickerCardView
    private var popup: KitPopup?

    init(browser: Browser) {
        self.browser = browser
        card = IconPickerCardView(browser: browser)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.open() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        let going = popup
        popup = nil
        going?.close()
    }

    private func open() {
        guard popup == nil, let window, let content = window.contentView, let target = browser.iconPicker.target else { return }
        let size = IconPickerCardView.size
        let anchor: NSView
        let spot: NSRect
        if let row = Self.anchor(for: target, in: content) {
            anchor = row
            spot = row.bounds
        } else {
            anchor = content
            let x = ((content.bounds.width - size.width) / 2).rounded()
            let top = ((content.bounds.height - size.height) / 2).rounded()
            let y = content.isFlipped ? top : content.bounds.height - top
            spot = NSRect(x: x, y: y, width: 1, height: 0)
        }
        popup = KitPopup.show(card, size: size, from: spot, of: anchor, edge: .auto, focus: true, bleeds: true) { [weak self] in
            guard let self, self.popup != nil else { return }
            self.popup = nil
            self.browser.iconPicker.close()
        }
        card.focus()
    }

    static func anchor(for target: IconPicker.Target, in root: NSView) -> NSView? {
        func shown(_ view: NSView) -> Bool { view.window != nil && !view.isHiddenOrHasHiddenAncestor && view.bounds.height > 0 }
        switch target {
        case .tab(let id):
            if let row = root.kitSubviews(of: TabRowView.self).first(where: { $0.tab?.id == id && shown($0) }) { return row }
            return root.kitSubviews(of: PinSquareView.self).first { $0.tab?.id == id && shown($0) }
        case .folder(let id):
            return root.kitSubviews(of: GroupHeadingView.self).first { $0.group?.id == id && shown($0) }
        case .space:
            return root.kitSubviews(of: SpaceTitlesView.self).first(where: shown)
        case .draft:
            return root.kitSubviews(of: NewSpaceIconFace.self).first(where: shown)
        }
    }
}

final class IconPickerCardView: NSView, NSTextFieldDelegate {
    static let size = NSSize(width: 366, height: 430)

    let browser: Browser
    private var picker: IconPicker { browser.iconPicker }
    private let well = KitBox(fill: Palette.NS.wash, corners: .radius(9))
    private let field = IconFindField()
    private let scroll = NSScrollView()
    private let sections = IconSectionsView()
    private let restore = KitButton(title: "", font: .systemFont(ofSize: BroadwaySize.small.font), look: .pill(.secondary))
    private let cancel = KitButton(title: "Cancel", font: .systemFont(ofSize: BroadwaySize.small.font), look: .pill(.secondary))
    private var watch: AnyCancellable?

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        field.placeholderString = "Find an icon"
        field.font = .systemFont(ofSize: 13)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cancel = { [weak self] in self?.picker.close() }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = sections
        sections.take = { [weak self] icon in self?.take(icon) }
        for button in [restore, cancel] {
            button.height = BroadwaySize.small.height
            button.padding = BroadwaySize.small.padding
        }
        restore.action = { [weak self] in self?.take(nil) }
        cancel.action = { [weak self] in self?.picker.close() }
        for view in [well, field, scroll, restore, cancel] as [NSView] { addSubview(view) }
        let picker = picker
        watch = kitObserve({ [weak picker] in (picker?.target, picker?.query) }) { [weak self] _ in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func focus() { window?.makeFirstResponder(field) }

    private var target: IconPicker.Target? { picker.target }

    private var picksSpace: Bool {
        switch target {
        case .space, .draft: true
        default: false
        }
    }

    private func take(_ icon: TabIcon?) {
        guard let target else { return }
        browser.setIcon(icon, of: target)
        picker.close()
    }

    private func refresh() {
        guard let target else { return }
        if field.stringValue != picker.query { field.stringValue = picker.query }
        sections.chosen = browser.icon(of: target)
        sections.show(IconChoices.sections(picker.query, space: picksSpace))
        restore.isHidden = browser.icon(of: target) == nil || target == .draft
        (restore.content as? KitLabel)?.text = switch target {
        case .folder: "Restore Folder Icon"
        case .space: "Restore Space Icon"
        default: "Restore Site Icon"
        }
        restore.setAccessibilityLabel((restore.content as? KitLabel)?.text)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12
        let width = bounds.width - 2 * pad
        well.frame = NSRect(x: pad, y: pad, width: width, height: 32)
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = NSRect(x: pad + 10, y: pad + (32 - fieldHeight) / 2, width: width - 20, height: fieldHeight)
        let tall = BroadwaySize.small.height
        let footY = bounds.height - pad - tall
        let cancelWidth = cancel.intrinsicContentSize.width
        cancel.frame = NSRect(x: bounds.width - pad - cancelWidth, y: footY, width: cancelWidth, height: tall)
        restore.frame = NSRect(x: pad, y: footY, width: restore.intrinsicContentSize.width, height: tall)
        let top = pad + 32 + 10
        scroll.frame = NSRect(x: pad, y: top, width: width, height: footY - 10 - top)
        sections.frame = NSRect(x: 0, y: 0, width: width, height: sections.height(width: width))
    }

    func controlTextDidChange(_ notification: Notification) {
        if picker.query != field.stringValue { picker.query = field.stringValue }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let query = picker.query
            if let first = IconChoices.first(query, space: picksSpace), !query.isEmpty { take(first) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            picker.close()
            return true
        default:
            return false
        }
    }

    override func cancelOperation(_ sender: Any?) { picker.close() }
}

private final class IconFindField: NSTextField {
    var cancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { cancel?() }
}

final class IconSectionsView: NSView {
    var take: ((TabIcon) -> Void)?
    var chosen: TabIcon? { didSet { if chosen != oldValue { grids.forEach { $0.chosen = chosen } } } }
    private var titles: [KitLabel] = []
    private var grids: [IconGridView] = []
    private let none = KitLabel("No icons match", font: .systemFont(ofSize: 12), color: KitColor.muted)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(none)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ shown: [(String, [IconChoices.Choice])]) {
        while titles.count < shown.count {
            let title = KitLabel("", font: .systemFont(ofSize: 11, weight: .semibold), color: KitColor.muted)
            let grid = IconGridView()
            grid.take = { [weak self] icon in self?.take?(icon) }
            addSubview(title)
            addSubview(grid)
            titles.append(title)
            grids.append(grid)
        }
        for (index, title) in titles.enumerated() {
            let on = index < shown.count
            title.isHidden = !on
            grids[index].isHidden = !on
            if on {
                title.text = shown[index].0
                grids[index].choices = shown[index].1
                grids[index].chosen = chosen
                grids[index].setAccessibilityLabel(shown[index].0)
            }
        }
        none.isHidden = !shown.isEmpty
        needsLayout = true
        superview?.needsLayout = true
        enclosingScrollView?.superview?.needsLayout = true
    }

    private var shownCount: Int { grids.filter { !$0.isHidden }.count }

    func height(width: CGFloat) -> CGFloat {
        guard shownCount > 0 else { return 24 + HiddenPanelView.lineHeight(.systemFont(ofSize: 12)) + 24 }
        var y: CGFloat = 0
        for index in 0..<shownCount {
            if index > 0 { y += 12 }
            y += HiddenPanelView.lineHeight(.systemFont(ofSize: 11, weight: .semibold)) + 6 + grids[index].height
        }
        return y
    }

    override func layout() {
        super.layout()
        let titleHeight = HiddenPanelView.lineHeight(.systemFont(ofSize: 11, weight: .semibold))
        var y: CGFloat = 0
        for index in 0..<shownCount {
            if index > 0 { y += 12 }
            titles[index].frame = kitSnap(NSRect(x: 4, y: y, width: bounds.width - 4, height: titleHeight))
            y += titleHeight + 6
            grids[index].frame = NSRect(x: 0, y: y, width: IconGridView.width, height: grids[index].height)
            y += grids[index].height
        }
        let noneSize = none.measure(width: bounds.width)
        none.frame = kitSnap(NSRect(x: (bounds.width - noneSize.width) / 2, y: 24, width: noneSize.width, height: noneSize.height))
    }
}

final class IconGridView: NSView {
    static let cell: CGFloat = 36
    static let spacing: CGFloat = 2
    static let columns = 9
    static var width: CGFloat { CGFloat(columns) * cell + CGFloat(columns - 1) * spacing }

    var choices: [IconChoices.Choice] = [] { didSet { if choices != oldValue { over = nil; needsDisplay = true } } }
    var chosen: TabIcon? { didSet { if chosen != oldValue { needsDisplay = true } } }
    var take: ((TabIcon) -> Void)?
    private var over: Int? { didSet { if over != oldValue { hovered() } } }
    private var pressed: Int?
    private var images: [String: NSImage] = [:]
    private var imagesDark: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var height: CGFloat {
        let rows = (choices.count + Self.columns - 1) / Self.columns
        return rows == 0 ? 0 : CGFloat(rows) * Self.cell + CGFloat(rows - 1) * Self.spacing
    }

    private func rect(_ index: Int) -> NSRect {
        let column = index % Self.columns
        let row = index / Self.columns
        return NSRect(x: CGFloat(column) * (Self.cell + Self.spacing), y: CGFloat(row) * (Self.cell + Self.spacing),
                      width: Self.cell, height: Self.cell)
    }

    private func index(at point: NSPoint) -> Int? {
        let step = Self.cell + Self.spacing
        let column = Int(point.x / step)
        let row = Int(point.y / step)
        guard point.x >= 0, point.y >= 0, column < Self.columns else { return nil }
        let index = row * Self.columns + column
        guard choices.indices.contains(index), rect(index).contains(point) else { return nil }
        return index
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = kitDark
        if imagesDark != dark {
            images = [:]
            imagesDark = dark
        }
        let step = Self.cell + Self.spacing
        let first = max(0, Int(dirtyRect.minY / step)) * Self.columns
        let last = min(choices.count, (Int(dirtyRect.maxY / step) + 1) * Self.columns)
        guard first < last else { return }
        let emojiFont = NSFont.systemFont(ofSize: 22)
        for index in first..<last {
            let box = rect(index)
            guard box.intersects(dirtyRect) else { continue }
            let choice = choices[index]
            if choice.icon == chosen || index == over {
                Palette.NS.wash.setFill()
                NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            }
            if let emoji = choice.icon.emoji {
                let words = NSAttributedString(string: emoji, attributes: [.font: emojiFont])
                let size = words.size()
                words.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2))
            } else if let symbol = choice.icon.symbol, let image = image(symbol) {
                let size = image.size
                image.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    private func image(_ symbol: String) -> NSImage? {
        if let held = images[symbol] { return held }
        let colour = KitColor.ink.withAlphaComponent(0.8)
        let made = KitGlyph.image(symbol, .init(size: 16, weight: IconLook.weight, palette: [colour]))
        images[symbol] = made
        return made
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { over = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { over = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { over = nil }

    private func hovered() {
        toolTip = over.map { choices[$0].words }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pressed = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let at = index(at: convert(event.locationInWindow, from: nil))
        defer { pressed = nil }
        guard let at, at == pressed else { return }
        take?(choices[at].icon)
    }

    override func accessibilityChildren() -> [Any]? {
        choices.indices.map { index in
            let choice = choices[index]
            let element = NSAccessibilityElement.element(withRole: .button, frame: .zero,
                                                         label: choice.icon.emoji ?? choice.words, parent: self) as! NSAccessibilityElement
            element.setAccessibilityFrameInParentSpace(rect(index))
            element.setAccessibilityHelp(choice.words)
            return element
        }
    }
}
