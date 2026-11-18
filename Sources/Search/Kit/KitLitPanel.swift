import AppKit

class KitLitPanel: NSPanel {
    static var benchHold = true
    static var asked = 0
    static var holds: Bool { !Store.testing || benchHold }

    var heldLit: Bool {
        guard KitLitPanel.holds, !styleMask.contains(.titled) else { return false }
        return standardWindowButton(.closeButton) == nil
    }

    @objc(_hasActiveAppearance) func litActiveAppearance() -> Bool {
        lit(NSSelectorFromString("_hasActiveAppearance"))
    }

    @objc(_hasActiveAppearanceIgnoringKeyFocus) func litActiveAppearanceIgnoringKeyFocus() -> Bool {
        lit(NSSelectorFromString("_hasActiveAppearanceIgnoringKeyFocus"))
    }

    private func lit(_ name: Selector) -> Bool {
        if Store.testing { KitLitPanel.asked += 1 }
        if heldLit { return true }
        guard NSPanel.instancesRespond(to: name), let made = NSPanel.instanceMethod(for: name) else { return false }
        typealias Ask = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(made, to: Ask.self)(self, name)
    }
}
