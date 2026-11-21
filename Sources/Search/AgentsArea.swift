import AppKit
import Observation
import Combine

@MainActor
@Observable
final class AgentsFolds {
    static let shared = AgentsFolds(store: Store.settings)
    nonisolated static let key = "agents.open"
    nonisolated static let retired = "agents.unfolded"

    var folded: Bool { didSet { if folded != oldValue { store?.set(!folded, forKey: Self.key) } } }
    var whole: Set<UUID> = []
    var open: Set<UUID> = []
    private let store: UserDefaults?

    init(store: UserDefaults? = nil) {
        self.store = store
        store?.removeObject(forKey: Self.retired)
        folded = !(store?.bool(forKey: Self.key) ?? false)
    }

    func toggle() { folded.toggle() }

    func toggle(_ agent: UUID) {
        if open.contains(agent) { open.remove(agent) } else { open.insert(agent) }
    }
}

enum AgentsLayout {
    static let row: CGFloat = Metrics.sideRowHeight
    static let gap: CGFloat = Metrics.sideGap
    static let step: CGFloat = row + gap
    static let pad: CGFloat = MiniPlayerView.openInset
    static let indent: CGFloat = SideLook.cardRowInset - pad
    static let rowLead: CGFloat = TabRowView.iconLead
    static let rowCorner: CGFloat = Metrics.sideRadius
    static let rim: CGFloat = (MiniPlayerView.height - row) / 2
    static let below: CGFloat = MiniPlayerView.below
    static let margin: CGFloat = 2 * rim + below
    static let lead: CGFloat = SideLook.rowLead - pad
    static let corner: CGFloat = SideLook.cardRadius - pad
    static let hover = KitTone(base: KitColor.ink, kind: .ink, opacity: 0.1)
    static let share: CGFloat = 0.4
    static let most = 5
    static let faces = 3
    static let faceStep: CGFloat = 12

    struct Section: Equatable {
        var rows: Int
        var whole = false
        var headed = false
        var open = false
    }

    enum Press: Equatable {
        case fold, question
    }

    enum Presence: Equatable {
        case still, travels, fades
    }

    struct Voice: Equatable {
        var title: String
        var line: String
        var attention = false
    }

    struct RowSlots: Equatable {
        var mark: NSRect
        var close: NSRect
        var dot: NSRect
        var tail: CGFloat
    }

    static let dotSide: CGFloat = 7
    static let tail: CGFloat = 10

    static func rowSlots(width: CGFloat, height: CGFloat) -> RowSlots {
        let side = SideLook.rowMark
        let square = Metrics.closeSquare(height)
        let inset = Metrics.closeInset(height)
        let close = NSRect(x: width - inset - square, y: inset, width: square, height: square)
        let dot = NSRect(x: close.midX - dotSide / 2, y: (height - dotSide) / 2, width: dotSide, height: dotSide)
        return RowSlots(mark: NSRect(x: rowLead, y: (height - side) / 2, width: side, height: side), close: close, dot: dot, tail: tail)
    }

    static func headed(_ sessions: Int) -> Bool { sessions > 1 }

    static func shown(_ count: Int, whole: Bool) -> Int {
        whole || count <= most ? count : most - 1
    }

    static func fold(_ tabs: Int, headed: Bool) -> Int { headed ? max(0, tabs - 1) : tabs }

    static func listed(_ section: Section) -> Bool { !section.headed || section.open }

    static func count(_ section: Section) -> Int? {
        section.headed && !section.open && section.rows > 0 ? section.rows : nil
    }

    static func rows(_ section: Section) -> Int {
        guard listed(section) else { return 0 }
        let shown = shown(section.rows, whole: section.whole)
        return shown + (shown < section.rows ? 1 : 0)
    }

    static func lead(asking: UUID?, acting: UUID?, stamps: [(id: UUID, stamp: Int)]) -> UUID? {
        if let now = asking ?? acting { return now }
        let last = stamps.filter { $0.stamp > 0 }.max { $0.stamp < $1.stamp }
        return last?.id ?? stamps.first?.id
    }

    static func headline(_ state: AgentLinkState, tab: String?, acting: String?) -> String {
        guard let tab, !tab.isEmpty else { return state.line }
        switch state {
        case .working(let doing): return "\(acting ?? doing) · \(tab)"
        case .idle: return "\(state.line) · \(tab)"
        case .quiet: return "Idle · \(tab)"
        default: return state.line
        }
    }

    static func presence(from: CGFloat, to: CGFloat, ready: Bool, reduced: Bool) -> Presence {
        guard ready, from != to else { return .still }
        guard reduced else { return .travels }
        return from == 0 || to == 0 ? .fades : .still
    }

    static func sectionHeight(_ section: Section) -> CGFloat {
        CGFloat((section.headed ? 1 : 0) + rows(section)) * step
    }

    static func content(_ sections: [Section]) -> CGFloat {
        sections.map(sectionHeight).reduce(0, +)
    }

    static func height(_ sections: [Section], folded: Bool, column: CGFloat) -> CGFloat {
        guard !sections.isEmpty else { return 0 }
        let full = row + (folded ? 0 : content(sections))
        return min(full, max(row, column * share)) + margin
    }

    static func press(asking: UUID?, front: UUID?) -> Press {
        asking != nil && asking != front ? .question : .fold
    }

    static func revealed(_ sessions: [(id: UUID, attention: Bool)]) -> UUID? {
        (sessions.first { $0.attention } ?? sessions.last)?.id
    }

    static func faces(_ sessions: [(id: UUID, attention: Bool)]) -> [UUID] {
        guard sessions.count > faces else { return sessions.map(\.id) }
        let asking = Set(sessions.filter(\.attention).prefix(faces).map(\.id))
        var room = faces - asking.count
        return sessions.filter { session in
            if asking.contains(session.id) { return true }
            guard room > 0 else { return false }
            room -= 1
            return true
        }.map(\.id)
    }

    static func tally(_ states: [AgentLinkState]) -> String {
        var asking = 0, working = 0, done = 0, failed = 0, idle = 0
        for state in states {
            switch state {
            case .needsYou: asking += 1
            case .working, .driving, .idle: working += 1
            case .finished, .done: done += 1
            case .failed: failed += 1
            case .quiet: idle += 1
            }
        }
        let parts = [(asking, "waiting for you"), (working, "working"), (done, "done"), (failed, "failed"), (idle, "idle")]
        return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    static func voice(_ sessions: [(title: String, state: AgentLinkState)]) -> Voice {
        let asking = sessions.filter { $0.state.attention }
        if let first = asking.first {
            var question = ""
            if case .needsYou(let asked) = first.state { question = asked }
            let rest = tally(sessions.filter { !$0.state.attention }.map(\.state))
            if asking.count > 1 {
                return Voice(title: "\(asking.count) agents need you", line: question.isEmpty ? first.title : "\(first.title): \(question)",
                             attention: true)
            }
            return Voice(title: "\(first.title) needs you", line: question.isEmpty ? rest : question, attention: true)
        }
        if sessions.count == 1, let only = sessions.first {
            return Voice(title: "Agents", line: "\(only.title) · \(only.state.line)")
        }
        return Voice(title: "Agents", line: tally(sessions.map(\.state)))
    }
}

struct AgentSession: Identifiable, Equatable {
    let link: AgentLink
    let tabs: [Tab]
    var elsewhere: Set<Tab.ID> = []

