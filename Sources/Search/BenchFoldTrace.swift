import AppKit

@MainActor
final class FoldTrace: NSObject {
    static let shared = FoldTrace()
    private static var headings: [UUID: Weak] = [:]
    private static var cards: [UUID: Weak] = [:]

    private struct Weak {
        weak var view: NSView?
    }

    static func track(heading: NSView, for id: UUID) {
        if headings[id]?.view !== heading { headings[id] = Weak(view: heading) }
    }

    static func track(card: NSView, for id: UUID) {
        if cards[id]?.view !== card { cards[id] = Weak(view: card) }
    }

    private static func shown(_ view: NSView?) -> CGRect? {
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let rect = view.convert(view.bounds, to: nil)
        let height = window.frame.height
        var top = height - rect.maxY, tall = rect.height
        if let layer = view.layer, let shown = layer.presentation(), let root = window.contentView?.superview?.layer,
           let rootShown = root.presentation() {
            let model = layer.convert(layer.bounds, to: root)
            let moved = shown.convert(shown.bounds, to: rootShown)
            let down = abs(model.minY - top) <= abs(model.minY - rect.minY)
            top += down ? moved.minY - model.minY : model.maxY - moved.maxY
            tall = moved.height
        }
        return CGRect(x: rect.minX, y: top, width: rect.width, height: tall)
    }

    private var link: CADisplayLink?
    private var started: CFTimeInterval = 0
    private var samples: [[String: Any]] = []
    private weak var browser: Browser?
    private weak var scroll: NSScrollView?

    static func run(_ ask: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        switch ask["action"] as? String {
        case "start":
            guard let window = browser.window ?? Links.window else { answer(["error": "foldtrace needs a window"]); return }
            shared.start(window, browser: browser)
            answer(["ok": true, "scroll": shared.scroll != nil])
        case "stop":
            answer(shared.stop())
        default:
            answer(["error": "foldtrace takes start or stop"])
        }
    }

    static func column(_ browser: Browser, in window: NSWindow) -> NSScrollView? {
        guard let frame = window.contentView?.superview else { return nil }
        let width = Double(browser.prefs.columnWidth), whole = Double(window.frame.width)
        let onRight = browser.prefs.sidePosition == .right
        func scrolls(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
        }
        let reach = width + 1 + (browser.folded ? 2 * Double(Metrics.floatGap) : 0)
        return scrolls(in: frame).filter { view in
            let rect = view.convert(view.bounds, to: nil)
            return rect.height > 60 && Double(rect.width) <= width + 1
                && (onRight ? Double(rect.minX) >= whole - reach : Double(rect.maxX) <= reach)
        }.max { $0.frame.height < $1.frame.height }
    }

    private func start(_ window: NSWindow, browser: Browser) {
        link?.invalidate()
        samples = []
        self.browser = browser
        scroll = FoldTrace.column(browser, in: window)
        started = CACurrentMediaTime()
        let made = window.displayLink(target: self, selector: #selector(tick(_:)))
        made.add(to: .main, forMode: .common)
        link = made
        sample()
    }

    @objc private func tick(_ link: CADisplayLink) { sample() }

    private func sample() {
        var shot: [String: Any] = ["t": (CACurrentMediaTime() - started) * 1000]
        if let scroll, let document = scroll.documentView {
            shot["offset"] = Double(scroll.contentView.bounds.minY)
            shot["shown"] = Double(scroll.contentView.layer?.presentation()?.bounds.minY ?? scroll.contentView.bounds.minY)
            shot["view"] = Double(scroll.contentView.bounds.height)
            shot["content"] = Double(document.frame.height)
            let far = NSRect(origin: NSPoint(x: scroll.contentView.bounds.minX, y: 1_000_000), size: scroll.contentView.bounds.size)
            shot["max"] = Double(scroll.contentView.constrainBoundsRect(far).minY)
            shot["drawn"] = Double(SideColumnView.measured["drawn"] ?? -1)
        }
        if let browser {
            var heads: [String: Double] = [:]
            var cards: [String: Double] = [:]
            for group in browser.tabGroups {
                if let frame = FoldTrace.shown(FoldTrace.headings[group.id]?.view) { heads[group.name] = Double(frame.minY) }
                if let frame = FoldTrace.shown(FoldTrace.cards[group.id]?.view) { cards[group.name] = Double(frame.height) }
            }
            shot["heads"] = heads
            shot["cards"] = cards
            if let root = browser.window?.contentView { shot["chips"] = FoldTrace.chips(in: root) }
        }
        samples.append(shot)
    }

    static func chips(in root: NSView) -> [[Double]] {
        guard let base = root.layer else { return [] }
        func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            view.subviews.flatMap { sub -> [T] in ((sub as? T).map { [$0] } ?? []) + all(type, in: sub) }
        }
        func shown(_ view: NSView) -> CGRect? {
            guard let layer = view.layer else { return nil }
            let drawn = layer.presentation() ?? layer
            return drawn.convert(drawn.bounds, to: base.presentation() ?? base)
        }
        func alpha(_ view: NSView) -> Double {
            var value = 1.0
            var layer = view.layer
            while let at = layer {
                value *= Double((at.presentation() ?? at).opacity)
                layer = at.superlayer
            }
            return value
        }
        func row(of view: NSView) -> NSView {
            var at: NSView? = view
            while let up = at, !(up is TabRowView) { at = up.superview }
            return at ?? view
        }
        let marks = all(RowMarkView.self, in: root).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { mark in
            shown(mark).map { ($0, alpha(row(of: mark))) }
        }
        return all(StackFoldButton.self, in: root).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { chip in
            guard let rect = shown(chip), alpha(chip) > 0.02 else { return nil }
            guard let mark = marks.min(by: { hypot($0.0.minX - rect.minX, $0.0.minY - rect.minY) < hypot($1.0.minX - rect.minX, $1.0.minY - rect.minY) })
            else { return nil }
            return [Double(rect.midX - mark.0.minX), Double(rect.midY - mark.0.minY), alpha(chip), mark.1, Double(rect.midY)]
        }
    }

