import AppKit

extension Bench {
    @MainActor static func axPress(_ identifier: String, in window: NSWindow) -> String? {
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        var visited = Set<ObjectIdentifier>()
        func value(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue()
        }
        func find(_ node: Any, depth: Int = 0) -> NSObject? {
            guard depth < 50, let node = node as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if value(node, "accessibilityIdentifier") as? String == identifier { return node }
            var children = value(node, "accessibilityChildren") as? [Any] ?? []
            if let view = node as? NSView { children += view.subviews }
            if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
            for child in children {
                if let found = find(child, depth: depth + 1) { return found }
            }
            return nil
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard let button = find(window), button.responds(to: selector), let method = button.method(for: selector) else {
            return "is absent from its test window's accessibility tree"
        }
        let press = unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector) -> ObjCBool).self)
        return press(button, selector).boolValue ? nil : "did not accept its accessibility press"
    }
}
