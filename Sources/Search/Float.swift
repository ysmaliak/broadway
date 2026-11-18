import AppKit
import WebKit

// A video that keeps playing after you have gone somewhere else, in a small
// window that stays above everything — other tabs, and other apps.
//
// WebKit will not hand a video to the system's picture-in-picture without a
// real click on the page, and nothing the app does counts as one. Chromium is
// looser, which is why this works elsewhere and refused here.
//
// So the engine is not asked. The page itself is moved: everything but the
// video is made invisible, the video is stretched to fill the viewport, and the
// whole web view is lifted out of the window and into a small floating one. The
// video never stops, because it is the same page it always was — it has only
// changed windows.

@MainActor
final class Float {
    private var panel: FloatPanel?
    private var controls: Controls?
    private weak var page: NSView?

    /// Asked to go away. The browser does the bookkeeping and calls back into
    /// `drop` — there is one way this window closes, and it is not this class
    /// quietly tidying up behind everyone's back. Two paths to closing is how
    /// it stayed on screen after the page had already gone home.
    var onClose: (() -> Void)?
    /// Bring the window forward and go to the tab it came from.
    var onReturn: (() -> Void)?
    /// Stop or start the video. Answers with whether it is playing now.
    var onPlayPause: ((@escaping (Bool) -> Void) -> Void)?
    /// Step over the bit you missed, or back to it.
    var onSkip: ((Double) -> Void)?
    var onProgress: ((@escaping (FloatMediaState) -> Void) -> Void)?
    var onCaptions: ((Int?) -> Void)?
    var onRate: ((Double, @escaping (Double?) -> Void) -> Void)?
    var onMute: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var home: (() -> NSRect?)?

    private var ticker: Timer?
    private var arriving: FloatTween?
    private var leaving: Leaving = .home
    private var picture: CGImage?
    private var dropping = false

    private enum Leaving { case home, away }

    static var moves: Bool { benchAway == nil && !(Store.testing && !Store.shownOnScreen) }

    static var shadowed: Bool { !ProcessInfo.processInfo.isLowPowerModeEnabled }

    var showing: Bool { panel != nil }

    /// Over the page while it is still laid out for the tab it came from: the
    /// video's last frame there, or the window's black where there is none.
    /// Until then the window showed that old layout, the video a fraction of
    /// itself in one corner, and then the video jumped to fill it.
    private var cover: NSView?
    private let settling = Settling()

    /// Whether the cover is up, and whether it shows a frame of the video
    /// (see `film float` in Bench.swift).
    var covered: Bool { cover != nil }
    var coveredByStill: Bool { cover?.layer?.contents != nil }

    /// Where a test run's bench opens the window instead: off every screen,
    /// at the size it would have had, and not remembered (see `film float`
    /// in Bench.swift). Nil everywhere else.
    static var benchAway: NSPoint?

    /// Two fingers flick the window to a corner instead of pushing it
    /// along (Settings › General). Off unless asked for.
    static var flicks = false

    /// Where a flick sends the window, a margin in from the edges of
    /// `area`. A swipe clearly both ways — between about 22° and 68° — takes
    /// it to the corner it points at; a straighter one along its stronger
    /// direction, against whichever of the other two edges it is nearer.
    nonisolated static func corner(for frame: NSRect, in area: NSRect, toward way: CGVector, margin: CGFloat = 12) -> NSPoint {
        let left = area.minX + margin, right = area.maxX - margin - frame.width
        let bottom = area.minY + margin, top = area.maxY - margin - frame.height
        let across = abs(way.dx), up = abs(way.dy)
        let x = way.dx > 0 ? right : left, y = way.dy > 0 ? top : bottom
        if min(across, up) >= 0.4 * max(across, up) { return NSPoint(x: x, y: y) }
        if across >= up { return NSPoint(x: x, y: frame.midY > area.midY ? top : bottom) }
        return NSPoint(x: frame.midX > area.midX ? right : left, y: y)
    }

    /// Where docking leaves the window: off the side of `area`, but for a
    /// sliver to bring it back by.
    nonisolated static func docked(_ frame: NSRect, right: Bool, in area: NSRect, sliver: CGFloat = 10) -> NSPoint {
        NSPoint(x: right ? area.maxX - sliver : area.minX - frame.width + sliver, y: frame.minY)
    }

    /// Whether the window can go into that side of `area`, one of `screens`:
    /// not where another screen carries on, where it would only slide onto
    /// that one instead.
    nonisolated static func dockable(_ frame: NSRect, right: Bool, in area: NSRect, screens: [NSRect]) -> Bool {
        let beyond = NSRect(x: right ? area.maxX : area.minX - frame.width, y: frame.minY, width: frame.width, height: frame.height)
        return !screens.contains { !$0.contains(area) && $0.intersects(beyond) }
    }

    /// Screens a test run's bench makes up, far off the real ones, for the
    /// window to flick and dock about (see `float` in Bench.swift). Nil
    /// everywhere else.
    static var benchScreens: [NSRect]?

    /// `still`: the video as it was in its tab, cut out of a picture of the
    /// page (see `still(of:picture:page:)`), shown until the page is laid out
    /// at this window's size.
    func lift(_ page: NSView, still: NSImage? = nil) {
        guard panel == nil else { return }
        self.page = page

        let size = NSSize(width: 440, height: 247)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        // Where it was last, at the size it was, if a screen still shows it;
        // otherwise the bottom right of this one.
        var spot = Float.remembered ?? NSRect(
            x: screen.maxX - size.width - 24,
            y: screen.minY + 24,
            width: size.width,
            height: size.height
        )
        if let away = Float.benchAway { spot.origin = away }

        let panel = FloatPanel(
            contentRect: spot,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above every ordinary window, this app's and everyone else's, and
        // present on whichever desktop you happen to be looking at.
        panel.level = KeepOnTop.panelLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = Float.shadowed
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        // The bench's, off every screen, is left out when a probe is hidden.
        panel.canHide = Float.benchAway == nil
        panel.aspectRatio = size
        // Kept once a move or a resize is over, not on each step of one: at
        // the end of a resize by its edges, as it closes (see drop), and as
        // the app quits with it open, which closes nothing.
        let keep: (Notification.Name, AnyObject) -> NSObjectProtocol = { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let frame = self?.restingFrame { Float.remembered = frame }
                }
            }
        }
        keeping = [
            keep(NSWindow.didEndLiveResizeNotification, panel),
            keep(NSApplication.willTerminateNotification, NSApp),
        ]
        panel.minSize = NSSize(width: 260, height: 146)

        // At the size the window opens at. Built at the default size and
        // then stretched to a remembered one, the page was laid out twice,
        // and the first frames of video filled only part of the window
        // (#257).
        let outline = FloatOutline(frame: NSRect(origin: .zero, size: spot.size))
        let ground = Ground(frame: outline.bounds)
        ground.autoresizingMask = [.width, .height]
        outline.addSubview(ground)
        ground.wantsLayer = true
        ground.layer?.backgroundColor = NSColor.black.cgColor
        ground.layer?.cornerRadius = FloatLayout.corner
        ground.layer?.cornerCurve = .continuous
        ground.layer?.masksToBounds = true

        // WebKit puts its own pinch recogniser on a web view, and a gesture
        // recogniser is consulted before the responder chain is. With it left
        // on, every pinch aimed at this window went into zooming the page
        // inside it instead of sizing the window. It comes back on landing.
        (page as? WKWebView)?.allowsMagnification = false

