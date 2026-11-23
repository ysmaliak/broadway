import AppKit
import Combine

@MainActor
enum SideSigns {
    static func popupSign(browser: Browser, tab: Tab) -> NSView { PopupSignView(browser: browser, tab: tab) }
    static func translateSign(tab: Tab) -> NSView { TranslateSignView(tab: tab) }
    static func callTimeLeft(browser: Browser, tab: Tab, changed: @escaping () -> Void) -> NSView {
        CallLeftSign(browser: browser, tab: tab, changed: changed)
    }
    static func agentFace(tab: Tab) -> NSView { AgentFaceSign(tab: tab) }
    static func peekBadge(page: Tab, size: CGFloat) -> NSView { PeekBadgeView(page: page, size: size) }
    static func tabAddressField(browser: Browser) -> NSView { TabAddressFieldView(browser: browser) }
    static func pinField(browser: Browser, tab: Tab) -> NSView { PinFieldView(browser: browser, tab: tab) }

    static func pinMeeting(browser: Browser, address: URL?, editing: Bool) -> NSView {
        PinMeetingView(browser: browser, address: address, editing: editing)
    }

    static func update(meeting: NSView, address: URL?, editing: Bool, width: CGFloat, height: CGFloat) {
        guard let view = meeting as? PinMeetingView else { return }
        view.address = address
        view.editing = editing
    }

    static func liveStatus(browser: Browser, id: UUID, collapsed: Bool) -> NSView {
        LiveStatusView(browser: browser, id: id, collapsed: collapsed)
    }

    static func update(liveStatus: NSView, collapsed: Bool) {
        (liveStatus as? LiveStatusView)?.collapsed = collapsed
    }

    static func split(browser: Browser, left: Tab, right: Tab, height: CGFloat) -> NSView {
        SplitSignView(browser: browser, left: left, right: right, height: height)
    }

    static func liveMore(browser: Browser, id: UUID) -> NSView {
        LiveMoreView(browser: browser, id: id)
    }

    static func liveNote(browser: Browser, id: UUID, height: CGFloat, interactive: Bool) -> NSView {
        LiveNoteView(browser: browser, id: id, height: height, interactive: interactive)
    }

    static func update(_ sign: NSView, colour: KitTone, ground: RowGround) {
        let named: NSAppearance.Name = ground.dark ? .darkAqua : .aqua
        if sign.appearance?.name != named { sign.appearance = NSAppearance(named: named) }
        switch sign {
        case let sign as SignView:
            sign.colour = colour.base.kitResolved(dark: ground.dark).withAlphaComponent(colour.opacity)
            sign.ink = ground.ink
            sign.refresh()
        case let sign as AgentFaceSign:
            sign.colour = colour.base.kitResolved(dark: ground.dark).withAlphaComponent(colour.opacity)
            sign.ink = ground.ink
        case let sign as SideGrounded:
            sign.ground = ground
        default:
            break
        }
    }
}

@MainActor
protocol SideGrounded: AnyObject {
    var ground: RowGround { get set }
}

final class AgentFaceSign: NSView {
    weak var tab: Tab?
    var colour: NSColor = KitColor.ink { didSet { if colour != oldValue { refresh() } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { refresh() } } }
    private let face = AgentCharacterFace()
    private var watch: AnyCancellable?

    init(tab: Tab) {
        self.tab = tab
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        addSubview(face)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        watch = kitTrack { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }
    override var fittingSize: NSSize { intrinsicContentSize }

    private func refresh() {
        guard let tab else { return }
        let mood = tab.agentMood ?? .reading
        face.seed = tab.agentTask.map { AgentLink(id: $0, name: "", key: .connection($0), connected: .distantPast).seed } ?? 0
        face.mood = tab.driving ? .driving : AgentCharacter.Mood(mood)
        face.colour = mood == .waving ? Palette.NS.unsafe : colour
        face.ink = ink
        let said = tab.agentActing ?? mood.title
        toolTip = said
        setAccessibilityLabel("Agent: \(said)")
    }

    override func layout() {
        super.layout()
        face.frame = bounds
    }
}

final class CallLeftSign: NSView {
    let browser: Browser
    weak var tab: Tab?
    private let minutes = CallMinutesView()
    private var watch: AnyCancellable?
    private let changed: () -> Void

