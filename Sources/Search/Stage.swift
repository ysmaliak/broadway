import AppKit
import Combine
import WebKit

@MainActor
final class TabPageView: NSView {
    struct Setup: Equatable {
        var holdsPage = true
        var corner: CGFloat = 0
        var veiled = false
        var space: UUID?
        var borrowing = false
        var hold: CGSize?
        var card: CardClip?
    }

    private(set) var tab: Tab
    private weak var browser: Browser?
    private var layersFor: (ObjectIdentifier, CGFloat)?
    private var troubleFor: ObjectIdentifier?
    private var setup = Setup()
    private var stage: StageView?
    private var layers: PageLayersView?
    private var cover: PageCover?
    private var note: PageNote?
    private var trouble: PageTroubleView?
    private var stuckCard: StuckCardView?
    private let swipe = SwipeView()
    private lazy var reads = KitReads { [weak self] in self?.later() }
    private var queued = false

    init(tab: Tab, browser: Browser?) {
        self.tab = tab
        self.browser = browser
        super.init(frame: .zero)
        addSubview(swipe)
    }

    private func later() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            self?.queued = false
            self?.refresh(animated: true)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func update(_ now: Setup, tab: Tab, browser: Browser?) {
        self.browser = browser
        let moved = tab !== self.tab
        if moved { self.tab = tab }
        let changed = moved || now != setup
        setup = now
        if changed || stage == nil { refresh(animated: false) }
    }

    func returnBorrowedPages() {
        stage?.returnBorrowedPages()
    }

    private func refresh(animated: Bool) {
        reads.track { refreshNow(animated: animated) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(animated: false)
    }

    private func refreshNow(animated: Bool) {
        let look = browser?.pageLook(in: setup.space) ?? SpaceLook()
        let page = look.page(dark: kitDark)
        if setup.holdsPage {
            let view = stage ?? made(StageView(), below: layers ?? cover ?? note ?? trouble ?? swipe)
            stage = view
            view.ground = page
            view.corner = setup.corner
            view.borrowing = setup.borrowing
            let shown = setup.veiled || !tab.isWeb || tab.asleep || tab.floating ? nil : tab.web
            view.show(shown, space: setup.space ?? browser?.spaceID)
            view.hold(growing: setup.hold)
            view.card = setup.card
        } else if let stage {
            stage.removeFromSuperview()
            self.stage = nil
        }
        if layers == nil, let browser, tab.page != nil || tab.isBlank {
            layers = made(PageLayersView(browser: browser, tab: tab, corner: setup.corner), below: cover ?? note ?? trouble ?? swipe)
        }
        if let layers, layersFor.map({ $0.0 != ObjectIdentifier(tab) || $0.1 != setup.corner }) ?? true {
            layersFor = (ObjectIdentifier(tab), setup.corner)
            layers.show(tab, corner: setup.corner)
        }
        layers?.look = look
        layers?.needsLayout = true
        showCover(animated: animated)
        showNote(animated: animated)
        note?.page = page
        if trouble == nil, tab.failure != nil {
            trouble = made(PageTroubleView(tab: tab, browser: browser), below: swipe)
        }
        if let trouble, troubleFor != ObjectIdentifier(tab) {
            troubleFor = ObjectIdentifier(tab)
            trouble.show(tab, browser: browser)
        }
        trouble?.look = look
        trouble?.needsLayout = true
        showStuck()
        swipe.pull = tab.pull
        needsLayout = true
    }

    private func showStuck() {
        guard tab.stuck.card, let browser else {
            stuckCard?.removeFromSuperview()
            stuckCard = nil
            return
        }
        if let stuckCard, stuckCard.tab === tab { return }
        stuckCard?.removeFromSuperview()
        stuckCard = made(StuckCardView(tab: tab, browser: browser), below: swipe)
    }

    private func made<View: NSView>(_ view: View, below: NSView) -> View {
        addSubview(view, positioned: .below, relativeTo: below)
        view.frame = bounds
        return view
    }

    private func showCover(animated: Bool) {
        if let image = tab.cover {
            if let cover, cover.image === image, cover.alphaValue > 0 { return }
            cover?.removeFromSuperview()
            let view = PageCover(image: image)
            cover = made(view, below: note ?? trouble ?? swipe)
            return
        }
        guard let going = cover else { return }
        cover = nil
        fade(going, out: true, curve: animated ? Motion.kitSlide : .none)
    }

    private func showNote(animated: Bool) {
        let curve: KitCurve = animated ? Motion.kitQuick : .none
        if tab.floating {
            guard note == nil else { return }
            let view = PageNote()
            note = made(view, below: trouble ?? swipe)
            fade(view, out: false, curve: curve)
            return
        }
        guard let going = note else { return }
        note = nil
        fade(going, out: true, curve: curve)
    }

    private func fade(_ view: NSView, out: Bool, curve: KitCurve) {
        view.wantsLayer = true
        guard let layer = view.layer, curve.animates else {
            if out { view.removeFromSuperview() } else { view.layer?.opacity = 1 }
            return
        }
        if !out { layer.opacity = 0 }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak view] in if out { view?.removeFromSuperview() } }
        layer.kitAnimate("opacity", to: out ? Swift.Float(0) : Swift.Float(1), curve: curve)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        for view in subviews where view.frame != bounds { view.frame = bounds }
    }
}

