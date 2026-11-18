import AppKit
import Observation
import Combine

@MainActor
@Observable
final class StackedFolds {
    static let shared = StackedFolds()
    static let key = "spaces.stacked.folded"

    private(set) var folded: Set<UUID>

    init() {
        folded = Set((Store.settings.stringArray(forKey: StackedFolds.key) ?? []).compactMap(UUID.init))
    }

    func isFolded(_ id: UUID) -> Bool { folded.contains(id) }

    func set(_ id: UUID, folded on: Bool) {
        guard folded.contains(id) != on else { return }
        if on { folded.insert(id) } else { folded.remove(id) }
        Store.settings.set(folded.map(\.uuidString).sorted(), forKey: StackedFolds.key)
    }

    func toggle(_ id: UUID) { set(id, folded: !isFolded(id)) }

    func forget(_ id: UUID) { set(id, folded: false) }

    func reload() {
        let saved = Set((Store.settings.stringArray(forKey: StackedFolds.key) ?? []).compactMap(UUID.init))
        if saved != folded { folded = saved }
    }
}

enum StackedSpaces {
    static let gap: CGFloat = 12
    static let headerHeight: CGFloat = 30
    static let headerPad: CGFloat = 2
    static let bodyTop: CGFloat = 2
    static let heldRamp: CGFloat = 8
    static let viewport = "stackedViewport"

    static func shared<T>(_ pins: [T], id: (T) -> UUID?, shared ids: Set<UUID>) -> [T] {
        pins.filter { pin in id(pin).map(ids.contains) ?? false }
    }

    static func own<T>(_ pins: [T], id: (T) -> UUID?, shared ids: Set<UUID>) -> [T] {
        pins.filter { pin in !(id(pin).map(ids.contains) ?? false) }
    }

    static func count(_ tabs: Int) -> String {
        tabs == 1 ? "1 tab" : "\(tabs) tabs"
    }

    static func section(at point: CGPoint, heads: [UUID: CGRect], bodies: [UUID: CGRect], except: UUID?) -> UUID? {
        if let head = heads.first(where: { $0.key != except && $0.value.contains(point) }) { return head.key }
        if heads.contains(where: { $0.key == except && $0.value.contains(point) }) { return nil }
        return bodies.first { $0.key != except && $0.value.contains(point) }?.key
    }

    static func shownTabs(total: Int, folded: Bool, active: Bool) -> Int {
        guard folded else { return total }
        return active && total > 0 ? 1 : 0
    }

    static let edge: CGFloat = 36
    static let fastest: CGFloat = 14

    static func edgeSpeed(y: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 2 * edge else { return 0 }
        if y < edge { return -fastest * min(1, (edge - y) / edge) }
        if y > height - edge { return fastest * min(1, (y - (height - edge)) / edge) }
        return 0
    }
}

struct StackedReorder: Equatable {
    let space: UUID
    let ids: [UUID]
    let from: Int
    let step: CGFloat
    private(set) var travel: CGFloat = 0
    private(set) var index: Int

    init?(space: UUID, ids: [UUID], step: CGFloat) {
        guard let from = ids.firstIndex(of: space), step > 0 else { return nil }
        self.space = space
        self.ids = ids
        self.from = from
        self.step = step
        index = from
    }

    @discardableResult
    mutating func carry(_ travel: CGFloat) -> Bool {
        self.travel = travel
        let now = min(max(0, from + Int((travel / step).rounded())), ids.count - 1)
        guard now != index else { return false }
        index = now
        return true
    }

    var order: [UUID] { Spaces.moved(ids, from: from, to: index) }
    var shift: CGFloat { travel - CGFloat(index - from) * step }
    var moved: Bool { index != from }
}

@MainActor
@Observable
final class StackedLift {
    private(set) var carrying: UUID?
    private(set) var order: [UUID]?
    private(set) var shift: CGFloat = 0
    private(set) var lead: CGFloat = 0
    private(set) var tail: CGFloat = 0