    init(browser: Browser, tab: Tab, changed: @escaping () -> Void) {
        self.browser = browser
        self.tab = tab
        self.changed = changed
        super.init(frame: .zero)
        addSubview(minutes)
        watch = kitTrack { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var left: Int? {
        guard browser.prefs.nextMeeting, let address = tab?.address, MeetingLink.service(of: address) != nil else { return nil }
        return Meetings.shared.minutesLeft(on: address)
    }

    override var fittingSize: NSSize { left == nil ? .zero : minutes.intrinsicContentSize }

    private func refresh() {
        let now = left
        minutes.isHidden = now == nil
        if let now { minutes.minutes = now }
        if superview != nil { changed() }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        minutes.frame = bounds
    }
}

final class PeekBadgeView: NSView {
    weak var page: Tab?
    var size: CGFloat { didSet { if size != oldValue { needsLayout = true } } }
    private let plate = KitBox(fill: Palette.NS.ground)
    private let mark = MarkView()
    private var watch: AnyCancellable?

    init(page: Tab, size: CGFloat) {
        self.page = page
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        plate.stroke = Palette.NS.hairline
        plate.strokeWidth = 0.5
        plate.wantsLayer = true
        plate.layer?.shadowColor = NSColor.black.cgColor
        plate.layer?.shadowOpacity = 0.12
        plate.layer?.shadowRadius = 1.5
        plate.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        plate.layer?.masksToBounds = false
        addSubview(plate)
        addSubview(mark)
        setAccessibilityElement(false)
        watch = kitTrack { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }
    override var fittingSize: NSSize { intrinsicContentSize }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func refresh() {
        guard let page else { return }
        mark.icon = page.icon
        mark.letter = page.monogram
    }

    override func layout() {
        super.layout()
        let box = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        plate.corners = .radius(size * 0.3)
        plate.kitSetFrame(box)
        mark.size = size * 0.7
        let inner = size * 0.7
        mark.kitSetFrame(NSRect(x: box.midX - inner / 2, y: box.midY - inner / 2, width: inner, height: inner))
    }
}

final class TabAddressFieldView: NSTextField {
    let keys: TabAddressFieldKeys
    let browser: Browser
    private var watch: AnyCancellable?
    private var claimed = false

    init(browser: Browser) {
        self.browser = browser
        keys = TabAddressFieldKeys(browser: browser)
        super.init(frame: .zero)
        delegate = keys
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 13)
        textColor = Palette.NS.ink
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        lineBreakMode = .byClipping
        stringValue = browser.tabDraft
        watch = kitObserve(initial: false, { [weak browser] in browser?.tabDraft }) { [weak self] _ in self?.follow() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func follow() {
        if !keys.typing, stringValue != browser.tabDraft { stringValue = browser.tabDraft }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            keys.unwatch()
            return
        }
        keys.watch(self)
        TabOffersPanel.follow(browser, anchor: self)
        guard !claimed else { return }
        claimed = true
        keys.claimed = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            guard let editor = self.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: Palette.NS.ink.withAlphaComponent(0.11),
                .foregroundColor: Palette.NS.ink,
            ]
            editor.selectAll(nil)
        }
    }
}

final class PinFieldView: NSTextField {
    let keys: PinFieldKeys
    weak var tab: Tab?
    private var watch: AnyCancellable?
    private var claimed = false

    init(browser: Browser, tab: Tab) {
        self.tab = tab
        keys = PinFieldKeys(browser: browser, tab: tab)
        super.init(frame: .zero)
        delegate = keys
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        alignment = .center
        font = .systemFont(ofSize: 12, weight: .medium)
        textColor = Palette.NS.ink
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        stringValue = tab.pin ?? ""
        watch = kitObserve(initial: false, { [weak tab] in tab?.pin }) { [weak self] _ in self?.follow() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func follow() {
        guard let tab else { return }
        if !keys.typing, stringValue != tab.pin ?? "" { stringValue = tab.pin ?? "" }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !claimed else { return }
        claimed = true
        keys.claimed = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            guard let editor = self.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: Palette.NS.ink.withAlphaComponent(0.12),
                .foregroundColor: Palette.NS.ink,
            ]
            editor.selectAll(nil)
        }
    }
}

final class PinMeetingView: NSView {
    let browser: Browser
    var address: URL? { didSet { if address != oldValue { refresh() } } }
    var editing: Bool { didSet { if editing != oldValue { refresh() } } }
    private let badge: PinMeetingBadgeView
    private var watch: AnyCancellable?
    private var shown = false