@MainActor
private final class PageCover: NSView {
    let image: NSImage
    private let picture = CALayer()

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        picture.contents = image
        picture.contentsGravity = .resize
        picture.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        layer?.addSublayer(picture)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        picture.frame = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
    }
}

@MainActor
private final class PageNote: NSView {
    var page: PageGround? {
        didSet {
            guard let page, page != oldValue else { return }
            ground.show(page)
            label.appearance = page.appearance
        }
    }
    private let ground = PageGroundView()
    private let label = KitLabel("This page is playing in the floating window", font: .systemFont(ofSize: 13), color: KitColor.muted)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.alignment = .center
        addSubview(ground)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let size = label.measure(width: bounds.width)
        label.frame = kitSnap(NSRect(x: (bounds.width - ceil(size.width)) / 2, y: (bounds.height - ceil(size.height)) / 2,
                                     width: ceil(size.width), height: ceil(size.height)))
    }
}

final class StageView: NSView {
    /// What this stage has been told to show, and the only thing it keeps.
    ///
    /// It used to track that *and* what it was holding, and reconcile the two.
    /// One divergence between them — a page taken by the floating window, a tab
    /// closed at the wrong moment, an update that arrived out of order — and
    /// the stage would sit there holding nothing while believing it held
    /// something. That is the white page, and it came back every time from a
    /// different direction because the bookkeeping had many ways to slip.
    ///
    /// Now there is one fact and one rule: show `wanted`, and put that right on
    /// every layout. Nothing to fall out of step with.
    private weak var wanted: NSView?
    private var spaceID: UUID?
    var borrowing = false

    var ground: PageGround? {
        didSet {
            guard ground != oldValue else { return }
            paintGround()
        }
    }
    private var groundView: PageGroundView?

    private func paintGround() {
        guard let ground else {
            groundView?.removeFromSuperview()
            groundView = nil
            return
        }
        let view = groundView ?? {
            let made = PageGroundView()
            made.frame = bounds
            addSubview(made, positioned: .below, relativeTo: nil)
            groundView = made
            return made
        }()
        view.show(ground)
    }

    @MainActor
    private final class Loan {
        weak var page: NSView?
        weak var parent: NSView?
        let frame: CGRect
        let alpha: CGFloat

        init(_ page: NSView, parent: NSView) {
            self.page = page
            self.parent = parent
            frame = page.frame
            alpha = page.alphaValue
        }
    }

    private var loans: [ObjectIdentifier: Loan] = [:]

    func returnBorrowedPages() {
        let returning = loans
        loans = [:]
        for loan in returning.values {
            guard let page = loan.page, page.superview === self, let parent = loan.parent, parent.window != nil else { continue }
            page.removeFromSuperview()
            parent.addSubview(page)
            page.frame = loan.frame
            page.alphaValue = loan.alpha
            (parent as? StageView)?.settle()
        }
    }