    @ObservationIgnored private(set) var reorder: StackedReorder?
    @ObservationIgnored var scrolled: CGFloat = 0
    @ObservationIgnored var viewport: CGFloat = 0
    @ObservationIgnored var content: CGFloat = 0
    @ObservationIgnored var scroll: ((CGFloat) -> Void)?
    @ObservationIgnored var commit: ((UUID, Int) -> Void)?
    @ObservationIgnored private(set) var cancelled = false
    @ObservationIgnored var scripted = false
    @ObservationIgnored private(set) var start: CGFloat = 0
    @ObservationIgnored private var hand: CGFloat = 0
    @ObservationIgnored private var gain: CGFloat = 0
    @ObservationIgnored private var keys: Any?
    @ObservationIgnored private var ticker: Timer?

    func begin(_ space: UUID, ids: [UUID], at y: CGFloat, top: CGFloat, step: CGFloat) {
        guard carrying == nil, !cancelled, let made = StackedReorder(space: space, ids: ids, step: step) else { return }
        reorder = made
        start = y
        hand = y
        gain = 0
        let lead = max(0, top - CGFloat(made.from) * step)
        let tail = max(0, scrolled + viewport - lead - CGFloat(ids.count) * step)
        KitChange.eased {
            carrying = space
            order = made.order
            self.lead = lead
            self.tail = tail
            shift = 0
        }
        watchKeys()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func move(to y: CGFloat) {
        guard carrying != nil else { return }
        hand = y
        follow()
        let speed = StackedSpaces.edgeSpeed(y: y, height: viewport)
        if speed == 0 { stopTicker() } else { startTicker() }
    }

    func end() {
        defer { cancelled = false }
        guard let reorder, carrying != nil else { return }
        let moved = reorder.moved
        KitChange.still {
            if moved { commit?(reorder.space, reorder.index) }
            order = nil
        }
        settle()
    }

    func cancel() {
        guard carrying != nil else { return }
        cancelled = true
        KitChange.eased { order = nil }
        settle()
    }

    private func settle() {
        stopTicker()
        unwatchKeys()
        reorder = nil
        KitChange.eased {
            carrying = nil
            shift = 0
            lead = 0
            tail = 0
        }
    }

    private func follow() {
        guard var reorder else { return }
        let changed = reorder.carry(hand - start + gain)
        self.reorder = reorder
        KitChange.still { shift = reorder.shift }
        if changed { KitChange.eased { order = reorder.order } }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        let speed = StackedSpaces.edgeSpeed(y: hand, height: viewport)
        let limit = max(0, content - viewport)
        let next = min(max(0, scrolled + speed), limit)
        guard speed != 0, next != scrolled else { return stopTicker() }
        gain += next - scrolled
        scrolled = next
        scroll?(next)
        follow()
    }

    private func watchKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.carrying != nil,
                  self.scripted || NSEvent.pressedMouseButtons & 1 != 0 else { return event }
            self.cancel()
            return nil
        }
    }

    private func unwatchKeys() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }
}

@MainActor
extension Browser {
    var stacked: Bool { prefs.stacksSpaces && !isPrivate }

    func stackedRow(_ id: UUID) -> Parked {
        if id == spaceID { return Parked(tabs: tabs, active: activeID, splits: splits, groups: tabGroups) }
        if let kept = parked[id] { return kept }
        let row = loadRow(id)
        parked[id] = row
        return row
    }

    func loadStackedRows() {
        for space in spaces where space.id != spaceID && parked[space.id] == nil {
            parked[space.id] = loadRow(space.id)
        }
    }

    var stageNext: Int? { SpaceLane.stage(spaceNext, stacked: stacked) }
    var stageSliding: Bool { !stacked && spaceSliding }

