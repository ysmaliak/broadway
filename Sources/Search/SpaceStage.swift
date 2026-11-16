import AppKit
import Combine

struct CardClip: Equatable {
    var rect: CGRect
    var corner: CGFloat
}

extension NSView {
    func clip(to card: CardClip?) {
        guard let card else {
            if layer?.mask != nil { layer?.mask = nil }
            return
        }
        wantsLayer = true
        guard let layer else { return }
        let rect = isFlipped ? card.rect : CGRect(x: card.rect.minX, y: bounds.height - card.rect.maxY,
                                                  width: card.rect.width, height: card.rect.height)
        let mask = layer.mask ?? CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.backgroundColor = NSColor.black.cgColor
        mask.frame = rect
        mask.cornerRadius = max(0, min(card.corner, rect.width / 2, rect.height / 2))
        mask.cornerCurve = .continuous
        if layer.mask !== mask { layer.mask = mask }
        CATransaction.commit()
    }
}

final class SpaceStageView: NSView {
    let browser: Browser
    let motion: SpaceMotion
    let content: NSView
    var corner: CGFloat { didSet { if corner != oldValue { needsLayout = true } } }
    var paired = false { didSet { if paired != oldValue { dress() } } }
    var onDress: (() -> Void)?
    private var dressing = false
    var makePreview: ((Parked, UUID) -> NSView)?

    var pageReady: () -> Bool = { true }

    private let body = StageBody()
    private let ride: RideView
    private let pictures: StagePicturesView
    private var previews: [UUID: RideView] = [:]
    private var bare: Set<UUID> = []
    private let rim = PaneEdge()
    private let coming = PaneEdge()
    private let comingHolder = StageBody()
    private let comingRide: RideView
    private(set) var cover: (space: UUID, rider: RideView)?
    private var coverTicket = 0
    private var fitting: DispatchWorkItem?
    static let coverMost: TimeInterval = 0.6
    static let fitAfter: TimeInterval = 0.15