    /// A page on its way out to the floating window (Browser.lift), kept
    /// here unseen under the one on show until the little window takes it,
    /// or it turns out to have nothing playing. Taken out of every window
    /// as the tab changed, the page let go of the layers it had drawn and
    /// built them all again in the little window, its video last; going out
    /// by switching tabs still jumped where ⇧⌘P didn't. Kept in a window,
    /// it goes out the way ⇧⌘P sends it.
    private weak var parting: NSView?

    private weak var outgoing: NSView?
    private weak var returning: NSView?
    private var outgoingTicket = 0
    static let holdForPaint: TimeInterval = 0.3

    /// Pages on a call — camera, microphone or screen in use — kept here
    /// unseen under the one on show when you go to another tab, as long as
    /// the call lasts. Taken out of the window, a page is one WebKit counts
    /// as out of sight: its timers held to once a second, its animation
    /// frames stopped. A call site that hands the camera on from a loop of
    /// its own (Google Meet takes about 45 pictures a second from it, by
    /// ImageCapture) stalls with it, and on a Meet call the others saw your
    /// picture frozen until you came back to the tab, where Safari and
    /// Chrome keep sending. Kept in the window, the page carries on as it
    /// did in front. Only pages on a call: any other tab still leaves the
    /// window, and is slowed and put to sleep as before.
    private var calls: [ObjectIdentifier: CallWatch] = [:]

    /// Whether this page is using the camera, the microphone or the screen.
    /// Muted counts: a camera turned off from the call's own button is a
    /// call still going.
    static func onCall(_ view: NSView) -> Bool {
        guard let web = view as? WKWebView else { return false }
        if web.cameraCaptureState != .none || web.microphoneCaptureState != .none { return true }
        return ExtensionCapture.screen(web)
    }

    /// Whether this page is one kept here unseen for its call.
    func holdsCall(_ view: NSView) -> Bool {
        calls[ObjectIdentifier(view)]?.web === view
    }

    func keep(_ page: NSView) {
        guard page.superview === self else { return }
        parting = page
    }

    func keepCall(_ page: NSView) {
        guard page.superview == nil, Self.onCall(page) else { return }
        page.alphaValue = 0
        page.frame = bounds
        addSubview(page, positioned: .below, relativeTo: nil)
        settle()
    }

    func letGo(_ page: NSView) {
        guard parting === page else { return }
        parting = nil
        if page.superview === self, page !== wanted { page.removeFromSuperview() }
        page.alphaValue = 1
    }

    /// The Web Inspector each page off show had docked beside it. WebKit
    /// docks it once, on show; a page coming back without it was laid out
    /// short, beside an empty space. Weak both ways: a closed tab's page
    /// takes its entry with it, and an inspector is kept by WebKit while it
    /// is open, never by this.
    private static let docks = NSMapTable<NSView, NSView>.weakToWeakObjects()

    /// Round, as the page's card is (see CardEdge): the web view is cut to
    /// the corners by this view's own layer, which a clip of SwiftUI's isn't
    /// always carried down to.
    var corner: CGFloat = 0 {
        didSet {
            guard corner != oldValue else { return }
            wantsLayer = true
            layer?.cornerRadius = corner
            layer?.cornerCurve = .continuous
            clip()
        }
    }

    var card: CardClip? {
        didSet {
            guard card != oldValue else { return }
            clip(to: card)
        }
    }

    var held: NSSize? {
        didSet {
            guard held != oldValue else { return }
            clip()
            needsLayout = true
        }
    }

    func hold(growing delta: CGSize?) {
        guard let delta else {
            held = nil
            return
        }
        let reach = NSSize(width: bounds.width + max(0, delta.width), height: bounds.height + max(0, delta.height))
        held = NSSize(width: max(reach.width, held?.width ?? 0), height: max(reach.height, held?.height ?? 0))
    }

    private func clip() {
        wantsLayer = true
        layer?.masksToBounds = corner > 0 || held != nil
    }

    override func layout() {
        super.layout()
        clip(to: card)
        if let groundView, groundView.frame != bounds { groundView.frame = bounds }
        settle()
    }

