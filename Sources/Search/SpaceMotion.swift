import AppKit
import Observation
import Combine

@MainActor
@Observable
final class SpaceMotion: NSObject {
    @ObservationIgnored private(set) var offset: CGFloat = 0
    @ObservationIgnored private(set) var width: CGFloat = 1
    private(set) var step = 0

    private struct Spring {
        let target: CGFloat
        let start: CGFloat
        let velocity: CGFloat
        var began: CFTimeInterval?
        let rate: CGFloat
        var settles: CFTimeInterval = 0
        let done: () -> Void

        func at(_ now: CFTimeInterval) -> (x: CGFloat, v: CGFloat) {
            guard let began else { return (start, velocity) }
            let t = CGFloat(max(0, now - began))
            let a = start - target
            let b = velocity + rate * a
            let fall = exp(-rate * t)
            return (target + (a + b * t) * fall, (b - rate * (a + b * t)) * fall)
        }
    }

    @ObservationIgnored private var spring: Spring?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var period: CFTimeInterval = 1.0 / 120
    @ObservationIgnored private var drawn: CFTimeInterval = 0
    @ObservationIgnored private var idle = 0
    @ObservationIgnored private var onLayers = false
    @ObservationIgnored private var told = 0
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var alone = true
    let riders = NSHashTable<AnyObject>.weakObjects()
    let followers = NSHashTable<AnyObject>.weakObjects()
    let crossing = SpaceCrossing()

    @ObservationIgnored var base: CGFloat = 0
    var local: CGFloat { offset - base }
    var progress: CGFloat { min(1, abs(local) / max(1, width)) }
    var moving: Bool { spring != nil }

    private var riding: [SpaceRiding] { riders.allObjects.compactMap { $0 as? SpaceRiding } }

    private func show(_ x: CGFloat, layers: Bool = true) {
        guard x != offset else { return }
        offset = x
        if layers { riding.forEach { $0.ride(x, width: width) } }
        tell()
    }

    private func tell() {
        for follower in followers.allObjects { (follower as? SpaceFollowing)?.follow(self) }
        let past = progress >= 0.5
        if crossing.past != past { crossing.past = past }
        let step = Int((local / max(1, width) * 96).rounded())
        guard step != told || (local == 0) != (told == 0) else { return }
        told = step
        self.step = step
    }

    private func hand(_ spring: Spring) {
        guard let began = spring.began, spring.settles == 0 else { return }
        let riders = riding
        guard !riders.isEmpty else { return }
        let handed = RideSpring(from: spring.start, to: spring.target, velocity: spring.velocity, rate: spring.rate,
                                began: began, width: width, base: base)
        riders.forEach { $0.spring(handed) }
        onLayers = true
    }

    func follow(_ x: CGFloat, width: CGFloat) {
        spring = nil
        onLayers = false
        self.width = width
        show(x)
        CATransaction.flush()
        idle = 0
        run()
    }

    func carry(to target: CGFloat, width: CGFloat, velocity: CGFloat? = nil, done: @escaping () -> Void) {
        self.width = width
        guard !Motion.reduced else {
            halt()
            show(target)
            return done()
        }
        let now = CACurrentMediaTime()
        let flying = spring.map { $0.began != nil } ?? false
        let going = velocity ?? (flying ? spring?.at(now).v : nil) ?? 0
        let ticking = link != nil || timer != nil
        let clock: CFTimeInterval? = velocity != nil || flying ? (ticking ? max(now, drawn) : now) : nil
        let made = Spring(target: target, start: offset, velocity: going, began: clock,
                          rate: CGFloat(2 * Double.pi / Motion.spaceResponse), done: done)
        spring = made
        onLayers = false
        hand(made)
        idle = 0
        run()
    }

    func bump(_ direction: CGFloat, width: CGFloat) {
        guard !Motion.reduced, spring == nil, offset == 0 else { return }
        self.width = width
        let rate = CGFloat(2 * Double.pi / Motion.spaceResponse)
        spring = Spring(target: 0, start: 0, velocity: direction * SpaceMotion.give * rate * exp(1),
                        began: nil, rate: rate, settles: 2 / Double(rate), done: {})
        run()
    }

    static let give = SpaceReach.give

    func halt() {
        if let spring, onLayers {
            let x = riding.lazy.compactMap(\.shown).first ?? spring.at(CACurrentMediaTime()).x
            onLayers = false
            self.spring = nil
            offset = x
            riding.forEach { $0.ride(x, width: width) }
            tell()
        }
        spring = nil
        onLayers = false
        idle = 0
    }