    init(browser: Browser, motion: SpaceMotion, corner: CGFloat, content: NSView) {
        self.browser = browser
        self.motion = motion
        self.corner = corner
        self.content = content
        pictures = StagePicturesView(browser: browser, motion: motion)
        ride = RideView(content: body, motion: motion)
        comingRide = RideView(content: comingHolder, motion: motion)
        super.init(frame: .zero)
        wantsLayer = true
        body.addSubview(content)
        body.addSubview(pictures)
        addSubview(ride)
        comingHolder.addSubview(coming)
        ride.addSubview(rim)
        ride.addSubview(comingRide)
        for view in [rim, comingRide] as [NSView] { view.setAccessibilityElement(false) }
        ride.limits = { [weak browser] in SpaceStageView.limits(browser) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static func limits(_ browser: Browser?) -> ClosedRange<CGFloat> {
        guard let browser else { return 0...0 }
        let real = browser.spaceAt, seen = browser.spaceSeen, next = browser.stageNext
        let rest = -SpaceLane.place(seen, real: real, seen: seen, next: next)
        guard let next, browser.spaces.indices.contains(next) else { return rest...rest }
        let far = -SpaceLane.place(next, real: real, seen: seen, next: next)
        return min(rest, far)...max(rest, far)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dress()
    }

    func dress() {
        guard !dressing else { return }
        dressing = true
        defer { dressing = false }
        onDress?()
        let seen = browser.spaceSeen
        let next = browser.stageNext.flatMap { browser.spaces.indices.contains($0) ? $0 : nil }
        let pair = (cover?.rider.content as? SpaceStagePreviewView)?.apart ?? paired
        let framed = corner > 0 && browser.prefs.splitView && (browser.stageSliding || !pair)
        func ink(_ index: Int) -> NSColor {
            PaneEdge.ink(browser.pageLook(in: browser.spaces.indices.contains(index) ? browser.spaces[index].id : nil), dark: kitDark)
        }
        Still.set {
            rim.isHidden = !framed
            comingRide.isHidden = !framed || next == nil
            rim.corner = corner
            coming.corner = corner
            rim.ink = ink(seen)
            if let next { coming.ink = ink(next) }
            rim.wrap(ride.bounds, in: ride, cut: ride.bounds)
            comingRide.frame = ride.bounds
            comingRide.set(RideLook(here: seen, span: 0, clip: .none, band: false, hits: false, fade: .in, seen: true))
            comingRide.layoutSubtreeIfNeeded()
            coming.wrap(comingHolder.bounds, in: comingHolder, cut: comingHolder.bounds)
        }
    }

    static func coming(here: Int, seen: Int, next: Int?) -> [Int] {
        var shown: [Int] = []
        for index in [seen, next].compactMap({ $0 }) where index != here && !shown.contains(index) {
            shown.append(index)
        }
        return shown
    }

    override func layout() {
        super.layout()
        browser.spaceNeighbour.watch()
        let here = browser.spaceAt
        let next = browser.stageNext
        let seen = browser.spaceSeen
        let calm = Motion.calm
        let switching = !browser.makingSpace && (next.map { browser.spaces.indices.contains($0) } ?? true)
        ride.frame = bounds
        ride.set(RideLook(here: here, span: !switching || calm ? 0 : nil, clip: .card(corner: corner, above: Metrics.cardGap),
                          band: false, own: true))
        ride.layoutSubtreeIfNeeded()
        dress()
        content.frame = body.bounds
        if next == nil { fitParkedSoon() }
        var kept: Set<UUID> = []
        if switching, let makePreview {
            for index in Self.coming(here: here, seen: seen, next: next) where browser.spaces.indices.contains(index) {
                let space = browser.spaces[index].id
                let row = browser.parked[space]
                kept.insert(space)
                if row != nil, bare.contains(space) {
                    previews[space]?.removeFromSuperview()
                    previews[space] = nil
                    bare.remove(space)
                }
                let rider = previews[space] ?? {
                    let page: NSView
                    if let row {
                        page = makePreview(row, space)
                    } else {
                        let ground = PageGroundView()
                        ground.show(browser.pageLook(in: space).page(dark: kitDark))
                        page = ground
                        bare.insert(space)
                    }
                    let made = RideView(content: page, motion: motion)
                    made.setAccessibilityElement(false)
                    body.addSubview(made, positioned: .below, relativeTo: pictures)
                    previews[space] = made
                    return made
                }()
                (rider.content as? SpaceStagePreviewView)?.sliding = true
                rider.frame = body.bounds
                rider.isHidden = calm && index != next
                rider.set(RideLook(here: here, span: 0, clip: .none, band: false, hits: false,
                                   lane: calm ? 0 : SpaceLane.place(index, real: here, seen: seen, next: next),
                                   fade: calm && index == next ? .in : .none))
            }
        }
        let landed = browser.spaces.indices.contains(here) && !browser.makingSpace ? browser.spaces[here].id : nil
        for (space, rider) in previews where !kept.contains(space) {
            previews[space] = nil
            bare.remove(space)
            if space == landed, next == nil, !calm, Self.covers(browser.active) {
                holdCover(rider, space: space, here: here)
                continue
            }
            rider.removeFromSuperview()
        }
        if let cover, cover.space != landed || next != nil {
            dropCover()
        }
        cover?.rider.frame = body.bounds
        pictures.frame = body.bounds
        pictures.corner = corner
        pictures.isHidden = !switching
        pictures.needsLayout = true
    }
}

extension SpaceStageView {
    private func fitParkedSoon() {
        fitting?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fitParked() }
        fitting = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fitAfter, execute: item)
    }

    func fitParked() {
        fitting = nil
        let size = body.bounds.size
        guard browser.stageNext == nil, size.width > 0, size.height > 0 else { return }
        for (space, tab) in Self.parkedPages(browser) {
            guard let web = tab.built, web.window == nil, web.frame.size != size else { continue }
            web.setFrameSize(size)
            browser.spacePictures.retake(tab, in: space)
        }
    }

    static func parkedPages(_ browser: Browser) -> [(UUID, Tab)] {
        browser.parked.compactMap { space, row -> (UUID, Tab)? in
            guard space != browser.spaceID, let active = row.active,
                  !browser.prefs.splitView || !row.splits.contains(where: { $0.contains(active) }),
                  let tab = row.tabs.first(where: { $0.id == active }) else { return nil }
            return (space, tab)
        }
    }