    /// A key the page didn't use, stopped here. WebKit gives such a key back
    /// to the view's superclass, which walks it up from the page, and the
    /// page's own view never sees it again: nothing in PageView is asked.
    /// Nothing above a page wants a plain key either, since Search's own are
    /// taken by the window's key monitor before the page sees them and the
    /// menus take theirs as key equivalents, so it goes all the way up and
    /// falls off the end of the responder chain, where macOS plays its
    /// "can't do that" sound. A page that reads the arrows itself without
    /// taking them from the page, as a game or a map does, beeped on every
    /// press (#402); Safari keeps them quiet. The stage is the page's frame,
    /// and the first thing of ours the key meets, so it stops here.
    override func keyDown(with event: NSEvent) {
        guard wanted != nil else { return super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .capsLock, .function, .numericPad])
        return flags.isEmpty ? false : super.performKeyEquivalent(with: event)
    }

    func show(_ page: NSView?, space: UUID? = nil) {
        if borrowing, wanted !== page { returnBorrowedPages() }
        if let page, page === parting {
            parting = nil
            page.alphaValue = 1
        }
        if let leaving = wanted, leaving !== page, let dock = subviews.first(where: Self.isInspector) {
            Self.docks.setObject(dock, forKey: leaving)
            dock.removeFromSuperview()
        }
        if let page, page === outgoing { outgoing = nil }
        if wanted !== page {
            if spaceID != space {
                release(fading: false)
            } else if let old = wanted, let page, holds(old, until: page) {
                holdOutgoing(old)
            } else if let old = wanted, let page, !isLent(page), covers(old, under: page) {
                coverReturn(of: page, with: old)
            } else {
                release(fading: false)
                crossfade()
            }
        }
        spaceID = space
        wanted = page
        settle()
    }

    private func holds(_ old: NSView, until page: NSView) -> Bool {
        guard window != nil, !(Store.testing && !Store.shownOnScreen),
              old.superview === self, old.alphaValue > 0, old !== parting,
              let fresh = page as? PageView, fresh.unpainted
        else { return false }
        return fresh.superview !== self || fresh.alphaValue == 0
    }

    private func covers(_ old: NSView, under page: NSView) -> Bool {
        guard window != nil, !(Store.testing && !Store.shownOnScreen),
              old.superview === self, old.alphaValue > 0, old !== parting, old !== outgoing,
              (old as? PageView)?.deviceSize == nil,
              let back = page as? PageView, !back.unpainted, back.deviceSize == nil,
              back.superview !== self
        else { return false }
        return true
    }

    private func coverReturn(of page: NSView, with old: NSView) {
        release(fading: false)
        outgoing = old
        returning = page
        outgoingTicket += 1
        let ticket = outgoingTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.returnCover) { [weak self] in
            guard let self, self.outgoingTicket == ticket else { return }
            self.release(fading: true)
        }
    }

    static let returnCover: TimeInterval = 0.05

    private func holdOutgoing(_ old: NSView) {
        outgoing = old
        outgoingTicket += 1
        let ticket = outgoingTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdForPaint) { [weak self] in
            guard let self, self.outgoingTicket == ticket else { return }
            self.release(fading: true)
        }
    }

    func painted(_ page: NSView) {
        guard page === wanted, outgoing != nil else { return }
        outgoingTicket += 1
        let ticket = outgoingTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + PageView.firstFrameFade) { [weak self] in
            guard let self, self.outgoingTicket == ticket else { return }
            self.release(fading: false)
        }
    }

    private func release(fading: Bool) {
        guard outgoing != nil || returning != nil else { return }
        outgoingTicket += 1
        if fading { crossfade() }
        if let back = returning {
            returning = nil
            if back === wanted { back.alphaValue = 1 }
        }
        outgoing = nil
        settle()
    }

    private func crossfade() {
        guard window != nil, let time = Motion.pageChange else { return }
        wantsLayer = true
        let fade = CATransition()
        fade.type = .fade
        fade.duration = time
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(fade, forKey: "page")
    }

    private func frame(for page: NSView) -> NSRect {
        if let size = (page as? PageView)?.deviceSize { return Self.deviceFrame(size, in: bounds) }
        guard let held else { return bounds }
        return NSRect(x: 0, y: bounds.height - held.height, width: held.width, height: held.height)
    }

    private func settle() {
        adoptStandIns()

        // Anything here that isn't wanted, out. Only ever what is actually
        // ours: a page may be somewhere else on purpose. Except the Web
        // Inspector docked beside the page: WebKit puts it here, next to the
        // web view, and shrinks the page to make room. Taken out on the next
        // resize, it left the page shrunk beside nothing (#91).
        let docked = inspecting
        for view in subviews where view !== wanted && view !== groundView && !(docked && Self.isInspector(view)) {
            if Self.isPlaceholder(view) {
                keepStandIn(view)
                continue
            }
            if view === outgoing {
                continue
            }
            // Unseen, and still drawn: WebKit asks whether its view is in a
            // window and not hidden, not whether anything shows of it.
            if view === parting {
                view.alphaValue = 0
                continue
            }
            if Self.onCall(view) {
                hold(view)
                continue
            }
            view.removeFromSuperview()
        }
        // Calls that ended, or pages that went elsewhere, are watched no more.
        for (key, watch) in calls {
            guard let web = watch.web, web.superview === self, web !== wanted, Self.onCall(web) else {
                watch.stop()
                calls[key] = nil
                continue
            }
        }

        guard let wanted, window != nil, !isLent(wanted) else { return }
        if wanted.superview === self, wanted.alphaValue == 0, wanted !== parting, wanted !== returning,
           (wanted as? PageView)?.unpainted != true {
            // Back from being kept for its call: seen again, and over the
            // others — the order of a view's subviews, changed without
            // taking anything out of the window.
            wanted.alphaValue = 1
            sortSubviews({ a, b, context in
                guard let context else { return .orderedSame }
                let front = Unmanaged<NSView>.fromOpaque(context).takeUnretainedValue()
                if a === front { return .orderedDescending }
                if b === front { return .orderedAscending }
                return .orderedSame
            }, context: Unmanaged.passUnretained(wanted).toOpaque())
        }
        if wanted.superview !== self {
            if borrowing, loans[ObjectIdentifier(wanted)] == nil, let parent = wanted.superview {
                loans[ObjectIdentifier(wanted)] = Loan(wanted, parent: parent)
            }
            // A web view can have only one superview, so taking it back is how
            // it is taken back.
            wanted.removeFromSuperview()
            // Seen — unless it has yet to draw, and would be seen white.
            wanted.alphaValue = (wanted as? PageView)?.unpainted == true || wanted === returning ? 0 : 1
            addSubview(wanted)
            if docked, let dock = Self.docks.object(forKey: wanted) {
                addSubview(dock, positioned: .below, relativeTo: wanted)
            }
            Self.docks.removeObject(forKey: wanted)
            // Full size, which WebKit, with its inspector back, cuts down to
            // make room for it again at the stage's size now.
            wanted.frame = frame(for: wanted)
            // A web view coming back into a window sometimes keeps the last
            // picture it had — which, after a while out of one, is nothing.
            // Asking it to draw again is cheap and is what brings it back.
            wanted.needsLayout = true
            wanted.needsDisplay = true
            wanted.layer?.setNeedsDisplay()
        }
        // With the inspector docked, WebKit lays the page and it out side by
        // side as this view changes size; setting the page's frame here would
        // cover the inspector.
        if !(docked && subviews.contains(where: Self.isInspector)) {
            wanted.frame = frame(for: wanted)
        }
    }

    /// A page on a call, kept: unseen, at the stage's size, and never the
    /// one the keys go to. Out of the window, a page loses the keys by
    /// itself; kept in it, a page that had them would go on taking what
    /// you type in the tab in front.
    private func hold(_ view: NSView) {
        view.alphaValue = 0
        if !(inspecting && subviews.contains(where: Self.isInspector)) { view.frame = bounds }
        if let window, let responder = window.firstResponder as? NSView,
           responder === view || responder.isDescendant(of: view) {
            window.makeFirstResponder(nil)
        }
        let key = ObjectIdentifier(view)
        guard calls[key]?.web !== view, let web = view as? WKWebView else { return }
        calls[key]?.stop()
        calls[key] = CallWatch(web) { [weak self] in self?.settle() }
    }

    /// Nothing reaches a page kept unseen: a click, a scroll or a drop
    /// there goes to the page on show.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let parting, let hit, hit === parting || hit.isDescendant(of: parting) { return nil }
        if let outgoing, let hit, outgoing !== wanted, hit === outgoing || hit.isDescendant(of: outgoing) {
            guard let wanted, wanted.superview === self else { return nil }
            return wanted.hitTest(convert(point, from: superview))
        }
        if let hit, let held = subviews.first(where: { holdsCall($0) && (hit === $0 || hit.isDescendant(of: $0)) }),
           held !== wanted {
            guard let wanted, wanted.superview === self else { return nil }
            return wanted.hitTest(convert(point, from: superview))
        }
        return hit
    }

    /// Whether the page on show has its Web Inspector up. WebKit answers only
    /// through names outside its public framework, asked for before use (see
    /// Inspector.swift).
    private var inspecting: Bool {
        guard let web = wanted as? WKWebView else { return false }
        let get = NSSelectorFromString("_inspector")
        guard web.responds(to: get), let inspector = web.perform(get)?.takeUnretainedValue() as? NSObject else { return false }
        let visible = NSSelectorFromString("isVisible")
        guard inspector.responds(to: visible) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(inspector.method(for: visible), to: Getter.self)(inspector, visible)
    }

    /// What WebKit leaves in a page's place while it fills the screen.
    static func isPlaceholder(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("FullScreenPlaceholder")
    }

    private let standIns = NSMapTable<NSView, WKWebView>.weakToWeakObjects()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { settle() }
    }

    func isLent(_ view: NSView?) -> Bool {
        guard let web = view as? WKWebView else { return false }
        return web.fullscreenState != .notInFullscreen && web.superview !== self
    }

    func standIn(for view: NSView?) -> NSView? {
        guard let view else { return nil }
        return subviews.first { Self.isPlaceholder($0) && standIns.object(forKey: $0) === view }
    }

    private func adoptStandIns() {
        guard let web = wanted as? WKWebView, web.fullscreenState != .notInFullscreen else { return }
        for view in subviews where Self.isPlaceholder(view) && standIns.object(forKey: view) == nil {
            standIns.setObject(web, forKey: view)
        }
    }

    private func keepStandIn(_ view: NSView) {
        guard let owner = standIns.object(forKey: view) else {
            if let web = wanted as? WKWebView, web.fullscreenState != .notInFullscreen { return }
            view.removeFromSuperview()
            return
        }
        guard owner.fullscreenState != .notInFullscreen, owner.superview !== self else {
            standIns.removeObject(forKey: view)
            view.removeFromSuperview()
            return
        }
        if view.frame != bounds { view.frame = bounds }
        let shown = owner === wanted
        if view.isHidden == shown { view.isHidden = !shown }
        if shown, subviews.last !== view {
            sortSubviews({ a, b, context in
                guard let context else { return .orderedSame }
                let front = Unmanaged<NSView>.fromOpaque(context).takeUnretainedValue()
                if a === front { return .orderedDescending }
                if b === front { return .orderedAscending }
                return .orderedSame
            }, context: Unmanaged.passUnretained(view).toOpaque())
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview !== wanted && subview !== groundView { needsLayout = true }
    }

    private static func isInspector(_ view: NSView) -> Bool {
        String(describing: type(of: view)).hasPrefix("WKInspector")
    }
}

