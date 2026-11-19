import AppKit

@MainActor
enum BenchDisc {
    static func look(in window: NSWindow?) -> [[String: Any]] {
        CATransaction.flush()
        guard let root = window?.contentView else { return [] }
        return discs(under: root).compactMap(read)
    }

    static func sample(in window: @escaping () -> NSWindow?, count: Int, every: Double, answer: @escaping ([String: Any]) -> Void) {
        var frames: [[String: Any]] = []
        let started = CACurrentMediaTime()
        func take() {
            frames.append(["t": CACurrentMediaTime() - started, "discs": look(in: window())])
            guard frames.count < min(800, max(1, count)) else {
                answer(["frames": frames])
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + min(0.5, max(0.004, every))) { take() }
        }
        take()
    }

    private static func discs(under view: NSView) -> [NSView] {
        var found: [NSView] = []
        for child in view.subviews {
            if view is SwipeView || view is PageView, symbol(in: child) != nil, ring(in: child.layer) != nil {
                found.append(child)
            } else {
                found += discs(under: child)
            }
        }
        return found
    }

    private static func symbol(in view: NSView) -> KitSymbol? {
        if let symbol = view as? KitSymbol { return symbol }
        for child in view.subviews { if let symbol = symbol(in: child) { return symbol } }
        return nil
    }

    private static func glass(in view: NSView) -> KitGlass? {
        if let glass = view as? KitGlass { return glass }
        for child in view.subviews { if let glass = glass(in: child) { return glass } }
        return nil
    }

    private static func ring(in layer: CALayer?) -> CAShapeLayer? {
        guard let layer else { return nil }
        if let shape = layer as? CAShapeLayer, shape.lineWidth > 0, shape.path != nil { return shape }
        for child in layer.sublayers ?? [] { if let shape = ring(in: child) { return shape } }
        return nil
    }

    private static func shown(_ layer: CALayer) -> CALayer { layer.presentation() ?? layer }

    private static func scale(of layer: CALayer, upTo top: CALayer) -> CGFloat {
        var scale: CGFloat = 1
        var at: CALayer? = layer
        while let now = at, now !== top {
            let t = shown(now).transform
            scale *= sqrt(t.m11 * t.m11 + t.m12 * t.m12)
            if now !== layer {
                let s = shown(now).sublayerTransform
                scale *= sqrt(s.m11 * s.m11 + s.m12 * s.m12)
            }
            at = now.superlayer
        }
        return scale
    }

    private static func opacity(of layer: CALayer, upTo top: CALayer) -> CGFloat {
        var opacity: CGFloat = 1
        var at: CALayer? = layer
        while let now = at, now !== top {
            opacity *= CGFloat(shown(now).opacity)
            at = now.superlayer
        }
        return opacity
    }

    private static func components(_ color: CGColor?) -> [Double] {
        guard let color, let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let parts = srgb.components else { return [] }
        return parts.map { Double($0) }
    }

    private static func read(_ disc: NSView) -> [String: Any]? {
        guard let host = disc.superview, let hostLayer = host.layer, let symbol = symbol(in: disc), let glass = glass(in: disc),
              let glassLayer = glass.layer, let ring = ring(in: disc.layer), let window = disc.window else { return nil }
        let size = glass.bounds.width
        let scale = scale(of: glassLayer, upTo: hostLayer)
        let model = glass.convert(glass.bounds, to: nil)
        let hostRect = host.convert(host.bounds, to: nil)
        let layer = disc.layer.map(shown)
        let moved = layer.map { l -> CGPoint in
            guard let model = disc.layer else { return .zero }
            return CGPoint(x: l.position.x - model.position.x, y: l.position.y - model.position.y)
        } ?? .zero
        let flipped = hostLayer.isGeometryFlipped || host.isFlipped
        let centre = CGPoint(x: model.midX + moved.x, y: model.midY + (flipped ? -moved.y : moved.y))
        let half = size * scale / 2
        let left = centre.x - half - hostRect.minX
        let right = hostRect.maxX - (centre.x + half)
        let top = hostRect.maxY - (centre.y + half)
        let bottom = (centre.y - half) - hostRect.minY
        let glyphName = symbol.name
        let edge = glyphName.contains("left") ? "left" : glyphName.contains("right") ? "right" : "top"
        let gap = edge == "left" ? left : edge == "right" ? right : top
        let pathBox = ring.path?.boundingBoxOfPath ?? .zero
        let ringInGlass = ring.convert(pathBox, to: glassLayer)
        let glyphLayer = symbol.layer.map { opacity(of: $0, upTo: hostLayer) } ?? 1
        let turned = symbol.superview?.layer.map { l -> CGFloat in
            let t = shown(l).sublayerTransform
            return atan2(t.m12, t.m11)
        } ?? 0
        let hub = (disc as? GestureDisc)?.edge.hub ?? .zero
        let glyphMiddle = symbol.superview.map { holder -> CGPoint in
            let t = holder.layer.map { shown($0).sublayerTransform } ?? CATransform3DIdentity
            let mid = CGPoint(x: holder.bounds.midX + hub.x, y: holder.bounds.midY + hub.y)
            return CGPoint(x: mid.x * t.m11 + mid.y * t.m21 + t.m41 - mid.x, y: mid.x * t.m12 + mid.y * t.m22 + t.m42 - mid.y)
        } ?? .zero
        var ink: [Double] = []
        window.effectiveAppearance.performAsCurrentDrawingAppearance { ink = components(symbol.tint.cgColor) }
        var out: [String: Any] = [
            "edge": edge,
            "hostX": Double(hostRect.minX),
            "hostY": Double(window.frame.height - hostRect.maxY),
            "glyph": glyphName,
            "size": Double(size),
            "scale": Double(scale),
            "diameter": Double(size * scale),
            "gap": Double(gap),
            "left": Double(left), "right": Double(right), "top": Double(top), "bottom": Double(bottom),
            "hostWidth": Double(hostRect.width), "hostHeight": Double(hostRect.height),
            "centreX": Double(centre.x - hostRect.minX), "centreY": Double(hostRect.maxY - centre.y),
            "opacity": Double(opacity(of: glassLayer, upTo: hostLayer)),
            "glyphOpacity": Double(glyphLayer * symbol.alphaValue),
            "glyphSize": Double(symbol.style.size),
            "glyphWeight": Double(symbol.style.weight.rawValue),
            "glyphWidth": Double(symbol.intrinsicContentSize.width),
            "ringWidth": Double(ring.lineWidth),
            "ring": Double((ring.presentation() ?? ring).strokeEnd),
            "ringInset": Double(ringInGlass.minX - glassLayer.bounds.minX),
            "ringDiameter": Double(ringInGlass.width),
            "ringInk": components((ring.presentation() ?? ring).strokeColor),
            "ink": ink,
            "corner": Double(glass.cornerRadius),
            "tint": components(glass.tintColor?.cgColor),
            "turned": Double(turned),
            "glyphDrift": Double(hypot(glyphMiddle.x, glyphMiddle.y)),
            "clipped": host.clipsToBounds || hostLayer.masksToBounds,
        ]
        if let shared = disc as? GestureDisc {
            out["progress"] = Double(shared.progress)
            out["target"] = Double(shared.gap)
            out["glyphOff"] = Double(hypot(shared.pivot.x - shared.bounds.midX, shared.pivot.y - shared.bounds.midY))
        }
        return out
    }
}