    static func covers(_ tab: Tab?) -> Bool {
        guard let tab else { return false }
        return !tab.isWeb || tab.asleep
    }

    private func holdCover(_ rider: RideView, space: UUID, here: Int) {
        if let cover, cover.rider !== rider { cover.rider.removeFromSuperview() }
        (rider.content as? SpaceStagePreviewView)?.sliding = false
        rider.frame = body.bounds
        rider.set(RideLook(here: here, span: 0, clip: .none, band: false, hits: false))
        cover = (space, rider)
        dress()
        coverTicket += 1
        let ticket = coverTicket
        let until = CACurrentMediaTime() + Self.coverMost
        func check() {
            guard coverTicket == ticket, cover != nil else { return }
            if pageReady() || CACurrentMediaTime() > until { return dropCover() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120) { check() }
        }
        DispatchQueue.main.async { check() }
    }

    func dropCover() {
        guard let cover else { return }
        self.cover = nil
        coverTicket += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.rider.removeFromSuperview()
        CATransaction.commit()
        dress()
    }
}

final class StageBody: NSView {
    override var isFlipped: Bool { true }
}

final class StagePicturesView: NSView {
    let browser: Browser
    let motion: SpaceMotion
    var corner: CGFloat = 0
    private let here = StagePicture()
    private let others = StageBody()
    private let ride: RideView
    private var shown: [UUID: StagePicture] = [:]

    init(browser: Browser, motion: SpaceMotion) {
        self.browser = browser
        self.motion = motion
        ride = RideView(content: others, motion: motion)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(here)
        addSubview(ride)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func image(_ index: Int, here at: Int) -> NSImage? {
        guard browser.spaces.indices.contains(index) else { return nil }
        let space = browser.spaces[index]
        let row = index == at ? Parked(tabs: browser.tabs, active: browser.activeID, splits: browser.splits, groups: browser.tabGroups)
            : browser.parked[space.id]
        guard let row, let tab = row.tabs.first(where: { $0.id == row.active }),
              !browser.prefs.splitView || !row.splits.contains(where: { $0.contains(tab.id) }) else { return nil }
        return index == at ? browser.spacePictures.landingImage(for: tab, in: space.id) : browser.spacePictures.image(for: tab, in: space.id)
    }

    override func layout() {
        super.layout()
        guard !isHidden else { return }
        browser.spaceNeighbour.watch()
        let at = browser.spaceAt
        let seen = browser.spaceSeen
        let next = browser.stageNext
        let calm = Motion.calm
        here.frame = bounds
        here.show(image(at, here: at), corner: 0)
        ride.frame = bounds
        ride.set(RideLook(here: at, span: 0, clip: .none, band: false, hits: false, fade: calm ? .in : .none))
        ride.layoutSubtreeIfNeeded()
        var kept: Set<UUID> = []
        for index in browser.spaces.indices where index != at {
            let space = browser.spaces[index].id
            guard let picture = image(index, here: at) else { continue }
            kept.insert(space)
            let view = shown[space] ?? {
                let made = StagePicture()
                others.addSubview(made)
                shown[space] = made
                return made
            }()
            let lane = calm ? 0 : SpaceLane.place(index, real: at, seen: seen, next: next)
            let frame = others.bounds.offsetBy(dx: lane * bounds.width, dy: 0)
            view.frame = next == nil ? apart(frame, lane: lane) : frame
            view.isHidden = (calm && next != index) || SpaceLane.covered(index, real: at, seen: seen, next: next)
            view.show(picture, corner: 0)
        }
        for (space, view) in shown where !kept.contains(space) {
            view.removeFromSuperview()
            shown[space] = nil
        }
    }

    private func apart(_ frame: CGRect, lane: CGFloat) -> CGRect {
        guard lane != 0, let window else { return frame }
        let edge = lane < 0 ? frame.maxX : frame.minX
        let shift = Self.clearing(edge: convert(CGPoint(x: edge, y: 0), to: nil).x, lane: lane, scale: window.backingScaleFactor)
        return frame.offsetBy(dx: shift, dy: 0)
    }

    static func clearing(edge: CGFloat, lane: CGFloat, scale: CGFloat) -> CGFloat {
        guard lane != 0, scale > 0 else { return 0 }
        let pixels = edge * scale
        let clear = lane < 0 ? pixels.rounded(.down) : pixels.rounded(.up)
        return (clear - pixels) / scale
    }
}

final class StagePicture: NSView {
    private let picture = CALayer()
    let rim = CAShapeLayer()
    private(set) var image: NSImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        picture.contentsGravity = .resize
        rim.fillColor = nil
        rim.isHidden = true
        layer?.addSublayer(picture)
        layer?.addSublayer(rim)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ image: NSImage?, corner: CGFloat, edge: NSColor? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer?.cornerRadius = corner
        guard let image, Self.fits(image.size, bounds.size) else {
            picture.contents = nil
            self.image = nil
            rim.isHidden = true
            return
        }
        if image !== self.image {
            self.image = image
            picture.contents = image
        }
        picture.frame = CGRect(origin: .zero, size: bounds.size)
        guard let edge, corner > 0 else {
            rim.isHidden = true
            return
        }
        rim.frame = picture.frame
        rim.path = PaneEdge.ring(in: rim.bounds, corner: corner)
        rim.fillRule = .evenOdd
        rim.fillColor = edge.cgColor
        rim.isHidden = false
    }