/// Tells a stage when a page it keeps for its call stops capturing, so the
/// page leaves the window as any tab behind does. WebKit's camera and
/// microphone states are public and observable; its screen's is asked for
/// by name, only where it answers to it.
final class CallWatch: NSObject {
    private static let keys = ["cameraCaptureState", "microphoneCaptureState", "_displayCaptureState"]
    private(set) weak var web: WKWebView?
    private var watching: [String] = []
    private let changed: () -> Void

    init(_ web: WKWebView, changed: @escaping () -> Void) {
        self.web = web
        self.changed = changed
        super.init()
        for key in Self.keys where key.hasPrefix("_") == false || web.responds(to: NSSelectorFromString(key)) {
            web.addObserver(self, forKeyPath: key, options: [], context: nil)
            watching.append(key)
        }
    }

    func stop() {
        if let web { for key in watching { web.removeObserver(self, forKeyPath: key) } }
        watching = []
    }

    deinit { stop() }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [weak self] in self?.changed() }
    }
}

final class DragStripView: NSView {
    var reserved: CGFloat = 0
    var below: CGFloat = 0
    var trailing: CGFloat = 0
    var onDoubleClick: (() -> Void)?
    var menuMaker: (() -> NSMenu)?

    override func menu(for event: NSEvent) -> NSMenu? { menuMaker?() }