    var id: UUID { link.id }

    var closes: Bool { !tabs.isEmpty }

    static func == (lhs: AgentSession, rhs: AgentSession) -> Bool {
        lhs.link == rhs.link && lhs.tabs.map(\.id) == rhs.tabs.map(\.id)
    }

    @MainActor
    func state(pending: [AgentQuestion]) -> AgentLinkState {
        if let thread = link.codex { return AgentLinkState.codex(thread, ended: link.ended) }
        let facts = tabs.map { tab in
            let asked = pending.first { $0.tab == tab.id || ($0.tab == nil && $0.task == link.id) }
            return AgentLinkState.TabFacts(acting: tab.agentActing, mood: tab.agentMood, driving: tab.driving,
                                           host: tab.pageAddress?.host(), question: asked?.title, asking: asked != nil)
        }
        let loose = pending.first { question in
            question.task == link.id && !tabs.contains { $0.id == question.tab } && !(question.tab.map(elsewhere.contains) ?? false)
        }
        let extra = loose.map { [AgentLinkState.TabFacts(question: $0.title, asking: true)] } ?? []
        return AgentLinkState.of(facts + extra, ended: link.ended, rest: link.rest, last: link.last)
    }

    func face(_ state: AgentLinkState, now: Date = Date()) -> AgentCharacter.Mood {
        AgentCharacter.face(state, ended: link.ended, connected: link.connected, now: now)
    }

    @MainActor
    func asking(pending: [AgentQuestion]) -> Tab? {
        tabs.first { tab in pending.contains { $0.tab == tab.id } } ?? tabs.first { $0.agentMood == .waving }
    }
}

extension AgentLinks {
    static func frontSpace() -> UUID? {
        guard let front = Browsers.front, front.showsSpaces else { return nil }
        return front.spaceID
    }

    static func frontSpaceNames() -> [AgentSpaceName]? {
        guard let front = Browsers.front, front.showsSpaces else { return nil }
        return front.spaces.map { AgentSpaceName(id: $0.id, name: $0.name) }
    }
}

extension Browser {
    var agentsInFront: Bool { Browsers.front === self || Browsers.front == nil }

    func agentSessions(links: [AgentLink], front: Bool, in space: UUID? = nil) -> [AgentSession] {
        let shown = space ?? spaceID
        let row = shown == spaceID ? tabs : parked[shown]?.tabs ?? []
        let sessions = links.compactMap { link -> AgentSession? in
            let everywhere = AgentBoard.allTabs(of: link.id)
            let held = everywhere.filter { $0.browser === self }.map(\.tab)
            let mine = held.filter { tab in row.contains { $0 === tab } }
            if mine.isEmpty {
                let waits = everywhere.isEmpty && (link.live || link.codex != nil) && link.announced
                return waits && tablessShown(link, in: shown, front: front) ? AgentSession(link: link, tabs: []) : nil
            }
            let away = held.filter { tab in !mine.contains { $0 === tab } }
            return AgentSession(link: link, tabs: mine, elsewhere: Set(away.map(\.id)))
        }
        return sessions.enumerated().sorted { one, two in
            one.element.link.connected == two.element.link.connected ? one.offset < two.offset : one.element.link.connected < two.element.link.connected
        }.map(\.element)
    }

    func tablessShown(_ link: AgentLink, in space: UUID, front: Bool) -> Bool {
        guard showsSpaces, let home = link.space, spaces.contains(where: { $0.id == home }) else { return front && space == spaceID }
        return home == space && (front || space != spaceID)
    }

    func agentAsks(in space: UUID) -> Bool {
        guard showsSpaces, space != spaceID, spaces.contains(where: { $0.id == space }) else { return false }
        let pending = AgentDesk.shared.pending
        return agentSessions(links: AgentLinks.shared.links, front: false, in: space).contains { $0.state(pending: pending).attention }
    }

    var agentAskingSpaces: [UUID] {
        spaces.map(\.id).filter(agentAsks(in:))
    }

    func agentSections(_ sessions: [AgentSession]) -> [AgentsLayout.Section] {
        let folds = AgentsFolds.shared
        let headed = AgentsLayout.headed(sessions.count)
        return sessions.map { session in
            AgentsLayout.Section(rows: AgentsLayout.fold(session.tabs.count, headed: headed), whole: folds.whole.contains(session.id),
                                 headed: headed, open: folds.open.contains(session.id))
        }
    }

    func agentLead(_ session: AgentSession, pending: [AgentQuestion]) -> Tab? {
        let now = session.asking(pending: pending) ?? session.tabs.first { $0.agentActing != nil }
        if let now {
            let top = session.tabs.filter { $0 !== now }.map(\.agentLed).max() ?? 0
            if now.agentLed <= top { now.agentLed = top + 1 }
        }
        let picked = AgentsLayout.lead(asking: now?.id, acting: nil, stamps: session.tabs.map { ($0.id, $0.agentLed) })
        return session.tabs.first { $0.id == picked }
    }

    static func agentTabName(_ tab: Tab) -> String {
        tab.title.isEmpty ? (tab.pageAddress?.host() ?? "New Tab") : tab.title
    }

    var linkedTabs: Set<Tab.ID> {
        let ids = Set(AgentLinks.shared.links.map(\.id))
        guard !ids.isEmpty else { return [] }
        return Set(tabs.filter { $0.agent && $0.agentTask.map(ids.contains) == true }.map(\.id))
    }

    func pressAgents() {
        let sessions = agentSessions(links: AgentLinks.shared.links, front: agentsInFront)
        let pending = AgentDesk.shared.pending
        let asked = sessions.filter { $0.state(pending: pending).attention }.compactMap { $0.asking(pending: pending) }.first
        if AgentsLayout.press(asking: asked?.id, front: activeID) == .question, let asked {
            bring(asked)
        } else if AgentsLayout.content(agentSections(sessions)) > 0 {
            KitChange.eased { AgentsFolds.shared.toggle() }
        } else if sessions.count == 1, let only = sessions.first {
            pressAgent(only)
        }
    }

    func pressAgent(_ session: AgentSession) {
        if session.link.codex != nil {
            CodexDesktop.shared.reveal(session.link)
            return
        }
        if let tab = agentLead(session, pending: AgentDesk.shared.pending) { bring(tab) }
    }

    func closeAgentTabs(_ session: AgentSession) {
        for tab in session.tabs { closeAgentTab(tab) }
    }