    static let slack: CGFloat = 1

    static func fits(_ image: CGSize, _ frame: CGSize) -> Bool {
        image.width > 0 && image.height > 0 && abs(image.width - frame.width) <= slack && abs(image.height - frame.height) <= slack
    }
}

extension StagePicture {
    static func report(in root: NSView) -> [[String: Any]] {
        guard let window = root.window else { return [] }
        return root.kitSubviews(of: StagePicture.self).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { view in
            guard let image = view.image else { return nil }
            let frame = view.convert(view.bounds, to: nil)
            let top = window.contentLayoutRect.maxY
            return ["box": [frame.minX, top - frame.maxY, frame.maxX, top - frame.minY].map { Double($0) },
                    "image": [Double(image.size.width), Double(image.size.height)],
                    "edge": Double(view.rim.isHidden ? 0 : PaneEdge.width)]
        }
    }
}

extension SpaceStageView {
    func traceReport() -> [String: Any] {
        let width = body.bounds.width
        func shown(_ view: NSView) -> (x: Double, opacity: Double) {
            guard let layer = view.layer else { return (0, 1) }
            let drawn = layer.presentation() ?? layer
            let x = drawn.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
            return (Double(x), Double(drawn.opacity))
        }
        func inside(_ view: NSView) -> Bool {
            let at = shown(view)
            return at.opacity > 0.01 && abs(at.x) < Double(width) - 0.5
        }
        let page = shown(ride.content)
        var intruders: [String] = []
        for (space, rider) in previews where !rider.isHidden && rider.superview != nil && inside(rider.content) {
            intruders.append("preview:\(space.uuidString.prefix(8))@\(Int(shown(rider.content).x))")
        }
        if let cover { intruders.append("cover:\(cover.space.uuidString.prefix(8))") }
        if !comingRide.isHidden, inside(comingRide.content) { intruders.append("coming@\(Int(shown(comingRide.content).x))") }
        if !pictures.isHidden { intruders += pictures.traceReport(width: width) }
        return ["pageX": page.x, "pageOpacity": page.opacity, "width": Double(width), "intruders": intruders,
                "previews": previews.count, "picturesShown": !pictures.isHidden]
    }
}

extension StagePicturesView {
    func traceReport(width: CGFloat) -> [String] {
        var out: [String] = []
        if here.image != nil, !here.isHidden { out.append("picture:here") }
        let rode = (ride.content.layer?.presentation() ?? ride.content.layer)?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
        for (space, view) in shown where !view.isHidden && view.image != nil {
            let x = view.frame.minX + rode
            if abs(x) < width - 0.5 { out.append("picture:\(space.uuidString.prefix(8))@\(Int(x))") }
        }
        return out
    }
}