    private var pressed: NSEvent?
    private var moved = false
    private var over = false

    /// The strip moves the window and answers the double-click itself.
    /// Left to say yes, AppKit takes both on too in the title bar the
    /// strip sits in, and a double-click answered twice — by AppKit on
    /// the press, here on the release — ends where it started.
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let inside = convert(point, from: superview)
        guard inside.x >= reserved, inside.x <= bounds.width - trailing else { return nil }
        // AppKit measures up from the bottom; the reservation is from the top.
        guard bounds.height - inside.y >= below else { return nil }
        return super.hitTest(point)
    }

    /// The window is not movable while the pointer is over a strip: macOS
    /// starts a title bar's drag before the app sees the press, so a tab
    /// picked up in the row carried the window off unless the window was
    /// unmovable already. Elsewhere it is movable, for Window › Move &
    /// Resize, tiling and window managers (#286).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        hover(false)
        super.viewWillMove(toWindow: newWindow)
    }

    private func hover(_ on: Bool) {
        guard let window, on != over else { return }
        over = on
        WindowHold.hover(window, on)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = event
        moved = false
    }

    /// Here the window is let go for the one drag, handed to the system's
    /// own window drag so it snaps and tiles as any window does.
    override func mouseDragged(with event: NSEvent) {
        guard let window, let pressed, !moved else { return }
        let dx = event.locationInWindow.x - pressed.locationInWindow.x
        let dy = event.locationInWindow.y - pressed.locationInWindow.y
        // A little slack, so a shaky click is still a click.
        if abs(dx) < 3 && abs(dy) < 3 { return }
        moved = true
        window.isMovable = true
        window.performDrag(with: pressed)
        window.isMovable = !WindowHold.held(window)
    }

    /// A double-click does what a title bar's does, unless this strip
    /// stands for empty tab row instead, in which case it opens a new
    /// tab, the same as the button it is standing in for. It answered
    /// every click before, so a double-click filled the screen on the
    /// first click and put the window back on the second, and looked
    /// like nothing at all.
    override func mouseUp(with event: NSEvent) {
        guard let window, !moved, event.clickCount == 2 else { return }
        if let onDoubleClick {
            onDoubleClick()
            return
        }
        WindowHold.doubleClick(window)
    }
}