    func stackedEnter(_ id: UUID, announcing: Bool = true, arriving: () -> Void = {}) {
        guard id != spaceID, let to = spaces.firstIndex(where: { $0.id == id }) else { return }
        let from = spaces.firstIndex { $0.id == spaceID }
        KitChange.still { switchSpace(to: id) }
        guard spaceID == id else { return }
        arriving()
        if !Motion.reduced, let from, from != to { fadeGround(from: from) }
        if announcing, !(folded && !peeking) { announce(space.name) }
    }

    func stackedSelect(_ tab: Tab, in id: UUID) {
        let arriving = id != spaceID
        let front = arriving ? parked[id]?.active : nil
        if arriving {
            if parked[id]?.tabs.contains(where: { $0.id == tab.id }) == true { parked[id]?.active = tab.id }
            stackedEnter(id, announcing: false)
        }
        guard spaceID == id, let live = tabs.first(where: { $0.id == tab.id }) else { return }
        let landed = arriving && activeID == live.id
        select(live, floatPrevious: !landed, arrived: landed)
        if let front, front != live.id { noteLeft(front, words: "") }
    }

    func stackedJump(to id: UUID) {
        StackedFolds.shared.set(id, folded: false)
        stackedEnter(id)
        stackedScroll = StackedScroll(space: id, count: stackedScroll.count + 1)
    }

    func stackedNewTab(in id: UUID) {
        guard id != spaceID else { return launch() }
        stackedEnter(id, announcing: false) { launch() }
    }

    private func fadeGround(from: Int) {
        let width = max(1, prefs.columnWidth)
        spaceMotion.window = window
        spaceNext = from
        spaceMotion.follow(width, width: width)
        spaceMotion.carry(to: 0, width: width) { [weak self] in
            guard let self else { return }
            KitChange.still {
                if self.spaceNext == from { self.spaceNext = nil }
                self.spaceMotion.rest()
            }
        }
    }
}

struct StackedScroll: Equatable {
    var space: UUID?
    var count = 0
}

@MainActor
@Observable
final class StackedCuts {
    var heads: [UUID: CGFloat] = [:]
    var bodies: [UUID: CGFloat] = [:]
    var held: CGFloat?

    func top(_ space: UUID) -> CGFloat {
        guard let head = heads[space], let body = bodies[space] else { return 0 }
        return max(0, head - body)
    }

    func bottom(_ space: UUID) -> CGFloat {
        guard let held, let body = bodies[space] else { return .infinity }
        return held - body
    }

    func note(held top: CGFloat?) {
        if held != top { held = top }
    }

    func note(head space: UUID, bottom: CGFloat?) {
        if heads[space] != bottom { heads[space] = bottom }
    }

    func note(body space: UUID, top: CGFloat?) {
        if bodies[space] != top { bodies[space] = top }
    }
}

@MainActor
enum StackedProbe {
    static var headers: [UUID: CGRect] = [:]
    static var rows: [UUID: [Tab.ID]] = [:]
    static var scrolled: CGFloat = 0
    static var lit: UUID?
    static var gathered: Set<UUID> = []
    static weak var lift: StackedLift?
    static var begin: ((UUID) -> Void)?
    static var scroll: ((CGFloat) -> Void)?
    static var run: ((CGFloat, CGFloat, CGFloat) -> Void)?
    static var wheel: ((Double, Int, Double, Int, CGFloat) -> Void)?
    static var inner: (() -> [UUID: CGFloat])?
    static var content: CGFloat = 0
    static var viewport: CGFloat = 0
    static var trace: [[String: Any]] = []
    static var tracing = false
    static var hit = ""
    static var travel: [UUID: CGRect?] = [:]
    static var open: [UUID: CGFloat] = [:]
    static var bodies: [UUID: CGRect] = [:]
    static var route = "direct"
}

@MainActor
extension Browser {
    func stackedDrop(_ tab: Tab, onto id: UUID) {
        guard id != spaceID, tabs.contains(where: { $0.id == tab.id }) else { return }
        if let pair = split(for: tab) {
            KitChange.eased { move(pair: pair, toSpace: id) }
            return
        }
        KitChange.eased { move(tab, toSpace: id) }
    }

