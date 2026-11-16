import AppKit

final class KitGlassCatch: KitFlippedView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        kitGlassOwner?.acceptsFirstMouse(for: event) ?? super.acceptsFirstMouse(for: event)
    }

    override var mouseDownCanMoveWindow: Bool { kitGlassOwner?.mouseDownCanMoveWindow ?? super.mouseDownCanMoveWindow }

    override func menu(for event: NSEvent) -> NSMenu? { kitGlassOwner?.menu(for: event) ?? super.menu(for: event) }
}

extension NSView {
    var kitGlassOwner: NSView? {
        var view = superview
        while let next = view {
            if next is NSGlassEffectView { return next.superview }
            view = next.superview
        }
        return nil
    }
}

extension NSGlassEffectView {
    var kitCatch: NSView {
        if let contentView { return contentView }
        let made = KitGlassCatch(frame: bounds)
        made.autoresizingMask = [.width, .height]
        contentView = made
        return made
    }

    func kitCatch(at point: NSPoint, in view: NSView) -> NSView? {
        guard effectIsInteractive, !isHiddenOrHasHiddenAncestor, bounds.contains(convert(point, from: view)) else { return nil }
        return kitCatch
    }
}