@MainActor
enum WindowHold {
    private static var hovered: [ObjectIdentifier: Int] = [:]

    static func hover(_ window: NSWindow, _ on: Bool) {
        let id = ObjectIdentifier(window)
        let count = max(0, (hovered[id] ?? 0) + (on ? 1 : -1))
        hovered[id] = count == 0 ? nil : count
        window.isMovable = count == 0
    }

    static func held(_ window: NSWindow) -> Bool { hovered[ObjectIdentifier(window)] != nil }

    static func doubleClick(_ window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }
}

@MainActor
final class PageLayersView: KitFlippedView {
    let browser: Browser
    private(set) var tab: Tab
    private var corner: CGFloat
    private var page: InternalPageHolder?
    private var newTab: NewTabPageView?
    var look: SpaceLook? { didSet { if look != oldValue { newTab?.look = look } } }

    init(browser: Browser, tab: Tab, corner: CGFloat) {
        self.browser = browser
        self.tab = tab
        self.corner = corner
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ tab: Tab, corner: CGFloat) {
        if tab !== self.tab {
            self.tab = tab
            page?.removeFromSuperview()
            page = nil
        }
        self.corner = corner
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        if let shown = tab.page {
            if let page, page.kind != shown.kind {
                page.removeFromSuperview()
                self.page = nil
            }
            let holder = page ?? {
                let made = InternalPageHolder(browser: browser, tab: tab, page: shown)
                addSubview(made, positioned: .below, relativeTo: newTab)
                page = made
                return made
            }()
            holder.corner = corner
            holder.asked = shown.detail
            holder.frame = bounds
        } else if let page {
            page.removeFromSuperview()
            self.page = nil
        }
        if tab.isBlank, !browser.prefs.floatingNewTab {
            let view = newTab ?? {
                let made = NewTabPageView(browser: browser, tab: tab, corner: corner, look: look)
                addSubview(made)
                newTab = made
                return made
            }()
            if view.tab !== tab { view.tab = tab }
            if let look { view.look = look }
            view.corner = corner
            view.frame = bounds
        } else if let newTab {
            newTab.removeFromSuperview()
            self.newTab = nil
        }
    }
}