        page.removeFromSuperview()
        page.frame = ground.bounds
        page.autoresizingMask = [.width, .height]
        ground.addSubview(page)
        ground.page = page
        ground.onLost = { [weak self] in
            guard let self, !self.dropping, self.panel === panel else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel === panel, self.page?.superview !== ground else { return }
                self.onClose?()
            }
        }

        // WebKit takes a moment to lay a page out at a new size, a third of
        // a second for YouTube's, and shows the layout it had meanwhile. The
        // still covers that moment, fitted as the video itself will be.
        let cover = NSView(frame: ground.bounds)
        cover.wantsLayer = true
        cover.layer?.backgroundColor = NSColor.black.cgColor
        cover.layer?.contents = still?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cover.layer?.contentsGravity = .resizeAspect
        cover.autoresizingMask = [.width, .height]
        ground.addSubview(cover)
        self.cover = cover

        let controls = Controls(frame: ground.bounds)
        controls.autoresizingMask = [.width, .height]
        controls.onClose = { [weak self] in
            self?.leaving = .away
            self?.onClose?()
        }
        controls.onReturn = { [weak self] in
            self?.leaving = .home
            self?.onReturn?()
        }
        controls.onPlayPause = { [weak self] in
            self?.onPlayPause? { playing in
                self?.controls?.answered(playing)
            }
        }
        controls.onSkip = { [weak self] seconds in self?.onSkip?(seconds) }
        controls.onSeek = { [weak self] fraction in self?.onSeek?(fraction) }
        controls.onRate = { [weak self] rate, answer in self?.onRate?(rate, answer) }
        controls.onMute = { [weak self] in self?.onMute?() }
        controls.onCaptions = { [weak self] choice in self?.onCaptions?(choice) }
        controls.onReveal = { [weak self] in self?.capture() }
        ground.addSubview(controls)
        self.controls = controls

        panel.onPress = { [weak self] in
            self?.arriving?.finish()
            self?.arriving = nil
            self?.capture()
        }
        panel.contentView = outline
        leaving = .home
        picture = still?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        controls.shade = picture.flatMap(FloatShade.init)
        if Float.moves { arriving = FloatMotion.arrive(panel, ground: ground) }
        panel.orderFrontRegardless()
        self.panel = panel
        polling(true)

        // Off once the page has drawn a frame at the window's size with the
        // video alone in it, and never later than the limit: a page that
        // stops answering does not leave the window frozen.
        if let web = page as? WKWebView {
            let zoom = max(web.pageZoom, 0.1)
            web.evaluateInSearch(Isolate.fits(width: spot.width / zoom, height: spot.height / zoom))
            settling.watch(web, within: 0.8) { [weak self] in self?.uncover() }
        } else {
            uncover()
        }

    }

    private func polling(_ on: Bool) {
        ticker?.invalidate()
        ticker = nil
        guard on else { return }
        capture()
        ask()
        let ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ask() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func ask() {
        guard let controls else { return }
        let read = controls.rateRead()
        onProgress? { [weak controls] state in controls?.polled(state, read: read) }
    }

    private func capture() {
        guard let web = page as? WKWebView, web.bounds.width > 0 else { return }
        let shot = WKSnapshotConfiguration()
        shot.afterScreenUpdates = false
        shot.snapshotWidth = NSNumber(value: Double(web.bounds.width))
        web.takeSnapshot(with: shot) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self, let image, self.page === web else { return }
                self.picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                self.controls?.shade = self.picture.flatMap(FloatShade.init)
            }
        }
    }

    /// The window's last place and size, kept across closing it and quitting,
    /// and given back only while a screen still shows most of it.
    private static var remembered: NSRect? {
        get {
            guard let text = Store.settings.string(forKey: "float.frame") else { return nil }
            let frame = NSRectFromString(text)
            let shown = NSScreen.screens.contains {
                let seen = $0.visibleFrame.intersection(frame)
                return seen.width * seen.height > 0.6 * frame.width * frame.height
            }
            return frame.width > 100 && shown ? frame : nil
        }
        set {
            guard benchAway == nil else { return }
            Store.settings.set(newValue.map(NSStringFromRect), forKey: "float.frame")
        }
    }

    private var keeping: [NSObjectProtocol] = []

    /// Where the window is, or was before it was docked at a side: a docked
    /// window is kept as it was, not as the sliver it is.
    private var restingFrame: NSRect? {
        guard let panel else { return nil }
        guard let home = controls?.dockedFrom else { return panel.frame }
        return NSRect(origin: home, size: panel.frame.size)
    }

    /// Puts the page down and closes. Whoever owns the page takes it back on
    /// their next layout.
    func drop() {
        guard let panel, !dropping else { return }
        dropping = true
        defer { dropping = false }
        settling.stop()
        arriving?.finish()
        arriving = nil
        cover = nil
        if let frame = restingFrame { Float.remembered = frame }
        keeping.forEach(NotificationCenter.default.removeObserver)
        keeping = []
        ticker?.invalidate()
        ticker = nil
        controls?.stop()
        if Float.moves, panel.isVisible, panel.screen != nil, controls?.docked == nil {
            let home = leaving == .home ? self.home : nil
            FloatMotion.leave(from: panel.frame, picture: picture, shadow: panel.hasShadow) { home?() }
        }
        (page as? WKWebView)?.allowsMagnification = true
        page?.removeFromSuperview()
        page = nil
        controls = nil
        picture = nil
        leaving = .home
        panel.onPress = nil
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
    }

    func bench(_ action: String, _ value: String?) -> [String: Any] {
        guard let controls else { return ["floating": false] }
        if action == "key", let value, let data = value.data(using: .utf8),
           let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = request["code"] as? Int, (0...65535).contains(code), let panel {
            var flags: NSEvent.ModifierFlags = []
            for flag in request["mods"] as? [String] ?? [] {
                switch flag {
                case "shift": flags.insert(.shift)
                case "command": flags.insert(.command)
                case "option": flags.insert(.option)
                case "control": flags.insert(.control)
                default: break
                }
            }
            let outside = request["outside"] as? Bool == true
            let target = outside ? Links.window : panel
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target?.windowNumber ?? 0, context: nil,
                characters: request["chars"] as? String ?? "", charactersIgnoringModifiers: request["chars"] as? String ?? "",
                isARepeat: request["repeat"] as? Bool ?? false, keyCode: UInt16(code)) {
                let handled = handleKey(event)
                var result = controls.bench("chrome", nil)
                result["handled"] = handled
                return result
            }
        }
        return controls.bench(action, value)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, NSApp.modalWindow == nil, !ShortcutStore.shared.recording,
              let panel, panel.attachedSheet == nil, let controls else { return false }
        let ownsKeys = event.window === panel
        guard ownsKeys || controls.reveal.inside else { return false }
        if !ownsKeys {
            guard let window = event.window, window.attachedSheet == nil else { return false }
            if window.firstResponder is NSTextView { return false }
            let browser = Browsers.browser(for: window)
            if browser?.active?.typing == true || browser?.active?.built?.inputContext != nil { return false }
            var view = window.firstResponder as? NSView
            while let current = view {
                if current is NSTextField { return false }
                if let web = current as? WKWebView, web.inputContext != nil { return false }
                view = current.superview
            }
        }
        guard let command = FloatCommand.read(code: event.keyCode, flags: event.modifierFlags, repeated: event.isARepeat, tempo: Tempo.on) else { return false }
        return controls.perform(command)
    }

    /// The live page from under the still. A short fade, for the frames of
    /// film that went by while it was up.
    private func uncover() {
        guard let cover else { return }
        self.cover = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            cover.animator().alphaValue = 0
        }, completionHandler: {
            cover.removeFromSuperview()
        })
    }

    /// The video's picture, cut out of a picture of its whole page. `picture`
    /// is where the video's picture sits in the page, and `page` the page's
    /// size, both in the page's own pixels. Nil unless nearly all of it was
    /// on screen: half a video, stretched to fill the window, is not the
    /// video.
    static func still(of shot: NSImage, picture: [Double], page: [Double]) -> NSImage? {
        guard picture.count == 4, page.count == 2, page[0] > 0, page[1] > 0,
              picture[2] > 0, picture[3] > 0,
              let whole = shot.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let box = CGRect(x: picture[0], y: picture[1], width: picture[2], height: picture[3])
        let seen = box.intersection(CGRect(x: 0, y: 0, width: page[0], height: page[1]))
        guard !seen.isNull, seen.width * seen.height >= 0.95 * box.width * box.height else { return nil }
        // An image's rows run down from the top, as a page's do.
        let scale = CGFloat(whole.width) / page[0]
        let cut = CGRect(x: seen.minX * scale, y: seen.minY * scale, width: seen.width * scale, height: seen.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: whole.width, height: whole.height))
        guard let part = whole.cropping(to: cut) else { return nil }
        return NSImage(cgImage: part, size: NSSize(width: seen.width, height: seen.height))
    }

    private final class Controls: NSView {
        var onClose: (() -> Void)?
        var onReturn: (() -> Void)?
        var onPlayPause: (() -> Void)?
        var onSkip: ((Double) -> Void)?
        var onSeek: ((Double) -> Void)?
        var onCaptions: ((Int?) -> Void)?
        var onReveal: (() -> Void)?
        var onRate: ((Double, @escaping (Double?) -> Void) -> Void)?
        var onMute: (() -> Void)?

        let chrome = FloatChrome()
        private(set) var reveal = FloatReveal()
        private(set) var play = FloatPlay()
        private(set) var time = FloatTime()
        private var rate = FloatRate()
        private var feedbackDue: DispatchWorkItem?
        private var due: DispatchWorkItem?
        private var dueAt: TimeInterval = 0
        private var tuck: DispatchWorkItem?
        private var lastSeek: TimeInterval = 0
        private let scrim = CAGradientLayer()
        var shade: FloatShade? { didSet { if shade != oldValue { needsLayout = true } } }

        private lazy var close = FloatCornerView(chrome: chrome, anchor: KitArrival.topTrailing, symbol: "xmark", label: "Close") { [weak self] in
            self?.pressedClose()
        }
        private lazy var back = FloatCornerView(chrome: chrome, anchor: KitArrival.topLeading, symbol: "pip.exit", label: "Back to Tab") { [weak self] in
            self?.pressedReturn()
        }
        private lazy var transport = FloatTransportView(
            chrome: chrome,
            rewind: { [weak self] in self?.pressedSkip(-15) },
            toggle: { [weak self] in self?.pressedPause() },
            forward: { [weak self] in self?.pressedSkip(15) }
        )
        private lazy var scrub = FloatScrubView(chrome: chrome) { [weak self] fraction, final in
            self?.scrubbed(to: fraction, final: final)
        }

        private lazy var speed = FloatSpeedView(chrome: chrome) { [weak self] in
            guard let self else { return }
            self.pressedRate(self.rate.step(1, wrapping: true))
        }
        private lazy var feedback = FloatFeedbackView(chrome: chrome)
        private lazy var captions = FloatCaptionsView(chrome: chrome) { [weak self] in self?.pressedCaptions($0) }
        private lazy var live = FloatLiveView(chrome: chrome) { [weak self] in self?.scrubbed(to: 1, final: true) }
        private lazy var waiting = FloatWaitingView(chrome: chrome)

        private var hosts: [NSView] { [close, back, transport, scrub, speed, feedback, captions, live] }

        private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true

            let stops = FloatLayout.scrim()
            scrim.colors = stops.alphas.map { NSColor(white: 0, alpha: CGFloat($0)).cgColor }
            scrim.locations = stops.locations.map { NSNumber(value: $0) }
            scrim.opacity = 0
            scrim.isHidden = true
            layer?.addSublayer(scrim)

            addSubview(waiting)
            hosts.forEach {
                $0.isHidden = true
                addSubview($0)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrim.frame = bounds
            CATransaction.commit()

            close.frame = FloatLayout.close(in: bounds)
            back.frame = FloatLayout.back(in: bounds)
            transport.frame = FloatLayout.transport(in: bounds)
            scrub.frame = FloatLayout.scrub(in: bounds)
            speed.frame = FloatLayout.speed(in: bounds).offsetBy(dx: chrome.captions.isEmpty ? 0 : -32, dy: 0)
            var told = FloatLayout.feedback(in: bounds)
            let scale = window?.backingScaleFactor ?? 2
            told.origin.y = (told.minY * scale).rounded(.down) / scale
            feedback.frame = told
            captions.frame = FloatLayout.captions(in: bounds)
            live.frame = FloatLayout.live(in: bounds)
            waiting.frame = FloatLayout.waiting(in: bounds)
            shadeKeys()
        }

        private func keys(in view: NSView) -> [FloatKeyView] {
            view.subviews.flatMap { ($0 as? FloatKeyView).map { [$0] } ?? keys(in: $0) }
        }

        private func shadeKeys() {
            hosts.forEach { $0.layoutSubtreeIfNeeded() }
            let size = bounds.size
            for key in hosts.flatMap(keys(in:)) {
                guard let shade, size.width > 0, size.height > 0 else {
                    key.shaded = false
                    continue
                }
                let frame = convert(key.bounds, from: key)
                let unit = CGRect(x: frame.minX / size.width, y: 1 - frame.maxY / size.height,
                                  width: frame.width / size.width, height: frame.height / size.height)
                key.shaded = shade.bright(in: unit)
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                    owner: self
                )
            )
        }

        override func mouseEntered(with event: NSEvent) {
            reveal.enter(at: Controls.now)
            apply()
        }

        override func mouseMoved(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            reveal.move(at: Controls.now, overControl: target(at: point) != nil)
            apply()
        }

        override func mouseExited(with event: NSEvent) {
            reveal.exit(at: Controls.now)
            apply()
        }

        private func apply() {
            if reveal.shown != chrome.shown { reveal.shown ? show() : hide() }
            guard let deadline = reveal.deadline else { return }
            if due != nil, deadline >= dueAt - 0.01 { return }
            due?.cancel()
            dueAt = deadline
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.due = nil
                self.reveal.tick(at: Controls.now)
                self.apply()
            }
            due = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.02, deadline - Controls.now), execute: work)
        }

        private func show() {
            tuck?.cancel()
            tuck = nil
            let first = hosts.contains { $0.isHidden }
            hosts.forEach { $0.isHidden = false }
            scrim.isHidden = false
            fadeScrim(to: 1)
            onReveal?()
            guard first else {
                chrome.shown = true
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.reveal.shown { self.chrome.shown = true } else { self.hide() }
            }
        }

        private func hide() {
            chrome.shown = false
            chrome.scrubbing = false
            fadeScrim(to: 0)
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.chrome.shown else { return }
                self.tuck = nil
                self.hosts.forEach { $0.isHidden = true }
                self.scrim.isHidden = true
            }
            tuck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
        }

        private func fadeScrim(to value: Swift.Float) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.reduced ? 0.12 : 0.22)
            scrim.opacity = value
            CATransaction.commit()
        }

        func stop() {
            feedbackDue?.cancel()
            feedbackDue = nil
            due?.cancel()
            due = nil
            tuck?.cancel()
            tuck = nil
            stopGlide()
            settling?.cancel()
            settling = nil
        }

        func answered(_ playing: Bool) {
            play.answered(playing)
            chrome.playing = play.playing
        }

        func rateRead() -> FloatRate.Read { rate.read() }

        func polled(_ state: FloatMediaState, read: FloatRate.Read) {
            let now = Controls.now
            play.polled(state.playing, at: now)
            time.polled(through: state.timeline.fraction(state.current), duration: state.timeline.span, at: now)
            chrome.playing = play.playing
            chrome.duration = time.duration
            chrome.through = time.shown
            chrome.timeline = state.timeline
            chrome.current = state.current
            chrome.captions = state.captions
            chrome.chapters = state.chapters
            chrome.waiting = state.waiting
            needsLayout = true
            rate.received(state.rate, read: read, at: now)
            syncRate()
        }

        private func pressedCaptions(_ selection: Int?) {
            guard !chrome.captions.isEmpty else { return }
            onCaptions?(selection)
        }

        private func target(at point: NSPoint) -> NSView? {
            guard chrome.shown else { return nil }
            if atCorner(point) { return nil }
            let slop = FloatLayout.slop
            if close.frame.insetBy(dx: -slop, dy: -slop).contains(point) { return close }
            if back.frame.insetBy(dx: -slop, dy: -slop).contains(point) { return back }
            if speed.frame.insetBy(dx: -slop, dy: -slop).contains(point) { return speed }
            if !chrome.captions.isEmpty, captions.frame.insetBy(dx: -slop, dy: -slop).contains(point) { return captions }
            if chrome.timeline.live, live.frame.contains(point) { return live }
            if transport.frame.contains(point) { return transport }
            if chrome.seekable, FloatLayout.scrubHit(in: bounds).contains(point) { return scrub }
            return nil
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let inside = convert(point, from: superview)
            if let host = target(at: inside) {
                return host.hitTest(inside) ?? host
            }
            return self
        }

        func surface(_ request: [String: Any]) {
            var state = FloatMediaState()
            state.playing = request["playing"] as? Bool ?? true
            state.timeline = FloatTimeline(ranges: [[0, 600]], live: request["live"] as? Bool ?? false)
            state.current = request["current"] as? Double ?? 240
            if request["captions"] as? Bool ?? true {
                state.captions = [FloatCaption(id: 0, name: "English", selected: true), FloatCaption(id: 1, name: "Deutsch", selected: false)]
            }
            if request["chapters"] as? Bool ?? true {
                state.chapters = [FloatChapter(start: 0, end: 120, name: "Intro"), FloatChapter(start: 120, end: 400, name: "The middle"),
                                  FloatChapter(start: 400, end: 600, name: "The end")]
            }
            state.waiting = request["waiting"] as? Bool ?? false
            polled(state, read: rate.read())
            chrome.rate = request["rate"] as? Double ?? 1.5
            chrome.controllable = true
            chrome.feedback = request["feedback"] as? String
            shade = (request["ground"] as? String).flatMap { FloatShade.luma(of: NSColor(hexString: $0)) }.map(FloatShade.init(uniform:))
            hosts.forEach { $0.isHidden = false }
            scrim.isHidden = false
            scrim.opacity = 1
            chrome.shown = true
        }

        func bench(_ action: String, _ value: String?) -> [String: Any] {
            let now = Controls.now
            switch action {
            case "hover":
                if value == "off" { reveal.exit(at: now) } else { reveal.enter(at: now) }
                apply()
            case "press":
                switch value {
                case "close": pressedClose()
                case "back": pressedReturn()
                case "rewind": pressedSkip(-15)
                case "forward": pressedSkip(15)
                case "pause", "play": pressedPause()
                case "speed": pressedRate(rate.step(1, wrapping: true))
                case "mute": onMute?()
                case "captions": pressedCaptions(nil)
                case "live": scrubbed(to: 1, final: true)
                default: return ["error": "press close|back|rewind|forward|pause"]
                }
            case "captions":
                pressedCaptions(value.flatMap(Int.init))
            case "rate":
                if let value, let picked = Double(value) { pressedRate(picked) }
            case "scrub":
                let fraction = Double(value ?? "") ?? 0.5
                scrubbed(to: fraction, final: false)
                scrubbed(to: fraction, final: true)
            default:
                break
            }
            return [
                "shown": chrome.shown,
                "playing": chrome.playing,
                "through": chrome.through,
                "duration": chrome.duration,
                "seekable": chrome.seekable,
                "rangeStart": chrome.timeline.start,
                "rangeEnd": chrome.timeline.end,
                "live": chrome.timeline.live,
                "lag": max(0, chrome.timeline.end - chrome.current),
                "waiting": chrome.waiting,
                "captions": chrome.captions.map { ["id": $0.id, "name": $0.name, "selected": $0.selected] as [String: Any] },
                "chapters": chrome.chapters.map { ["start": $0.start, "end": $0.end, "name": $0.name] as [String: Any] },
                "rate": chrome.rate,
                "controllable": chrome.controllable,
                "feedback": chrome.feedback ?? "",
                "hidden": hosts.map(\.isHidden),
                "deadline": reveal.deadline.map { $0 - now } as Any,
                "window": window?.windowNumber ?? 0,
            ]
        }
        // MARK: - moving and sizing

        private var grab = NSPoint.zero
        private var origin = NSRect.zero
        private var stretching = false

        private func atCorner(_ point: NSPoint) -> Bool {
            point.x > bounds.maxX - 18 && point.y < bounds.minY + 18
        }

        override func resetCursorRects() {
            addCursorRect(
                NSRect(x: bounds.maxX - 18, y: bounds.minY, width: 18, height: 18),
                cursor: .crosshair
            )
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            reveal.move(at: Controls.now)
            apply()
            // A click on the sliver of a docked window brings it back.
            if docked != nil {
                undock()
                ignoringDrag = true
                return
            }
            ignoringDrag = false
            stopGlide()
            grab = NSEvent.mouseLocation
            origin = window.frame
            stretching = atCorner(convert(event.locationInWindow, from: nil))
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, !ignoringDrag else { return }
            let now = NSEvent.mouseLocation
            let dx = now.x - grab.x
            let dy = now.y - grab.y

            guard stretching else {
                window.setFrameOrigin(NSPoint(x: origin.minX + dx, y: origin.minY + dy))
                return
            }
            resize(to: origin.width + dx, from: origin)
        }

        /// Two fingers on the trackpad move the window. There is nothing to
        /// scroll here — the window holds one picture — so the gesture is free
        /// to mean the thing you actually want it to mean.
        ///
        /// And the pointer travels with it. Moving the window alone leaves the
        /// cursor behind: it drifts towards the edge, falls out, and the window
        /// stops answering mid-gesture. Carrying it keeps it at the same place
        /// in the frame, so the window can be pushed as far as the screen goes.
        override func scrollWheel(with event: NSEvent) {
            guard let window else { return }
            // Only while fingers are actually down. Letting the glide continue
            // would fling the pointer across the screen after them.
            guard event.momentumPhase == [] else { return }
            if Float.flicks { return flickWheel(with: event) }
            // Docked, and flicks turned off since: out first, where it was.
            if docked != nil { return undock() }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            guard dx != 0 || dy != 0 else { return }

            let spot = window.frame.origin
            window.setFrameOrigin(NSPoint(x: spot.x + dx, y: spot.y - dy))

            // Screen coordinates run up from the bottom, the cursor's run down
            // from the top of the first display.
            guard let ground = NSScreen.screens.first else { return }
            let mouse = NSEvent.mouseLocation
            CGWarpMouseCursorPosition(
                CGPoint(
                    x: mouse.x + dx,
                    y: ground.frame.height - (mouse.y - dy)
                )
            )
            // Without this the pointer and the physical trackpad stay parted
            // for a moment, and the next flick arrives from the wrong place.
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        /// Two fingers flick the window to a corner, as in Dia and Arc: a
        /// swipe up takes it to the top on the side it is on, a swipe left to
        /// the left at the height it is at, a diagonal one to that corner —
        /// one move a swipe, however long the swipe. Dragging it anywhere is
        /// still the click's.
        private var swipe: CGVector = .zero
        private var flicked = false
        /// For a wheel, which has no gesture to belong to: one flick a turn.
        private var lastWheelFlick = Date.distantPast

        private func flickWheel(with event: NSEvent) {
            // Which way the fingers went, on screen: with natural scrolling
            // the deltas run with the fingers, without it against them.
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            let step = CGVector(dx: sign * event.scrollingDeltaX, dy: -sign * event.scrollingDeltaY)

            if event.phase == [] {
                // A mouse's wheel: every turn is a flick, a moment apart.
                guard Date().timeIntervalSince(lastWheelFlick) > 0.4, step != .zero else { return }
                lastWheelFlick = Date()
                if docked != nil {
                    if inward(step) { undock() }
                } else if let side = against(), outward(step, from: side) {
                    dock(side)
                } else {
                    flick(step)
                }
                return
            }
            if event.phase.contains(.began) {
                swipe = .zero
                flicked = false
                pulling = nil
                pullFrom = window?.frame.origin ?? .zero
            }
            swipe.dx += step.dx
            swipe.dy += step.dy
            let lifted = event.phase.contains(.ended) || event.phase.contains(.cancelled)

            // Docked: a swipe back towards the middle brings it out.
            if docked != nil {
                if !flicked, inward(swipe), abs(swipe.dx) > 24 || lifted {
                    flicked = true
                    undock()
                }
                if lifted {
                    swipe = .zero
                    flicked = false
                }
                return
            }

            // Against a side, and swiped at it: it gives, heavily, under the
            // fingers, and on lifting either goes into the side — only a
            // sliver left — or springs back out.
            if pulling == nil, !flicked, let side = against(), outward(swipe, from: side), abs(swipe.dx) > 6 {
                pulling = side
                // A spring still settling from the last one would pull the
                // other way, a frame at a time.
                stopGlide()
            }
            if pulling != nil {
                window?.setFrameOrigin(NSPoint(x: pullFrom.x + swipe.dx * Controls.give, y: pullFrom.y))
                // The window moves out from under the pointer as it gives, and
                // the fingers lifting can then be told to whatever is under
                // it instead: if nothing more comes, the pull is over anyway.
                settling?.cancel()
                let settle = DispatchWorkItem { [weak self] in self?.letGo() }
                settling = settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: settle)
                if lifted { letGo() }
                return
            }
            // Read from the whole swipe, as the fingers lift: a swipe often
            // sets off along one side before it turns diagonal, and read
            // early it went the wrong way. A long one doesn't wait.
            let length = hypot(swipe.dx, swipe.dy)
            if !flicked, length > 120 || (lifted && length > 20) {
                flicked = true
                flick(swipe)
            }
            if lifted {
                swipe = .zero
                flicked = false
            }
        }

        // Docking at a side, as in Dia: a strong swipe at the side the window
        // is against slides it off, leaving a sliver to bring it back by.
        enum Side { case left, right }
        private(set) var docked: Side?
        /// Where it was before it docked: where it goes back to.
        private(set) var dockedFrom: NSPoint?
        private var pulling: Side?
        private var pullFrom: NSPoint = .zero
        private var ignoringDrag = false
        /// How much of it stays on screen, docked.
        static let sliver: CGFloat = 10
        /// How far the fingers go at the side before letting go docks it.
        static let dockAt: CGFloat = 90
        /// How much the window gives under the fingers while pulled at a side.
        static let give: CGFloat = 0.35

        /// The usable part of the screen the window is on.
        private var area: NSRect? {
            if let made = Float.benchScreens, let window {
                let middle = NSPoint(x: window.frame.midX, y: window.frame.midY)
                return made.first { $0.contains(middle) } ?? made.first
            }
            return (window?.screen ?? NSScreen.main)?.visibleFrame
        }

        /// The side the window is up against, if it is, and if it can go
        /// into it.
        private func against() -> Side? {
            guard let window, let area else { return nil }
            let screens = Float.benchScreens ?? NSScreen.screens.map(\.frame)
            if window.frame.maxX >= area.maxX - 16,
               Float.dockable(window.frame, right: true, in: area, screens: screens) { return .right }
            if window.frame.minX <= area.minX + 16,
               Float.dockable(window.frame, right: false, in: area, screens: screens) { return .left }
            return nil
        }

        /// Clearly sideways, and at that side.
        private func outward(_ way: CGVector, from side: Side) -> Bool {
            abs(way.dx) > abs(way.dy) * 1.2 && (side == .right ? way.dx > 0 : way.dx < 0)
        }

        /// Back towards the middle from the side it is docked at.
        private func inward(_ way: CGVector) -> Bool {
            guard let docked else { return false }
            return abs(way.dx) > abs(way.dy) && (docked == .right ? way.dx < 0 : way.dx > 0)
        }

        private var settling: DispatchWorkItem?

        /// A pull at a side over: into the side, or back out.
        private func letGo() {
            settling?.cancel()
            settling = nil
            guard let side = pulling else { return }
            if outward(swipe, from: side), abs(swipe.dx) >= Controls.dockAt {
                dock(side, from: pullFrom)
            } else {
                glide(to: pullFrom, bouncing: true)
            }
            pulling = nil
            swipe = .zero
            flicked = false
        }

        private func dock(_ side: Side, from origin: NSPoint? = nil) {
            guard let window, let area else { return }
            dockedFrom = origin ?? window.frame.origin
            docked = side
            glide(to: Float.docked(window.frame, right: side == .right, in: area, sliver: Controls.sliver))
        }

        private func undock() {
            guard let window else { return }
            let back = dockedFrom ?? window.frame.origin
            docked = nil
            dockedFrom = nil
            glide(to: back, bouncing: true)
        }

        /// To the corner the swipe points at, a margin in from the edges of
        /// the screen's usable part.
        private func flick(_ way: CGVector) {
            guard let window, let area else { return }
            let target = Float.corner(for: window.frame, in: area, toward: way)
            guard target != window.frame.origin else { return }
            glide(to: target)
        }

        // The glide, a frame at a time off the display's own refresh — 120
        // a second on a ProMotion screen, where AppKit's window animation
        // stepped at 60 — on a critically damped spring: quick away,
        // settling into the corner without overshooting it.
        private var gliding: CADisplayLink?
        private var glideFrom: NSPoint = .zero
        private var glideTo: NSPoint = .zero
        private var glideStart: CFTimeInterval = 0
        /// Back out from a side: a spring that goes a little past and settles.
        private var glideBounces = false

        private func glide(to target: NSPoint, bouncing: Bool = false) {
            guard let window else { return }
            glideBounces = bouncing
            glideFrom = window.frame.origin
            glideTo = target
            glideStart = CACurrentMediaTime()
            if window.screen == nil {
                // On no screen — the bench's window, off every one — there
                // is no display to keep time by: a clock does instead.
                ticking = ticking ?? Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.glideStep() }
                }
            } else if gliding == nil {
                let link = displayLink(target: self, selector: #selector(glideStep(_:)))
                link.add(to: .main, forMode: .common)
                gliding = link
            }
        }

        private var ticking: Timer?

        @objc private func glideStep(_ link: CADisplayLink) { glideStep() }

        private func glideStep() {
            guard let window else { stopGlide(); return }
            let t = CGFloat(CACurrentMediaTime() - glideStart)
            let p: CGFloat
            let done: Bool
            if glideBounces {
                // Underdamped: past the place, and back to it.
                let omega: CGFloat = 16, zeta: CGFloat = 0.5
                let damped = omega * sqrt(1 - zeta * zeta)
                done = t > 0.9
                p = done ? 1 : 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta / sqrt(1 - zeta * zeta) * sin(damped * t))
            } else {
                let omega: CGFloat = 15
                done = t > 0.6
                p = done ? 1 : 1 - (1 + omega * t) * exp(-omega * t)
            }
            window.setFrameOrigin(NSPoint(
                x: glideFrom.x + (glideTo.x - glideFrom.x) * p,
                y: glideFrom.y + (glideTo.y - glideFrom.y) * p
            ))
            if done { stopGlide() }
        }

        private func stopGlide() {
            gliding?.invalidate()
            gliding = nil
            ticking?.invalidate()
            ticking = nil
        }

        /// A pinch sizes it about the pointer: whatever is under your fingers
        /// stays under your fingers, and the rest grows away from it. Sizing
        /// about the centre instead makes the picture slide sideways under a
        /// hand that never moved, which is what felt wrong.
        private var pinching: CGFloat = 0

        override func magnify(with event: NSEvent) {
            guard let window else { return }
            if event.phase == .began { pinching = 0 }
            pinching += event.magnification

            // Every event would mean a window resize, a web view relayout and a
            // video re-fit sixty times a second, which is the stutter. Moving
            // in steps of a fiftieth is below what an eye reads as a jump and
            // an order of magnitude less work.
            guard abs(pinching) > 0.02 else { return }
            let by = pinching
            pinching = 0
            resize(
                to: window.frame.width * (1 + by),
                from: window.frame,
                around: NSEvent.mouseLocation
            )
        }

        private func resize(to width: CGFloat, from was: NSRect, around anchor: NSPoint? = nil) {
            guard let window, was.width > 0 else { return }
            let limit = NSScreen.main?.visibleFrame.width ?? 1600
            // Keeps the shape: a video window that can be squashed is a video
            // window showing bars.
            let wide = min(max(window.minSize.width, width), limit * 0.85)
            let tall = wide * was.height / was.width

            let spot: NSPoint
            if let anchor {
                // Where the pointer sits within the window, as a fraction, kept
                // at the same fraction of the new one.
                let across = (anchor.x - was.minX) / was.width
                let up = (anchor.y - was.minY) / was.height
                spot = NSPoint(x: anchor.x - across * wide, y: anchor.y - up * tall)
            } else {
                spot = NSPoint(x: was.minX, y: was.maxY - tall)
            }
            // Not display: true — asking for an immediate redraw on every step
            // is what makes a live resize stutter. The next frame is soon
            // enough.
            window.setFrame(
                NSRect(x: spot.x, y: spot.y, width: wide, height: tall),
                display: false
            )
        }

        func perform(_ command: FloatCommand) -> Bool {
            switch command {
            case .back: pressedReturn()
            case .toggle: guard chrome.controllable else { return true }; pressedPause()
            case .seek(let seconds): guard chrome.controllable else { return true }; pressedSkip(seconds)
            case .speed(let direction): pressedRate(rate.step(direction))
            case .tempo(let direction): pressedRate(Tempo.next(from: rate.value, direction))
            case .mute: if chrome.controllable { onMute?() }
            case .captions: pressedCaptions(nil)
            }
            return true
        }

        private func syncRate() {
            chrome.rate = rate.value
            chrome.controllable = rate.available
        }

        private func pressedRate(_ value: Double) {
            guard rate.pick(value, at: Controls.now) else { return }
            syncRate()
            let request = rate.request
            showRate()
            onRate?(value) { [weak self] actual in
                guard let self, self.rate.acknowledged(actual, request: request, at: Controls.now) else { return }
                self.syncRate()
                if actual != nil { self.showRate() }
            }
        }

        private func showRate() {
            reveal.signal(at: Controls.now, for: 1.3)
            apply()
        }

        private func showFeedback(_ text: String) {
            feedbackDue?.cancel()
            reveal.signal(at: Controls.now, for: 1.3)
            apply()
            chrome.feedback = text
            let work = DispatchWorkItem { [weak self] in self?.chrome.feedback = nil }
            feedbackDue = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
        }

        private func pressedClose() { onClose?() }
        private func pressedReturn() { onReturn?() }

        private func pressedSkip(_ seconds: Double) {
            guard chrome.seekable else { return }
            if seconds < 0 { chrome.rewinds += 1 } else { chrome.forwards += 1 }
            if let target = chrome.timeline.clamp(chrome.position + seconds) {
                time.scrub(to: chrome.timeline.fraction(target))
                time.letGo(at: Controls.now)
            }
            chrome.through = time.shown
            onSkip?(seconds)
            showFeedback("\(seconds > 0 ? "+" : "−")\(Int(abs(seconds))) s")
        }

        private func pressedPause() {
            play.press(at: Controls.now)
            chrome.playing = play.playing
            onPlayPause?()
        }

        private func scrubbed(to fraction: Double, final: Bool) {
            guard chrome.seekable else { return }
            let now = Controls.now
            guard let target = chrome.timeline.target(fraction) else { return }
            time.scrub(to: chrome.timeline.fraction(target))
            chrome.through = time.shown
            if final {
                let shown = time.shown
                time.letGo(at: now)
                chrome.scrubbing = false
                reveal.release(at: now)
                onSeek?(shown)
                showFeedback(FloatTime.label(chrome.timeline.target(shown) ?? 0))
            } else {
                if !chrome.scrubbing {
                    chrome.scrubbing = true
                    reveal.hold(at: now)
                }
                if now - lastSeek > 0.12 {
                    lastSeek = now
                    onSeek?(time.shown)
                }
            }
            apply()
        }
    }
}

