import AppKit
import Observation
import Combine
import Symbols

@MainActor
@Observable
final class TabSwitcher {
    enum Direction { case left, right, up, down }

    enum Action {
        case close
        case reload
        case mute

        init?(_ event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .control else { return nil }
            switch event.shortcutCharacters {
            case "w": self = .close
            case "r": self = .reload
            case "m": self = .mute
            default: return nil
            }
        }
    }

    @ObservationIgnored private var recentIDs: [Tab.ID] = []
    private(set) var candidates: [Tab.ID] = []
    private(set) var selectedID: Tab.ID?
    private(set) var visible = false
    private var previews: [Tab.ID: (address: URL, image: NSImage)] = [:]

    @ObservationIgnored var partners: [Tab.ID: Tab.ID] = [:]

    @ObservationIgnored var panelFrame: CGRect = .zero
    @ObservationIgnored var cardFrames: [Tab.ID: CGRect] = [:]
    @ObservationIgnored private var rest: CGPoint?
    @ObservationIgnored private var moved = false

    func hover(at point: CGPoint) {
        guard visible else { return }
        if !moved {
            guard let rest else { return self.rest = point }
            guard abs(point.x - rest.x) + abs(point.y - rest.y) > 2 else { return }
            moved = true
        }
        if let id = card(at: point), id != selectedID { selectedID = id }
    }

    func card(at point: CGPoint) -> Tab.ID? {
        cardFrames.first { $0.value.contains(point) && candidates.contains($0.key) }?.key
    }

    func click(at point: CGPoint, pick: (Tab.ID) -> Void) -> Bool {
        guard visible else { return false }
        guard panelFrame.contains(point) else {
            cancel()
            return true
        }
        if let id = card(at: point) { pick(id) }
        return true
    }

    @ObservationIgnored private(set) var home: Tab.ID?

    @ObservationIgnored private var previewRequests: [Tab.ID: UUID] = [:]
    @ObservationIgnored private var reveal: DispatchWorkItem?
    @ObservationIgnored private var previewRequested = false
    @ObservationIgnored private var generation = UUID()
    var active: Bool { home != nil }

    func lastLeft(among row: Set<Tab.ID>, other id: Tab.ID) -> Tab.ID? {
        recentIDs.first { $0 != id && row.contains($0) }
    }

    func left(_ tab: Tab, alive: Set<Tab.ID>) {
        recentIDs = [tab.id] + recentIDs.filter { $0 != tab.id && alive.contains($0) }
        prune { kept($0) }
        if tab.isWeb { requestPreview(of: tab, gesture: nil) }
    }

    func step(row: [Tab.ID], current: Tab.ID, backwards: Bool) {
        guard active else {
            guard row.contains(current) else { return }
            begin(home: current, planet: ordered(row: row, current: current), backwards: backwards)
            return
        }
        walk(backwards: backwards)
    }

    func ordered(row: [Tab.ID], current: Tab.ID?) -> [Tab.ID] {
        let valid = Set(row)
        var seen: Set<Tab.ID> = []
        return Array(([current].compactMap { $0 } + recentIDs + row)
            .filter { valid.contains($0) && seen.insert($0).inserted }
            .prefix(10))
    }