@MainActor
final class InternalPageHolder: KitFlippedView {
    let browser: Browser
    let tab: Tab
    let kind: InternalPage.Kind
    let content: NSView
    var corner: CGFloat = 0 { didSet { if corner != oldValue { needsLayout = true } } }
    var asked: String? { didSet { (content as? SettingsTab)?.asked = asked } }

    init(browser: Browser, tab: Tab, page: InternalPage) {
        self.browser = browser
        self.tab = tab
        kind = page.kind
        content = Self.make(browser: browser, tab: tab, page: page)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        addSubview(content)
        let click = NSClickGestureRecognizer(target: self, action: #selector(pressed))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
        if let files = content as? FilesPageView { files.onPress = { [weak self] in self?.pressed() } }
        if let marks = content as? BookmarksPageView { marks.onPress = { [weak self] in self?.pressed() } }
        if kind == .passwords { browser.relist() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func make(browser: Browser, tab: Tab, page: InternalPage) -> NSView {
        switch page.kind {
        case .settings: return SettingsTab(browser: browser, asked: page.detail)
        case .history: return HistoryPage(browser: browser)
        case .downloads: return DownloadsPage(browser: browser, loot: browser.loot)
        case .files: return FilesPageView(browser: browser, loot: browser.loot, asTab: true)
        case .bookmarks: return BookmarksPageView(browser: browser, bookmarks: browser.bookmarks, asTab: true)
        case .passwords: return PasswordsPageView(browser: browser)
        case .importing: return ImportPageView(browser: browser)
        }
    }

    @objc private func pressed() {
        if browser.activeID != tab.id, browser.split(for: tab) != nil { browser.focusPane(tab) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.window?.recalculateKeyViewLoop() }
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = corner
    }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        needsDisplay = true
        content.frame = bounds
        if let history = content as? HistoryPage {
            history.show(hunt: browser.recallHunt, clearing: browser.recallMode == .clearing)
        } else if let downloads = content as? DownloadsPage {
            downloads.show(entries: browser.fetches.entries, kept: browser.loot.kept)
        }
    }
}

@MainActor
final class PageTroubleView: KitFlippedView {
    private(set) var tab: Tab
    private weak var browser: Browser?
    private var trouble: TroubleView?

    init(tab: Tab, browser: Browser?) {
        self.tab = tab
        self.browser = browser
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ tab: Tab, browser: Browser?) {
        self.tab = tab
        self.browser = browser
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    var look: SpaceLook? { didSet { if look != oldValue { needsLayout = true } } }

    private var search: (() -> Void)? {
        guard let browser, let host = tab.address?.host() ?? tab.pending?.host(),
              let url = browser.searchURL(for: host) else { return nil }
        let tab = tab
        return { tab.go(to: url) }
    }

    override func layout() {
        super.layout()
        guard let failure = tab.failure else {
            trouble?.removeFromSuperview()
            trouble = nil
            return
        }
        let host = tab.address?.host() ?? tab.pending?.host()
        let look = look ?? browser?.space.look ?? SpaceLook()
        let tab = tab
        let view = trouble ?? {
            let made = TroubleView(message: failure, host: host, look: look, search: search, retry: { tab.reload() })
            addSubview(made)
            trouble = made
            return made
        }()
        view.look = look
        view.onRetry = { tab.reload() }
        view.onSearch = search
        if view.message != failure || view.host != host { view.show(message: failure, host: host) }
        view.frame = bounds
    }
}
