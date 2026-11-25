import AppKit
import CoreImage
import QuartzCore

@MainActor
final class FloatTween: NSObject {
    private static var running: Set<FloatTween> = []

    private var link: CADisplayLink?
    private var clock: Timer?
    private let began = CACurrentMediaTime()
    private let duration: CFTimeInterval
    private let step: (CGFloat) -> Void
    private let done: () -> Void

    private init(duration: CFTimeInterval, step: @escaping (CGFloat) -> Void, done: @escaping () -> Void) {
        self.duration = duration
        self.step = step
        self.done = done
    }

    @discardableResult
    static func run(on view: NSView, duration: CFTimeInterval, step: @escaping (CGFloat) -> Void, done: @escaping () -> Void = {}) -> FloatTween {
        let tween = FloatTween(duration: duration, step: step, done: done)
        running.insert(tween)
        step(0)
        if view.window?.screen != nil {
            let link = view.displayLink(target: tween, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            tween.link = link
        } else {
            let clock = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak tween] _ in
                MainActor.assumeIsolated { tween?.tick() }
            }
            RunLoop.main.add(clock, forMode: .common)
            tween.clock = clock
        }
        return tween
    }

    @objc private func frame(_ link: CADisplayLink) { tick() }

    private func tick() {
        let seconds = (CACurrentMediaTime() - began) / FloatMotion.pace
        guard seconds < duration else { return finish() }
        step(CGFloat(seconds))
    }

    var moving: Bool { FloatTween.running.contains(self) }

    func finish() {
        guard FloatTween.running.contains(self) else { return }
        link?.invalidate()
        link = nil
        clock?.invalidate()
        clock = nil
        FloatTween.running.remove(self)
        step(CGFloat(duration))
        done()
    }

    func cancel() {
        link?.invalidate()
        link = nil
        clock?.invalidate()
        clock = nil
        FloatTween.running.remove(self)
    }

    nonisolated static func spring(_ seconds: CGFloat, omega: CGFloat, zeta: CGFloat) -> CGFloat {
        guard seconds > 0 else { return 0 }
        if zeta >= 1 { return 1 - (1 + omega * seconds) * exp(-omega * seconds) }
        let damped = omega * sqrt(1 - zeta * zeta)
        return 1 - exp(-zeta * omega * seconds) * (cos(damped * seconds) + zeta / sqrt(1 - zeta * zeta) * sin(damped * seconds))
    }

    nonisolated static func ease(_ value: CGFloat) -> CGFloat {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }
}

@MainActor
enum FloatMotion {
    static let rise: CGFloat = 64
    static let arriving: CFTimeInterval = 0.62
    static let flying: CFTimeInterval = 0.46
    static let sinking: CFTimeInterval = 0.3
    static let calm: CFTimeInterval = 0.18
    static var pace: CFTimeInterval = 1

    private(set) static var ghosts: [NSWindow] = []