    private func begin(home: Tab.ID, planet: [Tab.ID], backwards: Bool) {
        candidates = planet
        guard candidates.count > 1, candidates.first == home else {
            candidates = []
            return
        }
        self.home = home
        selectedID = backwards ? candidates.last : candidates[1]
        let work = DispatchWorkItem { [weak self] in self?.show() }
        reveal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func walk(backwards: Bool) {
        guard let selectedID, let index = candidates.firstIndex(of: selectedID) else { return }
        let next = (index + (backwards ? -1 : 1) + candidates.count) % candidates.count
        self.selectedID = candidates[next]
        show()
    }

    func move(_ direction: Direction) {
        guard let selectedID, let index = candidates.firstIndex(of: selectedID) else { return }
        show()
        switch direction {
        case .left: self.selectedID = candidates[(index - 1 + candidates.count) % candidates.count]
        case .right: self.selectedID = candidates[(index + 1) % candidates.count]
        case .up:
            guard index >= 5 else { return }
            self.selectedID = candidates[index - 5]
        case .down:
            guard index < 5, candidates.count > 5 else { return }
            self.selectedID = candidates[min(index + 5, candidates.count - 1)]
        }
    }

    func remove(_ id: Tab.ID) {
        guard active else { return }
        guard id != home else { return cancel() }
        let before = candidates
        guard let index = before.firstIndex(of: id) else { return }
        candidates.removeAll { $0 == id }
        cardFrames[id] = nil
        guard candidates.count > 1 else { return cancel() }
        if selectedID == id { selectedID = before[(index + 1) % before.count] }
    }

    private(set) var revision = 0

    func redraw() { revision &+= 1 }

    func finish(picking id: Tab.ID? = nil) -> Tab.ID? {
        let target = id ?? selectedID
        let valid = target.flatMap { candidates.contains($0) ? $0 : nil }
        cancel()
        return valid
    }

    func cancel() {
        guard active || reveal != nil || visible else { return }
        reveal?.cancel()
        reveal = nil
        generation = UUID()
        candidates = []
        home = nil
        selectedID = nil
        visible = false
        panelFrame = .zero
        cardFrames = [:]
        rest = nil
        moved = false
        prune { kept($0) }
        previewRequested = false
    }

    private func kept(_ id: Tab.ID) -> Bool {
        recentIDs.prefix(10).contains(id)
    }

    func reset() {
        cancel()
        recentIDs = []
        previewRequests = [:]
        if !previews.isEmpty { previews = [:] }
    }

    private func prune(to keep: (Tab.ID) -> Bool) {
        previewRequests = previewRequests.filter { keep($0.key) }
        if previews.keys.contains(where: { !keep($0) }) { previews = previews.filter { keep($0.key) } }
    }

    func preview(for id: Tab.ID, address: URL?) -> NSImage? {
        guard let cached = previews[id], cached.address == address else { return nil }
        return cached.image
    }

    func cachePreview(_ image: NSImage, for id: Tab.ID, address: URL) {
        let shown = candidates.contains(id) || candidates.contains { partners[$0] == id }
        guard kept(id) || (visible && shown) else { return }
        previews[id] = (address, image)
    }

    func capturePreviews(of tab: (Tab.ID) -> Tab?, current: Tab.ID?) {
        guard visible, !previewRequested else { return }
        previewRequested = true
        let token = generation
        let firsts = [selectedID].compactMap { $0 } + candidates.filter { $0 != selectedID }
        let orderedIDs = firsts.flatMap { id in [id] + [partners[id]].compactMap { $0 } }
        let ordered = orderedIDs.compactMap(tab)
            .filter { $0.id == current || preview(for: $0.id, address: $0.address) == nil }
        for (index, tab) in ordered.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.04) { [weak self, weak tab] in
                guard let self, let tab, self.generation == token, self.visible else { return }
                guard tab.id == current || self.preview(for: tab.id, address: tab.address) == nil else { return }
                self.requestPreview(of: tab, gesture: token)
            }
        }
    }

    private func requestPreview(of tab: Tab, gesture: UUID?) {
        guard let address = tab.address else { return }
        let id = tab.id
        let request = UUID()
        previewRequests[id] = request
        tab.preview(width: 180) { [weak self, weak tab] image in
            guard let self, self.previewRequests[id] == request else { return }
            self.previewRequests[id] = nil
            guard let tab, let image, tab.address == address,
                  gesture == nil || (self.generation == gesture && self.visible)
            else { return }
            self.cachePreview(image, for: id, address: address)
        }
    }

    private func show() {
        guard active, !visible else { return }
        reveal?.cancel()
        reveal = nil
        let seconds = Set(candidates.compactMap { partners[$0] })
        previews = previews.filter { key, _ in candidates.contains(key) || seconds.contains(key) }
        visible = true
    }
}

@MainActor
final class TabSwitcherView: NSView {
    let browser: Browser

