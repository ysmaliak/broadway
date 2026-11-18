import AppKit
import Combine

final class MiniPlayerView: KitHoverView, NSViewToolTipOwner, KitOnGlass {
    static let height: CGFloat = 44
    static let above: CGFloat = 0
    static let below: CGFloat = UpdateCardView.foot - UpdateCardView.height
    static let full: CGFloat = above + height + below
    static let art: CGFloat = 28
    static let pad: CGFloat = (height - art) / 2
    static let artRadius: CGFloat = SideLook.cardRadius - pad
    static let openInset: CGFloat = 4
    static let wordsLead: CGFloat = 8
    static let wordsEnd: CGFloat = 4
    static let fewestWords: CGFloat = 48
    static let key: CGFloat = 26
    static let keyGap: CGFloat = 2
    static let keysEnd: CGFloat = 7
    static let line: CGFloat = 2
    static let lineLit: CGFloat = 4
    static let lineSide: CGFloat = SideLook.cardRadius
    static let lineUp: CGFloat = 1
    static let lineHit: CGFloat = pad
    static let artWait: TimeInterval = 0.6
    static let timeTravel: CGFloat = 4
    static let timeFade: Double = 0.12
    static let timeCross: Double = 0.5

    let mini: MiniPlayer
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsLayout = true } } }
    var greys: KitGreys = .white { didSet { if greys != oldValue { needsLayout = true } } }
    var onRoom: (() -> Void)?
    var listBottom: CGFloat = 0
    private(set) var room: CGFloat = 0
    private(set) var share: Double = 0
    private(set) var trace: [[Double]] = []
    var filming: [(time: Double, picture: CGImage)]?

    private let card = KitFlippedView()
    private let glass = KitGlass.floating(radius: SideLook.cardRadius)
    private let open = KitButton(.plain(press: 1), label: "Go to Tab")
    private let face = KitFlippedView()
    private let cover = MiniCoverView()
    private let title = MiniWordsView(size: 12, weight: .semibold, color: KitColor.ink)
    private let detail = MiniWordsView(size: 11, weight: .regular, color: KitColor.muted)
    private let clockLine = MiniTimeView()
    private let progress = MiniProgressView()
    private lazy var back = MiniKey("backward.fill", "Previous", size: 13) { [weak self] in self?.pressLeft() }
    private lazy var toggle = MiniToggle { [weak self] in self?.mini.toggle() }
    private lazy var ahead = MiniKey("forward.fill", "Next", size: 13) { [weak self] in self?.pressRight() }
    private var held: MiniPlayer.Item?
    private var shownID: Tab.ID?
    private var shownTitle: String?
    private var shownArt: NSImage?
    private var follow: AnyCancellable?
    private var clock: Timer?
    private var scrubbing: Double?
    private var tipSize: NSSize = .zero
    private var motion: (from: CGFloat, to: CGFloat, fromShare: Double, toShare: Double, start: CFTimeInterval, curve: KitCurve, fade: Bool)?
    private var link: CADisplayLink?
    private var finish: Timer?
    private var waitedFor: Tab.ID?
    private var waitStarted: CFTimeInterval = 0
    private var leaving = false
    private(set) var timeShare: Double = 0
    private var timeRising = true
    private var timeMoves = true
    private var swap: (from: Double, to: Double, start: CFTimeInterval, curve: KitCurve)?
    private var swapBegan: CFTimeInterval = 0
    private(set) var swapTrace: [[Double]] = []
    private var watch: MiniWatch?

    init(mini: MiniPlayer) {
        self.mini = mini
        super.init(frame: .zero)
        wantsLayer = true
        card.wantsLayer = true
        card.layer?.opacity = 0
        addSubview(card)
        card.addSubview(glass)
        open.content = face
        open.action = { [weak self] in self?.mini.open() }
        face.wantsLayer = true
        face.addSubview(cover)
        face.addSubview(title)
        face.addSubview(detail)
        face.addSubview(clockLine)
        card.addSubview(open)
        for key in [back, toggle, ahead] as [NSView] { card.addSubview(key) }
        card.addSubview(progress)
        progress.onSeek = { [weak self] fraction in self?.seek(fraction) }
        progress.onScrub = { [weak self] fraction in self?.scrub(fraction) }
        progress.onStep = { [weak self] forward in self?.mini.skip(back: !forward) }
        progress.onHover = { [weak self] _ in self?.needsLayout = true }
        progress.onGlided = { [weak self] in self?.needsLayout = true }
        progress.said = { [weak self] in (self?.item?.position).map { Self.place($0) } }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Mini Player")
        follow = kitObserve({ [weak self] in self?.mini.item }) { [weak self] _ in
            self?.retarget()
            self?.needsLayout = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var item: MiniPlayer.Item? { mini.item }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: room)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            ticking(false)
            stopLink()
            if let swap {
                timeShare = swap.to
                self.swap = nil
            }
        }
        retarget()
    }

    private var target: (room: CGFloat, share: Double) {
        guard let now = item else { return (0, 0) }
        if now.waiting, shownID != now.id {
            if waitedFor != now.id {
                waitedFor = now.id
                waitStarted = CACurrentMediaTime()
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.artWait) { [weak self] in self?.retarget() }
            }
            if CACurrentMediaTime() - waitStarted < Self.artWait, share == 0 { return (0, 0) }
        }
        return (Self.full, 1)
    }

    func retarget() {
        let want = target
        let goal = motion.map { ($0.to, $0.toShare) } ?? (room, share)
        guard want.room != goal.0 || want.share != goal.1 else { return }
        leaving = want.share == 0
        guard window != nil, superview != nil else {
            room = want.room
            share = want.share
            motion = nil
            apply()
            onRoom?()
            return
        }
        let arriving = want.share > share || want.room > room
        let fade = Motion.reduced
        let curve: KitCurve = fade ? .easeOut(arriving ? 0.18 : 0.12) : arriving ? Motion.kitCover : Motion.kitSettle
        if fade {
            room = want.room
            onRoom?()
        }
        motion = (room, want.room, share, want.share, CACurrentMediaTime(), curve, fade)
        trace = []
        startLink()
        tick()
    }

    private func startLink() {
        finish?.invalidate()
        let ends = [motion.map { $0.start + Self.progressEnd($0.curve) }, swap.map { $0.start + Self.progressEnd($0.curve) }].compactMap { $0 }
        if let last = ends.max() {
            let end = max(0, last - CACurrentMediaTime()) + 0.1
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

    static func progressEnd(_ curve: KitCurve) -> Double {
        switch curve {
        case .none: return 0
        case .spring(let spring): return spring.animation("opacity", from: 0, to: 1).settlingDuration
        case .easeOut(let duration), .easeInOut(let duration): return duration
        }
    }

    @objc private func stepped(_ link: CADisplayLink) {
        tick()
    }

    static func progress(_ curve: KitCurve, at time: Double) -> (share: Double, done: Bool) {
        switch curve {
        case .none: return (1, true)
        case .spring(let spring):
            let end = spring.animation("opacity", from: 0, to: 1).settlingDuration
            return time >= end ? (1, true) : (min(1, max(0, spring.progress(time))), false)
        case .easeOut(let duration), .easeInOut(let duration):
            let t = min(1, max(0, time / max(0.001, duration)))
            return (1 - pow(1 - t, 3), t >= 1)
        }
    }

    private func tick(force: Bool = false) {
        guard motion != nil || swap != nil else {
            stopLink()
            return
        }
        let now = CACurrentMediaTime()
        var stamp = 0.0
        if let motion {
            let time = now - motion.start
            stamp = time
            let step = force ? (share: 1.0, done: true) : Self.progress(motion.curve, at: time)
            room = motion.from + (motion.to - motion.from) * step.share
            share = motion.fromShare + (motion.toShare - motion.fromShare) * step.share
            if step.done {
                room = motion.to
                share = motion.toShare
                self.motion = nil
                if share == 0 { leaving = false }
            }
            apply()
            onRoom?()
            superview?.layoutSubtreeIfNeeded()
            if Store.testing, trace.count < 400 {
                trace.append([time, Double(room), share, Double(listBottom)])
            }
        }
        if let swap {
            let step = force ? (share: 1.0, done: true) : Self.progress(swap.curve, at: now - swap.start)
            timeShare = swap.from + (swap.to - swap.from) * step.share
            if step.done {
                timeShare = swap.to
                self.swap = nil
            }
            if motion == nil { stamp = now - swapBegan }
            needsLayout = true
            layoutSubtreeIfNeeded()
            if Store.testing, swapTrace.count < 400 {
                let look = Self.swapLook(timeShare, rising: timeRising, moves: timeMoves)
                swapTrace.append([now - swapBegan, timeShare, Double(look.line.lift), Double(look.time.lift), look.line.opacity, look.time.opacity,
                                  Double(progress.drawn)])
            }
        }
        if motion == nil, swap == nil { stopLink() }
        if filming != nil { shoot(at: stamp) }
    }

    static func swapLook(_ share: Double, rising: Bool, moves: Bool) -> (line: (opacity: Double, lift: CGFloat), time: (opacity: Double, lift: CGFloat)) {
        let at = min(1, max(0, share))
        guard moves else { return ((1 - at, 0), (at, 0)) }
        let way: CGFloat = rising ? 1 : -1
        let gone = min(1, at / timeCross)
        let come = max(0, (at - (1 - timeCross)) / timeCross)
        return ((1 - gone, -way * timeTravel * at), (come, way * timeTravel * (1 - at)))
    }

    private func turn(_ on: Bool) {
        let want: Double = on ? 1 : 0
        guard want != (swap?.to ?? timeShare) else { return }
        guard window != nil else {
            swap = nil
            timeShare = want
            return
        }
        let now = CACurrentMediaTime()
        if swap == nil {
            timeRising = on
            timeMoves = !Motion.reduced
            swapBegan = now
            swapTrace = []
        }
        swap = (timeShare, want, now, Motion.reduced ? .easeOut(Self.timeFade) : Motion.kitRoll)
        startLink()
    }

    private func paintSwap() {
        let look = Self.swapLook(timeShare, rising: timeRising, moves: timeMoves)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        detail.layer?.opacity = Swift.Float(look.line.opacity)
        detail.layer?.transform = CATransform3DMakeTranslation(0, look.line.lift, 0)
        clockLine.layer?.opacity = Swift.Float(look.time.opacity)
        clockLine.layer?.transform = CATransform3DMakeTranslation(0, look.time.lift, 0)
        CATransaction.commit()
    }

    private func shoot(at time: Double) {
        guard let column = superview, let layer = column.layer, (filming?.count ?? 0) < 90 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(column.bounds.width * scale)
        let height = Int(column.bounds.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        let ground = filmGround
        context.saveGState()
        if layer.isGeometryFlipped || column.isFlipped {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
        }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        context.restoreGState()
        context.setBlendMode(.destinationOver)
        context.setFillColor(ground)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let picture = context.makeImage() { filming?.append((time, picture)) }
    }

    private var filmGround: CGColor {
        var ground = NSColor.windowBackgroundColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { ground = NSColor.windowBackgroundColor.cgColor }
        func bright(_ color: NSColor?) -> Bool { (color?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.5 }
        let lightInk = bright(ink.color(KitColor.ink, .ink, dark: kitDark))
        let system = NSColor(cgColor: ground)?.usingColorSpace(.sRGB)
        if (system?.alphaComponent ?? 0) < 1 || bright(system) == lightInk { ground = NSColor(white: lightInk ? 0.08 : 0.96, alpha: 1).cgColor }
        return ground
    }

    func saveFilm(to folder: URL) -> Int {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var saved = 0
        for (index, frame) in (filming ?? []).enumerated() {
            let url = folder.appendingPathComponent(String(format: "%03d.png", index))
            guard let target = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(target, frame.picture, nil)
            if CGImageDestinationFinalize(target) { saved += 1 }
        }
        let times = (filming ?? []).map(\.time)
        if let data = try? JSONSerialization.data(withJSONObject: times) {
            try? data.write(to: folder.appendingPathComponent("times.json"))
        }
        return saved
    }

    private func apply() {
        guard let layer = card.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = Swift.Float(share)
        let moves = motion.map { !$0.fade } ?? !Motion.reduced
        let scale = moves ? 0.96 + 0.04 * share : 1
        let drop = moves ? 6 * (1 - share) : 0
        let size = card.bounds.size
        var transform = CATransform3DMakeTranslation(size.width / 2, size.height / 2 + drop, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -size.width / 2, -size.height / 2, 0)
        layer.transform = transform
        CATransaction.commit()
        card.isHidden = share <= 0.001 && motion == nil
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    var cardFrameInColumn: NSRect { convert(card.frame, to: superview) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard item != nil, share > 0.5, !leaving, let superview else { return nil }
        let local = convert(point, from: superview)
        if grabsLine(local) { return progress }
        guard card.frame.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }

    var lineGrab: NSRect { KitReach.rect(convert(progress.frame, from: card), reach: KitReach.least).intersection(bounds) }

    private func grabsLine(_ local: NSPoint) -> Bool {
        guard !progress.isHidden, progress.seekable, lineGrab.contains(local) else { return false }
        return ![back, toggle, ahead].contains { !$0.isHidden && convert($0.frame, from: card).contains(local) }
    }

    override func layout() {
        super.layout()
        let now = item
        if let now { held = now }
        setAccessibilityElement(now != nil)
        guard let shown = now ?? held else { return }
        let side = Metrics.sideInset
        let box = NSRect(x: side, y: bounds.height - Self.below - Self.height, width: max(0, bounds.width - side * 2), height: Self.height)
        if card.frame != box {
            card.frame = box
            apply()
        }
        glass.frame = card.bounds
        glass.tintColor = Palette.NS.glassTint
        dress(shown)
        lay(shown, width: box.width, dark: kitDark)
        let second = shown.detail.isEmpty ? shown.site : shown.detail
        open.setAccessibilityLabel(second.isEmpty ? shown.title : "\(shown.title), \(second)")
        open.setAccessibilityHelp(shown.site.isEmpty ? "Go to Tab" : "Go to \(shown.site)")
        if shownID != nil, shownID != shown.id || shownTitle != shown.title || shownArt !== shown.art {
            face.layer?.kitTransition(Motion.kitSettle)
        }
        shownID = shown.id
        shownTitle = shown.title
        shownArt = shown.art
        ticking(now != nil && shown.playing && timed(shown))
    }

    private func lay(_ shown: MiniPlayer.Item, width: CGFloat, dark: Bool) {
        let key = Self.key
        let keyY = (Self.height - key) / 2
        let pair = shown.pair != .none
        ahead.frame = NSRect(x: width - Self.keysEnd - key, y: keyY, width: key, height: key)
        toggle.frame = NSRect(x: pair ? ahead.frame.minX - Self.keyGap - key : ahead.frame.minX, y: keyY, width: key, height: key)
        back.frame = NSRect(x: toggle.frame.minX - Self.keyGap - key, y: keyY, width: key, height: key)
        back.isHidden = !pair
        ahead.isHidden = !pair
        let keys = pair ? back.frame.minX : toggle.frame.minX

        let inset = Self.openInset
        open.frame = NSRect(x: inset, y: inset, width: max(0, keys - Self.wordsEnd - inset), height: Self.height - inset * 2)
        if tipSize != open.frame.size {
            tipSize = open.frame.size
            open.removeAllToolTips()
            open.addToolTip(NSRect(origin: .zero, size: tipSize), owner: self, userData: nil)
        }
        let artAt = Self.pad - inset
        let lead = artAt + Self.art + Self.wordsLead
        let artShown = open.frame.width - lead >= Self.fewestWords
        cover.isHidden = !artShown
        cover.frame = NSRect(x: artAt, y: artAt, width: Self.art, height: Self.art)
        let start = artShown ? lead : artAt
        let room = max(0, open.frame.width - start)
        let titleHeight = ceil(12 * 1.3)
        let detailHeight = ceil(11 * 1.3)
        let second = Self.second(shown)
        let timing = timed(shown)
        turn(timing)
        let stack = titleHeight + detailHeight * (second.isEmpty ? timeShare : 1)
        let y = (open.frame.height - stack) / 2
        title.frame = kitSnap(NSRect(x: start, y: y, width: room, height: titleHeight))
        detail.frame = kitSnap(NSRect(x: start, y: y + titleHeight, width: room, height: detailHeight))
        clockLine.frame = detail.frame
        detail.isHidden = second.isEmpty
        title.text = shown.title
        detail.text = second
        if timing, let position = shown.position {
            let at = (scrubbing.map { $0 * position.duration } ?? position.elapsed(now: Date())).rounded(.down)
            clockLine.show(MiniRule.clock(at), of: MiniRule.clock(position.duration))
        } else if timeShare == 0, swap == nil {
            clockLine.clear()
        }
        clockLine.isHidden = timeShare == 0 && swap == nil
        title.moving = hovering
        for words in [title, detail] { words.ink = ink }
        clockLine.ink = ink
        paintSwap()
        cover.art = shown.art
        cover.icon = shown.icon
        cover.letter = String((shown.site.isEmpty ? shown.title : shown.site).prefix(1)).uppercased()
        cover.paint(ink: ink, greys: greys, dark: dark, scale: window?.backingScaleFactor ?? 2)

        if let position = shown.position, !shown.live {
            progress.isHidden = false
            progress.frame = NSRect(x: Self.lineSide, y: Self.height - Self.lineHit, width: max(0, width - Self.lineSide * 2), height: Self.lineHit)
            progress.seekable = shown.seekable
            progress.show(position, ink: ink, dark: dark, scrub: scrubbing, lit: shown.seekable ? timeShare : 0)
        } else {
            progress.isHidden = true
        }
    }

    private func timed(_ shown: MiniPlayer.Item) -> Bool {
        guard shown.position != nil, !shown.live, !progress.isHidden else { return false }
        return scrubbing != nil || progress.hovering
    }

    static func second(_ shown: MiniPlayer.Item) -> String {
        let base = shown.detail.isEmpty ? shown.site : shown.detail
        var parts: [String] = []
        if shown.live { parts.append("Live") }
        if shown.speed, abs(shown.rate - 1) > 0.001 { parts.append(VideoSpeed.label(shown.rate)) }
        if !base.isEmpty { parts.append(base) }
        return parts.joined(separator: " · ")
    }

    static func place(_ position: MiniPosition, now: Date = Date()) -> String {
        "\(MiniRule.clock(position.elapsed(now: now))) of \(MiniRule.clock(position.duration))"
    }

    static func times(_ shown: MiniPlayer.Item, now: Date = Date()) -> String {
        if shown.live { return "Live" }
        return shown.position.map { place($0, now: now) } ?? ""
    }

    static func tip(_ shown: MiniPlayer.Item, now: Date = Date()) -> String {
        let second = shown.detail.isEmpty ? shown.site : shown.detail
        return [shown.title, second, times(shown, now: now)].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        (item ?? held).map { Self.tip($0) } ?? ""
    }

    override func accessibilityValue() -> Any? {
        item.map { Self.times($0) }
    }

    private func dress(_ shown: MiniPlayer.Item) {
        toggle.show(playing: shown.playing)
        switch shown.pair {
        case .tracks:
            back.set("backward.fill", words: "Previous")
            ahead.set("forward.fill", words: "Next")
            back.isEnabled = shown.previous
            ahead.isEnabled = shown.next
        case .seconds:
            back.set(MiniRule.symbol(back: true, seconds: shown.skip), words: "Back \(shown.skip) Seconds")
            ahead.set(MiniRule.symbol(back: false, seconds: shown.skip), words: "Forward \(shown.skip) Seconds")
            back.isEnabled = true
            ahead.isEnabled = true
        case .none:
            break
        }
        for key in [back, ahead] { key.ink = ink }
        toggle.ink = ink
    }

    private func pressLeft() {
        guard let shown = item else { return }
        shown.pair == .tracks ? mini.track(next: false) : mini.skip(back: true)
    }

    private func pressRight() {
        guard let shown = item else { return }
        shown.pair == .tracks ? mini.track(next: true) : mini.skip(back: false)
    }

    private func seek(_ fraction: Double) {
        mini.seek(to: fraction)
        scrubbing = nil
        needsLayout = true
    }

    private func scrub(_ fraction: Double) {
        scrubbing = fraction
        needsLayout = true
    }

    private func ticking(_ on: Bool) {
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        let wanted = on && (visible || Store.testing)
        guard wanted != (clock != nil) else { return }
        clock?.invalidate()
        clock = nil
        guard wanted else { return }
        schedule()
    }

    private func schedule() {
        guard let position = item?.position, position.playing, position.rate > 0 else { return }
        let at = position.elapsed(now: Date())
        let wait = max(0.05, ((at.rounded(.down) + 1) - at) / position.rate + 0.01)
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clock = nil
                self.needsLayout = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    override func hoverChanged() {
        needsLayout = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let shown = item else { return nil }
        return KitMenu.make(Self.menuItems(shown, mini: mini))
    }

    static func menuItems(_ shown: MiniPlayer.Item, mini: MiniPlayer) -> [KitMenuItem] {
        var items: [KitMenuItem] = [.action(shown.playing ? "Pause" : "Play") { mini.toggle() }]
        if shown.pair != .tracks, shown.previous || shown.next {
            items.append(.action("Previous", enabled: shown.previous) { mini.track(next: false) })
            items.append(.action("Next", enabled: shown.next) { mini.track(next: true) })
        }
        if shown.pair != .seconds, shown.position != nil {
            items.append(.action("Back \(shown.skip) Seconds") { mini.skip(back: true) })
            items.append(.action("Forward \(shown.skip) Seconds") { mini.skip(back: false) })
        }
        if shown.speed {
            items.append(.submenu("Speed", MiniRule.steps(around: shown.rate).map { rate in
                .action(VideoSpeed.label(rate), on: abs(rate - shown.rate) < 0.001) { mini.speed(rate) }
            }))
        }
        items.append(.separator)
        items.append(.action(shown.muted ? "Unmute Tab" : "Mute Tab") { mini.mute() })
        items.append(.action("Go to Tab") { mini.open() })
        let others = mini.items.filter { $0.id != shown.id }
        if !others.isEmpty {
            items.append(.separator)
            items.append(.header("Also Playing"))
            for other in others {
                items.append(.action(other.title) { mini.choose(other.id) })
            }
        }
        items.append(.separator)
        items.append(.action("Hide Player") { mini.dismiss() })
        return items
    }

    var benchFrames: [String: [Double]] {
        layoutSubtreeIfNeeded()
        var out: [String: [Double]] = [:]
        func walk(_ view: NSView, _ path: String) {
            for (index, sub) in view.subviews.enumerated() {
                let name = "\(path)/\(index):\(String(describing: type(of: sub)))"
                let frame = sub.frame
                out[name] = [frame.minX, frame.minY, frame.width, frame.height].map(Double.init)
                walk(sub, name)
            }
        }
        walk(self, "")
        return out
    }

    var benchState: [String: Any] {
        layoutSubtreeIfNeeded()
        let column = superview.map { $0.convert($0.bounds, to: nil) } ?? .zero
        let windowHeight = window?.contentView?.bounds.height ?? 0
        let cardWindow = card.convert(card.bounds, to: nil)
        func top(_ rect: NSRect) -> [Double] { [rect.minX, windowHeight - rect.maxY, rect.width, rect.height].map(Double.init) }
        func inCard(_ view: NSView) -> [Double] {
            guard !view.isHidden else { return [] }
            let frame = card.convert(view.bounds, from: view)
            return [frame.minX, frame.minY, frame.width, frame.height].map(Double.init)
        }
        return ["hovering": hovering, "room": Double(room), "share": share, "card": Double(card.frame.width),
                "cardFrame": [card.frame.minX, card.frame.minY, card.frame.width, card.frame.height].map(Double.init),
                "titleWidth": title.frame.width, "titleCut": title.cut, "sliding": title.sliding, "overflows": title.overflows,
                "cardInWindow": top(cardWindow), "column": top(column),
                "scale": Double(window?.backingScaleFactor ?? 2),
                "tip": (item ?? held).map { Self.tip($0) } ?? "", "value": accessibilityValue() as? String ?? "",
                "help": open.accessibilityHelp() ?? "", "label": open.accessibilityLabel() ?? "",
                "detail": (swap?.to ?? timeShare) == 1 ? clockLine.text : detail.text, "title": title.text,
                "time": clockLine.text, "timeShare": timeShare, "swap": swapTrace,
                "line": progress.drawnFraction ?? NSNull(), "lineThick": Double(progress.thick),
                "lineFrame": progress.isHidden ? [] : progress.lineBox.map { card.convert($0, from: progress) }
                    .map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) } ?? [],
                "artFrame": inCard(cover), "titleFrame": inCard(title),
                "keyFrames": [back, toggle, ahead].map(inCard).filter { !$0.isEmpty },
                "buttons": card.kitSubviews(of: KitButton.self).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { $0.accessibilityLabel() },
                "toggle": toggle.showing, "artInFirstFrame": trace.first.map { _ in shownArt != nil } ?? (shownArt != nil),
                "trace": trace, "frames": benchFrames]
    }

    func benchLineHover(_ on: Bool) {
        progress.benchPillHover(on)
        needsLayout = true
    }
}

final class MiniKey: KitButton {
    private let ring = CALayer()
    private let symbol: KitSymbol
    var ink: KitInk = .flat { didSet { symbol.ink = ink; paintRing() } }

    init(_ name: String, _ words: String, size: CGFloat, action: @escaping () -> Void) {
        symbol = KitSymbol(name, style: KitSymbol.Style(size: size, weight: .semibold), tint: KitColor.ink)
        super.init(.plain(press: 0.9), label: words, action: action)
        layer?.insertSublayer(ring, at: 0)
        content = symbol
        toolTip = words
        symbol.opacity = 0.8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(_ name: String, words: String) {
        if symbol.name != name { symbol.fade(to: name) }
        setAccessibilityLabel(words)
        toolTip = words
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }

    override func hoverChanged() {
        super.hoverChanged()
        paintRing()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintRing()
    }

    private func paintRing() {
        let lit = hovering && isEnabled
        let color = ink.color(KitColor.ink, .ink, opacity: lit ? 0.1 : 0, dark: kitDark).cgColor
        ring.kitAnimateColor(color)
        symbol.opacity = lit ? 1 : 0.8
    }
}

final class MiniToggle: KitButton {
    private let glyph = MiniGlyph()
    private(set) var showing = "play"
    var ink: KitInk = .flat { didSet { if ink != oldValue { paintGlyph() } } }

    init(action: @escaping () -> Void) {
        super.init(.pill(.primary), label: "Play", action: action)
        content = glyph
        glyph.show("play.fill", animated: false)
        toolTip = "Play"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: MiniPlayerView.key, height: MiniPlayerView.key) }

    func show(playing: Bool) {
        let name = playing ? "pause" : "play"
        guard name != showing else { return }
        showing = name
        glyph.show(playing ? "pause.fill" : "play.fill", animated: window != nil)
        setAccessibilityLabel(playing ? "Pause" : "Play")
        toolTip = playing ? "Pause" : "Play"
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintGlyph()
    }

    override func layout() {
        super.layout()
        glyph.frame = bounds
        paintGlyph()
    }

    private func paintGlyph() {
        glyph.contentTintColor = KitPill.ink(.primary)
    }
}

final class MiniGlyph: NSImageView {
    static let style = KitSymbol.Style(size: 11, weight: .bold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleNone
        imageAlignment = .alignCenter
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { false }

    private(set) var replaced = 0

    func show(_ name: String, animated: Bool) {
        guard let next = KitGlyph.image(name, Self.style) else { return }
        if animated, kitReplaces {
            replaced += 1
            setSymbolImage(next, contentTransition: .replace)
        } else {
            image = next
        }
    }
}

final class MiniCoverView: KitFlippedView {
    var art: NSImage? { didSet { if art !== oldValue { needsLayout = true } } }
    var icon: NSImage? { didSet { if icon !== oldValue { needsLayout = true } } }
    var letter = "" { didSet { if letter != oldValue { initial.text = letter } } }
    private let picture = CALayer()
    private let initial = KitLabel("", font: .systemFont(ofSize: 13, weight: .semibold), color: KitColor.muted)
    private var painted: (image: NSImage, scale: CGFloat, dark: Bool)?
    private(set) var paints = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        picture.contentsGravity = .resizeAspectFill
        picture.minificationFilter = .trilinear
        picture.magnificationFilter = .linear
        layer?.addSublayer(picture)
        addSubview(initial)
        initial.alignment = .center
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var showsArt: Bool { art != nil }

    func paint(ink: KitInk, greys: KitGreys, dark: Bool, scale: CGFloat) {
        guard let layer else { return }
        let side = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = MiniPlayerView.artRadius
        layer.backgroundColor = greys.tile(ink, dark: dark).cgColor
        layer.borderColor = ink.color(KitColor.ink, .ink, opacity: 0.08, dark: dark).cgColor
        layer.borderWidth = 0.5
        let shown = art ?? icon
        let inset: CGFloat = art != nil ? 0 : round(side * 0.2)
        picture.frame = bounds.insetBy(dx: inset, dy: inset)
        picture.contentsScale = scale
        if painted?.image !== shown || (shown != nil && (painted?.scale != scale || painted?.dark != dark)) {
            picture.contents = shown.map { $0.layerContents(forContentsScale: scale) }
            painted = shown.map { ($0, scale, dark) }
            paints += 1
        }
        picture.contentsGravity = art != nil ? .resizeAspectFill : .resizeAspect
        picture.isHidden = shown == nil
        picture.cornerRadius = art == nil ? 3 : 0
        picture.masksToBounds = art == nil
        picture.zPosition = -1
        CATransaction.commit()
        initial.isHidden = shown != nil
        initial.ink = ink
        let size = initial.intrinsicContentSize
        initial.frame = kitSnap(NSRect(x: 0, y: (side - size.height) / 2, width: side, height: size.height))
    }
}

final class MiniWordsView: KitFlippedView {
    static let pace: CGFloat = 36
    static let wait: Double = 0.6
    static let hold: Double = 1.1
    static let edge: CGFloat = 12

    private let label: KitLabel
    private let fade = CAGradientLayer()
    private let whole = CALayer()
    private var ran = false
    private var running = false
    private var returning = false
    private var turn = 0

    var text: String {
        get { label.text }
        set {
            guard label.text != newValue else { return }
            label.text = newValue
            label.setAccessibilityLabel(newValue)
            stop()
            ran = false
            needsLayout = true
        }
    }
    var ink: KitInk {
        get { label.ink }
        set { label.ink = newValue }
    }
    var moving = false {
        didSet {
            guard moving != oldValue else { return }
            if !moving {
                home()
                ran = false
            }
            needsLayout = true
        }
    }

    init(size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        label = KitLabel("", font: .systemFont(ofSize: size, weight: weight), color: color)
        super.init(frame: .zero)
        wantsLayer = true
        label.wantsLayer = true
        label.overflow = .fade(0)
        addSubview(label)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var overflows: Bool { label.intrinsicContentSize.width > bounds.width + 0.5 }
    var slidingPicture: CGImage? { whole.superlayer == nil ? nil : (whole.contents as! CGImage?) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stop()
    }
    var cut: Bool { overflows && !running }
    var sliding: Bool { running }
    var homing: Bool { returning }
    var offsetStandIn: Double?

    var benchSlide: (offset: Double, edges: [Double]) {
        let shown = whole.superlayer == nil ? nil : whole.presentation() ?? whole
        let offset = (shown?.value(forKeyPath: "transform.translation.x") as? NSNumber)?.doubleValue ?? 0
        let edges = layer?.mask == nil ? [] : ((fade.presentation() ?? fade).locations ?? []).map(\.doubleValue)
        return (offset, edges)
    }

    override func layout() {
        super.layout()
        let natural = label.intrinsicContentSize
        let extra = natural.width - bounds.width
        if running || returning, extra <= 0.5 { stop() }
        let starts = moving && !ran && !running && !returning && extra > 0.5 && Motion.kitQuick.animates
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.frame = kitPlace(NSRect(x: 0, y: (bounds.height - natural.height) / 2, width: max(natural.width, bounds.width), height: natural.height))
        if extra > 0.5 {
            fade.frame = bounds
            if !running { fade.locations = Self.edges(start: false, end: true, width: bounds.width) }
            layer?.mask = fade
        } else {
            layer?.mask = nil
        }
        CATransaction.commit()
        if starts { run(extra) }
    }

    static func edges(start: Bool, end: Bool, width: CGFloat) -> [NSNumber] {
        let edge = width > edge * 2 ? Double(edge / width) : 0
        return [0, NSNumber(value: start ? edge : 0), NSNumber(value: end ? 1 - edge : 1), 1]
    }

    private func run(_ extra: CGFloat) {
        guard let layer, let drawn = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return }
        label.cacheDisplay(in: label.bounds, to: drawn)
        guard let picture = drawn.cgImage else { return }
        running = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        whole.contents = picture
        whole.contentsScale = window?.backingScaleFactor ?? 2
        whole.frame = label.frame
        layer.addSublayer(whole)
        label.alphaValue = 0
        CATransaction.commit()
        let travel = max(0.5, Double(extra / Self.pace))
        let back = max(0.35, travel * 0.5)
        let total = Self.wait + travel + Self.hold + back
        let slide = CAKeyframeAnimation(keyPath: "transform.translation.x")
        slide.values = [0, 0, -extra, -extra, 0]
        slide.keyTimes = [0, Self.wait / total, (Self.wait + travel) / total, (Self.wait + travel + Self.hold) / total, 1].map { NSNumber(value: $0) }
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        slide.timingFunctions = [ease, ease, ease, ease]
        slide.duration = total
        let both = Self.edges(start: true, end: true, width: bounds.width)
        let atEnd = Self.edges(start: true, end: false, width: bounds.width)
        let resting = Self.edges(start: false, end: true, width: bounds.width)
        let edges = CAKeyframeAnimation(keyPath: "locations")
        edges.values = [resting, both, atEnd, both, resting]
        edges.keyTimes = slide.keyTimes
        edges.timingFunctions = slide.timingFunctions
        edges.duration = total
        turn &+= 1
        let mine = turn
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, self.turn == mine else { return }
                self.running = false
                self.ran = true
                self.rest()
                self.needsLayout = true
            }
        }
        whole.add(slide, forKey: "slide")
        fade.add(edges, forKey: "slide")
        CATransaction.commit()
    }

    private func home() {
        guard running else { return }
        let resting = Self.edges(start: false, end: true, width: bounds.width)
        let seen = ((whole.presentation() ?? whole).value(forKeyPath: "transform.translation.x") as? NSNumber)?.doubleValue ?? 0
        let from = Store.testing ? offsetStandIn ?? seen : seen
        let edges = (fade.presentation() ?? fade).locations ?? resting
        running = false
        turn &+= 1
        let mine = turn
        whole.removeAnimation(forKey: "slide")
        fade.removeAnimation(forKey: "slide")
        guard abs(from) > 0.5, let slide = Motion.kitRoll.animation("transform.translation.x", from: from, to: 0),
              let lift = Motion.kitRoll.animation("locations", from: edges, to: resting) else {
            rest()
            return
        }
        returning = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.locations = resting
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.returning, self.turn == mine else { return }
                self.returning = false
                self.rest()
                self.needsLayout = true
            }
        }
        whole.add(slide, forKey: "home")
        fade.add(lift, forKey: "home")
        CATransaction.commit()
    }

    private func stop() {
        guard running || returning else { return }
        running = false
        returning = false
        turn &+= 1
        for key in ["slide", "home"] {
            whole.removeAnimation(forKey: key)
            fade.removeAnimation(forKey: key)
        }
        rest()
    }

    private func rest() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        whole.removeFromSuperlayer()
        whole.contents = nil
        label.alphaValue = 1
        CATransaction.commit()
    }
}

