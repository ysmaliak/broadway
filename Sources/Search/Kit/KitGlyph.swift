import AppKit

@MainActor
enum KitGlyph {
    static func image(_ name: String, _ style: KitSymbol.Style = .init(size: NSFont.systemFontSize, weight: .regular), label: String? = nil) -> NSImage? {
        named(KitSymbolCache.image(name, style) { made(name, style) }, label)
    }

    static func plain(_ name: String, label: String? = nil) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)
    }

    static func made(_ name: String, _ style: KitSymbol.Style) -> NSImage? {
        let shown = style.fill && NSImage(systemSymbolName: "\(name).fill", accessibilityDescription: nil) != nil ? "\(name).fill" : name
        var config = NSImage.SymbolConfiguration(pointSize: style.size, weight: style.weight, scale: style.scale)
        if !style.palette.isEmpty { config = config.applying(.init(paletteColors: style.palette)) }
        if style.hierarchical { config = config.applying(.preferringHierarchical()) }
        return NSImage(systemSymbolName: shown, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    static func ink(of image: NSImage, scale: Int = 4) -> NSRect {
        let whole = NSRect(origin: .zero, size: image.size)
        let wide = max(1, Int(ceil(image.size.width)) * scale), high = max(1, Int(ceil(image.size.height)) * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)
        else { return whole }
        rep.size = NSSize(width: CGFloat(wide) / CGFloat(scale), height: CGFloat(high) / CGFloat(scale))
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return whole }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: whole)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return whole }
        var minX = wide, maxX = -1, minY = high, maxY = -1
        for y in 0..<high {
            let row = data + y * rep.bytesPerRow
            for x in 0..<wide where row[x * 4 + 3] > 25 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return whole }
        let unit = CGFloat(scale)
        return NSRect(x: CGFloat(minX) / unit, y: CGFloat(high - 1 - maxY) / unit,
                      width: CGFloat(maxX - minX + 1) / unit, height: CGFloat(maxY - minY + 1) / unit)
    }

    private struct Drawn: Hashable {
        let name: String
        let size: CGFloat
        let weight: CGFloat
        let scale: Int
        let fill: Bool
        let hierarchical: Bool
        let backing: CGFloat
    }

    private static var drawn: [Drawn: NSRect] = [:]

    static func drawnInk(_ name: String, _ style: KitSymbol.Style, in view: NSImageView, backing: CGFloat) -> NSRect? {
        let key = Drawn(name: name, size: style.size, weight: style.weight.rawValue, scale: style.scale.rawValue,
                        fill: style.fill, hierarchical: style.hierarchical, backing: backing)
        if let known = drawn[key] { return known }
        let unit = max(1, Int(backing.rounded()))
        let wide = Int(ceil(view.bounds.width)) * unit, high = Int(ceil(view.bounds.height)) * unit
        guard wide > 0, high > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)
        else { return nil }
        rep.size = NSSize(width: CGFloat(wide) / CGFloat(unit), height: CGFloat(high) / CGFloat(unit))
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.bitmapData else { return nil }
        var columns = [Int](repeating: 0, count: wide), rows = [Int](repeating: 0, count: high)
        for y in 0..<high {
            let row = data + y * rep.bytesPerRow
            for x in 0..<wide {
                let alpha = Int(row[x * 4 + 3])
                columns[x] = max(columns[x], alpha)
                rows[y] = max(rows[y], alpha)
            }
        }
        guard let across = inkSpan(columns), let down = inkSpan(rows) else { return nil }
        let step = CGFloat(unit)
        let found = NSRect(x: across.lowerBound / step, y: down.lowerBound / step,
                           width: (across.upperBound - across.lowerBound) / step, height: (down.upperBound - down.lowerBound) / step)
        if drawn.count > 600 { drawn.removeAll() }
        drawn[key] = found
        return found
    }

    static func inkSpan(_ line: [Int]) -> ClosedRange<CGFloat>? {
        guard let most = line.max(), most > 0 else { return nil }
        let floor = most * 15 / 100
        guard let first = line.firstIndex(where: { $0 > floor }), let last = line.lastIndex(where: { $0 > floor }) else { return nil }
        let start = CGFloat(first + 1) - min(1, CGFloat(line[first]) / CGFloat(most))
        let end = CGFloat(last) + min(1, CGFloat(line[last]) / CGFloat(most))
        return start <= end ? start...end : nil
    }

    private static func named(_ image: NSImage?, _ label: String?) -> NSImage? {
        guard let label, let image, let copy = image.copy() as? NSImage else { return image }
        copy.accessibilityDescription = label
        return copy
    }
}
