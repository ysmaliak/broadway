import AppKit

extension NSView {
    func kitMove(to frame: NSRect, animated: Bool, curve: KitCurve = Motion.kitSettle) {
        let snapped = kitSnapped(frame)
        guard self.frame != snapped else { return }
        guard animated, let layer else {
            self.frame = snapped
            return
        }
        let from = layer.presentation()?.position ?? layer.position
        let fromSize = layer.presentation()?.bounds.size ?? layer.bounds.size
        self.frame = snapped
        if from != layer.position, let animation = curve.animation("position", from: NSValue(point: from), to: NSValue(point: layer.position)) {
            animation.fillMode = .backwards
            layer.add(animation, forKey: "position")
        }
        if fromSize != layer.bounds.size,
           let animation = curve.animation("bounds.size", from: NSValue(size: fromSize), to: NSValue(size: layer.bounds.size)) {
            animation.fillMode = .backwards
            layer.add(animation, forKey: "bounds.size")
        }
    }

    func kitEnter(_ frame: NSRect) {
        self.frame = kitSnapped(frame)
        guard !Motion.reduced, let layer else { return }
        if let fade = KitCurve.easeOut(0.2).animation("opacity", from: Swift.Float(0), to: layer.opacity) {
            fade.fillMode = .backwards
            layer.add(fade, forKey: "enter.opacity")
        }
    }

    func kitRetire() {
        guard !Motion.reduced, superview != nil, let layer else {
            removeFromSuperview()
            return
        }
        let shown = layer.presentation() ?? layer
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shown.opacity
        fade.toValue = 0
        fade.duration = 0.14
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "retire.opacity")
        CATransaction.commit()
    }
}