    func rest() {
        halt()
        base = 0
        show(0)
    }

    func land() {
        spring = nil
        onLayers = false
        idle = 0
        riding.forEach { $0.hold() }
        base = 0
        offset = 0
        tell()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.riding.forEach { $0.letGo() }
        }
    }

    private func run() {
        guard link == nil, timer == nil else { return }
        let shown = window?.isVisible == true && (!Store.testing || Store.shownOnScreen)
        if shown, let window {
            let made = window.displayLink(target: self, selector: #selector(tick(_:)))
            made.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            made.add(to: .main, forMode: .common)
            link = made
        }
        let made = Timer(timeInterval: shown ? 0.1 : 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance(at: CACurrentMediaTime()) }
        }
        RunLoop.main.add(made, forMode: .common)
        timer = made
    }

    private func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let fastest = 1 / Double(max(60, window?.screen?.maximumFramesPerSecond ?? 60))
        let interval = link.targetTimestamp > link.timestamp ? link.targetTimestamp - link.timestamp : period
        guard interval > fastest * 1.5, spring != nil else {
            period = interval
            drawn = link.targetTimestamp
            return advance(at: link.targetTimestamp)
        }
        period = fastest
        var at = link.timestamp + fastest
        while at <= link.targetTimestamp + fastest / 2 {
            let when = at
            let wait = when - fastest + 0.002 - CACurrentMediaTime()
            if when == link.timestamp + fastest {
                drawn = when
                advance(at: when)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, wait)) { [weak self] in
                    guard let self, self.link != nil, self.spring != nil, when > self.drawn else { return }
                    self.drawn = when
                    self.advance(at: when)
                }
            }
            at += fastest
        }
    }

    private func advance(at now: CFTimeInterval) {
        guard var spring else {
            idle += 1
            if idle > 30 { stop() }
            return
        }
        if spring.began == nil {
            spring.began = now - period
            self.spring = spring
            hand(spring)
        }
        let x = spring.at(now).x
        let distance = 0.5 * width / max(width, window?.frame.width ?? width)
        if abs(x - spring.target) < distance, now - (spring.began ?? now) >= spring.settles {
            onLayers = false
            self.spring = nil
            offset = spring.target
            riding.forEach { $0.ride(spring.target, width: width) }
            tell()
            stop()
            spring.done()
        } else {
            show(x, layers: !onLayers)
        }
    }
}

@MainActor
@Observable
final class SpaceCrossing {
    var past = false
}

@MainActor
@Observable
final class SpaceNeighbour {
    @ObservationIgnored var index: Int? {
        didSet {
            revision &+= 1
            onTurn?()
        }
    }
    @ObservationIgnored var shown: Int? {
        didSet {
            revision &+= 1
            onTurn?()
        }
    }
    @ObservationIgnored var onTurn: (() -> Void)?
    private(set) var revision = 0

    func watch() { _ = revision }
}

enum SpaceLane {
    static func stage(_ next: Int?, stacked: Bool) -> Int? {
        stacked ? nil : next
    }

    static func place(_ index: Int, real: Int, seen: Int, next: Int?) -> CGFloat {
        if index == next, abs(index - seen) > 1 { return CGFloat(seen - real + (index > seen ? 1 : -1)) }
        return CGFloat(index - real)
    }

    static func covered(_ index: Int, real: Int, seen: Int, next: Int?) -> Bool {
        guard let next, index != next, abs(next - seen) > 1 else { return false }
        return place(index, real: real, seen: seen, next: next) == place(next, real: real, seen: seen, next: next)
    }
}

@MainActor
@Observable
final class SpacePages {
    @ObservationIgnored private(set) var warm: Set<UUID> = [] { didSet { revision &+= 1 } }
    @ObservationIgnored private(set) var held: [UUID: Parked] = [:] { didSet { revision &+= 1 } }
    @ObservationIgnored private(set) var adopted: UUID? { didSet { revision &+= 1 } }
    private(set) var revision = 0
    @ObservationIgnored weak var browser: Browser?
    @ObservationIgnored private var pending: DispatchWorkItem?
    @ObservationIgnored private var waited = 0

    func watch() { _ = revision }

    func settle(after delay: TimeInterval = 0.25) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.step() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func adopt(_ id: UUID, row: Parked?, leaving: UUID) {
        waited = 0
        held[leaving] = nil
        guard let row else { return }
        held[id] = row
        adopted = id
        warm.insert(id)
        warm.insert(leaving)
    }