    init(browser: Browser, address: URL?, editing: Bool) {
        self.browser = browser
        self.address = address
        self.editing = editing
        badge = PinMeetingBadgeView(browser: browser)
        super.init(frame: .zero)
        wantsLayer = true
        badge.wantsLayer = true
        badge.isHidden = true
        addSubview(badge)
        watch = kitTrack { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard shown else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    private var label: Meeting.PinLabel? {
        guard browser.prefs.nextMeeting, Meetings.isCalendar(address), !editing else { return nil }
        let meetings = Meetings.shared
        return browser.pinLabel(for: meetings.next, at: meetings.clock)
    }

    private func refresh() {
        let now = label
        if let now { badge.show(now, title: Meetings.shared.next?.event.title ?? "") }
        if (now != nil) != shown {
            shown = now != nil
            if shown { badge.isHidden = false }
            badge.alphaValue = shown ? 1 : 0
            badge.layer?.kitAnimate("opacity", to: Swift.Float(shown ? 1 : 0), curve: Motion.kitQuick)
            if !shown, Store.testing { Bench.meetingBadge = nil }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        badge.tile = bounds.width
        let size = badge.intrinsicContentSize
        let margin = PinMeetingPlaces.margin(in: bounds.height)
        let scale = window?.backingScaleFactor ?? 2
        badge.frame = NSRect(x: ((bounds.width - size.width) / 2 * scale).rounded() / scale, y: bounds.height - margin - size.height,
                             width: size.width, height: size.height)
        guard Store.testing, let content = window?.contentView else { return }
        Bench.meetingTile = global(bounds, in: content)
        if shown { Bench.meetingBadge = global(badge.frame, in: content) }
    }

    private func global(_ rect: NSRect, in content: NSView) -> CGRect {
        let inWindow = convert(rect, to: nil)
        return CGRect(x: inWindow.minX, y: content.bounds.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }
}

final class LiveSignInPill: KitButton {
    static var curve: KitCurve { Motion.reduced ? .none : .easeOut(0.12) }
    private let word = KitLabel("", font: .systemFont(ofSize: 11))
    private let capsule = KitBox(fill: nil, corners: .capsule)

    init(_ title: String, action: @escaping () -> Void) {
        super.init(.plain(press: 0.94), label: title, action: action)
        addSubview(capsule, positioned: .below, relativeTo: nil)
        word.text = title
        word.setAccessibilityElement(false)
        content = word
        padding = 6
        paintPill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var title: String {
        get { word.text }
        set {
            word.text = newValue
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let inner = word.halfPointSize
        return NSSize(width: inner.width + 12, height: inner.height + 4)
    }

    static func size(_ title: String) -> NSSize {
        let inner = KitLabel(title, font: .systemFont(ofSize: 11)).halfPointSize
        return NSSize(width: inner.width + 12, height: inner.height + 4)
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func layout() {
        super.layout()
        capsule.frame = bounds
    }

    override func hoverChanged() {
        super.hoverChanged()
        paintPill()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        paintPill()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        paintPill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func paintPill() {
        let lit = hovering && isEnabled
        capsule.layer?.kitTransition(LiveSignInPill.curve)
        word.layer?.kitTransition(LiveSignInPill.curve)
        word.font = .systemFont(ofSize: 11, weight: lit ? .medium : .regular)
        word.color = lit ? KitColor.ink : KitColor.muted
        capsule.fill = KitColor.ink.withAlphaComponent(pressed ? 0.16 : lit ? 0.08 : 0)
    }
}

final class LiveStatusView: NSView, SideGrounded {
    let browser: Browser
    let id: UUID
    var collapsed: Bool { didSet { if collapsed != oldValue { refresh() } } }
    var ground = RowGround() {
        didSet {
            guard ground != oldValue else { return }
            dot.tone = ground.greys.dot
            dot.ink = ground.ink
            ring.ink = ground.ink
            mark.ink = ground.ink
        }
    }
    private let count = KitLabel("", font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: KitColor.muted)
    private let dot = UnseenDotView()
    private let words = KitLabel("", font: .systemFont(ofSize: 11), color: KitColor.muted)
    private(set) var pill: LiveSignInPill?
    private let mark = KitSymbol(LiveQuiet.symbol, style: KitSymbol.Style(size: 11), tint: KitColor.muted)
    private(set) var warns = false
    let ring = RingView()
    private(set) var loads = false
    private(set) var rings = false
    private var watch: AnyCancellable?
    private var size = NSSize.zero
    private(set) var asked: String?
    var asks: Bool { pill != nil }
    var keeps: Bool { bare || warns }
    var said: String? { words.isHidden ? (mark.isHidden ? nil : LiveQuiet.words) : words.text }
    var marked: Bool { !mark.isHidden }
    static var warnWidth: CGFloat { (LiveQuiet.words as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width }
    private var bare = false
    var overCount = false { didSet { if overCount != oldValue { refresh(poke: false) } } }
    var short = false { didSet { if short != oldValue { refresh(poke: false) } } }
    static let shortSignIn = "Sign in"

    init(browser: Browser, id: UUID, collapsed: Bool) {
        self.browser = browser
        self.id = id
        self.collapsed = collapsed
        super.init(frame: .zero)
        for view in [count, dot, words, mark, ring] as [NSView] { addSubview(view) }
        dot.setAccessibilityElement(false)
        mark.setAccessibilityElement(false)
        mark.isHidden = true
        ring.lead = 0
        ring.isHidden = true
        watch = kitTrack { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { size }
    override var intrinsicContentSize: NSSize { size }

    private func refresh(poke: Bool = true) {
        let had = (asks, asked)
        let live = LiveFolders.shared
        let folder = live.folder(id)
        let held = LiveLoadingClock.shared.shown.contains(id)
        let stale = LiveQuiet.stale(id)
        let status = folder.flatMap { LiveQuiet.status($0, stale: stale) }
        let note = folder.flatMap { LiveQuiet.note($0, stale: stale) }
        let claimed = folder == nil || (status != nil && (collapsed || note == nil))
        loads = folder.map { LiveLoading.waits($0, asked: live.requested.contains(id)) } ?? false
        let rang = rings
        rings = held && (loads || (rang && (overCount || !claimed)))
        let own = rings && !overCount
        let quiet = own || folder?.state == .waiting
        let fresh = folder.flatMap { !quiet && collapsed && status == nil && $0.freshCount > 0 ? $0.freshCount : nil }
        count.isHidden = fresh == nil
        dot.isHidden = fresh == nil
        var made = NSSize.zero
        if let fresh {
            count.text = "\(fresh)"
            let said = fresh == 1 ? "1 item with new activity" : "\(fresh) items with new activity"
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(said)
            toolTip = said
            let text = count.intrinsicContentSize
            made = NSSize(width: text.width + 4 + 7, height: max(text.height, 7))
        } else {
            setAccessibilityElement(false)
            setAccessibilityLabel(nil)
            toolTip = nil
        }
        var button: (String, String, String, () -> Void)?
        var text: String?
        var warned = false
        if !own, let folder, let status, collapsed || note == nil {
            if !folder.paused, folder.state == .signIn {
                button = (short ? Self.shortSignIn : status, folder.signInWords, folder.signInWords, { [weak browser, id] in browser?.signInToLive(id) })
            } else {
                text = status
                warned = stale
            }
        }
        warns = warned
        clock(warned)
        asked = button == nil ? nil : status
        if warned, let folder {
            let help = LiveQuiet.help(folder, now: Date(), online: live.online)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel("\(LiveQuiet.words). \(help)")
            toolTip = help
        }
        if loads, let folder {
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(LiveLoading.spoken(folder))
        }
        mark.isHidden = !(warned && short)
        words.isHidden = text == nil || !mark.isHidden
        if !mark.isHidden {
            made = NSSize(width: 14, height: 14)
        } else if let text {
            words.text = text
            made = words.halfPointSize
        }
        if let button {
            let shown = pill ?? {
                let made = LiveSignInPill(button.0, action: button.3)
                addSubview(made)
                pill = made
                return made
            }()
            shown.title = button.0
            shown.action = button.3
            shown.setAccessibilityLabel(button.1)
            shown.toolTip = button.2
            made = shown.intrinsicContentSize
        } else if let shown = pill {
            shown.removeFromSuperview()
            pill = nil
        }
        bare = made == .zero && !overCount
        if bare { made = NSSize(width: LiveLoading.side, height: LiveLoading.side) }
        ring.show(own, animated: bare && window != nil)
        if made != size || asks != had.0 || asked != had.1 {
            size = made
            invalidateIntrinsicContentSize()
            if poke { superview?.needsLayout = true }
        } else if rings != rang, poke {
            superview?.needsLayout = true
        }
        needsLayout = true
    }

    private var ticking: Timer?

    private func clock(_ on: Bool) {
        guard on != (ticking != nil) else { return }
        ticking?.invalidate()
        ticking = nil
        guard on else { return }
        let made = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        made.tolerance = 10
        RunLoop.main.add(made, forMode: .common)
        ticking = made
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { clock(false) } else { refresh() }
    }

    override func layout() {
        super.layout()
        if !count.isHidden {
            let text = count.intrinsicContentSize
            count.kitSetFrame(NSRect(x: 0, y: (bounds.height - text.height) / 2, width: text.width, height: text.height))
            dot.kitSetFrame(NSRect(x: text.width + 4, y: (bounds.height - 7) / 2, width: 7, height: 7))
        }
        if !words.isHidden { words.kitSetFrame(bounds) }
        mark.kitSetFrame(bounds)
        pill?.frame = bounds
        let side = LiveLoading.side
        ring.kitSetFrame(NSRect(x: bounds.width - side, y: (bounds.height - side) / 2, width: side, height: side))
    }
}

final class LiveNoteView: NSView, SideGrounded {
    let browser: Browser
    let id: UUID
    let height: CGFloat
    var interactive: Bool { didSet { if interactive != oldValue { refresh() } } }
    var ground = RowGround() { didSet { if ground != oldValue { paint(animated: false) } } }
    private let line = LiveNoteLine()
    private var watch: AnyCancellable?

    init(browser: Browser, id: UUID, height: CGFloat, interactive: Bool) {
        self.browser = browser
        self.id = id
        self.height = height
        self.interactive = interactive
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(line)
        line.press = { [weak self] in self?.pressed() }
        watch = kitTrack { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var action: (() -> Void)?

    private func pressed() {
        guard interactive else { return }
        action?()
    }

    var said: [String: Any] {
        layoutSubtreeIfNeeded()
        return ["text": line.isHidden ? "" : line.text, "detail": line.detail ?? "", "cut": !line.isHidden && line.cut,
                "retry": !line.isHidden && line.detail == "Try again", "button": line.button, "width": bounds.width,
                "tip": line.isHidden ? "" : line.toolTip ?? "",
                "folder": LiveFolders.shared.folder(id)?.name ?? ""]
    }

    private func refresh() {
        let live = LiveFolders.shared
        guard let folder = live.folder(id), let note = LiveQuiet.note(folder), note != .loading else {
            clock(false)
            line.isHidden = true
            return
        }
        line.isHidden = false
        let site = folder.source.siteName
        action = nil
        var label: String?
        var help: String?
        var failed = false
        switch note {
        case .loading:
            break
        case .empty:
            let whole = folder.emptyWording
            line.show(symbol: "tray", text: fits(whole, strong: false) ? whole : folder.source.nothingWording, strong: false)
            label = whole
            if folder.noCycle != true, !folder.source.leftOut.isEmpty {
                help = "This folder leaves out issues in \(LinearStatus.words(folder.source.leftOut)). Change it in the folder's settings."
            }
        case .paused:
            line.show(symbol: "pause.circle", text: "Not updating", strong: false)
        case .signIn:
            if fits("Sign in to \(site)", strong: true) {
                line.show(symbol: "person.crop.circle", text: "Sign in to \(site)", strong: true)
            } else {
                line.show(symbol: "person.crop.circle", text: "Sign in", detail: site, strong: true)
            }
            action = { [weak browser, id] in browser?.signInToLive(id) }
            label = "Sign in to \(site)"
            help = "Opens \(site)'s sign-in page. The folder reads again once you're back."
        case .sso(let sso):
            line.show(symbol: "lock.shield", text: "Single sign-on", detail: sso.org ?? site, strong: true)
            action = { [weak browser, id] in browser?.signInToLive(id) }
            label = folder.signInWords
            help = "Opens single sign-on. The folder reads again once you're back."
        case .failed:
            let now = Date()
            help = LiveQuiet.help(folder, now: now, online: live.online)
            if !live.online || folder.why == .offline {
                line.show(symbol: "wifi.slash", text: "You're offline", strong: false)
            } else {
                let words = "Couldn't read \(site)"
                let title = fits(words, strong: false) ? words : "Couldn't read this site"
                let waits = LiveLimit.holds(folder, at: now)
                line.show(symbol: LiveQuiet.symbol, text: title, detail: waits ? nil : "Try again", strong: false)
                label = waits ? words : "\(words). Try again."
                if !waits {
                    action = { [id] in LiveFolders.shared.update(id, asked: true) }
                    failed = true
                }
            }
        }
        clock(note == .failed)
        line.button = action != nil
        line.enabled = interactive && !(failed && live.reading.contains(id))
        line.setAccessibilityLabel(label ?? line.text)
        line.setAccessibilityRole(action != nil ? .button : .staticText)
        line.toolTip = help ?? (folder.state == .signIn ? folder.signInWords : nil)
        paint(animated: false)
        needsLayout = true
    }

    private func fits(_ words: String, strong: Bool) -> Bool {
        let font = NSFont.systemFont(ofSize: 12, weight: strong ? .medium : .regular)
        let room = (bounds.width > 0 ? bounds.width : 214) - 31 - 6
        return (words as NSString).size(withAttributes: [.font: font]).width <= room
    }

    private var laidWidth: CGFloat = 0

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        if size.width != laidWidth {
            laidWidth = size.width
            refresh()
        }
    }

    private var ticking: Timer?

    private func clock(_ on: Bool) {
        guard on != (ticking != nil) else { return }
        ticking?.invalidate()
        ticking = nil
        guard on else { return }
        let made = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        made.tolerance = 5
        RunLoop.main.add(made, forMode: .common)
        ticking = made
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { clock(false) } else { refresh() }
    }

    private func paint(animated: Bool) {
        line.ground = ground
    }

    override func layout() {
        super.layout()
        line.frame = bounds
    }
}

final class LiveMoreView: NSView, SideGrounded {
    let browser: Browser
    let id: UUID
    var ground = RowGround() { didSet { if ground != oldValue { line.ground = ground } } }
    private let line = LiveNoteLine()
    private var watch: AnyCancellable?

    init(browser: Browser, id: UUID) {
        self.browser = browser
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(line)
        line.press = { [weak self] in self?.pressed() }
        watch = kitTrack { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static func words(_ folder: LiveFolder) -> String { "More on \(folder.source.siteName)" }

    private func pressed() {
        guard let page = LiveFolders.shared.folder(id)?.more.flatMap(URL.init(string:)) else { return }
        browser.open(page, foreground: true)
    }

    private func refresh() {
        guard let folder = LiveFolders.shared.folder(id), folder.more != nil else {
            line.isHidden = true
            return
        }
        line.isHidden = false
        let words = Self.words(folder)
        line.show(symbol: "arrow.up.right", text: words, strong: false)
        line.button = true
        line.enabled = true
        line.setAccessibilityLabel(words)
        line.setAccessibilityRole(.button)
        line.toolTip = "Opens the rest of this list on \(folder.source.siteName)"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        line.frame = bounds
    }
}

private final class LiveNoteLine: KitHoverView {
    var press: (() -> Void)?
    var button = false { didSet { if button != oldValue { paint(animated: false); window?.invalidateCursorRects(for: self) } } }
    var enabled = true { didSet { if enabled != oldValue { alphaValue = enabled || !button ? 1 : 0.45 } } }
    var ground = RowGround() { didSet { if ground != oldValue { paint(animated: false) } } }
    private(set) var text = ""
    private var strong = false
    private let plate = KitPlate(radius: SideLook.cardRowRadius)
    private let symbol = KitSymbol("ellipsis", style: KitSymbol.Style(size: 12))
    private let label = KitLabel("", font: .systemFont(ofSize: 12))
    private let second = KitLabel("", font: .systemFont(ofSize: SideLook.byline))
    private(set) var detail: String?
    private var down = false

    var cut: Bool {
        label.intrinsicContentSize.width > label.frame.width + 0.5
            || (detail != nil && second.intrinsicContentSize.width > second.frame.width + 0.5)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(plate)
        addSubview(symbol)
        addSubview(label)
        addSubview(second)
        second.setAccessibilityElement(false)
        label.setAccessibilityElement(false)
        symbol.setAccessibilityElement(false)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { !button }

    func show(symbol name: String, text: String, detail: String? = nil, strong: Bool) {
        self.text = text
        self.detail = detail
        self.strong = strong
        if symbol.name != name { symbol.name = name }
        label.text = text
        second.text = detail ?? ""
        second.isHidden = detail == nil
        label.font = .systemFont(ofSize: 12, weight: strong ? .medium : .regular)
        paint(animated: false)
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard button, !isHidden, frame.contains(point) else { return nil }
        return self
    }

    override func resetCursorRects() {
        if button { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func hoverChanged() { paint(animated: true) }

    private func paint(animated: Bool) {
        let ink = ground.ink
        let tone = strong || detail != nil ? KitTone.ink : KitTone.muted
        symbol.ink = ink
        symbol.tint = tone.base
        label.ink = ink
        label.color = tone.base
        second.ink = ink
        second.color = KitTone.muted.base
        second.opacity = SideLook.bylineTone
        plate.ink = ink
        plate.isHidden = !button
        if animated { plate.layer?.kitTransition(LiveSignInPill.curve) }
        let greys = ground.greys
        plate.fill = down ? greys.wash : hovering && enabled ? greys.hover : greys.hover.opacity(0.5)
    }

    override func layout() {
        super.layout()
        plate.kitSetFrame(bounds)
        symbol.kitSetFrame(NSRect(x: 10, y: 0, width: 14, height: bounds.height))
        let size = label.intrinsicContentSize
        let width = max(0, bounds.width - 31)
        guard detail != nil else {
            label.kitSetFrame(NSRect(x: 31, y: (bounds.height - size.height) / 2, width: width, height: size.height))
            return
        }
        let top = ((bounds.height - SideLook.titleLine - SideLook.bylineLine) / 2).rounded()
        symbol.kitSetFrame(NSRect(x: 10, y: top, width: 14, height: SideLook.titleLine))
        label.kitSetFrame(NSRect(x: 31, y: top + (SideLook.titleLine - size.height) / 2, width: width, height: size.height))
        let small = second.intrinsicContentSize
        second.kitSetFrame(NSRect(x: 31, y: top + SideLook.titleLine + (SideLook.bylineLine - small.height) / 2, width: width, height: small.height))
    }

    override func mouseDown(with event: NSEvent) {
        guard button, enabled else { return }
        down = true
        paint(animated: true)
        kitScale(Motion.reduced ? 1 : 0.98, curve: LiveSignInPill.curve)
    }

    override func mouseUp(with event: NSEvent) {
        guard down else { return }
        down = false
        paint(animated: true)
        kitScale(1, curve: LiveSignInPill.curve)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard button, enabled else { return false }
        press?()
        return true
    }
}

private extension KitLabel {
    var halfPointSize: NSSize {
        let size = measure(width: .greatestFiniteMagnitude)
        return NSSize(width: (size.width * 2).rounded(.up) / 2, height: ceil(size.height))
    }
}
