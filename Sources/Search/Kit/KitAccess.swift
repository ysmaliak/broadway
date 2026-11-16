import AppKit

extension NSView {
    @discardableResult
    func kitAccess(id: String? = nil, label: String? = nil, value: String? = nil, role: NSAccessibility.Role? = nil,
                   help: String? = nil, hidden: Bool = false) -> Self {
        if let id { setAccessibilityIdentifier(id) }
        if let role { setAccessibilityRole(role) }
        if let label { setAccessibilityLabel(label) }
        if let value { setAccessibilityValue(value) }
        if let help {
            toolTip = help
            setAccessibilityHelp(help)
        }
        setAccessibilityElement(!hidden && (label != nil || role != nil || isAccessibilityElement()))
        return self
    }

    func kitSubviews<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in ((view as? T).map { [$0] } ?? []) + view.kitSubviews(of: type) }
    }
}

extension NSStackView {
    static func kit(_ orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat = 0,
                    alignment: NSLayoutConstraint.Attribute? = nil, _ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.spacing = spacing
        if let alignment { stack.alignment = alignment } else { stack.alignment = orientation == .horizontal ? .centerY : .leading }
        stack.detachesHiddenViews = true
        stack.setHuggingPriority(.required, for: .horizontal)
        stack.setHuggingPriority(.required, for: .vertical)
        return stack
    }
}

extension NSView {
    func kitSnap(_ rect: NSRect) -> NSRect {
        let scale = window?.backingScaleFactor ?? 2
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.toNearestOrAwayFromZero) / scale }
        return NSRect(x: snap(rect.minX), y: snap(rect.minY), width: rect.width, height: rect.height)
    }
}

@MainActor
enum KitFocus {
    static var keyboardAccess: () -> Bool = { NSApp.isFullKeyboardAccessEnabled }

    static func takes(_ enabled: Bool) -> Bool {
        guard enabled, keyboardAccess() else { return false }
        guard let event = NSApp.currentEvent else { return true }
        return ![.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
    }

    static func presses(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        return flags.isEmpty && (event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 76)
    }
}