    func move(pair: TabSplit, toSpace id: UUID) {
        guard showsSpaces, id != spaceID, let destination = spaces.first(where: { $0.id == id }) else { return }
        let halves = pair.tabs.compactMap { half in tabs.first { $0.id == half } }
        guard halves.count == pair.tabs.count,
              halves.allSatisfy({ !$0.bench && $0.address.flatMap({ Browser.extensionHost(of: $0) }) == nil })
        else { return }
        let from = spaceID
        let complete: () -> Void = { [weak self] in
            guard let self, self.spaceID == from, self.splits.contains(where: { $0.id == pair.id }),
                  halves.allSatisfy({ half in self.tabs.contains { $0 === half } })
            else { return }
            self.finishPairMove(pair, halves, to: destination)
        }
        let store = Spaces.store(for: id)
        let asking = halves.filter { !$0.shy && $0.store !== store }
        guard !asking.isEmpty else { return complete() }
        var unsaved = false
        let asked = DispatchGroup()
        for half in asking {
            asked.enter()
            half.unsaved { if $0 { unsaved = true }; asked.leave() }
        }
        asked.notify(queue: .main) {
            guard unsaved else { return complete() }
            Ask.sure(
                "Move tabs?",
                detail: "A page in this Split View has unsaved form entries. Both pages will reopen in “\(destination.name)” with that space's accounts, so the entries may be lost.",
                confirm: "Move",
                then: {
                    for half in halves { half.leaveSettled = true }
                    complete()
                }
            )
        }
    }

    private func finishPairMove(_ pair: TabSplit, _ halves: [Tab], to destination: Space) {
        let mark = beginStep("Move to Space", carrying: halves.map(\.id), to: destination.id)
        defer { endStep(mark) }
        let ids = Set(halves.map(\.id))
        if let here = active, ids.contains(here.id), let next = successor(of: here, without: ids) {
            select(next, floatPrevious: false)
        }
        var arrived: Tab?
        holdingLoneFolders {
            for half in halves where finishMove(half, toSpace: destination.id, quietly: true) {
                if arrived == nil, LinkArrivals.arrived[half.id] != nil { arrived = half }
            }
        }
        guard !halves.contains(where: { half in tabs.contains { $0 === half } }) else { return }
        keepPair(pair, in: destination.id)
        writeSession(now: true)
        if let row = parked[destination.id] { writeSession(now: true, space: destination.id, row: row) }
        announce("Moved to \(destination.name)")
        if let arrived { LinkArrivals.moved(arrived, to: destination.id, in: self) }
    }

    private func keepPair(_ pair: TabSplit, in space: UUID) {
        guard var row = parked[space], !row.splits.contains(where: { $0.id == pair.id }) else { return }
        let rest = row.tabs.filter { !pair.contains($0.id) }
        let halves = pair.tabs.compactMap { id in row.tabs.first { $0.id == id } }
        guard halves.count == pair.tabs.count, let at = row.tabs.firstIndex(where: { pair.contains($0.id) }) else { return }
        row.tabs = rest
        row.tabs.insert(contentsOf: halves, at: min(at, rest.count))
        guard Browser.holds(pair, in: row.tabs) else { return }
        row.splits.append(pair)
        parked[space] = row
    }

