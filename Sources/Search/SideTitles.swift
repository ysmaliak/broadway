import AppKit
import Combine

final class SpaceTitleLineView: KitHoverView {
    enum Kind: Equatable {
        case space(TabIcon, String, muted: Bool)
        case privateWindow
    }

    var kind: Kind = .space(TabIcon(symbol: "square.dashed"), "", muted: false) { didSet { if kind != oldValue { refresh() } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { refresh() } } }
    var act: (() -> Void)?

    private let ground = KitPlate(radius: 8)
    private var pressed = false { didSet { if pressed != oldValue { paint(curve: Motion.kitQuick) } } }
    private(set) var over = false { didSet { if over != oldValue { paint(curve: Motion.kitQuick) } } }
    private var moves: NSTrackingArea?
    private let mark = SpaceMarkView(icon: TabIcon(symbol: "square.dashed"), size: 15)
    private let symbol = KitSymbol("eye.slash", style: KitSymbol.Style(size: 13, weight: .semibold))
    private let name = KitLabel("", font: .systemFont(ofSize: 15, weight: .semibold))
    private let note = KitLabel("Nothing is kept", font: .systemFont(ofSize: 11, weight: .medium), color: KitColor.muted)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for view in [ground, mark, symbol, name, note] as [NSView] { addSubview(view) }
        name.setAccessibilityElement(false)
        note.setAccessibilityElement(false)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func refresh() {
        switch kind {
        case .space(let icon, let text, let muted):
            mark.isHidden = false
            symbol.isHidden = true
            note.isHidden = true
            mark.icon = icon
            name.text = text
            name.font = .systemFont(ofSize: 15, weight: .semibold)
            name.color = muted ? KitColor.muted : KitColor.ink
            toolTip = nil
            setAccessibilityElement(true)
            setAccessibilityRole(act == nil ? .staticText : .button)
            setAccessibilityLabel(text)
            setAccessibilityIdentifier("")
        case .privateWindow:
            mark.isHidden = true
            symbol.isHidden = false
            note.isHidden = false
            name.text = "Private"
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            name.color = KitColor.ink
            toolTip = "This window keeps no history, cookies, sign-ins or tabs once it closes"
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel("Private, Nothing is kept")
            setAccessibilityIdentifier("private-window-title")
        }
        mark.ink = ink
        symbol.ink = ink
        name.ink = ink
        note.ink = ink
        paint(curve: .none)
        needsLayout = true
    }

    static let iconMiddle: CGFloat = TabRowView.iconLead + SideLook.rowMark / 2
    static let wordsStart: CGFloat = TabRowView.iconLead + SideLook.rowMark + SideLook.markGap

    var chip: NSRect { ground.frame }

    func point(_ place: NSPoint?) {
        over = place.map { chip.contains($0) } ?? false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let moves { removeTrackingArea(moves) }
        let made = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(made)
        moves = made
        pointed()
    }

    private func pointed() {
        point(hovering ? window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } : nil)
    }

    override func hoverChanged() {
        pointed()
    }

    override func mouseMoved(with event: NSEvent) {
        point(convert(event.locationInWindow, from: nil))
    }

    private func paint(curve: KitCurve) {
        if curve.animates { ground.layer?.kitTransition(curve) }
        let lit = over && act != nil && kind != .privateWindow
        ground.ink = ink
        ground.fill = KitTone.ink.opacity(lit ? (pressed ? 0.15 : 0.09) : 0)
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let middle = Self.iconMiddle
        mark.frame = kitSnap(NSRect(x: middle - 10, y: (height - 15) / 2, width: 20, height: 15))
        let side = symbol.intrinsicContentSize
        symbol.frame = kitSnap(NSRect(x: middle - side.width / 2, y: (height - side.height) / 2, width: side.width, height: side.height))
        let noteSize = note.isHidden ? .zero : note.measure(width: bounds.width)
        note.frame = kitSnap(NSRect(x: bounds.width - 8 - noteSize.width, y: (height - noteSize.height) / 2,
                                    width: noteSize.width, height: noteSize.height))
        let x = Self.wordsStart
        let room = max(0, (note.isHidden ? bounds.width : note.frame.minX - 8) - x)
        let size = name.measure(width: room)
        name.frame = kitSnap(NSRect(x: x, y: (height - size.height) / 2, width: min(room, size.width), height: size.height))
        let tall = min(height, 28)
        ground.kitSetFrame(kitSnap(NSRect(x: 0, y: (height - tall) / 2, width: min(bounds.width, name.frame.maxX + 10), height: tall)))
        pointed()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard act != nil, !isHidden, let superview else { return nil }
        return chip.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        guard chip.contains(convert(event.locationInWindow, from: nil)) else { return }
        act?()
    }

    override func accessibilityPerformPress() -> Bool {
        act?()
        return act != nil
    }
}

