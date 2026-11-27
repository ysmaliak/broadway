import AppKit

@MainActor
enum BenchSideTree {
    static let verbs: Set<String> = ["sidetree"]

    static func run(_ request: [String: Any], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing, let content = browser.window?.contentView else { return answer(["error": "sidetree needs a window on a test run"]) }
        guard let column = content.kitSubviews(of: SideColumnView.self).first(where: { !$0.isHiddenOrHasHiddenAncestor }) else {
            return answer(["error": "no column is in the window"])
        }
        if request["hover"] != nil, let window = column.window {
            let at = request["hover"] as? [Double] ?? []
            KitHoverView.pointerStandIn = at.count == 2 ? (window, column.convert(NSPoint(x: at[0], y: at[1]), to: nil)) : nil
            content.kitSubviews(of: KitHoverView.self).forEach { $0.settleHover() }
        }
        column.layoutSubtreeIfNeeded()
        var said: [[String: Any]] = []
        walk(column, in: column, depth: 0, seen: 1, into: &said)
        let place = column.convert(column.bounds, to: nil)
        answer(["views": said, "column": list(NSRect(x: place.minX, y: content.bounds.height - place.maxY, width: place.width, height: place.height))])
    }

    private static func list(_ box: NSRect) -> [Double] {
        [box.minX, box.minY, box.width, box.height].map { (Double($0) * 100).rounded() / 100 }
    }

    private static func walk(_ view: NSView, in column: NSView, depth: Int, seen: Double, into said: inout [[String: Any]]) {
        guard !view.isHidden else { return }
        let layer = view.layer
        let shown = seen * (layer.map { Double($0.opacity) } ?? Double(view.alphaValue))
        guard shown > 0.01 else { return }
        var one: [String: Any] = ["d": depth, "k": String(describing: type(of: view)), "f": list(view.convert(view.bounds, to: column)),
                                  "o": (shown * 100).rounded() / 100]
        if view.visibleRect.isEmpty { one["out"] = true }
        if let layer {
            if layer.cornerRadius > 0 { one["r"] = Double(layer.cornerRadius) }
            if layer.backgroundColor != nil { one["fill"] = true }
        }
        if let label = view as? KitLabel {
            one["t"] = label.text
            one["n"] = Double(ceil(label.measure(width: .greatestFiniteMagnitude).width))
            one["s"] = Double(label.font.pointSize)
            if label.alignment == .center { one["al"] = "center" }
            if label.alignment == .right { one["al"] = "right" }
        } else if let symbol = view as? KitSymbol {
            one["t"] = symbol.name
        } else if let field = view as? NSTextField {
            one["t"] = field.stringValue
        } else if let name = view.accessibilityLabel(), !name.isEmpty {
            one["a"] = name
        }
        said.append(one)
        let backed = Set(view.subviews.compactMap { $0.layer }.map(ObjectIdentifier.init))
        for sub in layer?.sublayers ?? [] where !backed.contains(ObjectIdentifier(sub)) {
            walk(sub, of: view, in: column, depth: depth + 1, seen: shown, into: &said)
        }
        for sub in view.subviews { walk(sub, in: column, depth: depth + 1, seen: shown, into: &said) }
    }

    private static func walk(_ layer: CALayer, of view: NSView, in column: NSView, depth: Int, seen: Double, into said: inout [[String: Any]]) {
        guard !layer.isHidden, let host = view.layer else { return }
        let shown = seen * Double(layer.opacity)
        guard shown > 0.01 else { return }
        let drawn = layer.backgroundColor != nil || layer.contents != nil || layer is CAShapeLayer || layer is CAGradientLayer || layer is CATextLayer
        if drawn {
            var one: [String: Any] = ["d": depth, "k": "~" + String(describing: type(of: layer)), "f": list(view.convert(host.convert(layer.bounds, from: layer), to: column)),
                                      "o": (shown * 100).rounded() / 100]
            if layer.cornerRadius > 0 { one["r"] = Double(layer.cornerRadius) }
            if let name = layer.name { one["a"] = name }
            said.append(one)
        }
        for sub in layer.sublayers ?? [] { walk(sub, of: view, in: column, depth: depth + 1, seen: shown, into: &said) }
    }
}
