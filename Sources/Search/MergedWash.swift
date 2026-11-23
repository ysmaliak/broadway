import AppKit
import QuartzCore

enum MergedForm: String {
    case full, follow, quiet, still
}

@MainActor
enum MergedCrowd {
    static let gap: CFTimeInterval = 0.35
    private static var last: CFTimeInterval = -.infinity

    static func first(now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        defer { last = now }
        return now - last > gap
    }

    static func forget() { last = -.infinity }
}

final class MergedCanvas: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
enum MergedMotion {
    static let key = "merged"
    static let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "backgroundColor": NSNull(),
                                            "transform": NSNull(), "colors": NSNull(), "cornerRadius": NSNull()]

    static func play(_ layer: CALayer, _ keyPath: String, from: Any, to: Any, lasts: CFTimeInterval,
                     timing: CAMediaTimingFunctionName = .easeOut) {
        let move = CABasicAnimation(keyPath: keyPath)
        move.fromValue = from
        move.toValue = to
        move.duration = lasts
        move.timingFunction = CAMediaTimingFunction(name: timing)
        add(move, to: layer, keyPath)
    }

    static func add(_ move: CAAnimation, to layer: CALayer, _ name: String) {
        layer.add(move, forKey: key + "." + name)
    }

    static func stop(_ layer: CALayer?) {
        guard let layer else { return }
        for name in layer.animationKeys() ?? [] where name.hasPrefix(key + ".") { layer.removeAnimation(forKey: name) }
    }
}