/// Sites with a player worth following into the little window.
///
/// Anywhere else, a playing video is as likely to be a background as a film,
/// and the difference isn't something a script can tell from the outside. So
/// the list is of places people go to watch, and the shortcut covers the rest.
enum Players {
    /// A host suffix, and for a few shops that also stream, the path that
    /// separates the film from the product page.
    private static let known: [(host: String, path: String?)] = [
        ("youtube.com", nil), ("youtu.be", nil), ("netflix.com", nil),
        ("primevideo.com", nil), ("amazon.com", "/gp/video"), ("amazon.fr", "/gp/video"),
        ("amazon.co.uk", "/gp/video"), ("amazon.de", "/gp/video"),
        ("disneyplus.com", nil), ("tv.apple.com", nil), ("twitch.tv", nil),
        ("vimeo.com", nil), ("dailymotion.com", nil), ("max.com", nil), ("hbomax.com", nil),
        ("canalplus.com", nil), ("mycanal.fr", nil), ("arte.tv", nil), ("france.tv", nil),
        ("tf1.fr", nil), ("6play.fr", nil), ("crunchyroll.com", nil), ("plex.tv", nil),
        ("peacocktv.com", nil), ("hulu.com", nil), ("paramountplus.com", nil),
        ("molotov.tv", nil), ("ocs.fr", nil), ("mubi.com", nil), ("criterionchannel.com", nil),
        ("ted.com", nil), ("nebula.tv", nil), ("curiositystream.com", nil),
    ]