    private func step() {
        pending = nil
        guard let browser else { return }
        let busy = SpaceSwipe.shared.touching || browser.spaceMotion.moving || browser.spaceNext != nil
        if busy, waited < 10 {
            waited += 1
            return settle(after: 0.15)
        }
        waited = 0
        if busy, adopted == nil { return }
        if adopted != nil {
            adopted = nil
            return settle(after: 0.05)
        }
        let here = browser.spaceID
        if !browser.nearSpaces.isEmpty, held[here] == nil {
            held = [here: Parked(tabs: browser.tabs, active: browser.activeID, splits: browser.splits, groups: browser.tabGroups)]
            return settle(after: 0.05)
        }
        let wanted = browser.nearSpaces
        if let missing = wanted.first(where: { !warm.contains($0) }) {
            browser.preloadSpaces()
            warm.insert(missing)
            return settle(after: 0.05)
        }
        let kept = warm.intersection(wanted)
        if kept != warm { warm = kept }
        if held.count > 1 { held = held.filter { $0.key == here } }
    }
}

struct FootLight: Equatable {
    let lit: CGFloat

    init(here: Bool, next: Bool, going: Bool, progress: CGFloat) {
        let share = going ? min(1, max(0, progress)) : 0
        lit = here ? (next ? 1 : 1 - share) : (next ? share : 0)
    }

    var scale: CGFloat { 1 + 0.08 * lit }
    var saturation: CGFloat { lit }
    var ink: CGFloat { lit }
    func opacity(hovering: Bool) -> CGFloat { hovering ? 1 : 0.55 + 0.45 * lit }
}


final class SpaceLitView: NSView, SpaceFollowing {
    var here: Bool { didSet { if here != oldValue { relight() } } }
    var next: Bool { didSet { if next != oldValue { relight() } } }
    var going = true { didSet { if going != oldValue { relight() } } }
    var hovering = false { didSet { if hovering != oldValue { relight() } } }
    var size: CGFloat = 1 { didSet { if size != oldValue { relight() } } }
    var dot: CGFloat = 0 { didSet { if dot != oldValue { relight() } } }
    var bead: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let bead else { return }
            bead.wantsLayer = true
            bead.layer?.opacity = 0
            addSubview(bead)
            needsLayout = true
        }
    }
    var tint: ((CGFloat) -> Void)?
    let content: NSView

    private let motion: SpaceMotion
    private var shown: FootLight?
    private var shownHover = false
    private var shownSize: CGFloat = 1
    private var shownDot: CGFloat = 0
    static let beadSide: CGFloat = 14
    private let saturate = CIFilter(name: "CIColorControls")
    static let crossfade: CFTimeInterval = 0.15

    init(motion: SpaceMotion, content: NSView, here: Bool, next: Bool) {
        self.motion = motion
        self.content = content
        self.here = here
        self.next = next
        super.init(frame: .zero)
        wantsLayer = true
        content.wantsLayer = true
        content.layerUsesCoreImageFilters = true
        saturate?.name = "saturate"
        addSubview(content)
        motion.followers.add(self)
        relight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { content.intrinsicContentSize }

    override func layout() {
        super.layout()
        content.frame = bounds
        let side = Self.beadSide
        bead?.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        shown = nil
        relight()
    }

    func follow(_ motion: SpaceMotion) {
        relight()
    }

    private func relight() {
        let light = FootLight(here: here, next: next, going: going, progress: motion.progress)
        guard light != shown || hovering != shownHover || size != shownSize || dot != shownDot, let layer = content.layer else { return }
        let jumped = Motion.reduced && window != nil && abs(light.lit - (shown?.lit ?? light.lit)) > 0.5
        shown = light
        shownHover = hovering
        shownSize = size
        shownDot = dot
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if jumped {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Self.crossfade
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "lit")
        }
        let mid = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        self.layer?.sublayerTransform = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0),
                                                                                CATransform3DMakeScale(light.scale * size, light.scale * size, 1)), mid)
        layer.opacity = Swift.Float(light.opacity(hovering: hovering) * (1 - dot))
        bead?.layer?.opacity = Swift.Float((hovering ? 1 : 0.3 + 0.7 * light.lit) * dot)
        if light.saturation < 1, let saturate {
            if layer.filters?.isEmpty ?? true { layer.filters = [saturate] }
            layer.setValue(light.saturation, forKeyPath: "filters.saturate.inputSaturation")
        } else if !(layer.filters?.isEmpty ?? true) {
            layer.filters = nil
        }
        CATransaction.commit()
        tint?(light.ink)
    }
}