    private func stop() -> [String: Any] {
        link?.invalidate()
        link = nil
        return ["samples": samples]
    }
}

@MainActor
final class PeekTrace: NSObject {
    static let shared = PeekTrace()

    private var link: CADisplayLink?
    private var called: CFTimeInterval = 0
    private var ticks: [(wall: Double, frame: Double, x: Double)] = []
    private var period: CFTimeInterval = 1.0 / 60
    private weak var scroll: NSScrollView?
    private var rigid: PeekRigid?

    static func run(_ ask: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard let window = browser.window ?? Links.window else { answer(["error": "peektrace needs a window"]); return }
        let toggle = ask["toggle"] as? Bool ?? false
        shared.start(window, browser: browser, out: toggle ? browser.folded : ask["out"] as? Bool ?? true, toggle: toggle,
                     rigid: ask["rigid"] as? Bool ?? false, seconds: ask["seconds"] as? Double ?? 0.6, answer)
    }

    private func start(_ window: NSWindow, browser: Browser, out: Bool, toggle: Bool, rigid watching: Bool, seconds: Double,
                       _ answer: @escaping ([String: Any]) -> Void) {
        link?.invalidate()
        ticks = []
        rigid = watching ? PeekRigid(window: window, docked: toggle) : nil
        scroll = FoldTrace.column(browser, in: window)
        let made = window.displayLink(target: self, selector: #selector(tick(_:)))
        made.add(to: .main, forMode: .common)
        link = made
        let before = place()
        called = CACurrentMediaTime()
        if toggle { browser.toggleFold() } else { browser.peek(out) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            link?.invalidate()
            link = nil
            var made = report(from: before, out: out)
            if let rigid { made["rigid"] = rigid.report() }
            rigid = nil
            answer(made)
        }
    }

    private func place() -> Double {
        guard let scroll else { return 0 }
        var slid: CGFloat = 0
        var view: NSView? = scroll
        while let at = view {
            if let card = at as? PeekSliding { slid += card.shift }
            view = at.superview
        }
        let x = Double(scroll.convert(scroll.bounds, to: nil).minX + slid)
        return x.isFinite ? x : 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        period = link.duration > 0 ? link.duration : period
        ticks.append(((CACurrentMediaTime() - called) * 1000, (link.timestamp - called) * 1000, place()))
        rigid?.sample(at: (link.timestamp - called) * 1000)
    }

    private func report(from before: Double, out: Bool) -> [String: Any] {
        let moving = ticks.indices.filter { abs(ticks[$0].x - (($0 == 0) ? before : ticks[$0 - 1].x)) > 0.01 }
        let first = moving.first
        let last = moving.last
        let frames = ticks.map(\.frame)
        let span = first.flatMap { f in last.map { Array(frames[max(0, f - 1)...$0]) } } ?? []
        let gaps = zip(span.dropFirst(), span).map { $0 - $1 }
        let budget = period * 1000
        return [
            "scroll": scroll != nil,
            "hz": period > 0 ? (1 / period).rounded() : 0,
            "from": before,
            "to": ticks.last?.x ?? before,
            "firstMoveMs": first.map { (ticks[$0].wall * 10).rounded() / 10 } as Any,
            "firstFrameMs": first.map { (ticks[$0].frame * 10).rounded() / 10 } as Any,
            "settleMs": last.map { (ticks[$0].frame * 10).rounded() / 10 } as Any,
            "movingTicks": moving.count,
            "missedFrames": gaps.reduce(0) { $0 + max(0, Int(($1 / budget).rounded()) - 1) },
            "worstGapMs": ((gaps.max() ?? 0) * 10).rounded() / 10,
            "path": ticks.prefix(40).map { [($0.frame * 10).rounded() / 10, ($0.x * 10).rounded() / 10] },
        ]
    }
}

@MainActor
final class PeekRigid {
    private weak var window: NSWindow?
    private let docked: Bool
    private var samples: [(t: Double, mover: CGFloat, lights: CGFloat?, seen: Bool, parts: [String: CGPoint])] = []
    private var keys: Set<String> = []
    private var sliding = 0
    private var cardShown = 0
    private var pending: [[Double]] = []

