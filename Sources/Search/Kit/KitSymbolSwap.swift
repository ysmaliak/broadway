import AppKit

extension KitSymbol {
    func fade(to name: String, duration: CFTimeInterval = KitSwap.cross) {
        guard name != self.name else { return }
        if !Motion.reduced, window != nil, let layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: KitSwap.crossKey)
        }
        self.name = name
    }
}

extension NSImageView {
    var kitReplaces: Bool { !Motion.reduced && window != nil && image != nil }
}