enum MergedInk {
    static func lab(_ c: ChecksTint.RGB) -> (Double, Double, Double) {
        func line(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = line(c.r), g = line(c.g), b = line(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func apart(_ a: ChecksTint.RGB, _ b: ChecksTint.RGB) -> Double {
        let x = lab(a), y = lab(b)
        return ((x.0 - y.0) * (x.0 - y.0) + (x.1 - y.1) * (x.1 - y.1) + (x.2 - y.2) * (x.2 - y.2)).squareRoot()
    }

    static func mix(_ ground: ChecksTint.RGB, _ colour: ChecksTint.RGB, _ share: Double) -> ChecksTint.RGB {
        let a = min(1, max(0, share))
        return (ground.r + (colour.r - ground.r) * a, ground.g + (colour.g - ground.g) * a, ground.b + (colour.b - ground.b) * a)
    }

    static func fit(_ start: Oklch, on grounds: [ChecksTint.RGB], dark: Bool, least: Double = ChecksTint.minimum) -> Oklch {
        var best = start
        var top = ChecksTint.worst(start, on: grounds)
        guard top < least else { return start }
        for way in [dark ? 0.01 : -0.01, dark ? -0.01 : 0.01] {
            for step in 1...99 {
                let l = start.l + Double(step) * way
                guard l > 0, l < 1 else { break }
                let out = Paint.gamut(Oklch(l: l, c: start.c, h: start.h))
                let found = ChecksTint.worst(out, on: grounds)
                if found >= least { return out }
                if found > top {
                    top = found
                    best = out
                }
            }
        }
        return best
    }
}

struct MergedScene {
    var bounds: NSRect
    var radius: CGFloat
    var ink: Oklch
    var under: ChecksTint.RGB
    var side: ChecksTint.RGB
    var pill: ChecksTint.Pill
    var dark: Bool

    var tint: NSColor { ink.color }
    var strength: Double { MergedWash.strength(under: under, side: side, ink: ink, pill: pill, dark: dark) }
    var ground: ChecksTint.RGB { MergedInk.mix(under, ChecksTint.rgb(ink), strength) }
    var glyph: Oklch { MergedInk.fit(ink, on: [ground, under], dark: dark) }
}

@MainActor
final class MergedWash {
    static let sweep: CFTimeInterval = 0.5
    static let fade: CFTimeInterval = 0.2

    private let canvas = MergedCanvas()
    private let fill = CALayer()
    private let crest = CAGradientLayer()
    private(set) var fading = false

    var layers: [CALayer] { canvas.superview == nil ? [] : [fill, crest] }
    var frame: NSRect { canvas.frame }

    nonisolated static let most = 0.6

    nonisolated static func plain(dark: Bool) -> Double { dark ? 0.22 : 0.14 }

    nonisolated static func lit(dark: Bool) -> Double { dark ? 0.36 : 0.27 }

    nonisolated static func strength(under: ChecksTint.RGB, side: ChecksTint.RGB, ink: Oklch, pill: ChecksTint.Pill, dark: Bool) -> Double {
        guard pill != .none, pill != .hover else { return plain(dark: dark) }
        let colour = ChecksTint.rgb(ink)
        let least = MergedInk.apart(MergedInk.mix(side, colour, plain(dark: dark)), side)
        var share = lit(dark: dark)
        while share < most {
            let washed = MergedInk.mix(under, colour, share)
            if MergedInk.apart(washed, side) >= least, MergedInk.apart(washed, under) >= least { return share }
            share += 0.01
        }
        return most
    }

    func wear(_ scene: MergedScene, in face: NSView, below content: NSView, form: MergedForm) {
        face.addSubview(canvas, positioned: .below, relativeTo: content)
        canvas.layer?.masksToBounds = true
        canvas.layer?.cornerCurve = .continuous
        canvas.layer?.actions = MergedMotion.still
        crest.startPoint = CGPoint(x: 0, y: 0.5)
        crest.endPoint = CGPoint(x: 1, y: 0.5)
        crest.opacity = 0
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        for layer in [fill, crest] {
            layer.actions = MergedMotion.still
            canvas.layer?.addSublayer(layer)
        }
        fit(scene)
        switch form {
        case .full, .follow:
            MergedMotion.play(fill, "transform.scale.x", from: 0, to: 1, lasts: Self.sweep)
            guard form == .full else { break }
            let run = CABasicAnimation(keyPath: "position.x")
            run.fromValue = -crest.bounds.width / 2
            run.toValue = scene.bounds.width + crest.bounds.width / 2
            let show = CAKeyframeAnimation(keyPath: "opacity")
            show.values = [1, 1, 0]
            show.keyTimes = [0, 0.7, 1]
            let pass = CAAnimationGroup()
            pass.animations = [run, show]
            pass.duration = Self.sweep * 1.25
            pass.timingFunction = CAMediaTimingFunction(name: .easeOut)
            MergedMotion.add(pass, to: crest, "crest")
        case .quiet:
            if let layer = canvas.layer { MergedMotion.play(layer, "opacity", from: 0, to: 1, lasts: 0.22) }
        case .still:
            break
        }
    }

    func fit(_ scene: MergedScene) {
        guard !fading else { return }
        canvas.frame = scene.bounds
        canvas.layer?.cornerRadius = scene.radius
        let box = canvas.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.bounds = box
        fill.position = CGPoint(x: 0, y: box.midY)
        fill.backgroundColor = scene.tint.withAlphaComponent(scene.strength).cgColor
        crest.bounds = CGRect(x: 0, y: 0, width: 96, height: box.height)
        crest.position = CGPoint(x: -48, y: box.midY)
        let glow = scene.tint.withAlphaComponent(scene.dark ? 0.30 : 0.22).cgColor
        crest.colors = [scene.tint.withAlphaComponent(0).cgColor, glow, scene.tint.withAlphaComponent(0).cgColor]
        CATransaction.commit()
    }

    func wane(done: @escaping () -> Void) {
        guard let layer = canvas.layer, canvas.superview != nil else {
            end()
            done()
            return
        }
        fading = true
        let from = (layer.presentation() ?? layer).opacity
        for part in [fill, crest, layer] { MergedMotion.stop(part) }
        canvas.alphaValue = 0
        let fading = CABasicAnimation(keyPath: "opacity")
        fading.fromValue = from
        fading.toValue = 0
        fading.duration = Self.fade
        fading.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fading.fillMode = .forwards
        fading.isRemovedOnCompletion = false
        MergedMotion.add(fading, to: layer, "opacity")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fading else { return }
                self.end()
                done()
            }
        }
    }

    func hold() {
        guard fading, let layer = canvas.layer else { return }
        fading = false
        let at = (layer.presentation() ?? layer).opacity
        MergedMotion.stop(layer)
        canvas.alphaValue = CGFloat(at)
    }

    func end() {
        fading = false
        for layer in [fill, crest, canvas.layer] { MergedMotion.stop(layer) }
        fill.removeFromSuperlayer()
        crest.removeFromSuperlayer()
        canvas.removeFromSuperview()
    }
}