    /// Hosts a test run's bench counts as players' (see `film float` in
    /// Bench.swift). Empty everywhere else.
    static var benchHosts: Set<String> = []

    static func knows(_ url: URL?) -> Bool {
        guard let url, let host = url.host()?.lowercased() else { return false }
        if benchHosts.contains(host) { return true }
        let path = url.path().lowercased()
        return known.contains { entry in
            guard host == entry.host || host.hasSuffix("." + entry.host) else { return false }
            guard let needle = entry.path else { return true }
            return path.hasPrefix(needle)
        }
    }
}

/// Sites whose videos never float out on their own: the site card's Don't
/// Float Videos Here (#267). Only switching tabs or apps is held back; ⇧⌘P
/// still lifts one by hand. Kept by host, as a site's sound is, and
/// forgotten with the other site choices (Browser.forgetCaptureChoices).
enum Grounded {
    static let prefix = "nofloat."

    static func holds(_ host: String) -> Bool {
        Store.settings.bool(forKey: prefix + host)
    }

    /// Off keeps nothing, as Autoplay's does.
    static func set(_ on: Bool, for host: String) {
        if on {
            Store.settings.set(true, forKey: prefix + host)
        } else {
            Store.settings.removeObject(forKey: prefix + host)
        }
    }
}

/// A panel that takes key status without bringing the whole app forward.
///
/// Borderless windows refuse to become key by default, and a window that never
/// becomes key is a window the system stops routing gestures to.
final class FloatPanel: KitLitPanel {
    var onPress: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onPress?() }
        super.sendEvent(event)
    }
}