    func agentMenu(_ session: AgentSession) -> NSMenu? {
        let menu = NSMenu()
        let link = session.link
        if !session.tabs.isEmpty {
            menu.addItem(PlusMenu.item("Keep Tabs") { [weak self] in for tab in session.tabs { self?.keepAgentTab(tab) } })
            menu.addItem(PlusMenu.item("Close Tabs") { [weak self] in self?.closeAgentTabs(session) })
        }
        if link.codex != nil {
            menu.addItem(PlusMenu.item("Show in Codex") { CodexDesktop.shared.reveal(link) })
            menu.addItem(PlusMenu.item("Hide") { CodexDesktop.shared.hide(link) })
        } else if link.live {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(PlusMenu.item("Disconnect") { AgentLinks.shared.end(link.id, .done(nil)) })
        }
        return menu.items.isEmpty ? nil : menu
    }
}

final class AgentsAreaView: NSView {
    struct Scene: Equatable {
        var space: UUID
        var front: Bool
    }

    struct Veil: Equatable {
        var from: Double
        var to: Double
        var lag: Double
        var length: Double
    }

    static let rise = SidePageView.foldRise
    static let reducedLeave: Double = 0.14

    let browser: Browser
    var column: CGFloat = 700 { didSet { if column != oldValue { needsLayout = true } } }
    var ground = RowGround() { didSet { if ground != oldValue { reground() } } }
    var facesShown = true { didSet { if facesShown != oldValue { AgentFaces.show(facesShown, in: self) } } }
    var onRoom: (() -> Void)?
    private(set) var settled = false
    private(set) var room: CGFloat = 0
    private(set) var trace: [[Double]] = []
    private(set) var veiled: Veil?

    private let glass = NSGlassEffectView()
    private let row = AgentHeadView()
    private let scroll = NSScrollView()
    private let list = KitFlippedView()
    private var heads: [UUID: AgentHeadView] = [:]
    private var rows: [Tab.ID: AgentRowView] = [:]
    private var mores: [UUID: AgentMoreRowView] = [:]
    private var shown: [AgentSession] = []
    private var sections: [AgentsLayout.Section] = []
    private var inside: [UUID: [Tab]] = [:]
    private var spans: [UUID: ClosedRange<CGFloat>] = [:]
    private var revealedFor: [UUID] = []
    private var openDrawn = Set<UUID>()
    private var wasFolded = true
    private var aimedColumn: CGFloat?
    private var aimedFolded: Bool?
    private var aimedScene: Scene?
    private var drawnScene: Scene?
    private var still = false
    private var entering = false
    private var parting: Timer?
    private var motion: (from: CGFloat, to: CGFloat, start: CFTimeInterval, curve: KitCurve, velocity: Double, folds: Bool)?
    private var link: CADisplayLink?
    private var finish: Timer?
    private var traceStart: CFTimeInterval = 0
    private lazy var reads = KitReads { [weak self] in self?.later() }

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        glass.cornerRadius = SideLook.cardRadius
        glass.tintColor = Palette.NS.glassTint
        addSubview(glass)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .automatic
        scroll.documentView = list
        scroll.wantsLayer = true
        addSubview(scroll)
        addSubview(row)
        row.press = { [weak browser] in browser?.pressAgents() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agents")
        reads.track { refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static func height(of browser: Browser, column: CGFloat) -> CGFloat {
        let sessions = browser.agentSessions(links: AgentLinks.shared.links, front: browser.agentsInFront)
        return AgentsLayout.height(browser.agentSections(sessions), folded: AgentsFolds.shared.folded, column: column)
    }

    var moving: Bool { motion != nil }

    private var scene: Scene { Scene(space: browser.spaceID, front: browser.agentsInFront) }

    var cardFrameInColumn: NSRect { convert(glass.frame, to: superview) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        glass.tintColor = Palette.NS.glassTint
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        entering = false
        if let motion {
            stopLink()
            self.motion = nil
            room = motion.to
        }
        if parting != nil {
            stopParting()
            room = 0
        }
    }

    func aim(_ goal: CGFloat) {
        let sameColumn = aimedColumn == column
        aimedColumn = column
        let scene = scene
        let sameScene = aimedScene == scene
        aimedScene = scene
        let folded = AgentsFolds.shared.folded
        let folds = aimedFolded.map { $0 != folded } ?? false
        aimedFolded = folded
        let target = parting != nil ? 0 : motion?.to ?? room
        guard goal != target else { return }
        let ready = settled && sameColumn && sameScene && window != nil
        let gone = room == 0 && motion == nil
        switch AgentsLayout.presence(from: target, to: goal, ready: ready, reduced: Motion.reduced) {
        case .still:
            let crossfade = ready && folds && target > 0 && goal > 0
            stopLink()
            stopParting()
            motion = nil
            entering = false
            room = goal
            veil(1, from: 1, lag: 0, length: 0)
            if crossfade { fade() }
            later()
        case .fades:
            stopLink()
            motion = nil
            if goal == 0 {
                veil(0, from: nil, lag: 0, length: Self.reducedLeave)
                part(after: Self.reducedLeave)
            } else {
                stopParting()
                room = goal
                veil(1, from: gone ? 0 : nil, lag: 0, length: Motion.reducedFade)
                later()
            }
        case .travels:
            stopParting()
            let now = CACurrentMediaTime()
            let at = shownRoom(at: now)
            let speed = shownSpeed(at: now)
            let span = goal - at.room
            if motion == nil {
                trace = []
                traceStart = now
            }
            if target == 0 {
                entering = gone
                veil(1, from: gone ? 0 : nil, lag: gone ? SideLook.growLag : 0, length: SideLook.growFade)
            } else if goal == 0 {
                veil(0, from: nil, lag: 0, length: Self.crossfade)
            }
            motion = (at.room, goal, now, Motion.kitCover, abs(span) > 0.01 ? speed / Double(span) : 0, folds || (motion?.folds ?? false))
            room = at.room
            startLink()
        }
    }

    private func veil(_ target: Swift.Float, from: Swift.Float?, lag: CFTimeInterval, length: CFTimeInterval) {
        guard let layer else { return }
        let start = from ?? (layer.animation(forKey: "presence") == nil ? layer.opacity : layer.presentation()?.opacity ?? layer.opacity)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = target
        CATransaction.commit()
        layer.removeAnimation(forKey: "presence")
        veiled = length > 0 ? Veil(from: Double(start), to: Double(target), lag: lag, length: length) : nil
        guard length > 0, start != target, window != nil,
              let fade = KitCurve.easeOut(length).animation("opacity", from: start, to: target) else { return }
        fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + lag
        fade.fillMode = .backwards
        layer.add(fade, forKey: "presence")
    }

    private func part(after delay: TimeInterval) {
        parting?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.parted() }
        }
        RunLoop.main.add(timer, forMode: .common)
        parting = timer
    }

    private func parted() {
        guard parting != nil else { return }
        stopParting()
        room = 0
        later()
        needsLayout = true
        onRoom?()
        superview?.layoutSubtreeIfNeeded()
    }

    private func stopParting() {
        parting?.invalidate()
        parting = nil
    }

    var presence: Double {
        guard let layer else { return 1 }
        return Double(layer.animation(forKey: "presence") == nil ? layer.opacity : layer.presentation()?.opacity ?? layer.opacity)
    }

    var fading: Bool { layer?.animation(forKey: "presence") != nil }

