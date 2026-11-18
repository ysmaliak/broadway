import AppKit
import Symbols

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

    @discardableResult
    func kitReplace(with next: NSImage) -> ReplaceSymbolEffect? {
        guard kitReplaces else {
            image = next
            return nil
        }
        setSymbolImage(next, contentTransition: KitSwap.downUp)
        return KitSwap.downUp
    }
}