final class FloatOutline: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .fullScreenUI
        blendingMode = .withinWindow
        appearance = NSAppearance(named: .darkAqua)
        state = KitLitPanel.holds ? .active : .followsWindowActiveState
        maskImage = FloatOutline.mask(FloatLayout.corner)
    }

    var shaped = true {
        didSet { maskImage = shaped ? FloatOutline.mask(FloatLayout.corner) : NSImage(size: NSSize(width: 1, height: 1)) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func mask(_ radius: CGFloat) -> NSImage {
        let reach = (radius * 1.53).rounded(.up)
        let side = reach * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let shape = CALayer()
            shape.frame = bounds
            shape.backgroundColor = NSColor.black.cgColor
            shape.cornerRadius = radius
            shape.cornerCurve = .continuous
            shape.render(in: context)
            return true
        }
        image.capInsets = NSEdgeInsets(top: reach, left: reach, bottom: reach, right: reach)
        image.resizingMode = .stretch
        return image
    }
}

private final class Ground: NSView {
    weak var page: NSView?
    var onLost: (() -> Void)?

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        if subview === page { onLost?() }
    }
}

/// Waits for a page moved between the tab and the floating window to settle
/// where it now is (`Isolate.fits` going out, `Isolate.off` coming back), so
/// that what covers it meanwhile comes off once, onto the page as it will
/// stay. The page is asked as often as the screen draws, one question at a
/// time, since an answer from JavaScript comes back once and not when
/// something changes; and whatever it says, the wait is over at the limit.
@MainActor
final class Settling {
    private var clock: Timer?
    private var then: (() -> Void)?
    private var asking = false
    private var drawn = false