    private func shownRoom(at time: CFTimeInterval) -> (room: CGFloat, done: Bool) {
        guard let motion else { return (room, true) }
        let step = Self.progress(motion.curve, at: time - motion.start, velocity: motion.velocity)
        return (motion.from + (motion.to - motion.from) * CGFloat(step.share), step.done)
    }

    private func shownSpeed(at time: CFTimeInterval) -> Double {
        guard let motion, case .spring(let spring) = motion.curve else { return 0 }
        return Double(motion.to - motion.from) * spring.rate(time - motion.start, velocity: motion.velocity)
    }

    static func progress(_ curve: KitCurve, at time: Double, velocity: Double = 0) -> (share: Double, done: Bool) {
        switch curve {
        case .none: return (1, true)
        case .spring(let spring):
            let end = spring.animation("opacity", from: 0, to: 1, velocity: velocity).settlingDuration
            let share = spring.progress(time, velocity: velocity)
            return time >= end ? (1, true) : (share, false)
        case .easeOut(let duration), .easeInOut(let duration):
            let t = min(1, max(0, time / max(0.001, duration)))
            return (1 - pow(1 - t, 3), t >= 1)
        }
    }

    static let crossfade: Double = 0.18

    private func fade() {
        layer?.kitTransition(.easeOut(Self.crossfade))
    }

    private func startLink() {
        finish?.invalidate()
        if let motion {
            let end = MiniPlayerView.progressEnd(motion.curve) + 0.1
            let timer = Timer(timeInterval: end, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(force: true) }
            }
            RunLoop.main.add(timer, forMode: .common)
            finish = timer
        }
        guard link == nil else { return }
        guard let screen = window?.screen ?? NSScreen.main else {
            tick(force: true)
            return
        }
        let made = screen.displayLink(target: self, selector: #selector(stepped))
        made.add(to: .main, forMode: .common)
        link = made
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        finish?.invalidate()
        finish = nil
    }

    @objc private func stepped(_ link: CADisplayLink) {
        tick()
    }

    private func tick(force: Bool = false) {
        guard let motion else {
            stopLink()
            return
        }
        let now = CACurrentMediaTime()
        let at = shownRoom(at: now)
        let done = force || at.done || abs(at.room - motion.to) < 0.05
        room = done ? motion.to : at.room
        if Store.testing { trace.append([now - traceStart, Double(room)]) }
        if done {
            self.motion = nil
            entering = false
            stopLink()
            later()
        }
        needsLayout = true
        onRoom?()
        superview?.layoutSubtreeIfNeeded()
    }

    private var pending = false