final class SpaceTitlesView: NSView {
    let browser: Browser
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsLayout = true } } }
    private let lane = SpaceTitlesLane()
    private let ride: RideView
    private var popup: KitPopup?
    private var editing: AnyCancellable?

    init(browser: Browser) {
        self.browser = browser
        ride = RideView(content: lane, motion: browser.spaceMotion)
        super.init(frame: .zero)
        addSubview(ride)
        lane.titles = self
        editing = kitObserve(initial: false, { [browser] in browser.editingLook }) { [weak self] _ in self?.editLook() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        browser.spaceNeighbour.watch()
        let frame = NSRect(x: -Metrics.sideInset, y: 0, width: bounds.width + 2 * Metrics.sideInset, height: bounds.height)
        if ride.frame != frame { ride.frame = frame }
        lane.lay()
        ride.set(RideLook(here: browser.spaceAt))
        DispatchQueue.main.async { [weak self] in self?.editLook() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    fileprivate func line(for index: Int, here: Bool) -> SpaceTitleLineView.Kind {
        if browser.isPrivate { return .privateWindow }
        guard browser.spaces.indices.contains(index) else {
            let named = browser.spaceDraftName.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .space(browser.draftIcon, named.isEmpty ? "Untitled" : named, muted: named.isEmpty)
        }
        let space = here && browser.spaces[index].id == browser.spaceID ? browser.space : browser.spaces[index]
        return .space(space.shownIcon, space.name, muted: false)
    }

    fileprivate var hereView: SpaceTitleLineView { lane.here }

    private func editLook() {
        if browser.editingLook, popup == nil, window != nil {
            let editor = SpaceLookEditorView(browser: browser)
            editor.settle = { change in KitChange.eased(change) }
            editor.refresh()
            popup = KitPopup.show(editor, size: editor.size, from: hereView.bounds, of: hereView, edge: .page,
                                  focus: NSApp.isFullKeyboardAccessEnabled, bleeds: true) { [weak self] in
                guard let self, self.popup != nil else { return }
                self.popup = nil
                if self.browser.editingLook { self.browser.editingLook = false }
            }
            editor.resized = { [weak self] size in self?.popup?.resize(to: size) }
        } else if !browser.editingLook, let shown = popup {
            popup = nil
            shown.close()
        }
    }
}

final class SpaceTitlesLane: NSView {
    weak var titles: SpaceTitlesView?
    let here = SpaceTitleLineView()
    private var others: [Int: SpaceTitleLineView] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(here)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        lay()
    }

    func lay() {
        guard let titles else { return }
        let browser = titles.browser
        let at = browser.spaceAt
        let next = browser.spaceNext
        let seen = browser.spaceSeen
        let width = browser.prefs.columnWidth
        let inset = Metrics.sideInset
        let height = SpaceTitleSize.height
        here.kind = titles.line(for: at, here: true)
        here.ink = titles.ink
        here.act = browser.isPrivate ? nil : { [weak browser] in if let browser { SpaceMenu.show(for: browser) } }
        here.frame = NSRect(x: inset, y: 0, width: width - 2 * inset, height: height)
        here.setAccessibilityElement(seen == at)
        var kept = Set<Int>()
        for index in SpaceTitleSize.around(at, seen: seen, next: next, count: browser.spaces.count) {
            let view = others[index] ?? {
                let made = SpaceTitleLineView()
                others[index] = made
                addSubview(made)
                return made
            }()
            view.kind = titles.line(for: index, here: false)
            view.ink = titles.ink
            view.act = nil
            view.isHidden = SpaceLane.covered(index, real: at, seen: seen, next: next)
            view.setAccessibilityElement(index == next || index == seen)
            let x = SpaceLane.place(index, real: at, seen: seen, next: next) * width
            view.setLane(NSRect(x: inset, y: 0, width: width - 2 * inset, height: height), shift: x)
            kept.insert(index)
        }
        for (index, view) in others where !kept.contains(index) {
            view.removeFromSuperview()
            others[index] = nil
        }
    }
}