    func watch(_ web: WKWebView, within limit: TimeInterval, then: @escaping () -> Void) {
        stop()
        self.then = then
        let began = CACurrentMediaTime()
        let clock = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak web] timer in
            MainActor.assumeIsolated {
                guard let self, self.clock === timer else { return }
                guard let web, CACurrentMediaTime() - began < limit else { return self.end() }
                // The page is drawn as it will stay: only the videos' own
                // pictures are left to catch up, which this side can see.
                if self.drawn {
                    if Settling.picturesFit(web) { self.end() }
                    return
                }
                guard !self.asking else { return }
                self.asking = true
                web.evaluateInSearch(Isolate.settled) { answer in
                    MainActor.assumeIsolated {
                        guard self.clock === timer else { return }
                        guard (answer as? Bool) == true else {
                            self.asking = false
                            return
                        }
                        // Laid out as it will stay, and drawn so by the page;
                        // over once that frame is on screen too, video and
                        // all. Nothing more is asked meanwhile.
                        Settling.afterDrawing(web) {
                            guard self.clock === timer else { return }
                            self.drawn = true
                            if Settling.picturesFit(web) { self.end() }
                        }
                    }
                }
            }
        }
        // Common modes: a landing begun by a click in the floating window is
        // still waited for while the pointer holds something down.
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
    }

    /// Once the page's view has shown what the page has drawn so far: WebKit
    /// draws in the page's own process and hands it to this one a moment
    /// later. At once where WebKit has no way to say.
    static func afterDrawing(_ web: WKWebView, _ then: @escaping () -> Void) {
        let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard web.responds(to: selector) else { return then() }
        typealias Call = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        unsafeBitCast(web.method(for: selector), to: Call.self)(web, selector) {
            MainActor.assumeIsolated { then() }
        }
    }

    /// Whether every video in the page is drawn at the size it is shown.
    /// WebKit draws a video's picture in another of its processes, into a
    /// layer of its own inside the room the page gives it, and when the
    /// room changes size it stretches the old picture to fill it until that
    /// process draws again at the new size, a third of a second on. A
    /// player that keeps its video small for longer than that while it
    /// finds its feet (landing, Isolate.off) has its picture redrawn small,
    /// and then stretched back up: blurred, or in part of its room, until
    /// drawn once more. The layers are WebKit's own and unnamed outside it,
    /// so where they can't be found there is nothing to wait for.
    private static func picturesFit(_ web: WKWebView) -> Bool {
        func fits(_ layer: CALayer) -> Bool {
            if String(describing: type(of: layer)) == "WebAVPlayerLayer" {
                for host in layer.sublayers ?? [] where String(describing: type(of: host)) == "CALayerHost" {
                    if abs(host.bounds.width - layer.bounds.width) > 2 || abs(host.bounds.height - layer.bounds.height) > 2 {
                        return false
                    }
                }
            }
            return (layer.sublayers ?? []).allSatisfy(fits)
        }
        return web.layer.map(fits) ?? true
    }

    /// Over now, whatever the page says: what was waiting is done.
    func end() {
        let then = self.then
        stop()
        then?()
    }

    /// Over, and nothing done: whatever was covered went with its window.
    func stop() {
        clock?.invalidate()
        clock = nil
        then = nil
        asking = false
        drawn = false
    }
}