    init(window: NSWindow, docked: Bool) {
        self.window = window
        self.docked = docked
    }

    private static func all(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(all)
    }

    private static func shift(_ layer: CALayer?) -> CGFloat {
        guard let layer else { return 0 }
        let shown = layer.presentation() ?? layer
        return shown.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
    }

    private var mover: (frame: NSView, moving: NSView)? {
        guard let root = window?.contentView else { return nil }
        let views = Self.all(in: root)
        if docked {
            guard let column = views.first(where: { $0 is SideColumnView && !Self.inCard($0) }) else { return nil }
            return (column, column)
        }
        guard let card = views.compactMap({ $0 as? PeekCardView }).first else { return nil }
        return (card, card.host)
    }

    private static func inCard(_ view: NSView) -> Bool {
        var at = view.superview
        while let view = at {
            if view is PeekCardView { return true }
            at = view.superview
        }
        return false
    }

    private static func place(_ view: NSView, in top: NSView) -> CGPoint {
        var point = view.convert(view.bounds, to: top).origin
        var at: NSView? = view
        while let view = at, view !== top {
            if let layer = view.layer, let shown = layer.presentation() {
                point.x += shown.position.x - layer.position.x + shift(shown) - shift(layer)
                point.y += (shown.position.y - layer.position.y) * (view.superview?.isFlipped == true ? 1 : -1)
            }
            at = view.superview
        }
        return point
    }

    private func note(_ view: NSView) {
        for each in Self.all(in: view) {
            guard let layer = each.layer else { continue }
            var layers = [layer]
            while let next = layers.popLast() {
                for key in next.animationKeys() ?? [] {
                    let path = (next.animation(forKey: key) as? CAPropertyAnimation)?.keyPath ?? "?"
                    keys.insert("\(type(of: each)).\(key):\(path)")
                }
                layers += next.sublayers ?? []
            }
        }
    }

    func sample(at t: Double) {
        guard let window, let mover else { return }
        let views = Self.all(in: mover.moving)
        var parts: [String: CGPoint] = [:]
        for (name, kind) in [("helm", HelmView.self), ("title", SpaceTitlesView.self), ("address", SideAddressView.self)] as [(String, NSView.Type)] {
            guard let view = views.first(where: { type(of: $0) == kind }) else { continue }
            parts[name] = Self.place(view, in: mover.moving)
            note(view)
        }
        if docked, let root = window.contentView,
           Self.all(in: root).contains(where: { ($0 as? PeekCardView).map { !$0.isHidden && $0.host.alphaValue > 0 && ($0.layer?.presentation()?.opacity ?? 1) > 0 } ?? false }) {
            cardShown += 1
        }
        let moved = Self.shift(mover.moving.layer)
        if let layer = mover.moving.layer, !(layer.animationKeys() ?? []).isEmpty { sliding += 1 }
        let seen = !mover.frame.isHidden && mover.moving.alphaValue > 0 && (mover.moving.layer?.presentation()?.opacity ?? 1) > 0
        var lights: CGFloat?
        if !window.styleMask.contains(.fullScreen), let bar = window.standardWindowButton(.closeButton)?.superview, !bar.isHidden {
            if let layer = bar.layer, layer.presentation() == nil {
                pending.append([t, layer.isHidden ? 1 : 0, layer.animation(forKey: "fold") == nil ? 0 : 1])
            } else {
                lights = Self.shift(bar.layer)
            }
        }
        samples.append((t, moved, lights, seen, parts))
    }

    func report() -> [String: Any] {
        let seen = samples.filter(\.seen)
        guard let rest = samples.last else { return ["frames": 0] }
        var helm: CGFloat = 0
        var head: CGFloat = 0
        for sample in seen {
            for (name, point) in sample.parts {
                guard let final = rest.parts[name] else { continue }
                let off = max(abs(point.x - final.x), abs(point.y - final.y))
                if name == "helm" { helm = max(helm, off) } else { head = max(head, off) }
            }
        }
        let paired = seen.compactMap { sample in sample.lights.map { (sample.t, $0 - sample.mover) } }
        let worst = paired.max { abs($0.1) < abs($1.1) }
        func round(_ value: CGFloat) -> Double { (Double(value) * 100).rounded() / 100 }
        return [
            "frames": seen.count,
            "sliding": sliding,
            "cardShown": cardShown,
            "lightsUnrendered": pending,
            "helmDrift": round(helm),
            "headDrift": round(head),
            "lightsDrift": round(abs(worst?.1 ?? 0)),
            "lightsWorst": worst.map { [($0.0 * 10).rounded() / 10, round($0.1)] } ?? [],
            "lightsFrames": paired.count,
            "keys": keys.sorted(),
            "path": seen.prefix(30).map { [($0.t * 10).rounded() / 10, round($0.mover), $0.lights.map(round) ?? -9999] },
        ]
    }
}