final class MiniTimeView: KitFlippedView {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private let label = KitLabel("", font: font, color: KitColor.muted)
    private var at = ""
    private var total = ""
    var ink: KitInk {
        get { label.ink }
        set { label.ink = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.setAccessibilityElement(false)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func width(_ text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    static func said(_ at: String, of total: String, in width: CGFloat) -> String {
        let both = "\(at) / \(total)"
        return Self.width(both) <= width + 0.5 ? both : at
    }

    var text: String { at.isEmpty ? "" : Self.said(at, of: total, in: bounds.width) }

    func show(_ at: String, of total: String) {
        guard at != self.at || total != self.total else { return }
        self.at = at
        self.total = total
        write()
    }

    func clear() {
        show("", of: "")
    }

    override func layout() {
        super.layout()
        label.frame = bounds
        write()
    }

    private func write() {
        let font = Self.font
        guard !at.isEmpty else {
            label.runs = [KitLabel.Run(text: "", font: font)]
            return
        }
        let place = KitLabel.Run(text: at, font: font, color: KitColor.ink)
        let rest = String(text.dropFirst(at.count))
        label.runs = rest.isEmpty ? [place] : [place, KitLabel.Run(text: rest, font: font)]
    }
}

final class MiniProgressView: KitHoverView {
    var onSeek: ((Double) -> Void)?
    var onScrub: ((Double) -> Void)?
    var onStep: ((Bool) -> Void)?
    var onGlided: (() -> Void)?
    var seekable = false
    var said: (() -> String?)?
    private let track = CALayer()
    private let fill = CALayer()
    private var shown: (position: MiniPosition, width: CGFloat, thick: CGFloat)?
    private var dragging = false
    private var pressed = false
    private(set) var thick: CGFloat = MiniPlayerView.line
    private(set) var drawn: CGFloat = MiniPlayerView.line
    private(set) var lineBox: NSRect?

    var drawnFraction: Double? {
        guard !isHidden, bounds.width > 0 else { return nil }
        return Double((fill.presentation()?.bounds.width ?? fill.bounds.width) / bounds.width)
    }

    var benchFill: Double { Double(fill.presentation()?.bounds.width ?? fill.bounds.width) }
    var benchRuns: Bool { fill.animation(forKey: "run") != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for part in [track, fill] {
            part.anchorPoint = .zero
            layer?.addSublayer(part)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Position")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func accessibilityValue() -> Any? { said?() }

    override func accessibilityPerformIncrement() -> Bool {
        onStep?(true)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onStep?(false)
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        seekable ? super.hitTest(point) : nil
    }

    override func resetCursorRects() {
        if seekable { addCursorRect(bounds, cursor: .pointingHand) }
    }

    private func fraction(_ event: NSEvent) -> Double {
        let x = convert(event.locationInWindow, from: nil).x
        return bounds.width > 0 ? Double(max(0, min(1, x / bounds.width))) : 0
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        pressed = true
        onScrub?(fraction(event))
    }

    override func mouseDragged(with event: NSEvent) { onScrub?(fraction(event)) }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        onSeek?(fraction(event))
    }

    func show(_ position: MiniPosition, ink: KitInk, dark: Bool, scrub: Double?, lit: Double) {
        thick = (hovering || dragging) && seekable ? MiniPlayerView.lineLit : MiniPlayerView.line
        drawn = MiniPlayerView.line + (MiniPlayerView.lineLit - MiniPlayerView.line) * CGFloat(min(1, max(0, lit)))
        let foot = bounds.height - MiniPlayerView.lineUp
        lineBox = NSRect(x: 0, y: foot - thick, width: bounds.width, height: thick)
        let seen = fill.presentation()?.bounds.width ?? fill.bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.backgroundColor = ink.color(KitColor.ink, .ink, opacity: 0.14, dark: dark).cgColor
        fill.backgroundColor = ink.color(KitColor.ink, .ink, opacity: 0.6, dark: dark).cgColor
        for part in [track, fill] { part.cornerRadius = drawn / 2 }
        track.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: drawn)
        track.position = CGPoint(x: 0, y: foot - drawn)
        fill.position = CGPoint(x: 0, y: foot - drawn)
        let now = Date()
        let width = bounds.width
        let start = max(drawn, width * (scrub ?? position.fraction(now: now)))
        fill.bounds = CGRect(x: 0, y: 0, width: start, height: drawn)
        CATransaction.commit()
        if pressed {
            pressed = false
            glide(from: seen, to: start)
        }
        if scrub != nil || gliding {
            fill.removeAnimation(forKey: "run")
            shown = nil
            return
        }
        if let shown, shown.position == position, shown.width == width, shown.thick == drawn { return }
        shown = (position, width, drawn)
        fill.removeAnimation(forKey: "run")
        guard position.playing, width > 0, position.rate > 0 else { return }
        let left = position.left(now: now) / position.rate
        guard left > 0 else { return }
        let run = CABasicAnimation(keyPath: "bounds.size.width")
        run.fromValue = start
        run.toValue = max(drawn, width)
        run.duration = left
        run.timingFunction = CAMediaTimingFunction(name: .linear)
        run.isRemovedOnCompletion = false
        run.fillMode = .forwards
        fill.add(run, forKey: "run")
    }

    var gliding: Bool { fill.animation(forKey: "glide") != nil }

    private func glide(from seen: CGFloat, to start: CGFloat) {
        fill.removeAnimation(forKey: "glide")
        guard abs(seen - start) > 0.5,
              let move = Motion.kitSettle.animation("bounds.size.width", from: seen - start, to: 0) as? CAPropertyAnimation else { return }
        move.isAdditive = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.onGlided?() }
        }
        fill.add(move, forKey: "glide")
        CATransaction.commit()
    }
}

final class MiniWatch {
    var link: CADisplayLink?
    var start: CFTimeInterval = 0
    var rows: [[String: Any]] = []
    var pictures: [CGImage] = []
    var films = false
    var steps: [[String: Any]] = []
    var ends: Double = 0
    var done: ((MiniWatch) -> Void)?
    var awake: NSObjectProtocol?
    weak var pressed: NSView?
}

extension MiniPlayerView {
    func benchSpot(_ spot: String, _ share: Double) -> NSPoint {
        switch spot {
        case "line":
            return progress.convert(NSPoint(x: progress.bounds.width * share, y: progress.bounds.height - Self.lineUp - Self.line), to: nil)
        case "card":
            return title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), to: nil)
        default:
            return NSPoint(x: -1000, y: -1000)
        }
    }

    func benchSettle() {
        func settle(_ view: NSView) {
            (view as? KitHoverView)?.settleHover()
            view.subviews.forEach(settle)
        }
        settle(self)
    }

    func benchPoint(_ spot: String, _ share: Double) {
        guard Store.testing, let window else { return }
        KitHoverView.pointerStandIn = (window, benchSpot(spot, share))
        benchSettle()
    }

    func benchMouse(_ kind: String, spot: String, _ share: Double) {
        guard Store.testing, let window, let frame = window.contentView?.superview else { return }
        let type: NSEvent.EventType = kind == "down" ? .leftMouseDown : kind == "up" ? .leftMouseUp : .leftMouseDragged
        let point = benchSpot(spot, share)
        KitHoverView.pointerStandIn = (window, point)
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
        switch type {
        case .leftMouseDown:
            watch?.pressed = frame.hitTest(frame.convert(point, from: nil))
            watch?.pressed?.mouseDown(with: event)
        case .leftMouseDragged:
            watch?.pressed?.mouseDragged(with: event)
        default:
            watch?.pressed?.mouseUp(with: event)
            watch?.pressed = nil
        }
    }

    func benchAct(_ steps: [[String: Any]], for seconds: Double, film: Bool, done: @escaping (MiniWatch) -> Void) {
        watch?.link?.invalidate()
        let made = MiniWatch()
        made.start = CACurrentMediaTime()
        made.films = film
        made.steps = steps.sorted { ($0["at"] as? Double ?? 0) < ($1["at"] as? Double ?? 0) }
        made.ends = seconds
        made.done = done
        made.awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "mini act")
        watch = made
        guard let link = (window?.screen ?? NSScreen.main)?.displayLink(target: self, selector: #selector(watched(_:))) else {
            watch = nil
            done(made)
            return
        }
        link.add(to: .main, forMode: .common)
        made.link = link
    }

    private func benchStep(_ step: [String: Any], at time: Double) {
        guard let watch else { return }
        let verb = step["do"] as? String ?? ""
        let spot = step["spot"] as? String ?? "line"
        let share = step["share"] as? Double ?? 0
        watch.rows.append(["t": time, "mark": "\(verb) \(spot) \(share)"])
        switch verb {
        case "point": benchPoint(spot, share)
        case "down", "drag", "up": benchMouse(verb, spot: spot, share)
        case "settle": benchSettle()
        case "seek": mini.seek(to: share)
        case "toggle": mini.toggle()
        default: break
        }
    }

    @objc private func watched(_ link: CADisplayLink) {
        guard let watch else { return }
        let time = CACurrentMediaTime() - watch.start
        if time >= watch.ends {
            watch.link?.invalidate()
            watch.link = nil
            if let awake = watch.awake { ProcessInfo.processInfo.endActivity(awake) }
            self.watch = nil
            watch.done?(watch)
            return
        }
        while let next = watch.steps.first, time >= next["at"] as? Double ?? 0 {
            watch.steps.removeFirst()
            benchStep(next, at: time)
        }
        guard watch.rows.count < 4000 else { return }
        var row = benchRow
        row["t"] = time
        if watch.films, watch.pictures.count < 900, let picture = snap() {
            row["frame"] = watch.pictures.count
            watch.pictures.append(picture)
        }
        watch.rows.append(row)
    }

    private var benchRow: [String: Any] {
        let slide = title.benchSlide
        func seen(_ layer: CALayer?) -> Double { Double(layer?.presentation()?.opacity ?? layer?.opacity ?? 0) }
        return ["title": slide.offset, "edges": slide.edges, "sliding": title.sliding, "words": title.text,
                "timeShare": timeShare, "time": clockLine.text, "timeOpacity": seen(clockLine.layer), "detailOpacity": seen(detail.layer),
                "thick": Double(progress.thick), "drawn": Double(progress.drawn), "fill": progress.benchFill,
                "lineWidth": Double(progress.bounds.width), "runs": progress.benchRuns, "lineHidden": progress.isHidden,
                "key": toggle.showing, "card": hovering, "line": progress.hovering,
                "opacity": seen(card.layer), "share": share, "leaving": leaving,
                "face": face.layer?.animation(forKey: kCATransition) != nil,
                "playing": item?.playing ?? false, "shown": item != nil, "scrub": scrubbing ?? -1,
                "at": item?.position?.elapsed(now: Date()) ?? -1]
    }

    private func snap() -> CGImage? {
        guard let layer else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let box = card.frame.insetBy(dx: -4, dy: -4)
        let width = Int(box.width * scale)
        let height = Int(box.height * scale)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        (layer.presentation() ?? layer).render(in: context)
        context.restoreGState()
        context.setBlendMode(.destinationOver)
        context.setFillColor(filmGround)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func benchSave(_ watch: MiniWatch, to folder: URL) -> Int {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var saved = 0
        for (index, picture) in watch.pictures.enumerated() {
            let url = folder.appendingPathComponent(String(format: "%04d.png", index))
            guard let target = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(target, picture, nil)
            if CGImageDestinationFinalize(target) { saved += 1 }
        }
        return saved
    }
}

extension CALayer {
    func kitAnimateColor(_ color: CGColor) {
        guard backgroundColor != color else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.reduced ? 0 : 0.12)
        backgroundColor = color
        CATransaction.commit()
    }
}

extension MiniPlayer {
    static func surface(lift: Double, frame: Bool, playing: Bool, pair: MiniPair = .tracks) -> NSView {
        let item = Item(id: UUID(), title: pair == .seconds ? "Chapter 7: The Long Way Round" : "Midnight City, the long remix of the song",
                        detail: pair == .seconds ? "A Reader" : "M83", site: "example.com", art: nil, playing: playing, pair: pair,
                        previous: true, next: true,
                        position: MiniPosition(time: 100, duration: pair == .seconds ? 4000 : 240, rate: 1, playing: playing, at: Date()),
                        live: false, rate: pair == .seconds ? 1.5 : 1, speed: pair == .seconds, seekable: true, muted: false, skip: 15)
        let view = MiniPlayerView(mini: MiniPlayer(surface: item))
        view.ink = KitInk(lift: lift)
        view.greys = frame ? .frame : .white
        return BenchFloating.sized(view, NSSize(width: 260, height: MiniPlayerView.full))
    }
}