enum Isolate {
    /// Everything but the video, out of the way. Visibility is inherited, so
    /// hiding the body and turning it back on for the video alone leaves the
    /// player's own machinery running untouched — which is what keeps the
    /// stream alive where cutting the DOM about would kill it.
    static let on = """
    (function () {
      var pick = window.__officeFloatPick;
      window.__officeFloatPick = null;
      var picked = pick && pick.isConnected, videos = picked ? [pick] : document.querySelectorAll('video');
      var picture = \(MiniScripts.picture);
      var best = null, area = 0;
      for (var i = 0; i < videos.length; i++) {
        var v = videos[i];
        if ((v.paused && !v.hasAttribute('\(Tempo.holdMark)')) || v.ended || v.readyState < 2) continue;
        if (!picked && !picture(v)) continue;
        var box = v.getBoundingClientRect();
        if (box.width * box.height >= area) { area = box.width * box.height; best = v; }
      }
      if (!best) {
        for (var k = 0; k < videos.length; k++) if (!videos[k].paused && !videos[k].ended && videos[k].readyState < 2) return 'loading';
        return 'none';
      }

      // Where the video's picture is, for cutting it out of a picture of the
      // page (Float.still): inside its box as `contain` fits it, which is
      // how a video is drawn unless the page says otherwise.
      var r = best.getBoundingClientRect(), pic = [r.left, r.top, r.width, r.height];
      var vw = best.videoWidth, vh = best.videoHeight;
      if (vw && vh && r.width && r.height && getComputedStyle(best).objectFit === 'contain') {
        var fit = Math.min(r.width / vw, r.height / vh);
        pic = [r.left + (r.width - vw * fit) / 2, r.top + (r.height - vh * fit) / 2, vw * fit, vh * fit];
      }
      // And where the video was in the page, at what size of page, for the
      // landing to wait for (see off). Not while the last float is still
      // landing: the page isn't as it was yet, and the place it is going
      // back to is the one kept from before. And whether Twitch's chat was
      // open, for opening it again (see off).
      var wait = window.__officeFloatWait;
      if (!window.__officeFloatHome || !(window.__officeFloatLanding || (wait && wait.landing && !wait.settled))) {
        window.__officeFloatHome = {
          box: [r.left + scrollX, r.top + scrollY, r.width, r.height],
          size: [best.offsetWidth, best.offsetHeight],
          wide: innerWidth, high: innerHeight,
          chat: !!document.querySelector('.right-column:not(.right-column--collapsed) [data-a-target="right-column__toggle-collapse-btn"]')
        };
      }
      var size = window.__officeFloatHome.size;
      // And the picture in it, as `contain` fits it. Twitch's player, in its
      // Studio mode, gives the video the page's whole height and draws the
      // picture in the middle of it, between black bars: scaled whole, the
      // bars took up the little window, and the picture a part of it.
      var shown = size;
      if (vw && vh && size[0] && size[1]) {
        var within = Math.min(size[0] / vw, size[1] / vh);
        shown = [vw * within, vh * within];
      }

      // A landing still waiting for its tab is called off: the page is out
      // again.
      window.__officeFloatLanding = null;
      window.__officeFloatWait = null;
      best.setAttribute('data-office-float', '');
      window.__officeFloatKept = best.tagName === 'VIDEO' ? null : best;
      var sheet = document.getElementById('office-float');
      if (!sheet) {
        sheet = document.createElement('style');
        sheet.id = 'office-float';
        (document.head || document.documentElement).appendChild(sheet);
      }
      sheet.textContent = [
        'html.office-floating, html.office-floating body {',
        'background:#000 !important; overflow:hidden !important; margin:0 !important}',
        'html.office-floating body > * { visibility:hidden !important }',
        'html.office-floating [data-office-float] {',
        'visibility:visible !important; position:fixed !important;',
        'left:0 !important; top:0 !important; right:0 !important; bottom:0 !important;',
        'width:100vw !important; height:100vh !important;',
        'max-width:none !important; max-height:none !important;',
        // The player's own box and clipping must not cut off the floating picture.
        'min-width:0 !important; min-height:0 !important; margin:0 !important; padding:0 !important; border:0 !important;',
        'clip-path:none !important; mask:none !important; -webkit-mask:none !important;',
        'border-radius:0 !important; outline:none !important; box-shadow:none !important;',
        // Players such as Netflix center the element with a translation.
        // With our top/left at zero, that moves it out of the floating window.
        'transform:none !important; translate:none !important; rotate:none !important; scale:none !important;',
        'opacity:1 !important; object-fit:contain !important; z-index:2147483647 !important}',
        // Better, where WebKit can divide one length by another: the video
        // keeps the size it had in its tab, and is only scaled to the
        // window, its picture as large as it goes whole and in the middle,
        // and whatever is around the picture off the window's edges. Made the
        // window's size, its picture is redrawn at that size by another of
        // WebKit's processes a third of a second after everything else, and
        // until then it showed at its old size shrunk with the page, in a
        // part of the window, before growing to fill it.
        size[0] && size[1] ? [
          '@supports (scale: calc(100vw / 1px)) {',
          'html.office-floating [data-office-float] {',
          '--office-float-by: min(calc(100vw / ' + shown[0] + 'px), calc(100vh / ' + shown[1] + 'px));',
          'right:auto !important; bottom:auto !important; margin:0 !important; box-sizing:border-box !important;',
          'width:' + size[0] + 'px !important; height:' + size[1] + 'px !important;',
          'min-width:0 !important; min-height:0 !important; transform-origin:0 0 !important;',
          'transform:translate(calc((100vw - ' + size[0] + 'px * var(--office-float-by)) / 2),',
          ' calc((100vh - ' + size[1] + 'px * var(--office-float-by)) / 2)) scale(var(--office-float-by)) !important}}'
        ].join('') : '',
        // Netflix renders timed text after the video, in a layer of its own
        // beside it or one level up. Keep it above the video without
        // exposing the rest of the player.
        'html.office-floating [data-office-float] ~ .player-timedtext,',
        'html.office-floating :has(> [data-office-float]) > .player-timedtext,',
        'html.office-floating :has([data-office-float]) > .player-timedtext {',
        'visibility:visible !important; z-index:2147483647 !important}',
        // Fixed or not, the video is still cut to the box of any ancestor
        // that clips — YouTube's player does — and in a window this small
        // that box sits partly or wholly off screen, more so on a page that
        // was scrolled. That was the black window.
        'html.office-floating body :has([data-office-float]) {',
        'overflow:visible !important;',
        // And fixed is only fixed to the window while no ancestor makes a
        // box of its own for it: a transform, a filter, containment, a
        // perspective, a backdrop, a container query — Twitch's player has
        // some — and the video was placed and sized inside that box instead,
        // part of it or none of it in the window. An ancestor drawn only
        // when on screen (content-visibility) wasn't drawn at all once the
        // rest of the page was hidden, and one faded out hid the video too.
        'transform:none !important; translate:none !important; rotate:none !important; scale:none !important;',
        'filter:none !important; backdrop-filter:none !important; -webkit-backdrop-filter:none !important;',
        'perspective:none !important; contain:none !important; container-type:normal !important;',
        'will-change:auto !important; content-visibility:visible !important;',
        'clip-path:none !important; mask:none !important; -webkit-mask:none !important;',
        'opacity:1 !important}',
        // The player's own controls would sit under ours, and two sets of
        // buttons on one small window is one set too many.
        'html.office-floating [data-office-float]::-webkit-media-controls {',
        'display:none !important}'
      ].join('');
      document.documentElement.classList.add('office-floating');

      // The mark has to be defended.
      //
      // Everything but the marked element is hidden, so the moment a player
      // rebuilds its DOM — and they all do, on a quality change, an ad break,
      // a React re-render — the mark goes with the old element and the window
      // turns pure black while still holding a perfectly live page. That is the
      // black rectangle, and it is not an orphaned window at all.
      //
      // So the mark is put back on whatever is playing now, four times a
      // second, for as long as the page is out.
      clearInterval(window.__officeFloatWatch);
      window.__officeFloatWatch = setInterval(function () {
        if (document.querySelector('[data-office-float]')) return;
        var kept = window.__officeFloatKept;
        if (kept && kept.isConnected) { kept.setAttribute('data-office-float', ''); return; }
        var again = null, most = 0;
        var all = document.querySelectorAll('video');
        for (var j = 0; j < all.length; j++) {
          var one = all[j];
          if ((one.paused && !one.hasAttribute('\(Tempo.holdMark)')) || one.ended || one.readyState < 2) continue;
          var shape = one.getBoundingClientRect();
          if (shape.width * shape.height >= most) {
            most = shape.width * shape.height;
            again = one;
          }
        }
        if (again) again.setAttribute('data-office-float', '');
      }, 250);

      return { floating: true, picture: pic, page: [innerWidth, innerHeight] };
    })();
    """