    func stackedReport() -> [String: Any] {
        let folds = StackedFolds.shared
        let sections: [[String: Any]] = spaces.map { space in
            let row = stackedRow(space.id)
            return [
                "id": space.id.uuidString,
                "name": space.name,
                "active": space.id == spaceID,
                "folded": folds.isFolded(space.id),
                "tabs": row.tabs.map(Bench.short),
                "front": row.active.flatMap { id in row.tabs.first { $0.id == id } }.map(Bench.short) ?? "",
                "header": StackedProbe.headers[space.id].map { ["y": $0.minY, "height": $0.height] } ?? [:],
                "drawn": (StackedProbe.gathered.contains(space.id) ? [] : StackedProbe.rows[space.id] ?? []).compactMap { id in row.tabs.first { $0.id == id } }.map(Bench.short),
            ]
        }
        let lift = StackedProbe.lift
        let inner = StackedProbe.inner?() ?? [:]
        return ["stacked": stacked, "space": spaceID.uuidString, "spaceNext": spaceNext ?? -1,
                "carrying": lift?.carrying?.uuidString ?? "", "order": (lift?.order ?? spaces.map(\.id)).map(\.uuidString),
                "shift": lift?.shift ?? 0, "lead": lift?.lead ?? 0,
                "active": active.map(Bench.short) ?? "", "sections": sections,
                "lit": StackedProbe.lit?.uuidString ?? "", "scrolled": StackedProbe.scrolled,
                "content": StackedProbe.content, "viewport": StackedProbe.viewport,
                "inner": Dictionary(uniqueKeysWithValues: inner.map { ($0.key.uuidString, $0.value) }),
                "open": Dictionary(uniqueKeysWithValues: StackedProbe.open.map { ($0.key.uuidString, $0.value) }),
                "trace": StackedProbe.trace, "hit": StackedProbe.hit,
                "page": ["x": PinDragProbe.shared.page.minX, "y": PinDragProbe.shared.page.minY]]
    }
}

final class StackedHeaderView: NSView {
    enum Carry: Equatable {
        case begin(CGFloat)
        case move(CGFloat)
        case end
    }

    static let height = StackedSpaces.headerHeight + StackedSpaces.headerPad * 2

