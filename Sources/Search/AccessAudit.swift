import AppKit
import ObjectiveC

@MainActor
protocol AccessActing {
    var acting: Bool { get }
}

@MainActor
enum AccessAudit {
    private final class Marker {}
    private static let module = String(reflecting: Marker.self).prefix { $0 != "." } + "."

    struct Gap: Equatable {
        let kind: String
        let type: String
        let identifier: String
        let frame: NSRect
        let path: String
        let near: String

        var report: [String: Any] {
            ["kind": kind, "type": type, "id": identifier, "path": path, "near": near,
             "frame": [frame.minX, frame.minY, frame.width, frame.height].map { Double($0.rounded()) }]
        }
    }

    static let actingRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .disclosureTriangle, .link, .slider, .incrementor,
    ]

    static func gaps(in root: NSView) -> [Gap] {
        var found: [Gap] = []
        walk(root, labelledAbove: false, into: &found)
        return found
    }

    static func gaps(in window: NSWindow) -> [Gap] {
        guard let content = window.contentView else { return [] }
        return gaps(in: content.superview ?? content)
    }

    static func named(_ view: NSView) -> Bool {
        for text in [view.accessibilityLabel(), view.accessibilityTitle()] {
            if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        }
        if let button = view as? NSButton, !button.title.isEmpty || button.image?.accessibilityDescription?.isEmpty == false { return true }
        if let control = view as? NSControl, !(view is NSButton), !control.stringValue.isEmpty { return true }
        if let image = view as? NSImageView, image.image?.accessibilityDescription?.isEmpty == false { return true }
        return false
    }

    static let notButtons: Set<String> = [
        "PlusLayerView", "DownloadsLayerView", "SpaceDraftStageView", "InternalPageHolder", "OnboardingView",
        "ColumnDragStrip", "DragStripView", "ColumnEdgeGrip", "KitField", "KitTrackField", "QuickActionRowView",
    ]

    static func acts(_ view: NSView) -> Bool {
        if let view = view as? AccessActing { return view.acting }
        if notButtons.contains(String(describing: type(of: view))) { return false }
        let name = NSStringFromClass(type(of: view))
        if name.hasPrefix("NS") || name.hasPrefix("_NS") || name.contains("<") { return false }
        if view.gestureRecognizers.contains(where: { recognizer in
            guard recognizer is NSClickGestureRecognizer || recognizer is NSPressGestureRecognizer,
                  let target = recognizer.target, let action = recognizer.action else { return false }
            return ours(type(of: target), defines: action)
        }) { return true }
        if view is NSScrollView || view is NSClipView || view is NSScroller || view is NSTableView || view is NSTextView { return false }
        if view is NSControl { return false }
        return implements(type(of: view), #selector(NSView.mouseUp(with:)))
    }

    private static func implements(_ type: AnyClass, _ selector: Selector) -> Bool {
        var cursor: AnyClass? = type
        while let current = cursor, current != NSView.self {
            let name = NSStringFromClass(current)
            if !name.hasPrefix("NS"), !name.hasPrefix("_NS"), defines(current, selector) { return true }
            cursor = class_getSuperclass(current)
        }
        return false
    }

    private static func ours(_ type: AnyClass, defines selector: Selector) -> Bool {
        var cursor: AnyClass? = type
        while let current = cursor {
            if NSStringFromClass(current).hasPrefix(module), defines(current, selector) { return true }
            cursor = class_getSuperclass(current)
        }
        return false
    }

    private static func defines(_ type: AnyClass, _ selector: Selector) -> Bool {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(type, &count) else { return false }
        defer { free(methods) }
        return (0..<Int(count)).contains { method_getName(methods[$0]) == selector }
    }

    private static func walk(_ view: NSView, labelledAbove: Bool, into found: inout [Gap]) {
        guard !view.isHidden, view.alphaValue > 0.01 else { return }
        if view.frame.width < 1 || view.frame.height < 1, view.subviews.isEmpty { return }
        let element = view.isAccessibilityElement()
        let role = view.accessibilityRole()
        let hasName = named(view)
        if element, let role, actingRoles.contains(role), !hasName {
            found.append(gap("unlabelled", view))
        } else if !element, !labelledAbove, acts(view), !(view.superview.map(acts) ?? false) {
            found.append(gap("hidden from VoiceOver", view))
        }
        let covered = labelledAbove || (element && hasName && role.map(actingRoles.contains) == true)
        for child in view.subviews { walk(child, labelledAbove: covered, into: &found) }
    }

    private static func gap(_ kind: String, _ view: NSView) -> Gap {
        var chain: [String] = []
        var cursor: NSView? = view
        while let current = cursor, chain.count < 5 {
            chain.append(String(describing: type(of: current)))
            cursor = current.superview
        }
        let frame = view.window.map { _ in view.convert(view.bounds, to: nil) } ?? view.frame
        return Gap(kind: kind, type: String(describing: type(of: view)), identifier: view.accessibilityIdentifier(),
                   frame: frame, path: chain.joined(separator: " < "), near: nearby(view))
    }

    private static func nearby(_ view: NSView) -> String {
        var words: [String] = []
        func look(_ node: NSView, depth: Int) {
            guard depth < 4, words.count < 3 else { return }
            if let field = node as? NSTextField, !field.stringValue.isEmpty { words.append(field.stringValue) }
            if let symbol = node as? KitSymbol { words.append("symbol:" + symbol.name) }
            if let label = node.toolTip, !label.isEmpty { words.append("tip:" + label) }
            for child in node.subviews { look(child, depth: depth + 1) }
        }
        look(view, depth: 0)
        if words.isEmpty, let parent = view.superview { look(parent, depth: 2) }
        return words.prefix(3).joined(separator: " | ")
    }
}
