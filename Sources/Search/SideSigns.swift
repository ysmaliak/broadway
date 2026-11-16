import AppKit
import Combine

@MainActor
enum SideSigns {
    static func popupSign(browser: Browser, tab: Tab) -> NSView { PopupSignView(browser: browser, tab: tab) }
    static func translateSign(tab: Tab) -> NSView { TranslateSignView(tab: tab) }
    static func callTimeLeft(browser: Browser, tab: Tab) -> NSView { CallLeftSign(browser: browser, tab: tab) }
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
        face.seed = tab.agentTask.map { AgentLink(id: $0, name: "", key: .task($0), connected: .distantPast).seed } ?? 0
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

    init(browser: Browser, tab: Tab) {
        self.browser = browser
        self.tab = tab
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
        superview?.needsLayout = true
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
        let size = badge.intrinsicContentSize
        let margin = PinMeetingPlaces.margin(in: bounds.height)
        badge.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.height - margin - size.height,
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

enum LiveLoading {
    static let width: CGFloat = 32

    static func shows(_ folder: LiveFolder, collapsed: Bool) -> Bool {
        folder.state == .waiting && !folder.paused && (collapsed || !folder.items.isEmpty)
    }

    static func spoken(_ folder: LiveFolder) -> String { "Loading \(folder.name)" }
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
            loading?.ink = ground.ink
        }
    }
    private let count = KitLabel("", font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: KitColor.muted)
    private let dot = UnseenDotView()
    private let words = KitLabel("", font: .systemFont(ofSize: 11), color: KitColor.muted)
    private(set) var pill: LiveSignInPill?
    private(set) var loading: GroupNameVeil?
    private var watch: AnyCancellable?
    private var size = NSSize.zero
    private(set) var asked: String?
    var asks: Bool { pill != nil }
    var short = false { didSet { if short != oldValue { refresh(poke: false) } } }
    static let shortSignIn = "Sign in"

    init(browser: Browser, id: UUID, collapsed: Bool) {
        self.browser = browser
        self.id = id
        self.collapsed = collapsed
        super.init(frame: .zero)
        for view in [count, dot, words] as [NSView] { addSubview(view) }
        dot.setAccessibilityElement(false)
        watch = kitTrack { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { size }
    override var intrinsicContentSize: NSSize { size }

    private func refresh(poke: Bool = true) {
        let had = (asks, asked)
        let folder = LiveFolders.shared.folder(id)
        let loads = folder.map { LiveLoading.shows($0, collapsed: collapsed) } ?? false
        let fresh = folder.flatMap { !loads && collapsed && $0.status == nil && $0.freshCount > 0 ? $0.freshCount : nil }
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
            toolTip = nil
        }
        var button: (String, String, String, () -> Void)?
        var text: String?
        if let folder, let status = folder.status, collapsed || folder.note == nil {
            if !folder.paused, folder.state == .signIn {
                button = (short ? Self.shortSignIn : status, folder.signInWords, folder.signInWords, { [weak browser, id] in browser?.signInToLive(id) })
            } else {
                text = status
            }
        }
        asked = button == nil ? nil : folder?.status
        if loads, let folder {
            let shown = loading ?? {
                let made = GroupNameVeil()
                made.ink = ground.ink
                addSubview(made)
                loading = made
                return made
            }()
            shown.isHidden = false
            let said = LiveLoading.spoken(folder)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(said)
            made = NSSize(width: LiveLoading.width, height: GroupNameReveal.barHeight)
        } else if let shown = loading {
            shown.removeFromSuperview()
            loading = nil
        }
        words.isHidden = text == nil
        if let text {
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
        if made != size || asks != had.0 || asked != had.1 {
            size = made
            invalidateIntrinsicContentSize()
            if poke { superview?.needsLayout = true }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if !count.isHidden {
            let text = count.intrinsicContentSize
            count.kitSetFrame(NSRect(x: 0, y: (bounds.height - text.height) / 2, width: text.width, height: text.height))
            dot.kitSetFrame(NSRect(x: text.width + 4, y: (bounds.height - 7) / 2, width: 7, height: 7))
        }
        if !words.isHidden { words.kitSetFrame(bounds) }
        pill?.frame = bounds
        loading?.kitSetFrame(bounds)
    }
}

final class LiveNoteView: NSView, SideGrounded {
    let browser: Browser
    let id: UUID
    let height: CGFloat
    var interactive: Bool { didSet { if interactive != oldValue { refresh() } } }
    var ground = RowGround() { didSet { if ground != oldValue { paint(animated: false) } } }
    private let line = LiveNoteLine()
    private var retry: LiveSignInPill?
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

    private func refresh() {
        let live = LiveFolders.shared
        guard let folder = live.folder(id), let note = folder.note else {
            line.isHidden = true
            retry?.removeFromSuperview()
            retry = nil
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
            line.show(symbol: "ellipsis", text: "Loading…", strong: false)
            label = "Loading \(folder.name)"
        case .empty:
            line.show(symbol: "tray", text: folder.source.emptyWording, strong: false)
            if !folder.source.leftOut.isEmpty {
                help = "This folder leaves out issues in \(LinearStatus.words(folder.source.leftOut)). Change it in the folder's settings."
            }
        case .paused:
            line.show(symbol: "pause.circle", text: "Not updating", strong: false)
        case .signIn:
            line.show(symbol: "person.crop.circle", text: "Sign in to \(site)", strong: true)
            action = { [weak browser, id] in browser?.signInToLive(id) }
            label = "Sign in to \(site)"
            help = "Opens \(site)'s sign-in page. The folder reads again once you're back."
        case .sso:
            line.show(symbol: "lock.shield", text: folder.signInWords, strong: true)
            action = { [weak browser, id] in browser?.signInToLive(id) }
            label = folder.signInWords
            help = "Opens single sign-on. The folder reads again once you're back."
        case .failed:
            line.show(symbol: "exclamationmark.triangle", text: "Couldn't read \(site)", strong: false)
            failed = true
        }
        line.button = action != nil
        line.enabled = interactive
        line.setAccessibilityLabel(label ?? line.text)
        line.setAccessibilityRole(action != nil ? .button : .staticText)
        line.toolTip = help
        if failed {
            let shown = retry ?? {
                let made = LiveSignInPill("Try Again") { [id] in LiveFolders.shared.update(id) }
                addSubview(made)
                retry = made
                return made
            }()
            shown.isEnabled = interactive && !live.reading.contains(id)
        } else if let shown = retry {
            shown.removeFromSuperview()
            retry = nil
        }
        paint(animated: false)
        needsLayout = true
    }

    private func paint(animated: Bool) {
        line.ground = ground
    }

    override func layout() {
        super.layout()
        if let retry {
            let size = retry.intrinsicContentSize
            let x = bounds.width - 6 - size.width
            retry.frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
            line.frame = NSRect(x: 0, y: 0, width: max(0, x - 6), height: bounds.height)
        } else {
            line.frame = bounds
        }
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
    private var down = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(plate)
        addSubview(symbol)
        addSubview(label)
        label.setAccessibilityElement(false)
        symbol.setAccessibilityElement(false)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { !button }

    func show(symbol name: String, text: String, strong: Bool) {
        self.text = text
        self.strong = strong
        if symbol.name != name { symbol.name = name }
        label.text = text
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
        let tone = strong ? KitTone.ink : KitTone.muted
        symbol.ink = ink
        symbol.tint = tone.base
        label.ink = ink
        label.color = tone.base
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
        label.kitSetFrame(NSRect(x: 31, y: (bounds.height - size.height) / 2, width: max(0, bounds.width - 31), height: size.height))
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