    static func shape(_ layer: CALayer?, scale: CGFloat, blur: CGFloat) {
        guard let layer else { return }
        let bounds = layer.bounds
        let anchor = CGPoint(x: layer.anchorPoint.x * bounds.width, y: layer.anchorPoint.y * bounds.height)
        let shift = CGPoint(x: (bounds.midX - anchor.x) * (1 - scale), y: (bounds.midY - anchor.y) * (1 - scale))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = scale == 1 ? CATransform3DIdentity
            : CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), CATransform3DMakeTranslation(shift.x, shift.y, 0))
        if blur > 0.1, let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]) {
            layer.filters = [filter]
        } else {
            layer.filters = nil
        }
        CATransaction.commit()
    }

    static func arrive(_ window: NSWindow, ground: NSView) -> FloatTween? {
        let final = window.frame
        if Motion.calm {
            window.alphaValue = 0
            return FloatTween.run(on: ground, duration: calm, step: { t in
                window.alphaValue = FloatTween.ease(t / calm)
            }, done: {
                window.alphaValue = 1
            })
        }
        ground.layerUsesCoreImageFilters = true
        let shadowed = window.hasShadow
        let outline = window.contentView as? FloatOutline
        window.hasShadow = false
        outline?.shaped = false
        window.alphaValue = 0
        return FloatTween.run(on: ground, duration: arriving, step: { t in
            let p = FloatTween.spring(t, omega: 15, zeta: 0.78)
            let q = FloatTween.spring(t, omega: 17, zeta: 0.62)
            window.setFrameOrigin(NSPoint(x: final.minX, y: final.minY - rise * (1 - p)))
            window.alphaValue = FloatTween.ease(t / 0.2)
            shape(ground.layer, scale: 0.82 + 0.18 * q, blur: 16 * (1 - FloatTween.ease(t / 0.34)))
        }, done: {
            window.setFrameOrigin(final.origin)
            window.alphaValue = 1
            shape(ground.layer, scale: 1, blur: 0)
            outline?.shaped = true
            window.hasShadow = shadowed
        })
    }

    static func leave(from frame: NSRect, picture: CGImage?, shadow: Bool, home: @escaping () -> NSRect?) {
        let ghost = KitLitPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ghost.level = .floating
        ghost.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        ghost.backgroundColor = .clear
        ghost.isOpaque = false
        ghost.hasShadow = shadow && Motion.calm
        ghost.ignoresMouseEvents = true
        ghost.isReleasedWhenClosed = false
        ghost.isExcludedFromWindowsMenu = true

        let face = NSView(frame: NSRect(origin: .zero, size: frame.size))
        face.wantsLayer = true
        face.layerUsesCoreImageFilters = true
        face.autoresizingMask = [.width, .height]
        face.layer?.backgroundColor = NSColor.black.cgColor
        face.layer?.cornerRadius = FloatLayout.corner
        face.layer?.cornerCurve = .continuous
        face.layer?.masksToBounds = true
        face.layer?.contents = picture
        face.layer?.contentsGravity = .resizeAspectFill
        if Motion.calm {
            let outline = FloatOutline(frame: face.frame)
            outline.addSubview(face)
            ghost.contentView = outline
        } else {
            ghost.contentView = face
        }
        ghost.orderFrontRegardless()
        ghosts.append(ghost)

        func gone() {
            ghost.orderOut(nil)
            ghost.close()
            ghosts.removeAll { $0 === ghost }
        }

        if Motion.calm {
            FloatTween.run(on: face, duration: calm, step: { t in
                ghost.alphaValue = 1 - FloatTween.ease(t / calm)
            }, done: gone)
            return
        }

        DispatchQueue.main.async {
            if let target = home(), target.width > 20, target.height > 20 {
                fly(ghost, face: face, from: frame, to: target, done: gone)
            } else {
                sink(ghost, face: face, from: frame, done: gone)
            }
        }
    }

    private static func fly(_ ghost: NSWindow, face: NSView, from: NSRect, to: NSRect, done: @escaping () -> Void) {
        FloatTween.run(on: face, duration: flying, step: { t in
            let p = FloatTween.spring(t, omega: 14, zeta: 1)
            let rect = NSRect(
                x: from.minX + (to.minX - from.minX) * p,
                y: from.minY + (to.minY - from.minY) * p,
                width: from.width + (to.width - from.width) * p,
                height: from.height + (to.height - from.height) * p
            )
            ghost.setFrame(rect.integral, display: false)
            ghost.alphaValue = 1 - FloatTween.ease((t - 0.12) / 0.3)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            face.layer?.cornerRadius = FloatLayout.corner * (1 - 0.6 * p)
            CATransaction.commit()
        }, done: done)
    }

    private static func sink(_ ghost: NSWindow, face: NSView, from: NSRect, done: @escaping () -> Void) {
        FloatTween.run(on: face, duration: sinking, step: { t in
            let p = FloatTween.ease(t / sinking)
            ghost.setFrameOrigin(NSPoint(x: from.minX, y: from.minY - 22 * p))
            ghost.alphaValue = 1 - p
            shape(face.layer, scale: 1 - 0.1 * p, blur: 12 * p)
        }, done: done)
    }
}