    private func later() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pending = false
            reads.track { self.refresh() }
        }
    }

    private func reground() {
        row.ground = ground
        for head in heads.values { head.ground = ground }
        for row in rows.values { row.ground = ground }
        for more in mores.values { more.ground = ground }
    }

    private func face(_ session: AgentSession, _ state: AgentLinkState, now: Date) -> AgentHeadLook.Face {
        AgentHeadLook.Face(id: session.id, mood: session.face(state, now: now), attention: state.attention, accent: session.link.accent,
                           seed: session.link.seed, name: session.link.title, said: state.line)
    }

    private var greetingEnds: Date?

    private func watchGreetings(_ sessions: [AgentSession], now: Date) {
        let ends = sessions.filter { $0.link.live }.map { $0.link.connected.addingTimeInterval(AgentCharacter.helloSpan) }.filter { $0 > now }.min()
        guard let ends, greetingEnds.map({ ends < $0 || $0 <= now }) ?? true else { return }
        greetingEnds = ends
        DispatchQueue.main.asyncAfter(deadline: .now() + ends.timeIntervalSince(now) + 0.05) { [weak self] in
            guard let self else { return }
            greetingEnds = nil
            later()
        }
    }

    private var closedRoom: CGFloat { AgentsLayout.height(sections, folded: true, column: column) }

    private func refresh() {
        let sessions = browser.agentSessions(links: AgentLinks.shared.links, front: browser.agentsInFront)
        let scene = scene
        if scene != drawnScene {
            drawnScene = scene
            still = true
        }
        if sessions.isEmpty, !shown.isEmpty, settled, !still, window != nil, room > 0 {
            superview?.needsLayout = true
            return
        }
        shown = sessions
        sections = browser.agentSections(shown)
        let questions = AgentDesk.shared.pending
        let folded = AgentsFolds.shared.folded
        let states = shown.map { $0.state(pending: questions) }
        let now = Date()
        watchGreetings(shown, now: now)
        let voice = AgentsLayout.voice(zip(shown, states).map { ($0.link.title, $1) })
        let unfolds = AgentsLayout.content(sections) > 0
        let only = shown.count == 1 ? shown.first : nil
        let faces = Set(AgentsLayout.faces(zip(shown, states).map { ($0.id, $1.attention) }))
        let keepsRows = !folded || (settled && (motion != nil || room > closedRoom + 0.5))

        var look = AgentHeadLook()
        look.faces = zip(shown, states).filter { faces.contains($0.0.id) }.map { face($0, $1, now: now) }
        look.title = voice.title
        look.line = voice.line
        look.attention = voice.attention
        look.working = !voice.attention && states.contains(where: \.working)
        look.said = voice.line.isEmpty ? voice.title : "\(voice.title): \(voice.line)"
        look.chevron = unfolds
        look.open = !folded
        look.closes = only?.closes ?? false
        look.closeLabel = only.map { "Close \($0.link.title)'s tabs" } ?? ""
        look.presses = unfolds || voice.attention || only?.link.codex != nil
        look.value = unfolds ? (folded ? "Shut" : "Open") : nil
        row.ground = ground
        row.show(look)
        row.closing = only.map { session in { [weak browser] in browser?.closeAgentTabs(session) } }
        row.menus = only.map { session in { [weak browser] in browser?.agentMenu(session) } }

        var keptHeads = Set<UUID>()
        var keptRows = Set<Tab.ID>()
        var keptMores = Set<UUID>()
        var listed: [UUID: [Tab]] = [:]
        if keepsRows {
            for (index, session) in shown.enumerated() {
                let section = sections[index]
                let state = states[index]
                var tabs = session.tabs
                if section.headed {
                    let lead = browser.agentLead(session, pending: questions)
                    tabs = session.tabs.filter { $0 !== lead }
                    let head = heads[session.id] ?? {
                        let made = AgentHeadView()
                        heads[session.id] = made
                        list.addSubview(made)
                        return made
                    }()
                    let id = session.id
                    var look = AgentHeadLook()
                    look.faces = [face(session, state, now: now)]
                    look.title = session.link.title
                    look.line = AgentsLayout.headline(state, tab: lead.map(Browser.agentTabName), acting: lead?.agentActing)
                    look.attention = state.attention
                    look.working = state.working
                    look.said = "\(session.link.title): \(look.line)"
                    look.strong = false
                    look.chevron = section.rows > 0
                    look.open = section.open
                    look.folds = true
                    look.count = AgentsLayout.count(section)
                    look.selected = lead.map { $0.id == browser.activeID } ?? false
                    look.roll = "\(lead?.id.uuidString ?? "none")\(state.attention ? " asks" : "")"
                    look.closes = session.closes
                    look.closeLabel = "Close \(session.link.title)'s tabs"
                    look.presses = session.link.codex != nil || !session.tabs.isEmpty
                    look.value = section.rows > 0 ? (section.open ? "Open" : "Shut") : nil
                    head.ground = ground
                    head.show(look)
                    head.press = { [weak browser] in browser?.pressAgent(session) }
                    head.fold = { KitChange.eased { AgentsFolds.shared.toggle(id) } }
                    head.closing = { [weak browser] in browser?.closeAgentTabs(session) }
                    head.menus = { [weak browser] in browser?.agentMenu(session) }
                    keptHeads.insert(session.id)
                }
                guard AgentsLayout.listed(section) else { continue }
                let count = AgentsLayout.shown(tabs.count, whole: section.whole)
                listed[session.id] = Array(tabs.prefix(count))
                for tab in tabs.prefix(count) {
                    let view = rows[tab.id] ?? {
                        let made = AgentRowView(browser: browser, tab: tab)
                        rows[tab.id] = made
                        list.addSubview(made)
                        return made
                    }()
                    view.ground = ground
                    view.refresh()
                    keptRows.insert(tab.id)
                }
                if count < tabs.count {
                    let more = mores[session.id] ?? {
                        let made = AgentMoreRowView()
                        mores[session.id] = made
                        list.addSubview(made)
                        return made
                    }()
                    let id = session.id
                    more.ground = ground
                    more.count = tabs.count - count
                    more.act = { KitChange.eased { _ = AgentsFolds.shared.whole.insert(id) } }
                    keptMores.insert(session.id)
                }
            }
        }
        inside = listed
        for (id, view) in heads where !keptHeads.contains(id) {
            heads[id] = nil
            leave(view)
        }
        for (id, view) in rows where !keptRows.contains(id) {
            rows[id] = nil
            leave(view)
        }
        for (id, view) in mores where !keptMores.contains(id) {
            mores[id] = nil
            leave(view)
        }
        if !facesShown { AgentFaces.show(false, in: self) }
        needsLayout = true
        superview?.needsLayout = true
    }

    private func leave(_ view: NSView) {
        guard settled, !still, window != nil, !AgentsFolds.shared.folded, let layer = view.layer else {
            view.removeFromSuperview()
            return
        }
        let shown = layer.presentation() ?? layer
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak view] in view?.removeFromSuperview() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shown.opacity
        fade.toValue = 0
        fade.duration = Motion.reduced ? Self.reducedLeave : Self.crossfade
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "retire.opacity")
        CATransaction.commit()
    }

    private func arrive(_ view: NSView, _ frame: NSRect) {
        let frame = view.kitSnapped(frame)
        guard let layer = view.layer else {
            view.frame = frame
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = frame.offsetBy(dx: 0, dy: -Self.rise)
        let from = layer.position
        view.frame = frame
        CATransaction.commit()
        if let slide = Motion.kitCover.animation("position", from: NSValue(point: from), to: NSValue(point: layer.position)) {
            slide.fillMode = .backwards
            layer.add(slide, forKey: "position")
        }
        if let fade = KitCurve.easeOut(SideLook.growFade).animation("opacity", from: Swift.Float(0), to: layer.opacity) {
            fade.fillMode = .backwards
            layer.add(fade, forKey: "enter.opacity")
        }
    }

    override func layout() {
        let clock = CACurrentMediaTime()
        defer { FrameGaps.shared.note("agents", from: clock) }
        super.layout()
        let quiet = still
        still = false
        let animated = settled && !quiet && !entering
        let inset = Metrics.sideInset
        let pad = AgentsLayout.pad
        let side = AgentsLayout.row
        let folded = AgentsFolds.shared.folded
        let open = AgentsLayout.height(sections, folded: false, column: column)
        let closed = AgentsLayout.height(sections, folded: true, column: column)
        let card = NSRect(x: inset, y: 0, width: max(0, bounds.width - 2 * inset), height: max(0, bounds.height - AgentsLayout.below))
        glass.isHidden = shown.isEmpty
        glass.frame = card
        row.isHidden = shown.isEmpty
        row.frame = NSRect(x: card.minX + pad, y: AgentsLayout.rim, width: max(0, card.width - 2 * pad), height: side)
        let top = AgentsLayout.rim + side
        let viewport = max(0, open - AgentsLayout.margin - side)
        let seen = min(viewport, max(0, card.maxY - AgentsLayout.rim - top))
        scroll.frame = NSRect(x: card.minX + pad, y: top, width: max(0, card.width - 2 * pad), height: seen)
        let share = open - closed > 0.5 ? min(1, max(0, (room - closed) / (open - closed))) : (folded ? 0 : 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scroll.layer?.opacity = Swift.Float(motion?.folds == true ? share : (folded && !moving ? 0 : 1))
        CATransaction.commit()
        let content = AgentsLayout.content(sections)
        let documentHeight = max(viewport, content)
        list.frame = NSRect(x: 0, y: 0, width: scroll.frame.width, height: documentHeight)
        let resting = folded && motion == nil
        guard !resting || !(rows.isEmpty && heads.isEmpty && mores.isEmpty) else {
            wasFolded = true
            settled = true
            return
        }
        let arrives = animated && !wasFolded && motion?.folds != true
        let moves = arrives && !Motion.reduced
        let width = scroll.frame.width
        func place(_ view: NSView, at top: CGFloat, lead: CGFloat) {
            let frame = NSRect(x: lead, y: top + AgentsLayout.gap, width: max(0, width - lead), height: side)
            if view.frame == .zero {
                if arrives { arrive(view, frame) } else { view.frame = view.kitSnapped(frame) }
            } else {
                view.kitMove(to: frame, animated: moves, curve: Motion.kitCover)
            }
        }
        var y: CGFloat = 0
        spans = [:]
        var unfolded = Set<UUID>()
        for (session, section) in zip(shown, sections) {
            let from = y
            if section.headed, let head = heads[session.id] {
                place(head, at: y, lead: 0)
                y += AgentsLayout.step
                if section.open { unfolded.insert(session.id) }
            }
            for tab in inside[session.id] ?? [] {
                guard let view = rows[tab.id] else { continue }
                place(view, at: y, lead: AgentsLayout.indent)
                y += AgentsLayout.step
            }
            if let more = mores[session.id] {
                place(more, at: y, lead: AgentsLayout.indent)
                y += AgentsLayout.step
            }
            spans[session.id] = from...y
        }
        let opened = unfolded.subtracting(openDrawn).first
        openDrawn = unfolded
        guard !folded else {
            wasFolded = true
            settled = true
            return
        }
        let ids = shown.map(\.id) + AgentDesk.shared.pending.map(\.id)
        let limit = max(0, documentHeight - viewport)
        if ids != revealedFor || wasFolded {
            revealedFor = ids
            let pending = AgentDesk.shared.pending
            reveal(AgentsLayout.revealed(shown.map { ($0.id, $0.state(pending: pending).attention) }), limit: limit, viewport: viewport,
                   animated: moves)
        } else if let opened {
            reveal(opened, limit: limit, viewport: viewport, animated: moves)
        } else if scroll.contentView.bounds.minY > limit {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: limit))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        wasFolded = false
        settled = true
    }

    private func reveal(_ id: UUID?, limit: CGFloat, viewport: CGFloat, animated: Bool) {
        guard let id, let span = spans[id] else { return }
        let seen = scroll.contentView.bounds
        var y = seen.minY
        if span.upperBound > y + viewport { y = span.upperBound - viewport }
        if span.lowerBound < y { y = span.lowerBound }
        let target = NSPoint(x: 0, y: max(0, min(limit, y)))
        guard target.y != seen.minY else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                scroll.contentView.animator().setBoundsOrigin(target)
            }
        } else {
            scroll.contentView.scroll(to: target)
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    var benchState: [String: Any] {
        let card = cardFrameInColumn
        return ["room": Double(room), "moving": moving, "card": [card.minX, card.minY, card.width, card.height].map(Double.init),
                "radius": Double(glass.cornerRadius), "glass": !glass.isHidden, "fade": Double(scroll.layer?.opacity ?? 1),
                "rows": rows.count + heads.count + mores.count, "trace": trace,
                "listed": list.subviews.filter { !$0.isHidden }.sorted { $0.frame.minY < $1.frame.minY }.map { view in
                    [view.frame.minX, view.frame.minY, view.frame.width, view.frame.height].map(Double.init)
                },
                "faces": row.faceStates,
                "heads": shown.compactMap { session in
                    heads[session.id].map { head in head.benchState.merging(["id": session.id.uuidString]) { _, new in new } }
                },
                "top": row.benchState, "presence": presence, "fading": fading,
                "veil": veiled.map { [$0.from, $0.to, $0.lag, $0.length] } ?? [],
                "crossfading": layer?.animationKeys()?.contains(where: { $0.hasPrefix("transition") }) ?? false]
    }
}