    private var switcher: TabSwitcher { browser.tabSwitcher }
    private let scrim = KitBox(fill: NSColor(white: 0, alpha: KitColor.dim))
    private let panel = SwitcherPanel()
    private let ring = KitBox(fill: Palette.NS.pickedPlate, corners: .radius(SwitcherGeometry.ringRadius))
    private let legend = SwitcherLegend()
    private var cards: [Tab.ID: SwitcherCard] = [:]
    private var watching: AnyCancellable?
    private var ringFor: Tab.ID?
    private var shown = false
    private var capture: DispatchWorkItem?
    private var captureFor: Tab.ID??
    var stage: CGRect? { didSet { if stage != oldValue, switcher.visible { needsLayout = true } } }

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: NSRect(x: 0, y: 0, width: 1180, height: 780))
        wantsLayer = true
        panel.fill = Palette.NS.ground
        panel.stroke = KitColor.hairline
        panel.corners = .radius(12)
        panel.passesClicks = false
        panel.moved = { [weak self] event in self?.hovered(event) }
        addSubview(scrim)
        addSubview(panel)
        panel.addSubview(ring)
        panel.addSubview(legend)
        isHidden = true
        let switcher = switcher
        watching = kitObserve(initial: false, { [weak switcher] in
            (switcher?.visible, switcher?.selectedID, switcher?.candidates, switcher?.revision)
        }) { [weak self] _ in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard switcher.visible, !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard panel.frame.contains(local) else { return nil }
        return super.hitTest(point)
    }

    private func refresh() {
        let visible = switcher.visible
        if isHidden == visible { isHidden = !visible }
        schedulePreviews(visible: visible)
        if visible {
            needsLayout = true
            layoutSubtreeIfNeeded()
        } else {
            shown = false
            ringFor = nil
        }
    }

    private func tab(_ id: Tab.ID) -> Tab? {
        browser.switcherTab(id)
    }

    private func schedulePreviews(visible: Bool) {
        guard visible else {
            capture?.cancel()
            capture = nil
            captureFor = nil
            return
        }
        let selected = switcher.selectedID
        if let captureFor, captureFor == selected { return }
        captureFor = .some(selected)
        capture?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, switcher.visible else { return }
            switcher.capturePreviews(of: { [browser] id in browser.switcherTab(id) }, current: browser.activeID)
        }
        capture = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func pixel(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return ceil(value * scale - 0.001) / scale
    }

    override func layout() {
        super.layout()
        scrim.frame = bounds
        guard switcher.visible else { return }
        _ = switcher.revision
        let ids = switcher.candidates
        let count = ids.count
        guard count > 0 else { return }
        let prefs = browser.prefs
        let area = SwitcherGeometry.area(bounds: bounds, top: safeAreaInsets.top, stage: stage)
        let columns = min(5, count)
        let width = SwitcherGeometry.cardWidth(area: area.width, columns: columns)
        let previewHeight = SwitcherGeometry.previewHeight(cardWidth: width)
        let cardHeight = SwitcherGeometry.cardHeight(cardWidth: width)
        let rows = (count + 4) / 5

        let gone = Set(cards.keys).subtracting(ids)
        for id in gone {
            cards[id]?.removeFromSuperview()
            cards[id] = nil
        }

        var frames: [Tab.ID: CGRect] = [:]
        var placed: [Tab.ID: NSRect] = [:]
        var widest: CGFloat = 0
        for row in 0..<rows {
            var x: CGFloat = 12
            let y = 12 + CGFloat(row) * (cardHeight + 8)
            for id in ids.dropFirst(row * 5).prefix(5) {
                guard let tab = tab(id) else {
                    cards[id]?.removeFromSuperview()
                    cards[id] = nil
                    continue
                }
                let card = cards[id] ?? {
                    let made = SwitcherCard()
                    made.pick = { [weak self] id in self?.browser.commitTabSwitch(picking: id) }
                    panel.addSubview(made)
                    cards[id] = made
                    return made
                }()
                let partner = switcher.partners[id].flatMap(self.tab)
                card.show(tab: tab, partner: partner, space: browser.switcherSpace(of: id), switcher: switcher, prefs: prefs,
                          selected: id == switcher.selectedID, animated: shown)
                let frame = NSRect(x: x, y: y, width: width, height: cardHeight)
                placed[id] = frame
                x += width + 8
            }
            widest = max(widest, x - 8 - 12)
        }

        let keys = prefs.switcherKeys
        legend.isHidden = !keys
        var height = 12 + CGFloat(rows) * cardHeight + CGFloat(rows - 1) * 8
        var legendSize = NSSize.zero
        if keys {
            legendSize = legend.fitting(pixel: pixel)
            widest = max(widest, legendSize.width)
            height += 8 + 2
            legend.frame = panel.kitSnap(NSRect(x: 12, y: height, width: legendSize.width, height: legendSize.height))
            height += legendSize.height
        }
        height += 12
        let panelSize = NSSize(width: widest + 24, height: height)
        let panelFrame = kitSnap(NSRect(x: area.minX + (area.width - panelSize.width) / 2,
                                        y: area.minY + (area.height - panelSize.height) / 2,
                                        width: panelSize.width, height: panelSize.height))
        panel.frame = panelFrame
        for (id, frame) in placed {
            guard let card = cards[id] else { continue }
            card.frame = panel.kitSnap(frame)
            card.place(width: width, previewHeight: previewHeight, pixel: pixel)
            frames[id] = windowRect(card.frame.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY))
        }

        placeRing(width: width, cardHeight: cardHeight)
        switcher.panelFrame = windowRect(panelFrame)
        switcher.cardFrames = frames
        shown = true
    }

    private func placeRing(width: CGFloat, cardHeight: CGFloat) {
        guard let selected = switcher.selectedID, let index = switcher.candidates.firstIndex(of: selected) else {
            ring.isHidden = true
            ringFor = nil
            return
        }
        let target = panel.kitSnap(NSRect(x: 12 + CGFloat(index % 5) * (width + 8), y: 12 + CGFloat(index / 5) * (cardHeight + 8),
                                          width: width, height: cardHeight))
        let moving = shown && !ring.isHidden && ringFor != nil && ringFor != selected
        ring.isHidden = false
        ringFor = selected
        guard moving, let layer = ring.layer, Motion.kitGlide.animates else {
            ring.layer?.removeAnimation(forKey: "glide.position")
            ring.layer?.removeAnimation(forKey: "glide.bounds")
            if ring.frame != target { ring.frame = target }
            return
        }
        let fromPosition = (layer.animation(forKey: "glide.position") != nil ? layer.presentation()?.position : nil) ?? layer.position
        let fromBounds = (layer.animation(forKey: "glide.bounds") != nil ? layer.presentation()?.bounds : nil) ?? layer.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = target
        CATransaction.commit()
        let curve = Motion.kitGlide
        if let animation = curve.animation("position", from: NSValue(point: fromPosition), to: NSValue(point: layer.position)) {
            layer.add(animation, forKey: "glide.position")
        }
        if let animation = curve.animation("bounds", from: NSValue(rect: fromBounds), to: NSValue(rect: layer.bounds)) {
            layer.add(animation, forKey: "glide.bounds")
        }
    }

    private func windowRect(_ rect: NSRect) -> CGRect {
        guard let window, let content = window.contentView else { return rect }
        let inWindow = convert(rect, to: nil)
        return CGRect(x: inWindow.minX, y: content.bounds.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    private func hovered(_ event: NSEvent) {
        guard let window, event.window === window, let content = window.contentView else { return }
        let at = event.locationInWindow
        switcher.hover(at: CGPoint(x: at.x, y: content.bounds.height - at.y))
    }
}

@MainActor
private final class SwitcherPanel: KitBox {
    var moved: ((NSEvent) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let made = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(made)
        area = made
    }

    override func mouseEntered(with event: NSEvent) { moved?(event) }
    override func mouseMoved(with event: NSEvent) { moved?(event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class SwitcherLegend: NSView {
    private static let keys = [("W", "Close"), ("R", "Reload"), ("M", "Mute")]
    private var labels: [(key: KitLabel, name: KitLabel)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (key, name) in Self.keys {
            let keyLabel = KitLabel("⌃" + key, font: .systemFont(ofSize: SwitcherGeometry.legend, weight: .medium), color: KitColor.ink)
            let nameLabel = KitLabel(name, font: .systemFont(ofSize: SwitcherGeometry.legend), color: KitColor.muted)
            for label in [keyLabel, nameLabel] {
                label.setAccessibilityElement(false)
                addSubview(label)
            }
            labels.append((keyLabel, nameLabel))
        }
        let spoken = Self.keys.flatMap { ["⌃" + $0.0, $0.1] }.joined(separator: ", ")
        kitAccess(label: spoken, role: .staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func fitting(pixel: (CGFloat) -> CGFloat) -> NSSize {
        var x: CGFloat = 0
        var height: CGFloat = 0
        for (index, pair) in labels.enumerated() {
            if index > 0 { x += 14 }
            for (step, label) in [pair.key, pair.name].enumerated() {
                if step > 0 { x += 4 }
                let size = label.measure(width: .greatestFiniteMagnitude)
                let width = pixel(size.width)
                let tall = pixel(size.height)
                height = max(height, tall)
                label.frame = NSRect(x: x, y: 0, width: width, height: tall)
                x += width
            }
        }
        for pair in labels {
            for label in [pair.key, pair.name] {
                label.frame = kitSnap(NSRect(x: label.frame.minX, y: (height - label.frame.height) / 2,
                                             width: label.frame.width, height: label.frame.height))
            }
        }
        return NSSize(width: x, height: height)
    }
}

@MainActor
private final class SwitcherPicture: KitBox {
    private let photo = CALayer()
    private let mark = KitMark(icon: nil, letter: "", side: 26)
    private var image: NSImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill = Palette.NS.hover
        layer?.masksToBounds = true
        photo.contentsGravity = .resizeAspectFill
        photo.masksToBounds = true
        photo.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(photo)
        addSubview(mark)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(image: NSImage?, icon: NSImage?, letter: String) {
        if self.image !== image {
            self.image = image
            photo.contents = image.map { $0.layerContents(forContentsScale: window?.backingScaleFactor ?? 2) }
        }
        photo.isHidden = image == nil
        mark.isHidden = image != nil
        mark.icon = icon
        mark.letter = letter
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.frame = bounds
        photo.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        mark.frame = kitSnap(NSRect(x: (bounds.width - 26) / 2, y: (bounds.height - 26) / 2, width: 26, height: 26))
    }
}

@MainActor
private final class SwitcherCard: NSView {
    var pick: ((Tab.ID) -> Void)?

    private var id: Tab.ID?
    private let pictures = KitBox(fill: nil, stroke: Palette.NS.pictureEdge, corners: .radius(SwitcherGeometry.pictureRadius))
    private let first = SwitcherPicture()
    private let second = SwitcherPicture()
    private let mark = KitMark(icon: nil, letter: "", side: 13)
    private let spaceMark = SpaceMarkView(icon: TabIcon(symbol: "house"), size: 11)
    private let caption = KitLabel("", font: .systemFont(ofSize: SwitcherGeometry.caption), color: KitColor.ink)
    private let muted = KitSymbol("speaker.slash.fill", style: .init(size: 9.5), tint: KitColor.muted, label: "Muted")
    private var paired = false
    private var showsMark = false
    private var showsSpace = false
    private var isMuted = false
    private var pressed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        pictures.layer?.masksToBounds = true
        pictures.addSubview(first)
        pictures.addSubview(second)
        addSubview(pictures)
        addSubview(mark)
        spaceMark.tint = KitColor.muted
        addSubview(spaceMark)
        addSubview(caption)
        addSubview(muted)
        caption.setAccessibilityElement(false)
        muted.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    func show(tab: Tab, partner: Tab?, space: Space?, switcher: TabSwitcher, prefs: Preferences, selected: Bool, animated: Bool) {
        let same = id == tab.id
        id = tab.id
        paired = partner != nil
        func picture(_ view: SwitcherPicture, _ page: Tab) {
            view.show(image: switcher.preview(for: page.id, address: page.address),
                      icon: page.icon, letter: page.monogram)
        }
        picture(first, tab)
        if let partner { picture(second, partner) }
        second.isHidden = partner == nil
        showsMark = !tab.isBlank
        mark.isHidden = !showsMark
        if showsMark {
            mark.icon = tab.icon
            mark.letter = tab.monogram
        }
        showsSpace = space != nil
        spaceMark.isHidden = !showsSpace
        if let space { spaceMark.icon = space.shownIcon }
        caption.text = partner.map { tab.label + " · " + $0.label } ?? tab.label
        let nowMuted = tab.muted || partner?.muted == true
        if nowMuted != isMuted || !same {
            let wasMuted = isMuted
            isMuted = nowMuted
            if same, animated, !Motion.reduced {
                if nowMuted {
                    muted.isHidden = false
                    muted.addSymbolEffect(.disappear, options: .nonRepeating, animated: false)
                    muted.addSymbolEffect(.appear, options: .nonRepeating, animated: true)
                } else if wasMuted {
                    muted.addSymbolEffect(.disappear, options: .nonRepeating, animated: true)
                }
            } else {
                muted.removeAllSymbolEffects(animated: false)
                muted.isHidden = !nowMuted
            }
        }
        setAccessibilityLabel(space.map { "Switch to \(tab.label), in \($0.name)" } ?? "Switch to \(tab.label)")
        setAccessibilityValue(selected ? "Selected" : "")
        needsLayout = true
    }

    func place(width: CGFloat, previewHeight: CGFloat, pixel: (CGFloat) -> CGFloat) {
        let inset = SwitcherGeometry.inset
        let inner = width - inset * 2
        pictures.frame = kitSnap(NSRect(x: inset, y: inset, width: inner, height: previewHeight))
        if paired {
            let side = (inner - 2) / 2
            first.frame = pictures.kitSnap(NSRect(x: 0, y: 0, width: side, height: previewHeight))
            second.frame = pictures.kitSnap(NSRect(x: side + 2, y: 0, width: side, height: previewHeight))
        } else {
            first.frame = NSRect(x: 0, y: 0, width: inner, height: previewHeight)
        }
        let natural = caption.measure(width: .greatestFiniteMagnitude)
        let textHeight = pixel(natural.height)
        let symbol = muted.intrinsicContentSize
        var rowHeight = textHeight
        if showsMark { rowHeight = max(rowHeight, 13) }
        let spaceSize = spaceMark.intrinsicContentSize
        if showsSpace { rowHeight = max(rowHeight, spaceSize.height) }
        if isMuted { rowHeight = max(rowHeight, symbol.height) }
        let top = inset + previewHeight + 7
        var x: CGFloat = inset
        if showsMark {
            mark.frame = kitSnap(NSRect(x: x, y: top + (rowHeight - 13) / 2, width: 13, height: 13))
            x += 13 + 6
        }
        if showsSpace {
            spaceMark.frame = kitSnap(NSRect(x: x, y: top + (rowHeight - spaceSize.height) / 2,
                                             width: spaceSize.width, height: spaceSize.height))
            x += spaceSize.width + 4
        }
        let room = inset + inner - x - (isMuted ? 6 + symbol.width : 0)
        let textWidth = max(0, min(pixel(natural.width), room))
        caption.frame = kitSnap(NSRect(x: x, y: top + (rowHeight - textHeight) / 2, width: textWidth, height: textHeight))
        x += textWidth + 6
        muted.frame = kitSnap(NSRect(x: x, y: top + (rowHeight - symbol.height) / 2, width: symbol.width, height: symbol.height))
    }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if let id, bounds.contains(convert(event.locationInWindow, from: nil)) { pick?(id) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let id else { return false }
        pick?(id)
        return true
    }
}

enum SwitcherGeometry {
    static let inset: CGFloat = 6
    static let pictureRadius: CGFloat = 5
    static let ringRadius: CGFloat = pictureRadius + inset
    static let legend: CGFloat = 11
    static let caption: CGFloat = 12

    static func area(bounds: CGRect, top: CGFloat, stage: CGRect?) -> CGRect {
        let whole = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        guard let stage, stage.width > 0, stage.height > 0 else { return whole }
        let inside = stage.intersection(whole)
        return inside.isNull || inside.isEmpty ? whole : inside
    }

    static func cardWidth(area: CGFloat, columns: Int) -> CGFloat {
        min(176, (area - 64 - CGFloat(columns - 1) * 8) / CGFloat(columns))
    }

    static func previewHeight(cardWidth: CGFloat) -> CGFloat {
        (cardWidth - inset * 2) * 0.62
    }

    static func cardHeight(cardWidth: CGFloat) -> CGFloat {
        previewHeight(cardWidth: cardWidth) + inset + 7 + 16 + 9
    }
}