    var space: Space { didSet { if space != oldValue { refresh() } } }
    var count: Int { didSet { if count != oldValue { refresh() } } }
    var lit = false { didSet { if lit != oldValue { paint(animated: true) } } }
    var gathered = false { didSet { if gathered != oldValue { refresh() } } }
    var lifted = false { didSet { if lifted != oldValue { lift() } } }
    var held: CGFloat = 0 { didSet { if held != oldValue { showHeld() } } }
    var openness: CGFloat = 1 { didSet { if openness != oldValue { showOpenness() } } }
    var onFrame = false { didSet { if onFrame != oldValue { paint(animated: false) } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { paint(animated: false) } } }
    var cuts: StackedCuts? { didSet { needsLayout = true } }
    var ground: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let ground { well.addSubview(ground) }
            needsLayout = true
        }
    }
    var carry: ((Carry) -> Void)?
    weak var column: NSView?

    private let browser: Browser
    private let folds: StackedFolds
    private let well = NSView()
    private let plate = KitBox(fill: nil, corners: .radius(Metrics.sideRadius))
    private let mark: SpaceMarkView
    private let name = KitLabel("", font: .systemFont(ofSize: 15, weight: .semibold))
    private let chip = KitBox(fill: KitColor.ink.withAlphaComponent(0.07), corners: .capsule)
    private let tally = KitLabel("", font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: KitColor.muted)
    private let doors = NSView()
    private let add = KitButton(.plain(press: 0.86))
    private let more = KitButton(.plain(press: 0.86))
    private let turn = KitButton(.plain(press: 0.86))
    private let chevron = KitSymbol("chevron.right", style: KitSymbol.Style(size: 11, weight: .semibold), tint: KitColor.muted)
    private let tuck = CALayer()
    private var area: NSTrackingArea?
    private var hovering = false { didSet { if hovering != oldValue { refresh() } } }
    private var down: (window: NSPoint, local: NSPoint)?
    private var carrying = false
    private var folded: Bool { folds.isFolded(space.id) }
    private var active: Bool { space.id == browser.spaceID }
    private var shownGathered: Bool?
    private var chipShare: CGFloat { gathered ? 1 : 1 - openness }
    private lazy var reads = KitReads { [weak self] in self?.refresh() }

    init(browser: Browser, folds: StackedFolds = .shared, space: Space, count: Int) {
        self.browser = browser
        self.folds = folds
        self.space = space
        self.count = count
        openness = folds.isFolded(space.id) ? 0 : 1
        mark = SpaceMarkView(space: space, size: 15)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        well.wantsLayer = true
        well.layer?.masksToBounds = true
        well.layer?.cornerRadius = Metrics.sideRadius
        well.layer?.cornerCurve = .continuous
        well.isHidden = true
        tuck.zPosition = 1
        layer?.addSublayer(tuck)
        chip.addSubview(tally)
        tally.setAccessibilityElement(false)
        name.setAccessibilityElement(false)
        name.overflow = .tail
        for (button, symbol) in [(add, "plus"), (more, "ellipsis")] {
            button.content = KitSymbol(symbol, style: KitSymbol.Style(size: 11, weight: .semibold), tint: KitColor.muted)
        }
        chevron.wantsLayer = true
        turn.content = chevron
        add.action = { [weak self] in self?.newTab() }
        more.action = { [weak self] in self?.menu() }
        turn.action = { [weak self] in self?.fold() }
        for button in [add, more, turn] { doors.addSubview(button) }
        doors.wantsLayer = true
        for view in [well, plate, mark, name, chip, doors] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        refresh()
        paint(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    private var inner: NSRect { bounds.insetBy(dx: 0, dy: StackedSpaces.headerPad) }

    override func layout() {
        super.layout()
        let row = inner
        plate.frame = row
        well.frame = row
        ground?.frame = well.bounds
        let showsChip = openness < 1 || gathered
        let showsDoors = hovering && !gathered
        let middle = row.minX + SpaceTitleLineView.iconMiddle
        mark.frame = kitSnap(NSRect(x: middle - 10, y: row.minY + (row.height - 18) / 2 - 0.5, width: 20, height: 18))
        var x = row.minX + SpaceTitleLineView.wordsStart
        let right = row.maxX - 3 - (showsDoors ? 72 : 0)
        let chipText = tally.intrinsicContentSize
        let chipWidth = chipText.width + 12
        let room = max(0, right - x - (showsChip ? chipWidth + 8 : 0) - 8 - (showsDoors ? 8 : 0))
        let shown = fitted(space.name, in: room)
        if name.text != shown.text { name.text = shown.text }
        let nameSize = name.intrinsicContentSize
        name.frame = kitSnap(NSRect(x: x, y: row.minY + (row.height - nameSize.height) / 2, width: ceil(shown.width) + 1, height: nameSize.height))
        x += shown.width + 8
        chip.frame = kitSnap(NSRect(x: x, y: row.minY + (row.height - 17) / 2, width: chipWidth, height: 17))
        tally.frame = kitSnap(NSRect(x: 6, y: (17 - chipText.height) / 2, width: chipText.width, height: chipText.height))
        doors.frame = NSRect(x: row.maxX - 3 - 72, y: row.minY + (row.height - 24) / 2, width: 72, height: 24)
        for (index, button) in [add, more, turn].enumerated() {
            button.frame = NSRect(x: CGFloat(index) * 24, y: 0, width: 24, height: 24)
        }
        let scale = window?.backingScaleFactor ?? 2
        let line = 1 / max(scale, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tuck.frame = NSRect(x: -Metrics.sideInset, y: bounds.maxY - line, width: bounds.width + Metrics.sideInset * 2, height: line)
        tuck.backgroundColor = ink.color(KitColor.ink, .ink, opacity: 0.1, dark: kitDark).cgColor
        tuck.opacity = Swift.Float(held)
        CATransaction.commit()
        showOpenness()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let made = NSTrackingArea(rect: inner, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(made)
        area = made
        if let window {
            let inside = inner.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) && !isHiddenOrHasHiddenAncestor
            if inside != hovering { hovering = inside }
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidHide() {
        super.viewDidHide()
        hovering = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint(animated: false)
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        down = (event.locationInWindow, convert(event.locationInWindow, from: nil))
        carrying = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        let travel = hypot(event.locationInWindow.x - down.window.x, event.locationInWindow.y - down.window.y)
        if !carrying {
            guard travel >= 5 else { return }
            carrying = true
            carry?(.begin(y(at: down.window, from: down)))
        }
        carry?(.move(y(at: event.locationInWindow, from: down)))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            down = nil
            carrying = false
        }
        if carrying {
            carry?(.end)
        } else if let down, inner.contains(down.local) {
            fold()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let name = space.name
        return KitMenu.make([
            .action(folded ? "Unfold \(name)" : "Fold \(name)", modifiers: [], run: { [weak self] in self?.fold() }),
            .action("New Tab in \(name)", symbol: MenuSymbol.newTab, modifiers: [], run: { [weak self] in self?.newTab() }),
            .action("Open Space Menu", modifiers: [], run: { [weak self] in self?.menu() }),
        ])
    }

    override func accessibilityLabel() -> String? { space.name }
    override func accessibilityRoleDescription() -> String? { "heading" }

    override func accessibilityValue() -> Any? {
        active ? "Current space" : folded ? StackedSpaces.count(count) : ""
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: folded ? "Unfold" : "Fold") { [weak self] in self?.fold(); return true },
         NSAccessibilityCustomAction(name: "New Tab") { [weak self] in self?.newTab(); return true },
         NSAccessibilityCustomAction(name: "Space Menu") { [weak self] in self?.menu(); return true }]
    }

    override func accessibilityChildren() -> [Any]? {
        hovering && !gathered ? [add, more, turn] : []
    }

    private func y(at point: NSPoint, from down: (window: NSPoint, local: NSPoint)) -> CGFloat {
        if let column {
            let there = column.convert(point, from: nil)
            return column.isFlipped ? there.y : column.bounds.height - there.y
        }
        return down.local.y + (down.window.y - point.y)
    }

    private func refresh() {
        reads.track { refreshNow() }
    }

    private func refreshNow() {
        let name = space.name
        if mark.icon != space.shownIcon { mark.icon = space.shownIcon }
        tally.text = "\(count)"
        add.setAccessibilityLabel("New Tab in \(name)")
        add.toolTip = "New Tab in \(name)"
        more.setAccessibilityLabel("\(name) Menu")
        more.toolTip = "\(name) Menu"
        let turnLabel = folded ? "Unfold \(name)" : "Fold \(name)"
        turn.setAccessibilityLabel(turnLabel)
        turn.toolTip = turnLabel
        let showsDoors = hovering && !gathered
        if gathered != shownGathered {
            let first = shownGathered == nil
            shownGathered = gathered
            chip.isHidden = false
            chip.layer?.kitAnimate("opacity", to: Swift.Float(chipShare), curve: first || window == nil ? .none : Motion.kitSettle, key: "fade")
            chip.alphaValue = chipShare
        }
        fade(doors, shown: showsDoors, curve: Motion.kitQuick)
        showOpenness()
        paint(animated: true)
        needsLayout = true
    }

    private func fitted(_ text: String, in room: CGFloat) -> (text: String, width: CGFloat) {
        let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        func width(_ string: String) -> CGFloat {
            NSAttributedString(string: string, attributes: [.font: font]).size().width
        }
        let whole = width(text)
        guard whole > room else { return (text, whole) }
        let characters = Array(text)
        var low = 0
        var high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            let tried = String(characters[..<mid]).trimmingCharacters(in: .whitespaces) + "…"
            if width(tried) <= room { low = mid } else { high = mid - 1 }
        }
        let cut = String(characters[..<low]).trimmingCharacters(in: .whitespaces) + "…"
        return (cut, min(room, width(cut)))
    }

    private func fade(_ view: NSView, shown: Bool, curve: KitCurve) {
        guard (view.alphaValue == 1) != shown || view.isHidden == shown else { return }
        view.isHidden = false
        view.layer?.kitAnimate("opacity", to: shown ? 1 : 0, curve: window == nil ? .none : curve, key: "fade")
        view.alphaValue = shown ? 1 : 0
        if !shown && view === doors { view.isHidden = !curve.animates || window == nil }
    }

    private func paint(animated: Bool) {
        let dark = kitDark
        let bright = active || lit
        mark.tint = active ? KitColor.ink : KitColor.muted
        mark.ink = ink
        mark.opacity = bright ? 1 : 0.6
        name.color = bright ? KitColor.ink : KitColor.muted
        name.ink = ink
        tally.ink = ink
        chip.fill = ink.color(KitColor.ink, .ink, opacity: 0.07, dark: dark)
        for button in [add, more] { (button.content as? KitSymbol)?.ink = ink }
        chevron.ink = ink
        let fill: NSColor? = lit ? grey(onFrame ? Palette.NS.sideWash : Palette.NS.wash)
            : lifted ? grey(onFrame ? Palette.NS.sidePicked : Palette.NS.picked)
            : hovering && !gathered ? grey(onFrame ? Palette.NS.sideHover : Palette.NS.hover) : nil
        let resolved = fill?.kitResolved(dark: dark)
        if plate.fill != resolved {
            if animated, window != nil { plate.layer?.kitTransition(Motion.kitQuick) }
            plate.fill = resolved
        }
    }

    private func grey(_ base: NSColor) -> NSColor {
        onFrame ? ink.color(base, .stronger(0.8), dark: kitDark) : base
    }

    private func showOpenness() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer = chevron.layer {
            let side = chevron.bounds
            let angle = -CGFloat.pi / 2 * openness
            let mid = CATransform3DMakeTranslation(side.midX, side.midY, 0)
            layer.removeAnimation(forKey: "turn")
            layer.transform = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-side.midX, -side.midY, 0),
                                                                      CATransform3DMakeRotation(angle, 0, 0, 1)), mid)
        }
        if !gathered, chip.layer?.animation(forKey: "fade") == nil || openness < 1 {
            chip.layer?.removeAnimation(forKey: "fade")
            chip.isHidden = false
            chip.alphaValue = chipShare
        }
        CATransaction.commit()
    }

    private func showHeld() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tuck.opacity = Swift.Float(held)
        CATransaction.commit()
    }

    private func lift() {
        well.isHidden = !lifted
        refresh()
    }

    private func fold() {
        KitChange.eased { folds.toggle(space.id) }
    }

    private func newTab() {
        browser.stackedNewTab(in: space.id)
    }

    private func menu() {
        browser.stackedEnter(space.id, announcing: false)
        guard browser.spaceID == space.id else { return }
        SpaceMenu.show(for: browser)
    }
}

final class StackedPickView: KitHoverView {
    var radius: CGFloat { didSet { plate.corners = .radius(radius) } }
    var onFrame = false { didSet { if onFrame != oldValue { paint() } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { paint() } } }
    var act: () -> Void
    private let plate = KitBox(fill: nil)
    private let label: String

    init(label: String, radius: CGFloat = Metrics.sideRadius, act: @escaping () -> Void) {
        self.label = label
        self.radius = radius
        self.act = act
        super.init(frame: .zero)
        wantsLayer = true
        plate.corners = .radius(radius)
        addSubview(plate)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        plate.frame = bounds
    }

    override func hoverChanged() { paint() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        act()
    }

    override func accessibilityPerformPress() -> Bool {
        act()
        return true
    }

    private func paint() {
        let base = onFrame ? Palette.NS.sideHover : Palette.NS.hover
        let wanted = hovering ? (onFrame ? ink.color(base, .stronger(0.8), dark: kitDark) : base.kitResolved(dark: kitDark)) : nil
        guard wanted != plate.fill else { return }
        if window != nil { plate.layer?.kitTransition(Motion.kitQuick) }
        plate.fill = wanted
    }
}