    /// Whether the page has settled where it now is: see `fits` and `off`,
    /// which set what this reads.
    static let settled = "!!(window.__officeFloatWait && window.__officeFloatWait.settled)"

    /// Out in the floating window: settled once the page is laid out at the
    /// window's size, CSS pixels, with the video alone in it. Checked as
    /// each frame is drawn, so the frame it answers for is drawn so too.
    static func fits(width: Double, height: Double) -> String {
        """
        (function () {
          var wait = window.__officeFloatWait = { settled: false }, began = Date.now();
          (function frame() {
            if (window.__officeFloatWait !== wait || Date.now() - began > 3000) return;
            var on = document.documentElement.classList.contains('office-floating');
            if (on && Math.abs(innerWidth - \(width)) <= 2 && Math.abs(innerHeight - \(height)) <= 2) {
              wait.settled = true;
              return;
            }
            requestAnimationFrame(frame);
          })();
          return true;
        })();
        """
    }

    /// Stop or start it, and say which it is now.
    /// Step over the bit you missed, or back to it.
    static func skip(_ seconds: Double) -> String {
        """
        (function () {
          var video = document.querySelector('[data-office-float]')
            || document.querySelector('video');
          if (!video) return false;
          \(mediaRange)
          var to = clamp(video.currentTime + (\(seconds)), ranges(video));
          if (to === null) return false;
          video.currentTime = to;
          return true;
        })();
        """
    }

    static func seek(_ fraction: Double) -> String {
        """
        (function () {
          var video = document.querySelector('[data-office-float]')
            || document.querySelector('video');
          if (!video) return false;
          \(mediaRange)
          var list = ranges(video);
          if (!list.length) return false;
          var start = list[0][0], end = Math.max.apply(null, list.map(function (range) { return range[1]; }));
          var to = clamp(start + Math.min(1, Math.max(0, \(fraction))) * (end - start), list);
          if (to === null) return false;
          video.currentTime = to;
          return true;
        })();
        """
    }

    static let toggle = """
    (function () {
      var video = document.querySelector('[data-office-float]')
        || document.querySelector('video');
      if (!video) return true;
      if (video.paused) { video.play(); } else { video.pause(); }
      return !video.paused;
    })();
    """

    /// Everything back as it was — once the page is back in its tab and laid
    /// out at the tab's size. Put back at once, while the page still had
    /// the little window's size, the player fitted the video to that, and
    /// the tab's first frames could show it so: YouTube's, 720×240 in a
    /// 720×405 window, dropped to a strip before it grew again (#257).
    static let off = """
    (function () {
      // The engine may have put the video in its own floating window as well —
      // some players ask for that themselves. Leaving one and not the other
      // leaves you with two.
      try {
        var out = document.querySelector('video[data-office-float]')
          || document.querySelector('video');
        if (out) {
          if (out.webkitPresentationMode === 'picture-in-picture') {
            out.webkitSetPresentationMode('inline');
          }
          if (document.pictureInPictureElement && document.exitPictureInPicture) {
            document.exitPictureInPicture();
          }
        }
      } catch (e) {}

      var root = document.documentElement;
      var landing = window.__officeFloatLanding = {};
      var wait = window.__officeFloatWait = { settled: false, landing: true };
      function put() {
        // Floated again in the meantime: that is the float's now.
        if (window.__officeFloatLanding !== landing) return;
        window.__officeFloatLanding = null;
        clearInterval(window.__officeFloatWatch);
        window.__officeFloatWatch = null;
        root.classList.remove('office-floating');
        var sheet = document.getElementById('office-float');
        if (sheet) sheet.textContent = '';
        var video = document.querySelector('[data-office-float]');
        if (video) video.removeAttribute('data-office-float');
        settle(video);
        reopen();
      }
      // Twitch, in its Studio mode, folds its chat away in a page as narrow as
      // the little window, and opens it again only when asked: back in its
      // tab, the chat stayed shut. Asked here, if it was open as the video
      // went out, once the page is the tab's size again.
      function reopen() {
        var home = window.__officeFloatHome;
        if (!home || !home.chat || root.classList.contains('office-floating')) return;
        if (innerWidth === wide && innerHeight === high) {
          // Put back by the clock, its tab not in front: once it is.
          addEventListener('resize', function again() {
            removeEventListener('resize', again);
            reopen();
          });
          return;
        }
        var shut = document.querySelector('.right-column--collapsed [data-a-target="right-column__toggle-collapse-btn"]');
        if (shut) shut.click();
      }
      // The tab covers the page with a picture of it as it was left, until
      // it is that again (Browser.land). Put back, the page still has the
      // player at the size it was given in the little window, and a player
      // such as YouTube's measures again on a clock of its own, half a
      // second later. So: settled once the video is back where it was, at
      // the size it was, in a page of the size it was, looked at as each
      // frame is drawn. A window resized meanwhile has no such place to go
      // back to, and settles once the video has kept still for 0.3 s.
      function settle(video) {
        var home = window.__officeFloatHome, began = Date.now(), last = null, still = 0;
        function near(a, b) {
          for (var i = 0; i < 4; i++) if (Math.abs(a[i] - b[i]) > 2) return false;
          return true;
        }
        function done() { wait.settled = true; }
        (function frame() {
          if (window.__officeFloatWait !== wait) return;
          var v = video && video.isConnected ? video : document.querySelector('video');
          if (!home || !v || Date.now() - began > 3000) return done();
          var r = v.getBoundingClientRect(), box = [r.left + scrollX, r.top + scrollY, r.width, r.height];
          if (innerWidth === home.wide && innerHeight === home.high) {
            if (near(box, home.box)) return done();
          } else {
            still = last && near(box, last) ? still || Date.now() : 0;
            last = box;
            if (still && Date.now() - still >= 300) return done();
          }
          requestAnimationFrame(frame);
        })();
      }
      // Each frame until the page is laid out at another size than the
      // little window's — the tab's — and its player has had that frame's
      // resize to fit the video to it. A page not drawn, its tab no longer
      // the one in front, is put back by the clock.
      var wide = innerWidth, high = innerHeight, began = Date.now();
      (function frame() {
        if (window.__officeFloatLanding !== landing) return;
        if (innerWidth !== wide || innerHeight !== high || Date.now() - began > 400) return put();
        requestAnimationFrame(frame);
      })();
      setTimeout(put, 1000);
      return 'landing';
    })();
    """
}

extension Float {
    static func surface(_ request: [String: Any]) -> NSView {
        let size = NSSize(width: request["width"] as? Double ?? 400, height: request["height"] as? Double ?? 225)
        let controls = Controls(frame: NSRect(origin: .zero, size: size))
        controls.surface(request)
        return BenchFloating.sized(controls, size)
    }
}