struct AgentHeadLook: Equatable {
    struct Face: Equatable {
        var id: UUID
        var mood: AgentCharacter.Mood
        var attention: Bool
        var accent: Int
        var seed: UInt64
        var name: String
        var said = ""
    }

    var faces: [Face] = []
    var title = ""
    var line = ""
    var said = ""
    var attention = false
    var working = false
    var strong = true
    var chevron = false
    var open = false
    var folds = false
    var count: Int?
    var selected = false
    var roll = ""
    var closes = false
    var closeLabel = ""
    var presses = true
    var value: String?
}

final class AgentHeadView: KitHoverView {
    var press: (() -> Void)?
    var fold: (() -> Void)?
    var closing: (() -> Void)?
    var menus: (() -> NSMenu?)?
    var ground = RowGround() { didSet { if ground != oldValue { paint() } } }
    private(set) var look = AgentHeadLook()

    let count = SideCountView()
    let close = CloseSpotView()
    private(set) var zone = NSRect.zero
    private let plate = KitPlate(radius: AgentsLayout.corner)
    private let live = KitPlate(radius: AgentsLayout.corner)
    private var faces: [UUID: NSView] = [:]
    private let title = KitLabel("", font: .systemFont(ofSize: 13, weight: SideLook.headingWeight))
    private let line = AgentLineView()
    private let chevron = KitSymbol("chevron.right", style: KitSymbol.Style(size: SideLook.chevron, weight: .semibold), tint: Palette.NS.muted)
    private lazy var turn = KitTurnView(chevron)
    private var laidOnce = false
    private var zoneArea: NSTrackingArea?
    private var overZone = false { didSet { if overZone != oldValue { paint() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for view in [plate, live, title, line, turn, count, close] as [NSView] { addSubview(view) }
        live.isHidden = true
        title.setAccessibilityElement(false)
        chevron.setAccessibilityElement(false)
        chevron.opacity = SideLook.chevronTone
        close.label = "Close Tabs"
        close.toolTip = "Close Tabs"
        close.isHidden = true
        close.armed = false
        close.act = { [weak self] in self?.closing?() }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func show(_ next: AgentHeadLook) {
        guard next != look || !laidOnce else { return }
        let was = look
        let drawn = laidOnce
        look = next
        var kept = Set<UUID>()
        for face in next.faces {
            let view = faces[face.id] ?? {
                let made = AgentFaces.make()
                faces[face.id] = made
                addSubview(made, positioned: .below, relativeTo: title)
                return made
            }()
            AgentFaces.set(view, mood: face.mood, attention: face.attention, accent: face.accent, seed: face.seed)
            view.toolTip = next.faces.count > 1 ? face.name : face.said.isEmpty ? face.mood.title : face.said
            kept.insert(face.id)
        }
        for (id, view) in faces where !kept.contains(id) {
            view.removeFromSuperview()
            faces[id] = nil
        }
        title.font = .systemFont(ofSize: 13, weight: next.strong ? SideLook.headingWeight : .medium)
        title.text = next.title
        line.set(next.line, rolls: drawn && !was.roll.isEmpty && was.roll != next.roll)
        line.working = next.working
        turn.turn(to: next.open ? .pi / 2 : 0, curve: drawn && was.chevron && next.chevron ? Motion.kitCover : .none)
        if let count = next.count { self.count.count = count }
        count.fold(next.count != nil, curve: drawn ? Motion.kitCover : .none)
        close.label = next.closeLabel.isEmpty ? "Close Tabs" : next.closeLabel
        toolTip = next.said
        setAccessibilityLabel(next.said)
        setAccessibilityValue(next.value)
        if next.folds, next.chevron {
            setAccessibilityCustomActions([NSAccessibilityCustomAction(name: next.open ? "Fold" : "Unfold") { [weak self] in
                self?.fold?()
                return true
            }])
        } else {
            setAccessibilityCustomActions(nil)
        }
        paint()
        needsLayout = true
    }

    private func paint() {
        let ink = ground.ink
        plate.ink = ink
        plate.fill = hovering && look.presses && !look.selected ? AgentsLayout.hover : nil
        live.isHidden = !look.selected
        if look.selected { SelectedLook.dress(live, greys: ground.greys, ink: ink) }
        title.ink = ink
        line.ink = ink
        chevron.ink = ink
        chevron.tint = overZone ? KitColor.ink : Palette.NS.muted
        chevron.opacity = overZone ? 1 : SideLook.chevronTone
        count.dress(ink)
        close.ink = ink
        let closes = look.closes && hovering
        if close.isHidden == closes {
            if laidOnce, Motion.kitQuick.animates { close.layer?.kitTransition(Motion.kitQuick) }
            close.isHidden = !closes
            needsLayout = true
        }
        close.armed = closes
        count.yields = closes
        if look.attention {
            title.color = Palette.NS.unsafe
            title.opacity = 1
            line.color = Palette.NS.unsafe
            line.opacity = 0.86
        } else {
            let tone: KitTone = look.strong || look.selected ? .strong : hovering ? .ink : .title
            title.color = tone.base
            title.opacity = tone.opacity
            line.color = Palette.NS.muted
            line.opacity = SideLook.bylineTone
        }
    }

    var faceStates: [[String: Any]] {
        look.faces.compactMap { face in
            guard let view = faces[face.id] as? AgentCharacterFace else { return nil }
            return view.benchState
        }
    }

    var benchState: [String: Any] {
        func box(_ rect: NSRect) -> [Double] {
            guard let window else { return [] }
            let frame = convert(rect, to: nil)
            return [frame.minX, window.frame.height - frame.maxY, frame.width, frame.height].map(Double.init)
        }
        return ["title": look.title, "line": look.line, "count": look.count.map { $0 as Any } ?? NSNull(), "countText": count.text,
                "countShown": look.count != nil && count.showing, "close": !close.isHidden, "chevron": look.chevron, "open": look.open,
                "selected": look.selected, "attention": look.attention, "hovering": hovering, "rolling": line.rolling, "rolls": line.rolls,
                "box": box(bounds), "countBox": box(count.frame), "closeBox": box(close.frame), "chevronBox": box(zone),
                "titleBox": box(title.frame), "lineBox": box(line.frame)]
    }

    override func layout() {
        super.layout()
        plate.kitSetFrame(bounds)
        live.kitSetFrame(bounds)
        let height = bounds.height
        let side = SideLook.rowMark
        var x = AgentsLayout.lead
        for face in look.faces {
            faces[face.id]?.frame = NSRect(x: x, y: (height - side) / 2, width: side, height: side)
            x += AgentsLayout.faceStep
        }
        if !look.faces.isEmpty { x += side - AgentsLayout.faceStep + SideLook.markGap }
        let slots = AgentsLayout.rowSlots(width: bounds.width, height: height)
        close.side = slots.close.width
        close.frame = slots.close
        var right = bounds.width - SideCountView.tail
        if look.count != nil {
            let width = count.width
            count.kitSetFrame(NSRect(x: right - width, y: (height - SideCountView.height) / 2, width: width, height: SideCountView.height))
            right -= width + SideCountView.gap
        }
        if !close.isHidden { right = min(right, close.frame.minX) }
        let stacked = !look.line.isEmpty
        let block = SideLook.titleLine + (stacked ? SideLook.bylineLine : 0)
        let top = (height - block) / 2
        let chevronSize = chevron.intrinsicContentSize
        let reserve = look.chevron ? chevronSize.width + SideLook.chevronGap : 0
        let room = max(0, right - x - reserve)
        let width = min(room, ceil(title.intrinsicContentSize.width))
        title.kitSetFrame(NSRect(x: x, y: top, width: width, height: SideLook.titleLine))
        turn.isHidden = !look.chevron
        turn.kitSetFrame(NSRect(x: x + width + SideLook.chevronGap, y: top + (SideLook.titleLine - chevronSize.height) / 2,
                                width: chevronSize.width, height: chevronSize.height))
        line.isHidden = !stacked
        line.kitSetFrame(NSRect(x: x, y: top + SideLook.titleLine, width: max(0, right - x), height: SideLook.bylineLine))
        zone = look.chevron ? NSRect(x: x + width, y: 0, width: chevronSize.width + 2 * SideLook.chevronGap, height: top + SideLook.titleLine) : .zero
        trackZone()
        laidOnce = true
    }

    private func trackZone() {
        let wanted = look.folds ? zone : .zero
        guard zoneArea?.rect ?? .zero != wanted else { return }
        if let zoneArea { removeTrackingArea(zoneArea) }
        zoneArea = nil
        overZone = false
        guard !wanted.isEmpty else { return }
        let made = NSTrackingArea(rect: wanted, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(made)
        zoneArea = made
    }

    func folds(at point: NSPoint) -> Bool { look.folds && look.chevron && zone.contains(point) }

    override func hoverChanged() {
        if !hovering { overZone = false }
        paint()
    }

    override func mouseEntered(with event: NSEvent) {
        if event.type == .mouseEntered, let zoneArea, event.trackingArea === zoneArea { overZone = true } else { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.type == .mouseExited, let zoneArea, event.trackingArea === zoneArea { overZone = false } else { super.mouseExited(with: event) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        if !close.isHidden, close.frame.contains(convert(point, from: superview)) { return close }
        return self
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        guard bounds.contains(at) else { return }
        if folds(at: at) { fold?() } else { press?() }
    }

    override func accessibilityPerformPress() -> Bool {
        press?()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? { menus?() }
}

final class AgentLineView: NSView {
    var text: String {
        get { label.text }
        set { set(newValue, rolls: false) }
    }
    var color: NSColor {
        get { label.color }
        set { label.color = newValue }
    }
    var opacity: Double {
        get { label.opacity }
        set { label.opacity = newValue }
    }
    var ink: KitInk {
        get { label.ink }
        set { label.ink = newValue }
    }
    var working = false { didSet { if working != oldValue { sweep() } } }
    var rolling: Bool { leaving != nil }
    private(set) var rolls = 0

    private let label = KitLabel("", font: .systemFont(ofSize: SideLook.byline), color: KitColor.muted)
    private var leaving: KitLabel?
    private let shine = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        label.wantsLayer = true
        addSubview(label)
        label.setAccessibilityElement(false)
        shine.startPoint = CGPoint(x: 0, y: 0.5)
        shine.endPoint = CGPoint(x: 1, y: 0.5)
        shine.colors = [NSColor(white: 0, alpha: 1).cgColor, NSColor(white: 0, alpha: 0.45).cgColor, NSColor(white: 0, alpha: 1).cgColor]
        shine.locations = [-0.3, -0.15, 0]
        shine.actions = ["bounds": NSNull(), "position": NSNull(), "locations": NSNull()]
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(_ text: String, rolls: Bool) {
        guard text != label.text else { return }
        let was = label.text
        let curve = Motion.kitRoll
        guard rolls, !was.isEmpty, window != nil, bounds.height > 0, curve.animates else {
            label.text = text
            return
        }
        leaving?.removeFromSuperview()
        self.rolls += 1
        let ghost = KitLabel(was, font: .systemFont(ofSize: SideLook.byline), color: label.color)
        ghost.wantsLayer = true
        ghost.opacity = label.opacity
        ghost.ink = label.ink
        ghost.frame = label.frame
        ghost.setAccessibilityElement(false)
        addSubview(ghost)
        leaving = ghost
        label.text = text
        let rise = Double(bounds.height)
        if let layer = label.layer {
            if let slide = curve.animation("transform.translation.y", from: rise, to: 0) { layer.add(slide, forKey: "roll.slide") }
            if let fade = curve.animation("opacity", from: Swift.Float(0), to: layer.opacity) { layer.add(fade, forKey: "roll.fade") }
        }
        guard let layer = ghost.layer else {
            ghost.removeFromSuperview()
            leaving = nil
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak ghost] in
            ghost?.removeFromSuperview()
            if let self, self.leaving === ghost { self.leaving = nil }
        }
        if let slide = curve.animation("transform.translation.y", from: 0, to: -rise) {
            slide.fillMode = .forwards
            slide.isRemovedOnCompletion = false
            layer.add(slide, forKey: "roll.slide")
        }
        if let fade = curve.animation("opacity", from: layer.opacity, to: Swift.Float(0)) {
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: "roll.fade")
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        label.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shine.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, working { sweep() }
    }

    private func sweep() {
        shine.removeAnimation(forKey: "sweep")
        guard working, !Motion.calm, window != nil else {
            layer?.mask = nil
            return
        }
        layer?.mask = shine
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.3, -0.15, 0]
        sweep.toValue = [1, 1.15, 1.3]
        sweep.duration = 1.9
        sweep.repeatCount = .infinity
        shine.add(sweep, forKey: "sweep")
    }
}

final class AgentRowView: KitHoverView {
    let browser: Browser
    let tab: Tab
    var ground = RowGround() { didSet { if ground != oldValue { refresh() } } }
    private let hoverGround = KitPlate(radius: AgentsLayout.rowCorner)
    private let liveGround = KitPlate(radius: AgentsLayout.rowCorner)
    private let mark = RowMarkView()
    private let title = KitLabel("", font: .systemFont(ofSize: 13))
    private let dot = KitBox(fill: nil, corners: .capsule)
    let close = CloseSpotView()
    private var start: NSPoint?
    private lazy var reads = KitReads { [weak self] in self?.refresh() }

    init(browser: Browser, tab: Tab) {
        self.browser = browser
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        mark.size = SideLook.rowMark
        for view in [hoverGround, liveGround, mark, title, dot, close] as [NSView] { addSubview(view) }
        title.setAccessibilityElement(false)
        close.toolTip = "Close Tab"
        close.act = { [weak self] in
            guard let self else { return }
            self.browser.closeAgentTab(self.tab)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func refresh() {
        reads.track { paint() }
    }

    private func paint() {
        let live = browser.activeID == tab.id
        let ink = ground.ink
        mark.icon = tab.icon
        mark.letter = tab.monogram
        mark.ink = ink
        title.text = tab.title.isEmpty ? (tab.pageAddress?.host() ?? "New Tab") : tab.title
        let tone: KitTone = live ? .strong : hovering ? .ink : .title
        title.color = tone.base
        title.opacity = tone.opacity
        title.ink = ink
        hoverGround.isHidden = live || !hovering
        hoverGround.fill = ground.greys.hover
        hoverGround.ink = ink
        liveGround.isHidden = !live
        SelectedLook.dress(liveGround, greys: ground.greys, ink: ink)
        close.ink = ink
        close.isHidden = !hovering
        if hovering {
            dot.isHidden = true
        } else if tab.agentActing != nil {
            dot.isHidden = false
            dot.fill = KitColor.ink.withAlphaComponent(0.55)
            dot.stroke = nil
            dot.toolTip = tab.agentActing
        } else if tab.agentFinished != nil && !tab.agentSeen {
            dot.isHidden = false
            dot.fill = nil
            dot.stroke = KitColor.muted
            dot.strokeWidth = 1
            dot.toolTip = "Not opened yet"
        } else {
            dot.isHidden = true
        }
        toolTip = tab.agentActing ?? tab.title
        setAccessibilityLabel(tab.title)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        hoverGround.kitSetFrame(bounds)
        liveGround.kitSetFrame(bounds)
        let metrics = AgentsLayout.rowSlots(width: bounds.width, height: bounds.height)
        mark.frame = metrics.mark
        close.side = metrics.close.width
        close.frame = metrics.close
        dot.frame = metrics.dot
        let x = mark.frame.maxX + SideLook.markGap
        let right = !close.isHidden ? close.frame.minX : !dot.isHidden ? dot.frame.minX - SideLook.markGap : bounds.width - metrics.tail
        let room = max(0, right - x)
        let size = title.measure(width: room)
        title.frame = kitSnap(NSRect(x: x, y: (bounds.height - size.height) / 2, width: min(room, size.width), height: size.height))
    }

    override func hoverChanged() { refresh() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        if !close.isHidden, close.frame.contains(convert(point, from: superview)) { return close }
        return self
    }

    override func mouseDown(with event: NSEvent) { start = event.locationInWindow }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil }
        guard let start else { return }
        let travel = CGSize(width: event.locationInWindow.x - start.x, height: event.locationInWindow.y - start.y)
        if hypot(travel.width, travel.height) >= 14 {
            if AgentRowView.leftFolder(travel, reach: AgentsLayout.row * 2) { browser.keepAgentTab(tab) }
            return
        }
        browser.bring(tab)
    }

    static func leftFolder(_ travel: CGSize, reach: CGFloat) -> Bool {
        abs(travel.height) > reach || abs(travel.width) > 60
    }

    override func accessibilityPerformPress() -> Bool {
        browser.bring(tab)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(PlusMenu.item("Keep Tab") { [weak self] in if let self { browser.keepAgentTab(tab) } })
        menu.addItem(PlusMenu.item("Close Tab") { [weak self] in if let self { browser.closeAgentTab(tab) } })
        return menu
    }
}

final class AgentMoreRowView: KitHoverView {
    var act: (() -> Void)?
    var count = 0 { didSet { if count != oldValue { label.text = count == 1 ? "1 more tab" : "\(count) more tabs"; setAccessibilityLabel(label.text) } } }
    var ground = RowGround() { didSet { if ground != oldValue { paint() } } }
    private let plate = KitPlate(radius: AgentsLayout.rowCorner)
    private let symbol = KitSymbol("ellipsis", style: KitSymbol.Style(size: 11, weight: .semibold))
    private let label = KitLabel("", font: .systemFont(ofSize: 13), color: KitColor.muted)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for view in [plate, symbol, label] as [NSView] { addSubview(view) }
        label.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func paint() {
        plate.fill = hovering ? ground.greys.hover : nil
        plate.ink = ground.ink
        label.color = hovering ? KitColor.ink : KitColor.muted
        label.ink = ground.ink
        symbol.tint = hovering ? KitColor.ink : KitColor.muted
        symbol.ink = ground.ink
    }

    override func layout() {
        super.layout()
        plate.kitSetFrame(bounds)
        let side = SideLook.rowMark
        let size = symbol.intrinsicContentSize
        symbol.frame = NSRect(x: AgentsLayout.rowLead + (side - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let x = AgentsLayout.rowLead + side + SideLook.markGap
        let room = max(0, bounds.width - 10 - x)
        let measured = label.measure(width: room)
        label.frame = kitSnap(NSRect(x: x, y: (bounds.height - measured.height) / 2, width: min(room, measured.width), height: measured.height))
    }

    override func hoverChanged() { paint() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { act?() }
    }

    override func accessibilityPerformPress() -> Bool {
        act?()
        return true
    }
}

@MainActor
enum AgentFaces {
    static func make() -> NSView { AgentCharacterFace() }

    static func set(_ view: NSView, mood: AgentCharacter.Mood, attention: Bool, accent: Int, seed: UInt64) {
        guard let face = view as? AgentCharacterFace else { return }
        face.seed = seed
        face.mood = mood
        face.colour = attention ? Palette.NS.unsafe : AgentCharacter.accentColor(accent)
    }

    static func show(_ shown: Bool, in view: NSView) {
        if let face = view as? AgentCharacterFace { face.columnShown = shown }
        for sub in view.subviews { show(shown, in: sub) }
    }
}
