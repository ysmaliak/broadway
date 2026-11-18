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
    private let store: UserDefaults?

    init(store: UserDefaults? = nil) {
        self.store = store
        store?.removeObject(forKey: Self.retired)
        folded = !(store?.bool(forKey: Self.key) ?? false)
    }

    func toggle() { folded.toggle() }
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
    }

    enum Press: Equatable {
        case fold, question
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

    static func rows(_ section: Section) -> Int {
        let shown = shown(section.rows, whole: section.whole)
        return shown + (shown < section.rows ? 1 : 0)
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

    var id: UUID { link.id }

    var closes: Bool { !link.live && !tabs.isEmpty }

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
        let loose = pending.first { question in question.task == link.id && !tabs.contains { $0.id == question.tab } }
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

extension Browser {
    var agentsInFront: Bool { Browsers.front === self || Browsers.front == nil }

    func agentSessions(links: [AgentLink], front: Bool) -> [AgentSession] {
        let sessions = links.compactMap { link -> AgentSession? in
            let everywhere = AgentBoard.allTabs(of: link.id)
            let mine = everywhere.filter { $0.browser === self }.map(\.tab)
            if mine.isEmpty {
                return everywhere.isEmpty && (link.live || link.codex != nil) && link.announced && front ? AgentSession(link: link, tabs: []) : nil
            }
            return AgentSession(link: link, tabs: mine)
        }
        return sessions.enumerated().sorted { one, two in
            one.element.link.connected == two.element.link.connected ? one.offset < two.offset : one.element.link.connected < two.element.link.connected
        }.map(\.element)
    }

    func agentSections(_ sessions: [AgentSession]) -> [AgentsLayout.Section] {
        let folds = AgentsFolds.shared
        let headed = AgentsLayout.headed(sessions.count)
        return sessions.map { AgentsLayout.Section(rows: $0.tabs.count, whole: folds.whole.contains($0.id), headed: headed) }
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
        let asked = session.asking(pending: AgentDesk.shared.pending)
        if let tab = asked ?? session.tabs.first(where: { $0.agentActing != nil }) ?? session.tabs.first { bring(tab) }
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
    let browser: Browser
    var column: CGFloat = 700 { didSet { if column != oldValue { needsLayout = true } } }
    var ground = RowGround() { didSet { if ground != oldValue { reground() } } }
    var facesShown = true { didSet { if facesShown != oldValue { AgentFaces.show(facesShown, in: self) } } }
    var onRoom: (() -> Void)?
    private(set) var settled = false
    private(set) var room: CGFloat = 0
    private(set) var trace: [[Double]] = []

    private let glass = NSGlassEffectView()
    private let row = AgentHeadView()
    private let scroll = NSScrollView()
    private let list = KitFlippedView()
    private var heads: [UUID: AgentHeadView] = [:]
    private var rows: [Tab.ID: AgentRowView] = [:]
    private var mores: [UUID: AgentMoreRowView] = [:]
    private var shown: [AgentSession] = []
    private var sections: [AgentsLayout.Section] = []
    private var spans: [UUID: ClosedRange<CGFloat>] = [:]
    private var revealedFor: [UUID] = []
    private var wasFolded = true
    private var aimedColumn: CGFloat?
    private var aimedFolded: Bool?
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

    var cardFrameInColumn: NSRect { convert(glass.frame, to: superview) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        glass.tintColor = Palette.NS.glassTint
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, let motion {
            stopLink()
            self.motion = nil
            room = motion.to
        }
    }

    func aim(_ goal: CGFloat) {
        let sameColumn = aimedColumn == column
        aimedColumn = column
        let folded = AgentsFolds.shared.folded
        let folds = aimedFolded.map { $0 != folded } ?? false
        aimedFolded = folded
        let target = motion?.to ?? room
        guard goal != target else { return }
        let moves = settled && sameColumn && window != nil && room > 0 && goal > 0
        guard moves, !Motion.reduced else {
            let crossfade = moves && folds
            stopLink()
            motion = nil
            room = goal
            if crossfade { fade() }
            later()
            return
        }
        let now = CACurrentMediaTime()
        let at = shownRoom(at: now)
        let speed = shownSpeed(at: now)
        let span = goal - at.room
        if motion == nil {
            trace = []
            traceStart = now
        }
        motion = (at.room, goal, now, Motion.kitCover, abs(span) > 0.01 ? speed / Double(span) : 0, folds || (motion?.folds ?? false))
        room = at.room
        startLink()
    }

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
        shown = browser.agentSessions(links: AgentLinks.shared.links, front: browser.agentsInFront)
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
        if keepsRows {
            for (index, session) in shown.enumerated() {
                let section = sections[index]
                let state = states[index]
                if section.headed {
                    let head = heads[session.id] ?? {
                        let made = AgentHeadView()
                        made.listed = true
                        heads[session.id] = made
                        list.addSubview(made)
                        return made
                    }()
                    var look = AgentHeadLook()
                    look.faces = [face(session, state, now: now)]
                    look.title = session.link.title
                    look.line = state.line
                    look.attention = state.attention
                    look.working = state.working
                    look.said = "\(session.link.title): \(state.line)"
                    look.strong = false
                    look.closes = session.closes
                    look.closeLabel = "Close \(session.link.title)'s tabs"
                    look.presses = session.link.codex != nil || !session.tabs.isEmpty
                    head.ground = ground
                    head.show(look)
                    head.press = { [weak browser] in browser?.pressAgent(session) }
                    head.closing = { [weak browser] in browser?.closeAgentTabs(session) }
                    head.menus = { [weak browser] in browser?.agentMenu(session) }
                    keptHeads.insert(session.id)
                }
                let count = AgentsLayout.shown(session.tabs.count, whole: section.whole)
                for tab in session.tabs.prefix(count) {
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
                if count < session.tabs.count {
                    let more = mores[session.id] ?? {
                        let made = AgentMoreRowView()
                        mores[session.id] = made
                        list.addSubview(made)
                        return made
                    }()
                    let id = session.id
                    more.ground = ground
                    more.count = session.tabs.count - count
                    more.act = { KitChange.eased { _ = AgentsFolds.shared.whole.insert(id) } }
                    keptMores.insert(session.id)
                }
            }
        }
        for (id, view) in heads where !keptHeads.contains(id) {
            heads[id] = nil
            retire(view)
        }
        for (id, view) in rows where !keptRows.contains(id) {
            rows[id] = nil
            retire(view)
        }
        for (id, view) in mores where !keptMores.contains(id) {
            mores[id] = nil
            retire(view)
        }
        if !facesShown { AgentFaces.show(false, in: self) }
        needsLayout = true
        superview?.needsLayout = true
    }

    private func retire(_ view: NSView) {
        if settled, !AgentsFolds.shared.folded { view.kitRetire() } else { view.removeFromSuperview() }
    }

    override func layout() {
        let clock = CACurrentMediaTime()
        defer { FrameGaps.shared.note("agents", from: clock) }
        super.layout()
        let animated = settled && !Motion.reduced
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
        let moves = animated && !wasFolded && motion?.folds != true
        let lead = AgentsLayout.indent
        let inner = max(0, scroll.frame.width - lead)
        func place(_ view: NSView, at top: CGFloat) {
            let y = top + AgentsLayout.gap
            let frame = NSRect(x: lead, y: y, width: inner, height: side)
            if view.frame == .zero, animated, !wasFolded { view.kitEnter(frame) } else { view.kitMove(to: frame, animated: moves) }
        }
        var y: CGFloat = 0
        spans = [:]
        for (session, section) in zip(shown, sections) {
            let from = y
            if section.headed, let head = heads[session.id] {
                place(head, at: y)
                y += AgentsLayout.step
            }
            let count = AgentsLayout.shown(session.tabs.count, whole: section.whole)
            for tab in session.tabs.prefix(count) {
                guard let view = rows[tab.id] else { continue }
                place(view, at: y)
                y += AgentsLayout.step
            }
            if count < session.tabs.count, let more = mores[session.id] {
                place(more, at: y)
                y += AgentsLayout.step
            }
            spans[session.id] = from...y
        }
        guard !folded else {
            wasFolded = true
            settled = true
            return
        }
        let ids = shown.map(\.id) + AgentDesk.shared.pending.map(\.id)
        let limit = max(0, documentHeight - viewport)
        if ids != revealedFor || wasFolded {
            revealedFor = ids
            reveal(limit: limit, viewport: viewport, animated: animated && !wasFolded)
        } else if scroll.contentView.bounds.minY > limit {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: limit))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        wasFolded = false
        settled = true
    }

    private func reveal(limit: CGFloat, viewport: CGFloat, animated: Bool) {
        let pending = AgentDesk.shared.pending
        guard let id = AgentsLayout.revealed(shown.map { ($0.id, $0.state(pending: pending).attention) }), let span = spans[id] else { return }
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
    var closes = false
    var closeLabel = ""
    var presses = true
    var value: String?
}

final class AgentHeadView: KitHoverView {
    var press: (() -> Void)?
    var closing: (() -> Void)?
    var menus: (() -> NSMenu?)?
    var ground = RowGround() { didSet { if ground != oldValue { paint() } } }
    var listed = false {
        didSet {
            plate.radius = listed ? AgentsLayout.rowCorner : AgentsLayout.corner
            needsLayout = true
        }
    }
    private(set) var look = AgentHeadLook()

    private let plate = KitPlate(radius: AgentsLayout.corner)
    private var faces: [UUID: NSView] = [:]
    private let title = KitLabel("", font: .systemFont(ofSize: 13, weight: SideLook.headingWeight))
    private let line = AgentLineView()
    private let chevron = KitSymbol("chevron.right", style: KitSymbol.Style(size: SideLook.chevron, weight: .semibold), tint: Palette.NS.muted)
    private lazy var turn = KitTurnView(chevron)
    private let close = AgentCloseKeyView()
    private var laidOnce = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for view in [plate, title, line, turn, close] as [NSView] { addSubview(view) }
        title.setAccessibilityElement(false)
        chevron.setAccessibilityElement(false)
        chevron.opacity = SideLook.chevronTone
        close.toolTip = "Close Tabs"
        close.isHidden = true
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
        line.text = next.line
        line.working = next.working
        turn.turn(to: next.open ? .pi / 2 : 0, curve: laidOnce && was.chevron && next.chevron ? Motion.kitSettle : .none)
        close.isHidden = !next.closes
        close.setAccessibilityLabel(next.closeLabel)
        toolTip = next.said
        setAccessibilityLabel(next.said)
        setAccessibilityValue(next.value)
        paint()
        needsLayout = true
    }

    private func paint() {
        let ink = ground.ink
        plate.ink = ink
        plate.fill = hovering && look.presses ? (listed ? ground.greys.hover : AgentsLayout.hover) : nil
        title.ink = ink
        line.ink = ink
        chevron.ink = ink
        if look.attention {
            title.color = Palette.NS.unsafe
            title.opacity = 1
            line.color = Palette.NS.unsafe
            line.opacity = 0.86
        } else {
            let tone: KitTone = look.strong ? .strong : hovering ? .ink : .title
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

    override func layout() {
        super.layout()
        plate.kitSetFrame(bounds)
        let height = bounds.height
        let side = SideLook.rowMark
        var x = listed ? AgentsLayout.rowLead : AgentsLayout.lead
        for face in look.faces {
            faces[face.id]?.frame = NSRect(x: x, y: (height - side) / 2, width: side, height: side)
            x += AgentsLayout.faceStep
        }
        if !look.faces.isEmpty { x += side - AgentsLayout.faceStep + SideLook.markGap }
        var right = bounds.width - 10
        if look.closes {
            close.frame = NSRect(x: bounds.width - 8 - Metrics.closeSide, y: (height - Metrics.closeSide) / 2,
                                 width: Metrics.closeSide, height: Metrics.closeSide)
            right = close.frame.minX - 9
        }
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
        laidOnce = true
    }

    override func hoverChanged() { paint() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        if look.closes, close.frame.contains(convert(point, from: superview)) { return close }
        return self
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press?()
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
        set { label.text = newValue }
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

    private let label = KitLabel("", font: .systemFont(ofSize: SideLook.byline), color: KitColor.muted)
    private let shine = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
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
    private let close = CloseSpotView()
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

final class AgentCloseKeyView: KitHoverView {
    var act: (() -> Void)?
    private let circle = KitBox(fill: nil, corners: .capsule)
    private let mark = KitSymbol("xmark", style: KitSymbol.Style(size: 10, weight: .bold))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(circle)
        addSubview(mark)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func paint() {
        circle.fill = KitColor.ink.withAlphaComponent(hovering ? 0.1 : 0)
        mark.tint = KitColor.ink
        mark.opacity = hovering ? 1 : 0.8
    }

    private func press(_ on: Bool) {
        let scale: CGFloat = on && !Motion.reduced ? 0.9 : 1
        let mid = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        let squeeze = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0),
                                                              CATransform3DMakeScale(scale, scale, 1)), mid)
        layer?.kitAnimate("transform", to: NSValue(caTransform3D: squeeze), curve: on ? Motion.kitQuick : Motion.kitSettle, key: "press")
    }

    override func layout() {
        super.layout()
        circle.frame = bounds
        let size = mark.intrinsicContentSize
        mark.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func hoverChanged() { paint() }
    override func mouseDown(with event: NSEvent) { press(true) }

    override func mouseUp(with event: NSEvent) {
        press(false)
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
